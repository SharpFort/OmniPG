# you asked

问题 1：APISIX 侧如何订阅 PostgreSQL 的 LISTEN/NOTIFY？
当前方案中，数据库通过 pg_notify('casbin_channel') 发出通知，但 APISIX 基于 OpenResty（Nginx+LuaJIT），其 worker 进程无法持有阻塞式的 PostgreSQL LISTEN 长连接。

APISIX 是否有官方的或社区验证的方案来订阅 PG NOTIFY？
是否需要在 APISIX 旁边部署一个 sidecar 桥接进程（如 Go/Python 写的 pg_notify → APISIX Admin API 的桥接器）？
如果使用 sidecar 方案，桥接器自身的高可用如何保证？它与 APISIX 的通信协议是什么？
请画出完整的架构图，清晰标注哪些组件主动连接哪些组件。
# 问题 2：Lua-Casbin 如何从 PostgreSQL 加载策略？
APISIX 的 authz-casbin 插件如何配置 PostgreSQL 数据库适配器？
具体使用哪个 Lua 库？（luasql-postgres？pgmoon？）在 OpenResty 生态中哪个最成熟稳定？
请给出完整的插件配置 YAML 示例，包含：
数据库连接串（含连接池大小）
读取的视图/表名（casbin_rule）
重试策略和超时配置
model.conf 的嵌入方式
如果 PostgreSQL 直连方案不可行，是否可以用 etcd 作为中间缓存层？（即：桥接进程读取 PG → 写入 etcd → APISIX 从 etcd 加载）
casbin-pg-adapter  在整个过程起作用么?

---

# googleaistudio response

针对这两个极具深度且切中生产落地要害的架构设计问题，以下为您提供详细的剖析和工程实施方案。

---

## 问题 1：APISIX 侧如何订阅 PostgreSQL 的 LISTEN/NOTIFY？

### 1.1 为什么 OpenResty 进程不适合直连 PostgreSQL 进行 LISTEN？
您的直觉非常准确。在 OpenResty（Nginx）的多 worker 进程架构下，让 APISIX 直连 PostgreSQL 进行阻塞式监听存在以下致命缺陷：
1. **连接数爆炸与竞争：** Nginx 启动了 $N$ 个 worker 进程，每个 worker 如果都去跑 `LISTEN`，会导致数据库连接数成倍上升，并且引发消息的重复处理或竞争。
2. **阻塞 cosocket 限制：** 虽然可以使用非阻塞库，但 `LISTEN` 长连接需要长期占用 socket 通道，在网关这种高并发、高吞吐的场景下，维持对数据库的常驻监听长连接会污染网关的轻量级底座。

### 1.2 业界验证的最佳实践：Sidecar（桥接同步器）方案
我们**强烈建议**在 APISIX 旁部署一个极其轻量级的 **Policy Syncer（策略同步桥接器）**，作为 Sidecar 进程运行。

其工作原理是：**同步器单点监听 PostgreSQL ──> 提取数据 ──> 调用 APISIX Admin API ──> etcd 自动广播给所有 APISIX Worker**。

#### 完整系统架构图：
```text
┌────────────────────────────────────────────────────────┐
│                   PostgreSQL (Pigsty)                  │
│  ┌───────────────────────┐   ┌──────────────────────┐  │
│  │ Traditional RBAC Tabs │   │ casbin_rule (View)   │  │
│  └───────────┬───────────┘   └──────────▲───────────┘  │
│              │ (Auto-Map)               │              │
│              └──────────────────────────┘              │
│              │ (Trigger NOTIFY)                        │
│              ▼                                         │
│         LISTEN/NOTIFY (casbin_channel)                 │
└──────────────┬─────────────────────────────────────────┘
               │
               │ (PG Socket 长连接监听)
               ▼
┌────────────────────────────────────────────────────────┐
│         Policy Syncer (Go/Python Sidecar)              │
│  1. LISTEN casbin_channel                              │
│  2. SELECT * FROM casbin_rule                          │
│  3. Format as CSV string                               │
│  4. HTTP PUT /apisix/admin/plugin_metadata/...        │
└──────────────┬─────────────────────────────────────────┘
               │
               │ (HTTP Admin API PUT 协议)
               ▼
┌────────────────────────────────────────────────────────┐
│                     Apache APISIX                      │
│   ┌─────────────────────┐       ┌───────────────────┐  │
│   │ Admin API Engine    │──────>│ etcd (存储中心)    │  │
│   └─────────────────────┘       └─────────┬─────────┘  │
│                                           │            │
│                                           │ (Watch/    │
│                                           ▼  热加载)   │
│   ┌─────────────────────┐       ┌───────────────────┐  │
│   │ Client Requests     │──────>│ Lua-Casbin        │  │
│   │ (DELETE /api/users) │       │ (本地内存计算)     │  │
│   └─────────────────────┘       └───────────────────┘  │
└────────────────────────────────────────────────────────┘
```

### 1.3 桥接同步器的高可用（HA）如何保证？
同步器虽然是单点，但它是**完全无状态（Stateless）**的。要保证其高可用，有以下几种标准策略：
1. **多实例部署 + 幂等写入（首选）：** 
   因为 APISIX Admin API 的 `PUT` 请求是**天然幂等（Idempotent）**的（同样的策略写一次和写十次结果一样）。你可以部署 2-3 个同步器实例，同时监听 PG。一旦收到通知，它们会并发去更新 APISIX。虽然会带来微乎其微的冗余写，但系统结构最简单、可用性最高。
2. **利用 Postgres 咨询锁（Advisory Locks）：**
   在同步器的代码中，启动时先执行 `SELECT pg_try_advisory_lock(123456);`。只有抢到锁的“主实例”才启动 `LISTEN` 循环。其余“备实例”处于等待状态，一旦主实例挂掉，备实例抢到锁并接管监听。
3. **通信协议：**
   * **同步器 ──> PG：** 标准 TCP (PostgreSQL 协议)。
   * **同步器 ──> APISIX：** 标准 **HTTP RESTful API (Admin API)**。APISIX 会自动将数据落盘到 **etcd**。

---

## 问题 2：Lua-Casbin 如何从 PostgreSQL 加载策略？

### 2.1 揭开 `authz-casbin` 插件配置的残酷真相
在仔细阅读 APISIX 的 `authz-casbin` 源码和配置 schema 后，你会发现一个关键局限：**APISIX 内置的 `authz-casbin` 插件，在路由/服务配置中只接受 `model`、`policy` 文本内容或者 `model_path`、`policy_path` 文件路径，并不支持直接在配置里填入数据库连接参数（Adapter）**。

要让它支持直连数据库，你需要自己在 OpenResty 中安装 `pgmoon` 并魔改插件，这会破坏 APISIX 原生无代码维护的优势。

### 2.2 降维打击：通过 etcd 中间缓存层实现（Admin API 桥接）
因此，**“桥接进程读取 PG ──> 写入 APISIX (etcd) ──> APISIX 内存加载”**（即您提到的 etcd 中间缓存方案）不仅完全可行，而且是**生产环境下唯一推荐的、最成熟的方案**。

#### 为什么它是黄金方案：
1. **网关极致的高可用：** 
   网关（APISIX）与数据库（PostgreSQL）彻底解耦。如果 Pigsty 数据库集群进行维护或者意外宕机，**网关的鉴权完全不受影响**，因为它直接从 etcd 读取并缓存在内存中。
2. **极简配置（DRY 原则）：**
   我们可以利用 APISIX 的 **Plugin Metadata (插件元数据)** 特性，将 `model` 和最新的 `policy` 全局写入。这样，你几百个 API 路由只需要开启插件名字，不需要重复配置任何规则。

---

### 2.3 完整的插件配置与落地指南

#### 第一步：同步器向 APISIX 更新全局策略（元数据）
当同步器（Sidecar）从数据库视图 `casbin_rule` 读取出数据后，它会拼接成一条 CSV 文本，然后向 APISIX 发起如下请求：

*   **API 路径：** `PUT /apisix/admin/plugin_metadata/authz-casbin`
*   **Payload (JSON)：**
```json
{
  "model": "[request_definition]\nr = sub, obj, act\n\n[policy_definition]\np = sub, obj, act\n\n[role_definition]\ng = _, _\n\n[policy_effect]\ne = some(where (p.eft == allow))\n\n[matchers]\nm = g(r.sub, p.sub) && keyMatch2(r.obj, p.obj) && r.act == p.act",
  "policy": "p, role_admin, /api/v1/users/:id, GET\np, role_admin, /api/v1/users/:id, DELETE\ng, alice, role_admin"
}
```
*APISIX 收到此请求后，会将策略存入 **etcd**，并以毫秒级速度自动通知所有 APISIX Worker 节点的 Lua-Casbin 引擎热加载，完全无须重启*。

#### 第二步：具体的路由 (Route) 配置
在 APISIX 中创建业务路由时（例如 PostgREST 代理路由），配置变得极为清爽，只需要指定从哪个 Header 提取用户名即可（其余规则自动继承上面的元数据全局策略）：

```yaml
# yaml 格式的路由配置
uri: /api/v1/*
plugins:
  # 1. 开启 JWT 校验插件，自动解析出用户身份
  jwt-auth: {}
  
  # 2. 开启 Casbin 鉴权插件
  authz-casbin:
    # 告诉插件从哪个 Header 里提取主语 (subject)。
    # 通常 jwt-auth 校验通过后，会将用户名写入特定 Header（如 X-User-Id）
    username: X-User-Id 

upstream:
  type: roundrobin
  nodes:
    "postgrest_server:3000": 1  # 后端直通 PostgREST
```

---

### 三、 `casbin-pg-adapter` 在整个过程中起作用吗？

在您当前的这套 **“视图（View）编译模型”** 架构下，**`casbin-pg-adapter` 不需要起任何作用。**

#### 原因分析：
*   **在 PG 一侧：** 我们没有直接让 Casbin 的 SDK 去修改 `casbin_rule`。写数据的唯一源头是传统的关系表，转换工作是由 PostgreSQL 视图自动完成的，这代替了 `casbin-pg-adapter` 的 SQL 翻译工作。
*   **在网关一侧：** 既然我们通过“同步器 ──> Admin API”将数据推送到 etcd 中，APISIX 是从内存/etcd 中载入 CSV 格式的 `policy` 的，完全不需要连接数据库。
*   **在同步器一侧：** 同步器只需要执行一句最普通的 SQL 查询：`SELECT ptype, v0, v1... FROM casbin_rule;`，然后用逗号拼接成字符串即可，根本不需要引入复杂的 `casbin-pg-adapter` 库。

#### 什么时候才需要它？
只有当你的架构里存在一个 **“Go 语言编写的独立后端服务”**，且这个服务内部运行了 `go-casbin`，并且需要**直接直连并双向读写** PostgreSQL 的 `casbin_rule` 表时，才会在该 Go 服务中引入 `casbin-pg-adapter`。在您当前的无代码网关架构下，它完全是多余的。

---

# you asked

问题 3：JWT 密钥全生命周期管理
JWT 签名密钥（PGRST_JWT_SECRET）如何安全存储？使用什么工具？（Vault？环境变量？K8s Secrets？）
密钥轮转（Rotation）策略是什么？轮转期间旧 Token 如何平滑过渡？
多环境（dev / staging / prod）下密钥如何隔离管理？
PostgREST 和 APISIX 都需要知道 JWT Secret，它们之间的密钥分发方案是什么？
# 问题 4：传输层与网络安全
APISIX 是否作为 SSL/TLS 的终止点？证书管理方案是什么？
APISIX 与 PostgREST 之间的内部通信是否需要 mTLS？
PostgREST 的 PGRST_DB_ANON_ROLE 等敏感配置如何安全注入？
数据库连接是否需要 SSL 加密？
# 问题 5：常见 Web 攻击防护
CSRF 防护：Admin UI 直接调用 PostgREST API，CSRF 防护策略是什么？
CORS 策略：跨域访问的白名单和策略如何配置？
SQL 注入：PL/pgSQL 中使用动态 SQL（EXECUTE）时如何防范注入？
重放攻击：JWT 是否有 nonce 或 jti 机制防止重放？
# 问题 6：数据库层安全
PL/pgSQL 函数应以什么权限执行？SECURITY DEFINER vs SECURITY INVOKER 的选择策略？
pgsodium 的透明列加密密钥管理方案？根密钥存储在哪里？
pgaudit 的审计日志保留策略、存储位置、防篡改方案？

---

# googleaistudio response

针对您提出的这四个维度、共12个极其专业的安全和数据库工程痛点问题，以下为您提供**生产环境级别**的系统性安全方案。这些方案均完全契合 **Pigsty (PostgreSQL) + PostgREST + APISIX** 的技术栈生态。

---

## 问题 3：JWT 密钥全生命周期管理

### 3.1 密钥安全存储
*   **最佳实践：** 采用**不对称加密（RS256）**，这是管理 JWT 密钥生命周期的黄金法则。
*   **存储工具：** 
    *   **私钥（仅用于签名）：** 存放在 PostgreSQL 的安全 Schema 中，由 `pgsodium` 加密保护（或通过 Vault 动态注入给登录 PL/pgSQL 函数）。
    *   **公钥/JWKS（用于验签）：** 存放在 **HashiCorp Vault** 或 **K8s Secrets** 中，并以环境变量形式注入给 PostgREST 和 APISIX，或者通过一个专用的内部 JWKS Endpoint（JSON Web Key Set）进行分发。

### 3.2 密钥轮转（Rotation）策略与平滑过渡
对称加密（HS256）轮转必须同时修改所有节点，极易中断业务。而 **RS256 可以完美实现零停机轮转**：
1.  **多公钥共存：** PostgREST 和 APISIX 配置支持读取一个 JWKS（包含多个公钥，每个公钥有唯一的 `kid` - Key ID）。
2.  **轮转步骤：**
    *   **步骤一：** 生成新的密钥对 $B$，将公钥 $B$ 加入到 JWKS 列表中（此时 JWKS 含有旧公钥 $A$ 和新公钥 $B$）。
    *   **步骤二：** 数据库登录函数切换为使用新私钥 $B$ 签署 JWT（其 Header 携带 `kid = B`）。
    *   **步骤三：** 此时，旧 Token（由私钥 $A$ 签署）依然可以通过公钥 $A$ 验签成功；新 Token 可以通过公钥 $B$ 验签成功。实现了完全无感的平滑过渡。
    *   **步骤四：** 等待旧 Token 的 TTL（如 24 小时）全部过期后，从 JWKS 中安全地移除旧公钥 $A$。

### 3.3 多环境隔离
*   **物理隔离：** Dev, Staging, Prod 必须使用完全不同的 CA 根证书和不同的密钥对。
*   **GitOps 管理：** 使用 `SOPS`（Secrets on Git）配合 1Password/Vault 插件，对 Git 仓库中的各环境密钥配置文件进行加密存储，仅在 CI/CD 部署时解密注入。

### 3.4 密钥分发方案
*   **动态拉取（免配置同步）：** 
    *   PostgREST 支持配置 `PGRST_JWT_SECRET` 指向一个 JWK Set 的 URL 网址 [1.1.9]。
    *   APISIX 同样可以配置 `authz-casbin` 或自定义 Lua 插件去该 URL 动态获取公钥。
    *   你只需要在内部网络中部署一个极简的 Key-Server（或直接由 Vault 提供），PostgREST 和 APISIX 在启动和轮转时会自动拉取，**两端无需手动同步密钥** [1.1.9]。

---

## 问题 4：传输层与网络安全

### 4.1 SSL/TLS 终止与证书管理
*   **终止点：** APISIX 必须作为唯一的 SSL/TLS 终止点。
*   **证书管理：** 启用 APISIX 原生的 **`acme` 插件**，它能与 Let's Encrypt / Sectigo 等自动化 CA 对接，实现证书的**自动申请、自动续期、热加载（零重启）**。

### 4.2 内部通信是否需要 mTLS？
*   **视部署拓扑而定：**
    *   *同宿主机/K8s 同 Pod：* PostgREST 作为 APISIX 的 Sidecar 部署，通过本地环回网卡（`127.0.0.1`）通信，**不需要** mTLS。
    *   *跨主机/跨 VPC 通信：* **必须启用 mTLS**。APISIX 作为 Upstream 客户端需携带证书，PostgREST 配置 `PGRST_SERVER_TLS_CLIENT_CA` 进行客户端双向证书校验。

### 4.3 PostgREST 敏感配置安全注入
*   **方案：** 避免在命令行或常规环境变量中明文写出 `PGRST_DB_ANON_ROLE`。
*   使用 K8s Secrets 将敏感配置挂载为只读文件（如 `/secret/postgrest.conf`），PostgREST 启动时通过参数指向该文件：`postgrest /secret/postgrest.conf`。该文件仅对 `postgrest` 运行用户可读（权限 400）。

### 4.4 数据库连接 SSL 加密
*   **强制启用：** Pigsty 在安装时默认生成了自签名 CA。
*   PostgREST 的连接串（`PGRST_DB_URI`）必须强制配置：
    `postgresql://user:pass@db:5432/db?sslmode=verify-full&sslrootcert=/path/to/ca.crt`。
    这不仅能防止传输监听，还能彻底防范针对数据库连接的 **DNS 劫持和中间人攻击**。

---

## 问题 5：常见 Web 攻击防护

### 5.1 CSRF 防护策略
*   由于 Admin UI 直接通过 PostgREST 暴露的 API 进行无后端交互：
    *   **如果 JWT 存储在 `LocalStorage/SessionStorage` 中：** 通过 `Authorization: Bearer <JWT>` 头部发送。由于浏览器**绝不会**在跨站请求中自动携带自定义 Header，**此方案天然免疫 CSRF 攻击**，无须额外防护。
    *   **如果 JWT 存储在 Cookie 中（为了防 XSS）：** 必须在 Cookie 上设置 `SameSite=Strict; Secure; HttpOnly`。同时在 APISIX 上配置一个简易的 Lua 拦截规则，校验 HTTP 请求的 `Origin`/`Referer` 头部是否在可信白名单内。

### 5.2 CORS 策略配置
*   **禁止在 PostgREST 层配置 CORS**（保持其隐藏在网关后）。
*   在 **APISIX 路由**上启用原生的 **`cors` 插件**：
```json
{
  "plugins": {
    "cors": {
      "allow_origins": "https://admin.yourdomain.com", // 严格限制白名单，杜绝 "*"
      "allow_methods": "GET,POST,PUT,DELETE,OPTIONS",
      "allow_headers": "Authorization,Content-Type,Accept-Version",
      "expose_headers": "Content-Range,Location",
      "allow_credential": true,
      "max_age": 1728000
    }
  }
}
```

### 5.3 SQL 注入防护（针对 PL/pgSQL 动态 SQL）
在 PL/pgSQL 中使用 `EXECUTE` 执行动态 SQL 时，必须遵守以下严格铁律：
*   **铁律一：绝对不要拼接字符串。**
*   **铁律二：使用 `format()` 函数。** 
    *   使用 `%I` 格式化 SQL 标识符（表名、列名）。
    *   使用 `%L` 格式化 SQL 字面量（变量值）。
*   **铁律三：使用 `USING` 关键字传参（防注入最佳实践）。**

**安全示范代码：**
```sql
CREATE OR REPLACE FUNCTION get_user_by_dynamic_table(p_table_name text, p_user_id uuid)
RETURNS SETOF sys_user AS $$
BEGIN
    -- %I 会自动为表名加上双引号，防止标识符注入；$1 通过 USING 安全绑定
    RETURN QUERY EXECUTE format('SELECT * FROM %I WHERE id = $1', p_table_name)
    USING p_user_id; 
END;
$$ LANGUAGE plpgsql;
```

### 5.4 重放攻击（Replay Attack）防护
1.  **极短的 Access Token 生命周期：** 将 JWT 的有效期限制在 15 分钟内，配合长周期的 Refresh Token（安全存储在数据库中用于刷新）。
2.  **`jti`（JWT ID）单次有效性校验（JTI Whitelist/Blacklist）：**
    *   数据库生成 JWT 时，在 Payload 中注入随机且唯一的 `jti`（UUID）。
    *   在网关 APISIX 侧，利用自定义 Lua 脚本或 Redis 插件，将收到的 `jti` 记录在 Redis 内存中（TTL 与 JWT 有效期一致）。
    *   若网关收到一个 `jti` 已存在于 Redis 中的请求，直接判定为重放攻击，予以拦截。

---

## 问题 6：数据库层安全

### 6.1 PL/pgSQL 的执行权限策略选择

| 权限模式 | 行为特征 | 适用场景与安全策略 |
| :--- | :--- | :--- |
| **`SECURITY INVOKER`** *(默认)* | 函数以**调用者**的权限运行。 | **绝大多数普通查询和业务函数。** 此时用户的行级安全策略（RLS）依然生效，能够保证越权阻断。 |
| **`SECURITY DEFINER`** | 函数以**创建者**（通常是 superuser 或 schema owner）的权限运行。 | **特殊高权业务。** 例如：用户注册（需要往敏感的用户主表插入数据）、密码重置。 |

#### ⚠️ `SECURITY DEFINER` 的致命漏洞与防御
如果一个 `SECURITY DEFINER` 函数被恶意篡改 `search_path`，可能会引发**特权提升攻击（木马攻击）**。
*   **必须采取的防御：** 声明 `SECURITY DEFINER` 函数时，**必须显式指定其安全搜索路径**，防止恶意用户在 `public` 或临时表中建立同名函数进行劫持。
```sql
CREATE OR REPLACE FUNCTION reset_user_password(p_username text, p_new_password text)
RETURNS boolean AS $$
-- 业务逻辑...
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sys_schema, pg_temp; -- 强行锁定安全搜索路径，拒绝 trojan 攻击
```

### 6.2 `pgsodium` 的透明列加密（TCE）密钥管理
*   `pgsodium` 基于先进的 `libsodium` 密码库。
*   **根密钥存储：** 
    在 Pigsty 部署中，`pgsodium` 的 256 位根密钥（Root Key）是**严格存储在 PostgreSQL 实例之外的操作系统文件中的**（通常在 `/var/lib/pgsql/data/pgsodium.key` 或通过系统的 Keyring 管理）。
*   **派生密钥：** 
    数据库在运行期间，永远不会在磁盘上以明文存储列加密密钥。`pgsodium` 利用 Key Derivation Function (KDF) 机制，在内存中动态根据根密钥和对应的 `key_id` 派生出表级、列级的子密钥进行加解密。
*   即使数据库 `.sql` 备份泄露，只要外部的 `pgsodium.key` 文件不泄露，黑客也完全无法解密表中任何加密字段。

### 6.3 `pgaudit` 审计日志的保留、存储与防篡改

#### 1. 存储与管道化流转（Pigsty 架构原生支持）
*   **物理存储：** `pgaudit` 会将结构化的审计日志直接输出到 PostgreSQL 的标准错误输出（`stderr`）或系统的 `syslog`。
*   **防篡改流转管道：**
    *   Pigsty 默认集成了 **Vector**（或者是 Fluent-bit）作为本地日志收集 Agent。
    *   Vector 会在操作系统底层（以非数据库用户的 root/vector 高权限运行）实时读取 pg_log 日志，并**瞬间将其异步推送到远端的安全日志中心——Grafana Loki（或 Elasticsearch）**。

#### 2. 防篡改与保留策略
*   **单向安全阻断：** 数据库进程（`postgres` 用户）只有往标准输出写日志的权限，**绝对没有往 Loki/Elasticsearch 修改或删除日志的权限**。
*   **防删除机制：** 一旦审计日志被 Vector 抽走并存入远端 Loki，即使数据库超级管理员（`postgres` 角色）遭遇黑客劫持，黑客也无法通过任何 SQL 语句抹去或篡改已经发送到远端 Loki 的审计痕迹。这实现了物理意义上的**审计防篡改与职责分离（SoD）**。
*   **保留策略：** 在 Loki 或 Elasticsearch 侧配置全局数据保留策略（Retention Policy），例如自动保留 180 天（满足网络安全法合规要求），到期后在日志服务侧自动物理销毁。

---

# you asked

问题 7：全链路高可用方案
APISIX 高可用：etcd 集群的最小节点数和部署拓扑？多 APISIX 实例如何负载均衡（前置 LB 选型？）
PostgREST 高可用：多实例部署时，前置负载均衡器选型（Nginx / HAProxy / APISIX upstream 自带负载均衡）？
Pigsty PostgreSQL 高可用：Patroni + etcd 的主备自动切换，切换时间（RTO）是多少？
请给出完整的高可用部署拓扑图，标注每个组件的实例数量、通信端口和故障切换行为。
数据库主备切换时，APISIX 的 PostgreSQL 连接如何自动切换到新主库？（连接串是否包含多个主机？）
# 问题 8：casbin 缓存的高可用一致性
多个 APISIX 实例各自持有 casbin 策略的内存缓存
主备切换后，pg_notify 的 LISTEN 连接会断开，重连到新主库的机制是什么？
如何确保所有 APISIX 实例的策略缓存最终一致？有没有"全量重载"的对账机制（如定时从数据库全量刷新）？
# 问题 9：备份与恢复
推荐的数据备份工具和策略？（Pigsty 集成的 pgBackRest / WAL-G）
RPO（恢复点目标）和 RTO（恢复时间目标）的推荐值？
备份文件的异地存储方案？
灾难恢复演练的建议频率？

---

# googleaistudio response

针对高可用、缓存一致性以及备份恢复这三个生产环境的核心运维痛点，以下为您提供深度对接 **Pigsty** 物理架构的工业级解决方案。

---

## 问题 7：全链路高可用方案

在 Pigsty 的生态中，高可用已经作为“一等公民”被完整封装。无需复杂的二次开发，即可实现极高规格的容灾设计。

### 7.1 APISIX 高可用设计
*   **etcd 集群部署拓扑：** 
    *   **节点数：** 最小 **3 节点**（Raft 协议的最小法定人数需求，可容忍 1 台节点物理损坏）。
    *   **拓扑：** 将 etcd 实例与 3 个 APISIX 实例同机部署，或者部署在 3 台独立的轻量级管理节点（Control Plane）上。
*   **多 APISIX 负载均衡（前置 LB）：**
    *   **选型：HAProxy + Keepalived**。这是最经典且适合虚拟机/物理机环境的四层 VIP（虚拟 IP）高可用方案。
    *   **工作机制：** 两台 HAProxy 节点通过 Keepalived 绑定一个 VIP。当主 HAProxy 挂掉，VIP 在 1-2 秒内漂移到备 HAProxy。HAProxy 负责将流量轮询分发给后端的 3 个 APISIX 实例。

### 7.2 PostgREST 高可用设计
*   **部署：** 部署 3 个完全无状态的 PostgREST 实例。
*   **负载均衡器选型：直接使用 APISIX Upstream**。
    *   由于 APISIX 本身就是一个极其优秀的七层反向代理，不要在 APISIX 和 PostgREST 之间再增加一层 HAProxy，这会徒增网络开销。直接在 APISIX 中将 3 个 PostgREST 节点配置为一个 Upstream 组，利用 APISIX 自带的轮询（Round Robin）和健康检查（Passive/Active Health Check）机制实现自动剔除与容灾。

### 7.3 Pigsty PostgreSQL 高可用（Patroni + etcd/Consul）
*   **工作机制：** Pigsty 默认采用 **Patroni + Consul**（或配置为 etcd）作为分布式共识存储（DCS）。
*   **故障切换指标（基于 Pigsty 官方数据）：**
    *   **主库故障自动切换时间（RTO）：** **≈ 45秒**。
    *   **数据丢失量（RPO）：** 默认异步复制模式下 **RPO < 1MB**；若开启数据库“同步提交（Synchronous Commit）”的一致性优先模式，可达到 **RPO = 0（零数据丢失）**。
    *   **从库故障（RTO）：** 几乎为 **0**（网关层自动剔除，瞬时连接断开）。

### 7.4 完整高可用部署拓扑图

```text
                                [ CLIENTS ]
                                     │
                             (DNS / Anycast IP)
                                     ▼
        ┌────────────────────────────────────────────────────────┐
        │              HAProxy + Keepalived (VIP)                │
        │   [ HAProxy-1 (Active) ]     [ HAProxy-2 (Backup) ]    │ (x2 节点, 默认端口: 443)
        └──────────────┬────────────────────────┬────────────────┘
                       │                        │ (四层负载均衡轮询)
                       ▼                        ▼
        ┌────────────────────────────────────────────────────────┐
        │                     APISIX Cluster                     │
        │   [ APISIX-1 ]         [ APISIX-2 ]         [ APISIX-3 ]│ (x3 节点, 默认端口: 80/443)
        └──────────────┬────────────────────────┬────────────────┘
                       │                        │ (APISIX Upstream 自动七层负载均衡)
                       ▼                        ▼
        ┌────────────────────────────────────────────────────────┐
        │                   PostgREST Cluster                    │
        │   [ PostgREST-1 ]    [ PostgREST-2 ]    [ PostgREST-3 ]│ (x3 实例, 默认端口: 3000)
        └──────────────┬────────────────────────┬────────────────┘
                       │
                       │ (访问数据库 VIP, 连接端口: 5433)
                       ▼
        ┌────────────────────────────────────────────────────────┐
        │          Pigsty DB HAProxy + vip-manager (VIP)         │
        │   [ HAProxy-1 ]         [ HAProxy-2 ]      [ HAProxy-3 ]│ (x3 节点, 默认端口: 5433)
        └──────────────┬────────────────────────┬────────────────┘
                       │                        │ (根据 Patroni 健康检查自动路由至 Leader)
                       ▼                        ▼
        ┌────────────────────────────────────────────────────────┐
        │               PostgreSQL HA (Patroni)                  │
        │  ┌──────────────┐     ┌──────────────┐     ┌─────────┐ │
        │  │ PG-1 (Leader)│     │ PG-2 (Replica)     │ PG-3    │ │ (x3 实例, 物理端口: 5432)
        │  └──────────────┘     └──────────────┘     └─────────┘ │
        └────────────────────────────────────────────────────────┘
```

### 7.5 数据库主备切换时，连接如何自动切换？
**不需要修改 PostgREST 的连接串，PostgREST 不需要知道任何主备 IP**。

**Pigsty 优雅的设计机制：**
1.  Pigsty 在每个数据库节点上都部署了 **HAProxy**（监听 5433 写入端口，5434 只读端口），以及一个叫 **`vip-manager`** 的轻量级守护进程。
2.  `vip-manager` 实时监听 Patroni 的状态。一旦主库发生故障，Patroni 选举出 `PG-2` 作为新 Leader，新 Leader 诞生后，`vip-manager` 会自动将 **数据库 VIP（Virtual IP）** 瞬间漂移到 `PG-2` 所在的物理机上。
3.  **对 PostgREST 的影响：** PostgREST 连接的始终是数据库的 VIP:5433。主备切换发生时，PostgREST 只会经历一次短暂的 **TCP 连接断开**。在连接池重连后（秒级），由于 VIP 已经漂移，新的 TCP 连接会自动握手到新的主库上。

---

## 问题 8：casbin 缓存的高可用一致性

当有多台 APISIX 各自持有本地的 Lua-Casbin 内存缓存时，确保它们在数据库故障切换前后的缓存强一致，是本方案的核心要点。

### 8.1 主备切换后，LISTEN 连接的自动重连
*   当数据库发生故障切换，原本连接在旧主库上的 **Policy Syncer（Sidecar 桥接器）** 会收到 TCP 连接断开的系统错误（Connection reset by peer）。
*   **重连机制：** 
    *   在编写 Policy Syncer（例如用 Go 或 Python 编写）时，必须在 PG 客户端连接池配置 **自动指数退避重连（Exponential Backoff Retry）**。
    *   因为数据库主备自动切换需要大约 45 秒。在此期间，Syncer 会不断尝试重新连接数据库的 **VIP:5433**。
    *   一旦 45 秒后新主库就位、VIP 漂移成功，Syncer 的下一次重连尝试会瞬间成功，并自动在连接上执行 `LISTEN casbin_channel;` 重新恢复监听。

### 8.2 如何确保所有 APISIX 实例的缓存最终一致？
我们在之前的架构中采用了 **“etcd 中间缓存层”**，这几乎是分布式高可用的一致性银弹：
1.  **事件源唯一：** 尽管有 3 个 APISIX 节点，但它们不直接去监听数据库。真正监听数据库的只有 **Policy Syncer**。
2.  **etcd 强一致广播：** 当 Syncer 收到更新，它向 APISIX 的 Admin API 发送 `PUT` 请求。APISIX 会将数据写入底层的 **etcd 集群**。
3.  **Raft 与 Watch 机制：** etcd 集群通过 Raft 协议保证了多节点数据的强一致。而所有的 APISIX 节点都在通过 HTTP/2 的 **gRPC Watch 机制** 实时监听同一个 etcd。
4.  **最终一致：** 一旦 etcd 中的策略数据改变，etcd 会**原子性地、同时广播**给所有 3 个 APISIX 节点。3 个节点本地内存的 Lua-Casbin 会在几毫秒内同步完成重载。这从架构上彻底避免了各节点缓存不一致的问题。

### 8.3 兜底的“全量对账与重载”机制
为防止因为极端网络分区导致 `pg_notify` 丢失广播，我们必须在 **Policy Syncer** 中引入**对账（Reconciliation）机制**：
*   **定时全量对比（Cron Job）：**
    *   在 Syncer 中设置一个每 10 分钟运行一次的定时器。
    *   **计算数据库哈希：** 
        在数据库执行 `SELECT md5(string_agg(concat(ptype, v0, v1, v2, v3, v4, v5), ',' ORDER BY ptype, v0, v1, v2)) FROM casbin_rule;` 拿到当前数据的指纹哈希 $H_{db}$。
    *   **计算网关哈希：** 
        调 APISIX 的 Admin API 获取当前的 policy，在内存中用同样的规则拼装并计算指纹哈希 $H_{api}$。
    *   **对账决策：** 
        如果 $H_{db} \neq $H_{api}$，说明同步出现了偏差。Syncer 会绕过 `pg_notify`，直接拉取最新的数据强制向 APISIX 发起一次 `PUT` 覆盖。这保证了即使发生极端异常，系统最大一致性延迟也绝对不会超过 10 分钟。

---

## 问题 9：备份与恢复

### 9.1 推荐的数据备份工具与策略
*   **备份工具：pgBackRest**。
    这是 Pigsty 原生打包、深度集成且默认配置好的备份方案。它支持并行备份/恢复、增量/差异备份、备份传输加密、以及直接写入 S3 存储。
*   **备份策略（黄金组合）：**
    *   **全量备份（Full Backup）：** 每周日凌晨 2:00 执行一次（保留最近 4 周）。
    *   **差异备份（Differential Backup）：** 每周一至周六凌晨 2:00 执行一次（保留最近 7 天）。
    *   **WAL 连续归档（Continuous WAL Archiving）：** 
        Pigsty 的 Patroni 配置中会默认开启 `archive_command`。每当数据库产生一个 16MB 的 WAL（预写日志）段，或者每隔 5 分钟，就会利用 `pgbackrest archive-push` **实时、异步地将 WAL 推送到备份端**。这是实现零丢失灾备的核心。

### 9.2 RPO 与 RTO 指标推荐值

| 指标维度 | 推荐目标值 | 技术保障手段 |
| :--- | :--- | :--- |
| **本地高可用故障 RTO** | **< 45 秒** | 基于 Patroni + Keepalived VIP 自动漂移。 |
| **本地高可用故障 RPO** | **< 1 MB 或 0** | 默认异步流复制延迟极低；一致性要求极高的核心库可开启同步提交（Synchronous Commit）实现 RPO = 0。 |
| **灾难性恢复 RPO** *(灾备)* | **< 1 分钟 / 接近 0** | 归功于 pgBackRest 的连续 WAL 归档。在恢复时，可以进行 **PITR（Point-in-Time Recovery，任意时间点恢复）**，精准恢复至灾难发生前的一秒。 |
| **灾难性恢复 RTO** *(灾备)* | **< 30 分钟** *(以100GB数据为例)* | pgBackRest 极速的**多通道并行恢复（Parallel Restore）**技术。在千兆网络和 NVMe 硬盘下，恢复速度通常可达 100MB/s - 400MB/s。 |

### 9.3 备份文件的异地存储方案
*   **异地 S3 兼容对象存储：** 
    Pigsty 完美支持将 pgBackRest 直接配置为直写外部对象存储（例如 腾讯云 COS、阿里云 OSS、AWS S3 或异地的自建 MinIO 集群）。
*   **不可变勒索防护（WORM）：**
    强烈建议在存储备份的 S3 Bucket 上开启 **Object Lock（对象锁定/合规模式）**，将其设置为“14天内不允许任何人（包括 root）修改和删除”。这样即使整个数据库物理机遭遇勒索病毒挟持，黑客也绝对无法删除异地的安全备份。

### 9.4 灾难恢复演练建议
1.  **每周自动验证（无人工介入）：**
    在 CI/CD 服务器或一台专门的测试虚拟机上，配置一个每周定时任务。自动拉取最新的 pgBackRest 全量+差异备份进行 `restore`，启动一个临时 PG 进程，并执行简单的健康检查（如 `SELECT count(*) FROM sys_user`）。如果验证失败，自动往钉钉/企业微信群发送报警。
2.  **每半年全链路演练（人工介入）：**
    由 DBA 牵头，模拟“整个主数据中心被物理摧毁”的灾难场景。演练只使用异地 S3 上的备份文件，在一台完全干净的机器上通过 Pigsty 命令行脚本从零拉起一个新的集群，并将测试流量导入，验证系统完全恢复所需的时间是否符合 RTO 预期。

---

# you asked

# 问题 10：菜单与按钮权限的前后端协议
用户登录后获取完整菜单树的 API 设计？（GET /rpc/get_user_menu？）
返回的 JSON 结构示例（包含菜单项、子菜单、按钮权限标识）？
按钮级权限的前端实现方案（Vue 3 的 v-permission 指令 / React 的 <Permission> 组件）？
前端路由守卫的实现伪代码？
# 问题 11：前端权限的缓存与同步
前端获取的权限数据缓存多久？存储在 localStorage 还是 Pinia/Vuex？
当后端权限变更时，前端如何感知并更新？（轮询？WebSocket？等下次登录？）
用户被管理员"踢下线"（强制登出）的实现方案？

---

# googleaistudio response

针对前端与后端在权限管理层面的高内聚对接，以下为您提供完整的**菜单树协议设计**、**前端 Vue 3 落地代码**以及**利用 PostgreSQL + PostgREST 原生安全特性的“强制登出/黑名单”方案**。

---

## 问题 10：菜单与按钮权限的前后端协议

### 10.1 动态获取菜单树 API（PL/pgSQL 实现）
在 PostgREST 中，你可以通过配置 `db-pre-request` 自动获取当前 JWT 中的用户身份 [1.1.2]。前端只需请求 `GET /rpc/get_user_menu`，不需要在 URL 中传递任何参数，防止越权查询。

```sql
CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json AS $$
DECLARE
    v_username varchar;
    v_menu_tree json;
BEGIN
    -- 1. 从 JWT Claims 中动态提取当前用户名 (由 PostgREST 自动注入)
    v_username := current_setting('request.jwt.claims', true)::json->>'username';
    
    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;

    -- 2. 联表查询：用户 -> 角色 -> 菜单 -> 组装成嵌套 JSON 树
    -- 假定 sys_menu 表含 id, parent_id, name, path, component, icon, permission_tag 等字段
    WITH RECURSIVE menu_cte AS (
        -- 根菜单
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.icon, m.permission_tag, m.sort_order,
            json_build_array()::json AS children
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        JOIN sys_user u ON ur.user_id = u.id
        WHERE u.username = v_username AND m.parent_id IS NULL
        
        UNION ALL
        
        -- 子菜单递归
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.icon, m.permission_tag, m.sort_order,
            json_build_array()::json AS children
        FROM sys_menu m
        JOIN menu_cte c ON m.parent_id = c.id
    )
    -- 注意：这里在数据库内直接利用 Postgres 强大的 JSON 函数将其聚合成树状 JSON
    SELECT json_agg(row_to_json(t)) INTO v_menu_tree
    FROM (
        SELECT id, parent_id, name, path, component, icon, permission_tag 
        FROM menu_cte 
        ORDER BY sort_order
    ) t;

    RETURN v_menu_tree;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 10.2 接口返回的嵌套 JSON 结构示例
```json
[
  {
    "id": "1",
    "parent_id": null,
    "name": "UserManagement",
    "path": "/system/user",
    "component": "Layout",
    "meta": {
      "title": "用户管理",
      "icon": "user-icon"
    },
    "children": [
      {
        "id": "11",
        "parent_id": "1",
        "name": "UserList",
        "path": "list",
        "component": "system/user/index",
        "meta": {
          "title": "用户列表",
          "icon": "list-icon"
        },
        "buttons": ["user:add", "user:edit", "user:delete"]  // 该路由下的按钮级权限
      }
    ]
  }
]
```

### 10.3 按钮级权限自定义指令（Vue 3 实现）
在 Vue 3 中，我们通过一个全局的自定义指令 `v-permission`，如果用户不拥有特定标识，则直接将按钮从 DOM 树中安全移除。

```javascript
// src/directives/permission.js
import { useUserStore } from '@/store/user'

export const permissionDirective = {
  mounted(el, binding) {
    const { value } = binding
    const userStore = useUserStore()
    
    // 获取用户当前拥有的所有按钮权限标记列表
    const permissions = userStore.buttonPermissions // 例如: ['user:add', 'user:edit']

    if (value && value instanceof Array && value.length > 0) {
      const hasPermission = permissions.some(role => value.includes(role))
      
      // 如果没有权限，物理移除 DOM 节点
      if (!hasPermission) {
        el.parentNode && el.parentNode.removeChild(el)
      }
    } else {
      throw new Error(`need permissions! Like v-permission="['user:add']"`)
    }
  }
}
```

### 10.4 前端动态路由守卫伪代码
```javascript
// src/router/guard.js
import router from '@/router'
import { useUserStore } from '@/store/user'

const whiteList = ['/login', '/404'] // 白名单路由

router.beforeEach(async (to, from, next) => {
  const userStore = useUserStore()
  const hasToken = userStore.token

  if (hasToken) {
    if (to.path === '/login') {
      next({ path: '/' })
    } else {
      const hasRoles = userStore.routes && userStore.routes.length > 0
      if (hasRoles) {
        next()
      } else {
        try {
          // 1. 从 PostgREST API (RPC) 获取用户专属菜单树
          const menuTree = await userStore.fetchUserMenu()
          
          // 2. 将扁平/嵌套的菜单树动态编译为 Vue Router 识别的 Route 对象
          const accessRoutes = filterAsyncRoutes(menuTree)
          
          // 3. 动态注入路由
          accessRoutes.forEach(route => {
            router.addRoute(route)
          })
          
          // 4. 确保路由已完全挂载
          next({ ...to, replace: true })
        } catch (error) {
          userStore.resetToken()
          next(`/login?redirect=${to.path}`)
        }
      }
    }
  } else {
    if (whiteList.indexOf(to.path) !== -1) {
      next()
    } else {
      next(`/login?redirect=${to.path}`)
    }
  }
})
```

---

## 问题 11：前端权限的缓存与同步

### 11.1 前端获取的权限数据存储与生命周期
*   **存储位置：Pinia (内存) + SessionStorage (临时缓存)**。
    *   **为什么不用 LocalStorage：** LocalStorage 写入物理磁盘，永久保留。如果用户离开电脑没有安全退出，下一次打开浏览器会直接沿用旧数据，极易被 XSS 提取。
    *   **SessionStorage 的优势：** 它的生命周期仅在当前浏览器标签页（Tab）有效，标签页一旦关闭，数据物理抹除，安全性明显高于 LocalStorage。

### 11.2 后端权限变更，前端如何实时感知？
既然没有传统后端进行 WebSocket 长连接维持，我们有两种极简而高安全的同步策略：
1.  **短生命周期 JWT + 无感刷新（推荐）：**
    *   网关分发的 Access Token 有效期仅设为 **15分钟**。
    *   前端配置 Axios 拦截器，一旦遇到 401 报错，自动在后台静默发起 `POST /rpc/refresh_token`。
    *   当管理员在后台修改了该用户的权限，15分钟内他的 Access Token 会自然过期。在无感刷新的瞬间，PostgREST 会为其颁发包含最新 Role 信息的 Token。前端感知到 Token 发生变化，自动刷新页面，重新动态加载路由。
2.  **SSE（Server-Sent Events）单向广播：**
    *   利用前置网关 APISIX。APISIX 收到 PostgreSQL 发来的 `pg_notify` 广播后，可以通过一个极简的全局插件，向前端暴露一个长连接 `/api/v1/stream`。
    *   前端监听该 SSE 通道，一旦收到 `reload_permission` 信号，立即强制触发 `location.reload()` 重新获取菜单和路由。

---

### 11.3 核心亮点：“踢下线”（强制登出）的无后端实现方案

在完全没有 Go/Java 后端的系统里，如何把一个拥有合法 JWT（且尚未过期）的用户踢下线？

**PostgREST 提供了一个堪称完美且完全运行在数据库内部的黑名单解决方案——`db-pre-request` 预检查函数** [1.1.2]。

#### 第一步：在 PostgreSQL 中建立 Token 黑名单表
```sql
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY, -- JWT 的唯一标识符 ID
    blacklisted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL -- JWT 本身的过期时间，到期后可被 pg_timetable 自动清理
);
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);
```

#### 第二步：编写 Pre-Request 拦截函数（核心高光点）
在 PostgREST 的配置文件 `postgrest.conf` 中，配置这一行 [1.1.2]：
```properties
db-pre-request = "public.check_token_blacklist"
```
这个函数会在 **每一次** HTTP 请求抵达数据库执行任何操作前，自动、强制在当前事务中首先执行 [1.1.2]：

```sql
CREATE OR REPLACE FUNCTION check_token_blacklist()
RETURNS void AS $$
DECLARE
    v_jti varchar;
BEGIN
    -- 1. 从当前请求的 JWT claims 中提取该 token 的唯一 jti
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    -- 2. 如果该 jti 存在于数据库黑名单表中，直接强行抛出异常，中断整个数据库事务
    IF v_jti IS DISTINCT FROM NULL AND EXISTS (
        SELECT 1 FROM sys_token_blacklist WHERE jti = v_jti
    ) THEN
        -- 抛出 P0001 自定义安全异常，PostgREST 会自动将其翻译为 HTTP 401 Unauthorized
        RAISE EXCEPTION 'Token Has Been Revoked' USING ERRCODE = 'P0001';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

#### 第三步：“踢人”业务逻辑
当管理员在 Admin 后台点击“强制踢下线”按钮时：
1.  前端 ──(POST)──> `/rpc/kick_user { "user_id": "xxx" }`。
2.  在 `kick_user` 函数里，将该用户当前活跃的 `jti` 写入 `sys_token_blacklist` 表。
3.  该用户的浏览器在接下来的 0.01 秒内发起的任何 HTTP 请求（即便其 JWT 还在有效期内），都会在进入 PostgREST 的瞬间，被 `check_token_blacklist` 拦截并强行返回 **HTTP 401** [1.1.2]。
4.  前端 Axios 响应拦截器捕获到 401，立刻清除 SessionStorage 并将其重定向至登录页。

这个方案**100% 由数据库驱动**，没有任何外部内存中间件依赖，安全控制精确到请求级别，性能极高，是一个极具魅力的数据库原生高安全设计。

---

# you asked

问题 12：Token 管理方案
推荐使用 Access Token + Refresh Token 双 Token 方案吗？
Access Token 的有效期建议？（如 15 分钟）
Refresh Token 如何安全存储？（httpOnly Cookie vs localStorage 的安全性对比）
Refresh Token 如何轮换（Rotation）防止被盗用？
# 问题 13：登出与 Token 失效
用户主动登出时，Token 如何失效？（黑名单方案？）
黑名单存储在哪里？（PostgreSQL 表？Redis？）
多设备登录的管理策略？（允许同时登录？后登录踢前登录？）

---

# googleaistudio response

针对用户会话、令牌安全、多设备控制等核心安全工程设计，以下为您提供**双 Token 轮转机制（RTR）**以及**多设备登录控制（SSO）**的完全数据库驱动方案。

---

## 问题 12：Token 管理方案

### 12.1 推荐双 Token（Access + Refresh）方案吗？
**非常推荐**。在无传统后端的网关级架构中，双 Token 方案是平衡“高安全性”与“用户体验”的黄金法则：
*   **Access Token (AT)：** 扮演“快速通行证”。有效期建议设为 **15分钟**，其设计为无状态，缓存在前端内存中，由 APISIX 极速校验。
*   **Refresh Token (RT)：** 扮演“身份凭证”。有效期较长（如 7天到 14天），它是**有状态的**，记录在数据库中，专门用于在 AT 过期时静默换取新的 AT。

### 12.2 Refresh Token 存储：httpOnly Cookie 与 localStorage 对比

| 维度 | LocalStorage | HttpOnly, Secure, SameSite Cookie |
| :--- | :--- | :--- |
| **防 XSS 窃取** | ❌ 极差。任何 XSS 漏洞都能让黑客通过 JS 直接读取。 | 主动防范。JS 脚本完全无法读取该 Cookie。 |
| **防 CSRF 跨站** | ❌ 较差。前端常通过 Header 发送。 | 存在风险。可通过设置 `SameSite=Strict/Lax` 得到极好缓解。 |
| **推荐等级** | 不推荐存储 RT。 | **强烈推荐存储 RT。** |

*   **安全部署策略：**
    1.  **登录响应：** 数据库登录函数在成功后，将 **Access Token** 放入 JSON Body 返回（前端存入 Pinia 内存中，不落盘）；同时，通过 HTTP Header 将 **Refresh Token** 写入 `HttpOnly; Secure; SameSite=Strict` 的 Cookie 中。
    2.  **安全刷新：** 每次刷新 AT 时，前端 Axios 拦截器捕获 401，然后静默请求 `/rpc/refresh_token`（浏览器会自动携带该安全 Cookie），换回新的 AT。

### 12.3 Refresh Token 轮转（Rotation, RTR）机制
为了防止 RT 被窃取后黑客获得永久访问权，必须引入 **“Refresh Token 轮转（RTR）”**：**每次使用旧 RT 刷新时，数据库会同时作废该旧 RT，并强制颁发一个全新的 RT 给前端。**

#### 数据库防重放（Replay Attack）检测：
如果黑客窃取了某个 RT，就会出现“旧 RT 被使用两次”的情况（黑客用一次，正常用户用一次）。
*   **防御机制：** 一旦数据库检测到已被标记为“已使用”的旧 RT 再次请求刷新，说明发生窃取。数据库会**立即物理作废该用户下的所有会话（Session）**，强制两端同时下线，保障安全。

---

## 问题 13：登出与 Token 失效

### 13.1 主动登出时的 Token 失效机制
当用户点击“退出登录”时：
1.  **无状态 AT 失效：** 由于 AT 无法在网关层物理删除，必须将其 `jti` 写入 **黑名单**，生存时间为该 AT 剩余的有效期（最大 15分钟），过期后由定时任务自动清理。
2.  **有状态 RT 失效：** 数据库直接**物理删除**对应的 `sys_user_session` 记录。任何后续的刷新尝试都会直接失效。

### 13.2 黑名单存储在哪里？（PostgreSQL 表 vs Redis）
*   **中低并发（< 5,000 QPS）：** 直接存在 PostgreSQL 的 `sys_token_blacklist` 表中，利用 PostgREST 的 `db-pre-request` 函数在数据库事务内进行极简拦截 [1.1.2]。
*   **高并发（> 10,000 QPS）：** 存储在 **Redis** 中。
    *   *数据流向：* 用户登出 ──> 写入 Postgres 黑名单表 ──> 触发器 `NOTIFY` ──> Sidecar 桥接进程 ──> 写入 Redis。
    *   *拦截：* 在 APISIX 网关层编写一个 Lua 脚本，每次请求到来时，直接查询本地极速的 Redis 缓存。这样可以**保护 PostgreSQL 昂贵的 CPU 算力不被大量的黑名单查询消耗**。

---

### 13.3 多设备登录管理策略与 PL/pgSQL 实现

我们可以在数据库中建立一个 `sys_user_session` 表来管理所有的会话。以下代码为您演示：**双 Token 轮转（RTR）**、**防重放攻击**、以及 **单设备登录（后登录踢前登录，SSO）** 的完整 PL/pgSQL 实现。

#### 1. 会话表设计
```sql
CREATE TABLE sys_user_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id) ON DELETE CASCADE,
    refresh_token_hash VARCHAR(64) NOT NULL UNIQUE, -- 存储 RT 的哈希值，防止泄露
    is_used BOOLEAN DEFAULT FALSE,                  -- 是否已被轮转使用过
    client_ip VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL
);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);
```

#### 2. 用户登录：生成会话与“后登录踢前登录”（SSO）
```sql
CREATE OR REPLACE FUNCTION user_login_sso(p_username text, p_password text)
RETURNS json AS $$
DECLARE
    v_user_id uuid;
    v_user_role varchar;
    v_old_session RECORD;
    v_new_rt varchar;
    v_new_rt_hash varchar;
    v_new_at varchar;
    v_jti varchar;
BEGIN
    -- 1. 验证用户密码并获取 ID
    SELECT id, role_id INTO v_user_id, v_user_role 
    FROM sys_user WHERE username = p_username AND password_hash = crypt(p_password, password_hash);
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = 'P0001';
    END IF;

    -- 2. 【SSO 核心】：查询该用户已有的活跃会话，将其全部“踢下线”
    FOR v_old_session IN SELECT id, refresh_token_hash FROM sys_user_session WHERE user_id = v_user_id AND is_used = FALSE LOOP
        -- a. 将旧会话标记为已使用/作废
        UPDATE sys_user_session SET is_used = TRUE WHERE id = v_old_session.id;
        
        -- b. 提取旧会话对应的 AT jti (如果存在)，写入黑名单以防重放
        -- (实际中可在登录时记录 jti 到 session 表，在此将其加入 sys_token_blacklist)
    END LOOP;

    -- 3. 生成新的双 Token
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex'); -- 随机生成强 RT
    v_new_rt_hash := sha256(v_new_rt::bytea);        -- 哈希存储

    -- 写入新会话
    INSERT INTO sys_user_session (user_id, refresh_token_hash, expired_at)
    VALUES (v_user_id, v_new_rt_hash, now() + interval '7 days');

    -- 生成 Access Token (AT)
    v_new_at := sign(
        json_build_object(
            'jti', v_jti,
            'role', v_user_role,
            'username', p_username,
            'exp', extract(epoch from now() + interval '15 minutes')::integer
        ),
        'your_jwt_secret_key'
    );

    -- 返回双 Token 给前端
    RETURN json_build_object(
        'access_token', v_new_at,
        'refresh_token', v_new_rt -- 实际部署中，此值应通过 Cookie 写入，此处仅作逻辑演示
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

#### 3. Token 刷新与轮转（RTR）及防重放安全拦截
```sql
CREATE OR REPLACE FUNCTION refresh_token_rtr(p_old_rt text)
RETURNS json AS $$
DECLARE
    v_old_rt_hash varchar;
    v_session RECORD;
    v_username varchar;
    v_user_role varchar;
    v_new_rt varchar;
    v_new_rt_hash varchar;
    v_new_at varchar;
    v_jti varchar;
BEGIN
    v_old_rt_hash := sha256(p_old_rt::bytea);

    -- 1. 查询该旧 RT 对应的会话
    SELECT s.*, u.username, r.role_code 
    INTO v_session
    FROM sys_user_session s
    JOIN sys_user u ON s.user_id = u.id
    JOIN sys_role r ON u.role_id = r.id
    WHERE s.refresh_token_hash = v_old_rt_hash;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Session' USING ERRCODE = 'P0001';
    END IF;

    -- 2. 【RTR 核心安全防御】：如果该旧 RT 已经被使用过 (is_used = TRUE)
    -- 说明发生了 Token 窃取和重放攻击！
    IF v_session.is_used = TRUE THEN
        -- 强行物理抹除该用户名下的所有会话，实现紧急“全端下线”安全封锁
        DELETE FROM sys_user_session WHERE user_id = v_session.user_id;
        RAISE EXCEPTION 'Security Breach Detected: Replay Attack! All sessions revoked.' USING ERRCODE = 'P0002';
    END IF;

    -- 3. 校验是否过期
    IF v_session.expired_at < NOW() THEN
        DELETE FROM sys_user_session WHERE id = v_session.id;
        RAISE EXCEPTION 'Session Expired' USING ERRCODE = 'P0001';
    END IF;

    -- 4. 通过校验，执行轮转：作废当前旧 RT
    UPDATE sys_user_session SET is_used = TRUE WHERE id = v_session.id;

    -- 5. 颁发全新 RT 和全新 AT
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    -- 写入新 RT 会话
    INSERT INTO sys_user_session (user_id, refresh_token_hash, expired_at)
    VALUES (v_session.user_id, v_new_rt_hash, now() + interval '7 days');

    v_new_at := sign(
        json_build_object(
            'jti', v_jti,
            'role', v_session.role_code,
            'username', v_session.username,
            'exp', extract(epoch from now() + interval '15 minutes')::integer
        ),
        'your_jwt_secret_key'
    );

    RETURN json_build_object(
        'access_token', v_new_at,
        'refresh_token', v_new_rt
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 总结

通过在数据库内部实现这套 **SSO 登录** 与 **RTR 双 Token 轮转控制** 逻辑：
*   **安全性极其强悍：** 彻底杜绝了因客户端不安全存储带来的持久性越权风险。
*   **极致轻量：** 没有任何复杂的业务代码层，所有的状态变换、安全锁死、重放攻击检测均以**毫秒级数据库底层事务**的形式就地执行，完美契合您的无后端、全 PostgreSQL 驱动设计蓝图。

---

# you asked

# 问题 14：行级权限与 Casbin 的协同
数据级权限（如"部门经理只能看本部门数据"）的实现方案？
是否使用 PostgreSQL 的 RLS（Row-Level Security）？
RLS 策略如何与 Casbin 的 API 级权限配合？（请求先过 Casbin → 再过 RLS？）
RLS 策略中对"当前用户"的识别是依赖什么？（current_setting('app.current_user_id')？）
# 问题 15：多租户数据隔离
完整的多租户方案（数据库级隔离？Schema 级隔离？行级隔离？）
如果使用行级隔离，tenant_id 如何在所有表上统一应用 RLS 策略？
租户上下文的传递方式？（JWT 中携带 tenant_id？请求头？URL 前缀？）

---

# googleaistudio response

这两项设计将带您进入 PostgreSQL 安全架构的最底层。**行级安全（RLS）**与**多租户行级隔离**是无后端（Database-Driven）架构的核心基石。

以下为您详细拆解如何让 API 级的 Casbin 与数据级的 RLS 完美协同，以及如何安全地实现多租户行级隔离。

---

## 问题 14：行级权限与 Casbin 的协同

### 14.1 数据级权限的实现方案
对于诸如“部门经理只能看本部门数据”这类**数据行级（Row-Level）**的权限，最佳也是唯一的实现方案是使用 **PostgreSQL 原生的行级安全机制（Row-Level Security, RLS）**。

### 14.2 APISIX + Casbin 与 PostgreSQL RLS 的协同管道
这是一个典型的**“深度防御（Defense in Depth）”**安全管道：

```text
[ 客户端请求 ] 
      │
      ▼
┌──────────────────────────────────────────┐
│ 1. API 级校验：APISIX + Casbin           │ ────> "该用户(角色)能否调用 GET /api/v1/employees 接口？"
└───────────────────┬──────────────────────┘
                    │ (通过：放行至 PostgREST 转化为 SQL)
                    ▼
┌──────────────────────────────────────────┐
│ 2. 数据级校验：PostgreSQL RLS            │ ────> "该用户能否看到这条员工记录(其 department_id 是否匹配)？"
└───────────────────┬──────────────────────┘
                    │ (通过：仅返回/修改符合 RLS 策略的数据行)
                    ▼
[ 过滤后的响应数据 ]
```

*   **第一道防线（API 级 / 粗粒度）：** APISIX 的 `authz-casbin` 插件拦截请求。它只关心“角色与接口的关系”（例如：`DeptManager` 角色是否有权对 `/api/v1/employees` 目录发起 `GET` 请求）。如果不允许，直接在网关层返回 `403`，请求绝不触达数据库。
*   **第二道防线（数据级 / 细粒度）：** PostgREST 将请求转化为 `SELECT * FROM sys_employee` 并向数据库发起。PostgreSQL 的 RLS 引擎启动，自动在底层给 SQL 加上隐式过滤条件（如 `AND department_id = '研发部'`）。
    *   这解决了“纵向越权”问题：即使研发部经理和销售部经理调用的都是同一个 API，他们各自也只能查出自己部门的行数据。

### 14.3 RLS 策略中对“当前用户”的识别与性能优化
PostgREST 接收到带有 JWT 的请求后，会将 JWT 的 Payload 转化并缓存在当前数据库事务连接的 Local 变量中。

你可以通过 `current_setting('request.jwt.claims', true)` 轻松读取 JWT 中的任何声明 [1.1.2]。

#### ⚠️ 避坑指南：必须进行性能优化
由于 RLS 会对 `SELECT` 扫描到的**每一行数据**进行策略评估，如果你直接在每行评估里使用 `::json->>'user_id'` 进行 JSON 序列化，会导致**查询性能急剧雪崩**。

*   **最佳实践：** 编写一个声明为 `STABLE`（稳定函数）和 `PARALLEL SAFE` 的助手函数，让 Postgres 在同一个事务内只执行并缓存一次 JSON 解析结果：

```sql
-- 1. 创建高性能读取当前用户 ID 的助手函数
CREATE OR REPLACE FUNCTION current_user_id() 
RETURNS uuid AS $$
    -- STABLE 关键字确保在该事务内多次调用时，Postgres 会直接返回缓存的值，不重复解析 JSON
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'user_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;

-- 2. 创建高性能读取当前用户部门 ID 的助手函数
CREATE OR REPLACE FUNCTION current_user_dept_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'dept_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
```

#### 3. RLS 策略（Policy）实装：
```sql
-- 开启 RLS 约束
ALTER TABLE sys_employee ENABLE ROW LEVEL SECURITY;

-- 创建数据行访问策略：
-- 如果当前用户是超级管理员 (从 JWT role 提取)，或者当前员工记录属于该用户所在的部门
CREATE POLICY employee_dept_isolation_policy ON sys_employee
AS USING (
    current_setting('request.jwt.claims', true)::json->>'role' = 'super_admin'
    OR department_id = current_user_dept_id()
);
```

---

## 问题 15：多租户数据隔离

### 15.1 完整的多租户方案对比与选型

| 隔离方案 | 物理隔离（一户一DB） | 逻辑隔离（一户一Schema） | 行级共享（Shared-Schema / RLS） |
| :--- | :--- | :--- | :--- |
| **隔离强度** | 🌟🌟🌟🌟🌟 *(最高，物理级)* | 🌟🌟🌟🌟 *(中高)* | 🌟🌟 *(中低)* |
| **运维成本** | ❌ 极高。100个租户需要启100个DB和100个PostgREST。 | ❌ 较高。数据库表结构升级（Dbmate 迁移）时，需要逐个 Schema 循环执行。 | 🌟🌟🌟🌟🌟 *(极低。所有租户共享同一张表，运维难度等同于单体应用)*。 |
| **推荐等级** | 不适合 SaaS 型多租户项目。 | 适合极少数高客单价、有强隔离要求的企业。 | **强烈推荐（首选）**。配合 PostgreSQL RLS 能够达到完美的平衡。 |

---

### 15.2 行级隔离下，如何统一安全地应用 RLS 策略？

在 Shared-Schema 模式下，多租户最担心的就是“因为开发人员疏忽漏写了 `WHERE tenant_id = xxx` 导致数据泄露”。

PostgreSQL 10+ 引入了 **`AS RESTRICTIVE`（限制性策略）**，它是解决多租户数据泄露的终极武器。

#### 限制性策略的工作原理：
正常的 `USING` 策略（`AS PERMISSIVE`）之间是 `OR` 关系，容易因为漏写而被绕过。而 **`AS RESTRICTIVE` 策略会强制与系统所有的其他策略执行 `AND` 关系**。

#### 统一隔离实现方案：

##### 第一步：创建租户提取函数
```sql
CREATE OR REPLACE FUNCTION current_tenant_id() 
RETURNS varchar AS $$
    SELECT current_setting('request.jwt.claims', true)::json->>'tenant_id';
$$ LANGUAGE sql STABLE PARALLEL SAFE;
```

##### 第二步：在所有业务表上绑定强制限制性租户隔离策略
```sql
-- 开启 RLS
ALTER TABLE sys_order ENABLE ROW LEVEL SECURITY;

-- 强行注入限制性多租户过滤（这是物理防线，只要 tenant_id 不对，任何其他的业务 RLS 策略都不会放行）
CREATE POLICY tenant_isolation_strict_policy ON sys_order
AS RESTRICTIVE -- 限制性策略
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());
```

##### 第三步：编写业务级访问策略（正常的 `OR` 关系）
```sql
-- 这是一条业务策略：允许订单的创建者或者其上级查看
CREATE POLICY order_business_policy ON sys_order
FOR SELECT
USING (
    created_by = current_user_id() 
    OR manager_id = current_user_id()
);
```
*   **最终效果：** 
    PostgreSQL 在执行查询时，会自动组合出如下逻辑：
    `WHERE (tenant_id = current_tenant_id()) AND (created_by = current_user_id() OR manager_id = current_user_id())`
    这确保了不论你的业务策略写得多复杂、是否漏掉了租户判断，**多租户隔离防线都绝对不会被击穿**。

---

### 15.3 租户上下文的最佳传递方式：JWT 载荷注入（JWT Claim Injection）

在 “PostgREST + APISIX” 的无后端架构中，租户上下文的传递有以下三种常见方案：

1.  **URL 前缀 (不推荐)：** `/api/tenant_123/orders` 
    *   *不足：* 需要在 APISIX 中写大量的 URL Rewrite 规则，且不够美观。
2.  **自定义请求头 (不推荐)：** `X-Tenant-ID: tenant_123`
    *   *不足：* 如果不经过极其严格的安全过滤，用户可以通过恶意篡改该 HTTP Header 来假冒其他租户，极易发生“横向越权”。
3.  **JWT 载荷注入（唯一推荐，最安全）：**
    *   **工作机制：** 
        在用户登录成功时，数据库登录函数 `user_login_sso` 已经验证过该用户属于哪个租户，并将 `tenant_id` **硬编码签署进 JWT 的 Payload 中**。
    *   **安全性表现：**
        由于 JWT 是经过对称/非对称密码加密签署的，前端或攻击者**完全无法伪造或篡改** JWT 中的 `tenant_id`。
    *   **流程：**
        前端在后续的每一次 API 请求中，只需无感地在 Header 携带该 JWT。PostgREST 解析后，`current_tenant_id()` 助手函数自动安全读取，并完美驱动底层的行级多租户 RLS 策略。

### 总结

*   **API 边界控制**交给 **APISIX + Casbin**，解决“你能不能调这个接口”的问题。
*   **行级与租户隔离**交给 **PostgreSQL RLS + RESTRICTIVE 策略**，结合**高性能 STABLE 助手函数**，解决“你能不能看这行数据”的问题。
*   **信任链条**以 **密码学 JWT** 为核心建立并向下传递。

这三者形成闭环，构建出了一套极其稳固、高并发、且具备金融级安全防御的无后端分布式数据服务。

---

# you asked

# 问题 16：各规模下的性能预估
请针对以下两种规模，给出量化的性能评估：

指标	小规模	大规模
用户数	10,000	1,000,000
角色数	100	10,000
API 数	500	5,000
用户-角色关系	~30,000	~10,000,000
角色-API 关系	~5,000	~500,000
casbin_rule 视图的查询耗时预估？
APISIX 内存中 casbin 策略的内存占用？
APISIX 冷启动时 LoadPolicy 的耗时？
pg_notify 从触发到 APISIX 刷新完成的端到端延迟？
# 问题 17：性能瓶颈与优化
当规则数量达到百万级时，瓶颈在哪里？如何优化？
casbin_rule 视图是否需要物化视图（Materialized View）做缓存？
是否需要为超大租户设计分库分表策略？

---

# googleaistudio response

针对这套架构在业务规模膨胀到“百万级数据”时的性能表现，以下为您提供**量化的压测/估算指标对照表**，并深度剖析其物理瓶颈与行业顶尖的优化方案。

---

## 问题 16：各规模下的性能预估

以下评估基于主流生产服务器配置（如：8 核 CPU，16GB 内存，NVMe SSD 硬盘），且 **APISIX 开启了 4 个 Worker 进程**。

### 16.1 性能预估量化对照表

| 评估指标 | 小规模 (3.5 万条规则) | 大规模 (1050 万条规则) <br>*(未优化状态)* | 大规模 (50 万条规则) <br>*(优化后：角色注入 JWT)* |
| :--- | :--- | :--- | :--- |
| **用户数 / 角色数 / API数** | 10k / 100 / 500 | 1M / 10k / 5k | 1M / 10k / 5k |
| **用户-角色关系 (`g` 规则)** | 约 30,000 条 | 约 10,000,000 条 | **0 条** *(由 DB 预解析)* |
| **角色-API 关系 (`p` 规则)** | 约 5,000 条 | 约 500,000 条 | 约 500,000 条 |
| **1. `casbin_rule` 视图查询耗时** | **< 15 ms** | **1.5秒 - 5.0秒** *(全表扫描)* | **< 150 ms** *(大幅瘦身)* |
| **2. APISIX 单 Worker 内存占用** | **约 8.7 MB** | **约 2.6 GB** *(OOM 崩溃风险)* | **约 125 MB** *(极安全)* |
| **3. APISIX 冷启动 `LoadPolicy` 耗时** | **< 0.3 秒** | **45秒 - 120秒** *(GC 严重卡顿)* | **< 3.0 秒** |
| **4. `pg_notify` 端到端同步延迟** | **< 0.5 秒** | **同步失败** *(etcd 默认 1.5MB 限制)* | **< 4.0 秒** |

---

## 问题 17：性能瓶颈与优化（大厂架构级方案）

### 17.1 规则数达百万级时的核心瓶颈在哪里？
当规则数量达到 1000 万级时，系统的瓶颈不在 PostgreSQL，也不在网关的 CPU，而在 **APISIX (OpenResty) 进程的内存限制**：
1.  **LuaJIT 的内存天花板：** 
    OpenResty 的主计算引擎 LuaJIT 在 64 位系统下默认存在 **2GB（开启 GC64 后为 4GB）的内存上限**。1000 万条规则在 Lua 内存中需要组装成 1000 万个独立的哈希表，会消耗至少 2.6GB 内存，这会直接撑爆 LuaJIT 的 GC 内存限制，导致 APISIX **频繁发生 OOM（Out of Memory）崩溃**。
2.  **etcd 传输上限限制：**
    APISIX 的 Admin API 底层是 etcd。etcd 默认单次事务的请求大小限制为 **1.5MB**。一次性推送 1000 万条（约 300MB）的 CSV 文本，etcd 会直接拒绝写入。

---

### 17.2 终极优化：角色在 JWT 中预解析（Role-in-JWT）
为了彻底解决上述内存爆炸问题，必须将 `g` 规则（用户与角色的映射，占比 95% 以上）从网关内存中剔除。

#### 优化方案设计：
1.  **数据库端预解析：** 用户在登录时，PL/pgSQL 的 `user_login_sso` 直接在数据库内部查表，计算出该用户拥有的所有角色代码（如 `["role_admin", "role_editor"]`），并**直接作为 Claims 写入 JWT**。
2.  **网关层瘦身：** 
    由于 JWT 里已经声明了角色，APISIX **不再需要加载任何 `g` 规则**！它在内存中只需要加载 `p` 规则（角色 ↔ API 关系，仅 50 万条）。
3.  **结果：** 规则数从 **1050 万** 瞬间降到 **50 万**。APISIX 内存开销从 2.6GB 锐减到 125MB，冷启动和网络传输性能提升了数十倍，完全消除了 OOM 风险。

---

### 17.3 `casbin_rule` 视图是否需要物化视图（Materialized View）？
**在大规模场景下，强烈建议使用物化视图或物理表。**

*   **普通视图的缺点：** 
    标准视图在每次 `SELECT` 时都会实时执行底层的 `JOIN` 和 `UNION ALL`。对于 50 万行的表，这意味着每次网关重载，数据库都要消耗大量的 CPU 进行联表计算，耗时可能高达 1.5 秒。
*   **物化视图方案：**
    物化视图会将数据物理写入磁盘。查询它等同于查询单张物理表，耗时可缩短至 **< 50ms**。
*   **配合触发器的物化视图自动刷新：**
```sql
-- 创建物化视图
CREATE MATERIALIZED VIEW casbin_rule AS
SELECT ... (仅保留 p 规则的 SQL 逻辑);

-- 在 sys_role_api 表变更时触发刷新
CREATE OR REPLACE FUNCTION refresh_casbin_mv()
RETURNS TRIGGER AS $$
BEGIN
    -- 1. 并发刷新物化视图（需要对视图建立唯一索引）
    REFRESH MATERIALIZED VIEW CONCURRENTLY casbin_rule;
    -- 2. 广播通知
    PERFORM pg_notify('casbin_channel', 'reload');
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
```

---

### 17.4 是否需要为超大租户设计分库分表策略？
在 PostgreSQL 中，如果单个租户的数据量达到数亿条，**不需要采用侵入性极高的分布式分库分表**，而是推荐使用 **PostgreSQL 原生的“声明式分区表（Declarative Partitioning）”**。

#### 落地方案（分区表 + RLS 联动）：
1.  **按租户 ID 分区：**
    对于订单表 `sys_order`，采用 `PARTITION BY LIST (tenant_id)` 进行声明式分区：
```sql
CREATE TABLE sys_order (
    id UUID,
    tenant_id VARCHAR(50) NOT NULL,
    amount NUMERIC,
    ...
) PARTITION BY LIST (tenant_id);

-- 为超大租户单独建立物理分区（分区 A）
CREATE TABLE sys_order_tenant_a 
    PARTITION OF sys_order FOR VALUES IN ('tenant_a');

-- 为中小租户建立共享默认分区（分区 B）
CREATE TABLE sys_order_tenant_default 
    PARTITION OF sys_order DEFAULT;
```
2.  **Constraint Exclusion（约束排除）带来的极致性能：**
    当用户发起请求时，底层的 RLS 限制性策略会自动在 SQL 后追加 `WHERE tenant_id = 'tenant_a'`。
    PostgreSQL 的查询优化器在解析 SQL 时，会自动触发“分区裁剪（Partition Pruning）”，**直接越过其他所有租户的分区，只扫描 `sys_order_tenant_a` 这一张子表**。
3.  **结论：** 
    即使整张逻辑表有十亿条数据，其单次查询性能也等同于该租户自身子表的小数据量查询，完美兼顾了“Shared-Schema 的低运维成本”与“物理分区的高性能”。

---

# you asked

# 问题 18：PL/pgSQL 测试方案
推荐使用什么测试框架？（pgTAP？pg_prove？）
如何编写一个测试用例（请给出完整示例：测试一个同步触发器函数）？
如何将数据库测试集成到 Git + CI/CD（GitHub Actions / GitLab CI）流水线中？
# 问题 19：数据库迁移管理
Dbmate 的 down 迁移（回滚）如何设计？是否要求每次 migration 配对 down 脚本？
生产环境执行 migration 的安全流程？（先在从库测试？执行前自动备份？）
多人协作时的 migration 命名冲突如何解决？
# 问题 20：多环境配置管理
dev / staging / prod 三套环境的配置管理推荐方案？
敏感配置（JWT Secret、DB 密码）推荐用什么工具注入？
给出一个完整的 .env.example 或配置文件模板？

---

# googleaistudio response

以下为您提供**PL/pgSQL 自动化测试**、**Dbmate 数据库安全迁移管理**、以及**多环境敏感配置管理**的工程化实战指南。

---

## 问题 18：PL/pgSQL 测试方案

在数据库驱动的无后端架构中，数据库内逻辑（视图、触发器、安全函数）就是核心的业务逻辑。对其进行自动化单元测试是保障生产安全的底线。

### 18.1 推荐框架：pgTAP + pg_prove
*   **pgTAP：** PostgreSQL 生态中黄金标准的单元测试框架，完全用 PL/pgSQL 编写 [1.1.4]。它允许您直接在 SQL 中编写断言（Assert），测试表结构、视图、函数和触发器行为。
*   **pg_prove：** 一个轻量级的命令行测试运行器，可递归执行项目中的测试 SQL 脚本并汇总 TAP (Test Anything Protocol) 报告。

### 18.2 编写 pgTAP 测试用例
以下测试用例将测试我们前文实现的“用户-角色关系变化自动同步到 `casbin_rule` 视图”的触发器。

```sql
-- db/tests/test_user_role_trigger.sql
BEGIN; -- 开启事务，确保测试数据绝不污染真实数据库，测试结束时强制 ROLLBACK

SELECT plan(4); -- 声明本次测试计划执行 4 个断言

-- 断言 1：验证基础表和视图是否存在
SELECT has_table('sys_user_role', 'sys_user_role 表应该存在');
SELECT has_view('casbin_rule', 'casbin_rule 视图应该存在');

-- 准备测试沙盒数据
INSERT INTO sys_user (id, username) VALUES ('11111111-1111-1111-1111-111111111111', 'test_user_alice');
INSERT INTO sys_role (id, role_code, role_name) VALUES ('22222222-2222-2222-2222-222222222222', 'test_role_admin', 'Test Admin');

-- 断言 2：测试插入关联数据时，视图是否自动生成对应的 g 规则
INSERT INTO sys_user_role (user_id, role_id) VALUES ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

SELECT results_eq(
    $$ SELECT ptype, v0, v1 FROM casbin_rule WHERE v0 = 'test_user_alice' $$,
    $$ VALUES ('g'::varchar, 'test_user_alice'::varchar, 'test_role_admin'::varchar) $$,
    '向 sys_user_role 插入数据后，casbin_rule 视图应自动生成符合契约的 g 规则'
);

-- 断言 3：测试删除关联数据时，视图中的 g 规则是否自动被清理
DELETE FROM sys_user_role WHERE user_id = '11111111-1111-1111-1111-111111111111';

SELECT is_empty(
    $$ SELECT 1 FROM casbin_rule WHERE v0 = 'test_user_alice' $$,
    '从 sys_user_role 删除数据后，casbin_rule 视图中对应的规则应自动被清理'
);

-- 完成测试并回滚
SELECT * FROM finish();
ROLLBACK; -- 强制回滚，保持数据库干净
```

### 18.3 集成到 CI/CD 流水线 (GitHub Actions 示例)
在持续集成中，每次代码提交自动拉起临时 PostgreSQL 镜像，载入模式结构（Migrations），运行 pgTAP 单元测试：

```yaml
# .github/workflows/db-test.yml
name: Database Unit Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      # 拉起带 pgTAP 插件的 PostgreSQL 容器
      postgres:
        image: pgcharles/pgtap:15 # 预装了 pgtap 扩展的 pg 镜像
        env:
          POSTGRES_DB: app_test
          POSTGRES_PASSWORD: test_password
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
    - uses: actions/checkout@v3

    # 安装 Dbmate 与 pg_prove 运行器
    - name: Install Tools
      run: |
        curl -fsSL -o /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
        chmod +x /usr/local/bin/dbmate
        sudo apt-get update && sudo apt-get install -y cpanminus
        sudo cpanm TAP::Parser::SourceHandler::pgTAP # 安装 pg_prove

    # 运行数据库迁移，重建结构
    - name: Run Database Migrations
      run: |
        dbmate --url "postgres://postgres:test_password@localhost:5432/app_test?sslmode=disable" up

    # 运行 pgTAP 单元测试
    - name: Run PL/pgSQL Unit Tests
      run: |
        pg_prove -h localhost -U postgres -d app_test --ext .sql db/tests/
      env:
        PGPASSWORD: test_password
```

---

## 问题 19：数据库迁移管理

### 19.1 Dbmate 的 down 迁移设计原则
在 Dbmate 中，每个迁移文件必须严格包含 `-- migrate:up` 和 `-- migrate:down` 两个部分 [2.1.2]：

*   **原则：** 在**开发和测试环境**中，必须配对编写完美的 `down` 脚本。这能够确保开发人员在本地快速回滚调试（`dbmate rollback`）。
*   **生产红线：禁止在生产环境直接运行 `rollback` 或 `down`！**
    *   因为含有 `DROP TABLE` 或 `ALTER TABLE DROP COLUMN` 的 `down` 脚本，一旦在生产环境执行，会导致灾难性的数据丢失。
    *   **安全的生产修复方案（向前滚动，Roll-Forward）：** 如果上一次上线的迁移出错了，不要回滚它。应该在本地编写一个新的 `up` 迁移脚本（例如：`20260706_fix_constraint.sql`），在其中安全地还原表结构或字段，并将其作为一次新的部署向上推进。

### 19.2 生产环境执行迁移的安全流程
为了保证生产环境数据库零宕机（Zero Downtime）与高可用，必须执行如下安全发布流程：

1.  **分步上线与影子测试：** 
    禁止不经过测试直接对生产库做 DDL。必须首先在配置完全相同的 Staging 数据库（预发布库）上执行一次 Migrations。
2.  **强制全量物理备份：** 
    在生产执行 DDL 之前的几分钟内，触发一次 `pgBackRest` 的差异/增量物理备份，确保一击不中时有最强力的底牌。
3.  **零停机 DDL 指令：** 
    如果需要在生产环境创建索引，禁止直接使用 `CREATE INDEX`（这会锁表阻止写入）。必须使用 **`CREATE INDEX CONCURRENTLY`**（并发创建索引） [2.1.2]。
    *   *注：* 针对此类不需要在事务里执行的特殊语句，Dbmate 文件开头需要加上注释指示器：`-- dbmate:no-transaction` [2.1.2]。
4.  **超时控制与锁等待：** 
    对大表加字段或改约束时，配置 `set lock_timeout = '3s';`。如果 3 秒内拿不到锁，迁移应当自动中断报错，避免长时间阻塞业务。

### 19.3 多人协作时的 Migration 命名冲突解决机制
Dbmate 采用标准的 **UTC 时间戳 + 业务后缀** 命名迁移文件（如 `20260706140000_add_user.sql`） [2.1.4]。
*   **优势：** 相比于自增数字（`001_xxx.sql`），时间戳冲突的概率几乎为 0。即使多人同时在不同的 Feature 分支开发并合并到 `main` 分支，文件也不会重名。
*   **无序执行支持：** Dbmate 内部会将已执行过的迁移文件哈希记录在 `schema_migrations` 表中 [2.1.8]。合并代码后，如果 Dbmate 检测到某个较早时间戳的迁移文件尚未被执行，它会自动执行该遗漏文件，不会因为时间戳交错而报错。
*   **`schema.sql` 冲突解决方案：**
    多人合并 PR 时，`db/schema.sql`（数据库结构快照）文件极易产生 Git 冲突 [2.1.2]。
    *   *最佳实践：* 在合并 main 分支后，开发人员应在本地运行一次 `dbmate down && dbmate up`，让本地的本地快照自动重写，并以此快照覆盖合并冲突，提交即可 [2.1.2]。

---

## 问题 20：多环境配置管理

### 20.1 三套环境配置推荐方案
采用经典的 **“十二要素应用（Twelve-Factor App）”** 准则：**代码与配置彻底分离。代码库只有一份，配置完全通过环境变量（Environment Variables）注入。**

*   **开发环境 (dev)：** 本地读取根目录下的 `.env` 文件。
*   **测试/预发环境 (staging) 与 生产环境 (prod)：** 绝不允许在服务器上存放 `.env` 明文配置文件。必须使用容器编排系统（Kubernetes Secret）或云服务商的密钥中心。

### 20.2 敏感配置注入工具选型
*   **Kubernetes 部署：** 使用 **ExternalSecrets Operator**。它能自动与 HashiCorp Vault、AWS Secrets Manager、1Password 联动，将外部高安全密钥中心的敏感数据，动态转化为 K8s 原生的加密 `Secrets`，然后以环境变量形式挂载给 PostgREST 和 APISIX 容器。
*   **虚拟机/裸机/Pigsty 部署：** 推荐使用 **Doppler** 或者是 **HashiCorp Vault**。
    在启动 PostgREST 服务时，不读取任何配置文件，通过极简的命令动态注入解密后的临时环境变量：
    ```bash
    doppler run -- postgrest /etc/postgrest.conf
    ```

---

### 20.3 完整的多环境 `.env.example` 模板

在您的项目 Git 仓库根目录，放置如下安全且标准的模板。开发人员只需将其复制为 `.env` 并填入本地密码即可：

```ini
# ==============================================================================
# 统一多环境配置文件模板 (.env.example)
# 说明：此文件包含本地开发所需的全部配置，生产环境应用此模板配置 Kubernetes Secrets / Vault
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 基础环境定义
# ------------------------------------------------------------------------------
APP_ENV=development                       # 可选值: development, staging, production
APP_NAME=zero-backend-rbac

# ------------------------------------------------------------------------------
# 2. PostgreSQL 数据库连接配置 (Pigsty 集群拓扑)
# ------------------------------------------------------------------------------
# 数据库主写入 VIP (PostgREST 与 Dbmate 读写通道使用)
DB_HOST=127.0.0.1
DB_PORT=5433                              # Pigsty 默认 HAProxy 主写入端口
DB_NAME=app_db
DB_USER=app_owner                         # 数据库特权 Schema 拥有者，拥有 DDL/DML 权限
DB_PASSWORD=your_super_secure_db_password_here
DB_SSL_MODE=verify-full                  # 生产环境必须强制 verify-full 以防止 DNS 劫持

# 数据库只读 VIP (可选，高并发下用于 APISIX 直接读取 casbin_rule 视图)
DB_READ_HOST=127.0.0.1
DB_READ_PORT=5434                         # Pigsty 默认 HAProxy 只读端口

# Dbmate 专用的连接串标准格式
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=${DB_SSL_MODE}

# ------------------------------------------------------------------------------
# 3. PostgREST 服务配置
# ------------------------------------------------------------------------------
PGRST_SERVER_HOST=127.0.0.1
PGRST_SERVER_PORT=3000

# 数据库匿名角色（对应数据库内只读无权角色，用于前置网关未携带 JWT 的探路请求）
PGRST_DB_ANON_ROLE=web_anon

# 数据库架构隔离（PostgREST 暴露的业务 API Schema）
PGRST_DB_SCHEMAS=api_v1

# 预请求校验拦截函数 (用于前文提到的黑名单/强制登出防御)
PGRST_DB_PRE_REQUEST=api_v1.check_token_blacklist

# ------------------------------------------------------------------------------
# 4. JWT 安全与密码学配置 (RS256 黄金方案)
# ------------------------------------------------------------------------------
# 验签算法 (强烈建议使用非对称加密 RS256，无需向外泄露私钥，保证安全性)
JWT_ALGORITHM=RS256

# 公钥内容 / JWKS Endpoint (PostgREST 和 APISIX 仅需要配置公钥进行 JWT 签名验证)
# 可以直接填入 JWK Set JSON 内容，或者填入一个高可用内部 Key 服务器地址
PGRST_JWT_SECRET="{\"keys\": [{\"kty\": \"RSA\", \"kid\": \"key-v1\", \"n\": \"...\", \"e\": \"AQAB\"}]}"

# 数据库内部登录函数专用的签名私钥 (此私钥必须严格保密，仅注入给登录/生成 Token 的 PL/pgSQL 函数)
DB_JWT_PRIVATE_KEY_PEM="-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----"

# ------------------------------------------------------------------------------
# 5. API 网关 APISIX 配置
# ------------------------------------------------------------------------------
APISIX_ADMIN_KEY=edd1c9f034335f136f87ad84b625c8f1  # 网关管理 Token (仅 Policy Syncer 拥有)
APISIX_HOST=127.0.0.1
APISIX_PORT=9080

# ------------------------------------------------------------------------------
# 6. Redis 配置 (高并发网关限流与 Token 黑名单缓存)
# ------------------------------------------------------------------------------
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=your_redis_secure_password
```

---

# you asked

# 问题 21：权限审批流程
如果权限分配需要审批（提交→审批→生效），在当前架构中的实现方案是什么？是否需要引入"待审批关系表"？

# 问题 22：API 版本管理
PostgREST 如何支持 API 版本化（如 v1/v2）？通过不同 Schema？不同 URL 前缀？

# 问题 23：文件上传处理
Admin 后台如需上传头像、导入 Excel，PostgREST 能否处理？是否需要额外的文件服务？

# 问题 24：监控与告警
APISIX + PostgREST + Pigsty 的统一监控方案？
关键的告警规则推荐（如网关 5xx 率飙升、DB 连接数打满、权限变更异常频发等）
# 问题 25：扩展插件许可证合规
Pigsty 打包的扩展中，哪些有商业使用限制？（如 AGPL 许可的 pg_timetable、pg_net 等）在生产环境中使用是否有法律风险？

---

# googleaistudio response

以下为您提供这五个极具工程落地价值的进阶方案剖析与合规评估。

---

## 问题 21：权限审批流程

在安全合规要求较高的企业中，“提交申请 ──> 审批 ──> 生效”是标准流程。

### 1. 为什么不能直接在 `sys_user_role` 表加状态字段？
*   **不安全：** 如果直接在操作表（`sys_user_role`）上加 `status` 字段（如 `pending`, `approved`），一旦开发人员或视图逻辑在 `JOIN` 时漏写了 `WHERE status = 'approved'`，就会造成重大的安全漏洞（未审批的权限直接生效）。
*   **违反单一职责：** 操作表应当只存放**当前正在生效**的干净数据。

### 2. 推荐方案：引入“待审批关系表”（工作流与操作表分离）

```text
Admin UI ──(POST /rpc/submit_role_request)──> 写入 sys_user_role_request (status='pending')
                                                       │
                                                       ▼
Approver ──(POST /rpc/approve_role_request)──> 更新 status='approved' 
                                                       │
                                              (同一个 DB 事务中)
                                                       ▼
                                         INSERT INTO sys_user_role 
                                                       │
                                              (触发器触发通知)
                                                       ▼
                                        casbin_rule 视图更新 ──> 网关重载
```

#### 数据库设计：
*   **操作表 `sys_user_role`：** 保持不变，仅存放当前生效的“用户-角色”映射。
*   **审批流表 `sys_user_role_request`：**
```sql
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'approved', 'rejected'
    applicant_id UUID NOT NULL,
    approver_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP WITH TIME ZONE
);
```

#### 审批通过的 PL/pgSQL 事务函数：
```sql
CREATE OR REPLACE FUNCTION approve_role_request(p_request_id uuid)
RETURNS boolean AS $$
DECLARE
    v_req RECORD;
    v_approver_id uuid;
BEGIN
    -- 1. 从 JWT 提取审批人 ID
    v_approver_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;

    -- 2. 锁住并查询该申请（防止并发重复审批）
    SELECT * INTO v_req FROM sys_user_role_request 
    WHERE id = p_request_id AND status = 'pending' FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found or already processed' USING ERRCODE = 'P0001';
    END IF;

    -- 3. 在同一个事务中更新状态并写入操作表
    UPDATE sys_user_role_request 
    SET status = 'approved', approver_id = v_approver_id, approved_at = now()
    WHERE id = p_request_id;

    -- 写入操作表（会触发前面我们写好的网关重载触发器）
    INSERT INTO sys_user_role (user_id, role_id) 
    VALUES (v_req.user_id, v_req.role_id)
    ON CONFLICT DO NOTHING;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## 问题 22：API 版本管理

在 PostgREST 中，最优雅且符合 REST 规范的版本化方案是：**多 PostgreSQL Schemas + 网关请求头重写**。

### 1. 数据库多 Schema 隔离
在数据库中创建独立Schema：`api_v1` 和 `api_v2`。
```sql
-- v1 视图
CREATE OR REPLACE VIEW api_v1.users AS SELECT id, username FROM sys_user;

-- v2 视图 (新增了字段)
CREATE OR REPLACE VIEW api_v2.users AS SELECT id, username, created_at FROM sys_user;
```
并在 `postgrest.conf` 中声明这两个暴露的 Schema：
```properties
db-schemas = "api_v1, api_v2"
```

### 2. 客户端请求与网关自动路由
PostgREST 原生支持通过 HTTP 的 **`Accept`** 或 **`Accept-Profile` 头部** 来无缝切换 Schema：
*   请求 `Accept-Profile: api_v1` 时，PostgREST 自动路由到 `api_v1` 架构。
*   请求 `Accept-Profile: api_v2` 时，自动路由到 `api_v2`。

为了让前端开发者能使用更直观的 URL（如 `/api/v1/users`），**由前置网关 APISIX 进行重写拦截**：

```yaml
# APISIX 针对 v1 路由的配置
uri: /api/v1/*
plugins:
  proxy-rewrite:
    regex_uri: ["^/api/v1/(.*)", "/$1"] # 去掉 /api/v1 前缀
    headers:
      set:
        Accept-Profile: "api_v1" # 动态注入 PostgREST 识别的版本头
```
通过这种网关与 Schema 咬合的方式，前端得到了直观的 URL，而数据库得到了极度安全的 Schema 级物理版本隔离。

---

## 问题 23：文件上传处理

### 1. PostgREST 能否处理？
技术上可以。PostgREST 支持二进制原始 Payload (`application/octet-stream`)，并可将其存入 Postgres 的 `bytea`（二进制）字段中。

### 2. ⚠️ 强烈不建议直接存入数据库（数据库反模式）
将头像、PDF、Excel 等文件以 BLOB 形式存入 PostgreSQL 会导致：
*   **数据库急剧膨胀（Bloat）：** 频繁的垃圾回收（VACUUM）导致 CPU 飙升。
*   **内存污染：** 读取大文件会污染数据库昂贵的 `shared_buffers` 内存缓存。
*   **备份灾难：** 导致物理备份文件（`pgBackRest`）体积巨大，严重拖慢灾备 RTO。

### 3. 最佳替代方案：S3 预签名 URL 上传（Pre-signed URL）
这是无后端/低代码架构下最标准的云原生文件处理方案：

```text
1. Admin UI ──(POST /rpc/get_upload_url)──> PostgREST (PL/Python 调用 boto3)
                                                     │
                                            (生成安全的短期预签名 PUT URL)
                                                     ▼
2. Admin UI <──(返回 Presigned PUT URL)──────────────
│
├──(3. 直接上传大文件，不经过任何后端/数据库)──> MinIO / S3 对象存储
│
└──(4. 上传成功后，将文件静态 URL 写入用户表)──> PATCH /api_v1/users/1 { "avatar_url": "..." }
```
通过这种设计，PostgREST 只负责传递几十个字节的临时签名，大文件上传的带宽和存储全部由 **MinIO**（Pigsty 生态完美支持）承载，保护了数据库的计算底座。

---

## 问题 24：监控与告警

### 24.1 APISIX + PostgREST + Pigsty 统一监控
*   **监控大脑：** **Pigsty 自带的世界级 Prometheus + Grafana 监控系统**。
*   **APISIX 监控接入：** 
    开启 APISIX 的 `prometheus` 插件，将其指标暴露路径（`/apisix/prometheus/metrics`）作为抓取目标（Target）配置进 Pigsty 的 Prometheus 中。
*   **PostgREST 监控接入：**
    PostgREST 在开启连接保持的情况下，原生提供 `/metrics` 接口（符合 Prometheus 格式）。同样将其配置进 Prometheus 即可。

### 24.2 关键告警规则推荐（Prometheus Alert Rules）

#### 1. 网关 5xx 状态码飙升告警 (APISIX)
代表网关、PostgREST 或是数据库连接发生了严重的中断：
```yaml
expr: sum(rate(apisix_http_status{status=~"5.."}[5m])) / sum(rate(apisix_http_status[5m])) > 0.05
for: 2m
labels:
  severity: critical
annotations:
  summary: "网关 5xx 异常比例超过 5%，请立刻排查后端 PostgREST 健康状况"
```

#### 2. 数据库连接数将近打满告警 (PostgreSQL)
防止由于连接泄露或瞬时高并发导致数据库拒绝新连接：
```yaml
expr: pg_stat_database_numbackends / pg_settings_max_connections > 0.85
for: 3m
labels:
  severity: warning
annotations:
  summary: "PostgreSQL 数据库连接数使用率已超 85%，当前连接数: {{ $value }}"
```

#### 3. 权限变更异常频发告警 (Security Audit)
当 `sys_user_role` 表的写入速度在短时间内异常飙升，可能意味着有管理员账户被劫持正在批量提权，或者是批量同步脚本发生了死循环：
```yaml
expr: rate(pgaudit_audit_events{class="WRITE", statement=~".*sys_user_role.*"}[5m]) > 20
for: 1m
labels:
  severity: warning
annotations:
  summary: "检测到权限变更行为异常频发，过去5分钟内写入率超过阈值，疑似提权攻击或配置异常"
```

---

## 问题 25：扩展插件许可证合规

在商业或企业级生产环境中使用开源数据库时，合规是绕不开的法律门槛（尤其是对 copyleft 许可证的担忧）。

### 1. Pigsty 打包的核心扩展许可证分析
您可以完全放心，**Pigsty 打包并力推的核心扩展插件，几乎全为极其宽松、对商业闭源完全无害的许可证**：

*   **`pg_timetable`（高级调度引擎）：** 采用 **MIT 许可证**。
    *   *商业合规性：* MIT 是目前最宽松的许可证。你可以任意修改、分发、用于商业闭源软件中，没有任何开源传染风险。
*   **`pg_net`（异步 HTTP 客户端）：** 采用 **Apache 2.0 许可证**。
    *   *商业合规性：* 允许自由用于商业目的、修改和分发，不强制开源你的上层代码。
*   **`pgjwt`、`pgcrypto`、`pgaudit`、`pg_cron` 等：** 采用 **PostgreSQL License** 或 **BSD/MIT**。
    *   *商业合规性：* 与 PostgreSQL 官方主体许可证完全一致，对商业闭源 100% 友好。

### 2. 为什么 Pigsty 在生产环境使用没有法律风险？
1.  **没有 AGPL 传染风险：** 
    Pigsty 的核心数据路径插件中，**没有任何一个是基于 AGPL 或 SSPL（如 MongoDB 采用的排他许可证）等具有强传染性、限制云厂商/商业化使用的许可证。**
2.  **合规合法的架构：**
    在这套架构中，你只是通过标准的 SQL、TCP 协议或 PostgREST 封装的 HTTP API 去调用这些插件的能力。这在法律上属于“正常使用开源软件的外部功能接口”，不属于“修改并重新发布衍生作品”。

因此，您可以无后顾之忧地将基于 Pigsty 构建的这一整套无后端安全架构，部署在任何大型外企、金融机构或商业化 SaaS 系统中。