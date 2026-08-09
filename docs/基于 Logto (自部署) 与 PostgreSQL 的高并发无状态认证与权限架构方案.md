# 基于 Logto (自部署) 与 PostgreSQL 的高并发无状态认证与权限架构方案

本设计文档旨在为开发团队提供一套关于 **身份认证（AuthN）** 与 **业务授权（AuthZ）** 解耦的完整架构方案。

本方案选择 **自部署（Self-Hosted）的开源 Logto** 作为统一身份认证与 IAM 系统，选择 **PostgreSQL（结合 RLS 行级安全与会话变量）** 作为业务权限与租户隔离的最终执行点，兼顾高并发下的系统性能与业务安全。

---

## 一、 架构愿景与总体设计

传统的权限系统通常在每次业务请求时，都需要通过后端代码进行复杂的多表关联查询（用户 ⇋ 角色 ⇋ 权限），这在微服务和高并发场景下会造成严重的数据库性能瓶颈。

本方案采用 **“前端轻量级缓存、后端无状态校验”** 的架构设计：
1. **身份认证与多渠道登录（AuthN）**：完全托管给自部署的 Logto。
2. **前端权限控制（菜单与按钮展示）**：前端在初始化时，通过用户 JWT 携带的多个角色，在数据库端利用 SQL 的**并集与去重机制**，一次性拉取该用户可访问的完整菜单与 API 列表并缓存在前端内存，后续 UI 渲染完全无需再次请求后端。
3. **后端业务鉴权（AuthZ）**：后端接口和数据库采用**无状态（Stateless）校验**。在事务开始时将 JWT 的 Claims 注入到 PG 会话中，利用 PostgreSQL 的 **行级安全（Row-Level Security, RLS）** 策略实现常数级复杂度 $O(1)$ 的数据与租户隔离。

---

## 二、 技术选型一览与参考链接

### 1. 认证中心（IAM / AuthN）
* **选型**：**Logto (Self-Hosted 开源版)**
  * **选型理由**：极佳的现代化 UI 体验，原生支持多渠道登录、多因素认证（MFA）和多租户（Organization）模型。自部署版本几乎免费开放了所有核心及企业级功能。
  * **官方文档参考链接**：
    * [Logto 官方主页](https://logto.io)
    * [Logto 开源自部署指南](https://docs.logto.io/get-started/self-hosting)
    * [Logto 自定义 JWT Claim 说明](https://docs.logto.io/developers/custom-jwt-claims)
    * [Logto Webhooks 开发者文档](https://docs.logto.io/developers/webhooks)

### 2. 数据库与权限执行点（AuthZ）
* **选型**：**PostgreSQL (推荐基于 Pigsty 部署生态)**
  * **选型理由**：利用 PostgreSQL 强大的 RLS（行级安全）和 JSON 聚合功能。
  * **可选扩展支持**：
    * `pg_session_jwt` (用于在数据库端直接解析与验证 JWT 签名)
    * `acl` 扩展（如果需要针对特定资源行进行极其细粒度的自定义 ACL 授权）
  * **Pigsty 扩展目录参考链接**：[Pigsty Extension Catalog](https://pigsty.cc/ext/cate/)

---

## 三、 核心机制设计

### 机制 1：无状态认证与 JWT 自定义 Claims 注入

为了让后端和数据库能够进行无状态校验，我们必须让 Logto 颁发的 **Access Token (JWT)** 携带必要的鉴权元数据。

#### 1. 配置 Logto 动态注入 Claims
在 Logto Console 的“Console > API Resources”中，利用 Logto 提供的 **Custom JWT Claims** 脚本功能 [2.1.3, 2.1.7]。编写一段轻量级的 JavaScript 代码，在生成 Token 前将用户的角色、租户 ID 等动态注入到 JWT 的 Payload 中：

```javascript
// Logto 动态 JWT 注入脚本示例
const getCustomJwtClaims = async ({ user, context }) => {
  // 从上下文中获取该用户在当前组织/租户下的角色
  const roles = context.organizationRoles || []; 
  const tenantId = context.organizationId || 'default_tenant';

  return {
    roles: roles.map(r => r.name), // 转换为字符串数组，例如 ["editor", "viewer"]
    tenant_id: tenantId,
    username: user.username || user.primaryEmail
  };
};
```

#### 2. 生成的 JWT Payload 结构样例
```json
{
  "sub": "logto_user_uuid_123456",
  "iss": "https://your-logto-domain.com",
  "exp": 1712345678,
  "tenant_id": "tenant_abc_789",
  "roles": ["editor", "viewer"],
  "username": "alex@example.com"
}
```

---

### 机制 2：前端资源加载与数据库级并集去重

当用户登录成功后，前端需要获取其可访问的菜单和 API。为了防止 N+1 次查询和后端内存计算，本设计采用 **数据库单条 SQL 并集去重** 方案。

#### 1. 数据库权限对照表设计
在 PostgreSQL 中建立一张扁平的角色-资源对照表（或物化视图）`role_resources`：

```sql
CREATE TABLE role_resources (
    id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL,
    resource_type VARCHAR(20) NOT NULL, -- 'menu' 或 'api'
    resource_id VARCHAR(100) NOT NULL,   -- 路由路径或 API 路径
    action VARCHAR(20) NOT NULL         -- 'read', 'write', 'delete'等
);

-- 示例数据
INSERT INTO role_resources (role_name, resource_type, resource_id, action) VALUES
('viewer', 'menu', '/dashboard', 'read'),
('editor', 'menu', '/dashboard', 'read'), -- 两个角色均有此权限
('editor', 'menu', '/articles', 'write'),
('admin', 'api', '/api/v1/users', 'delete');
```

#### 2. 多角色一次性合并与去重 SQL
当用户携带 `roles = ['viewer', 'editor']` 请求其可用资源时，后端直接将该数组作为参数传入，由 PostgreSQL 执行集合并集和去重：

```sql
-- 使用 DISTINCT 自动做并集去重
SELECT DISTINCT resource_type, resource_id, action
FROM role_resources
WHERE role_name = ANY($1::text[]); 
-- 参数 $1 传入的值为：['viewer', 'editor']
```

#### 3. 结构化 JSON 聚合查询（可选）
如果希望数据库直接返回按资源类型归类的 JSON 对象，可使用以下高级聚合查询：

```sql
SELECT 
    resource_type,
    json_agg(DISTINCT jsonb_build_object('id', resource_id, 'action', action)) AS resources
FROM role_resources
WHERE role_name = ANY($1::text[])
GROUP BY resource_type;
```

* **架构收益**：完全避免了后端代码中的 `for` 循环，数据库在一两毫秒内直接输出合并好的权限树，前端将其一次性缓存至内存（如 Pinia 或 Redux）。

---

### 机制 3：后端无状态 RLS 行级安全隔离

在实际的业务操作中，虽然前端过滤了菜单，但后端必须对每一条 SQL 执行强制的安全隔离。

#### 1. 数据库会话变量注入
当后端接收到业务 API 请求时，首先验证 JWT 签名，然后将 JWT 中的 `tenant_id` 和 `user_id` 注入到当前 PG 数据库连接的会话上下文中：

```sql
-- 在每个数据库连接或事务开始时执行
SELECT set_config('app.current_user_id', 'logto_user_uuid_123456', true);
SELECT set_config('app.current_tenant_id', 'tenant_abc_789', true);
```
*(注：第三个参数 `true` 表示该设置仅在当前事务（Transaction）中有效，事务结束后自动销毁，防止连接池复用时的污染。)*

#### 2. 在业务表上配置 RLS 策略
创建业务数据表，并编写行级安全策略。PostgreSQL 会自动拦截所有 `SELECT`、`UPDATE`、`DELETE` 操作：

```sql
-- 启用行级安全
ALTER TABLE business_data ENABLE ROW LEVEL SECURITY;

-- 创建租户与用户双重隔离策略
CREATE POLICY tenant_user_isolation_policy ON business_data
AS RESTRICTIVE
USING (
    tenant_id = current_setting('app.current_tenant_id')
    AND (
        owner_id = current_setting('app.current_user_id') 
        OR 'admin' = ANY(string_to_array(current_setting('app.current_user_roles', true), ','))
    )
);
```

* **架构收益**：业务层的 SQL 语句变得极其简单（只需执行 `SELECT * FROM business_data`），数据库底层的 RLS 引擎会自动附加隔离条件，安全性达到数据库内核级。

---

### 机制 4：实体数据同步（Logto Webhooks 方案）

虽然权限是无状态校验的，但业务系统中的外键约束（例如“订单表”必须关联一个存在于“用户表”的 ID）要求我们必须在 PG 业务库中同步一份基本的用户、角色和租户信息。

#### 1. 禁止使用 `CREATE ROLE`
**特别注意**：千万不要将 Logto 的用户同步为 PG 底层的系统角色（即不要在 PG 中执行 `CREATE ROLE username`）。这会导致数据库系统表膨胀、严重的锁争抢，并使数据库连接池失效。所有用户和角色必须存储为**业务表的数据行（Rows）**。

#### 2. Webhook 事件订阅设计
在自部署的 Logto 后台配置 Webhook 接收端点指向您的后端服务，并订阅以下事件来保持 PG 镜像表的实时一致性 [2.1.2]：

| 业务实体 | 订阅的 Logto 事件类型 [2.1.2] | 后端 PG 对应的 SQL 行为 |
| :--- | :--- | :--- |
| **用户 (User)** | `User.Created`<br>`User.Deleted`<br>`User.Data.Updated` | `INSERT ... ON CONFLICT DO UPDATE`（用户表镜像维护） |
| **角色 (Role)** | `Role.Created`<br>`Role.Deleted`<br>`Role.Data.Updated` | 同步更新 PG 业务库中的 `roles` 定义表 |
| **租户/组织 (Org)**| `Organization.Created`<br>`Organization.Deleted` | 同步维护业务库中的 `tenants` 物理表 |
| **租户角色绑定** | `Organization.Membership.Updated` | 同步维护业务库中的 `user_tenants` 及 `user_roles` 关联表 |

#### 3. Webhook 安全验证
后端在接收到 Logto 的 Webhook 请求时，**必须验证其签名**（使用 HMAC-SHA256 算法对比 Secret 与 Header 中的 `logto-signature-sha-256`），防止恶意伪造伪造权限包 [2.1.3]。

---

## 四、 完整业务时序与数据流

以下为本方案从用户登录到业务请求的完整时序：

```
[ 终端用户 ]         [ 前端 App ]         [ 后端网关/API ]        [ Logto IAM ]       [ PostgreSQL ]
    │                     │                     │                     │                     │
    ├─ 1. 点击登录 ──────>│                     │                     │                     │
    │                     ├─ 2. 重定向登录 ──────────────────────────>│                     │
    │                     │                                           │                     │
    │                     │<─ 3. 输入凭证并成功登录 ──────────────────┤                     │
    │                     │   (颁发携带自定义 claims 的 JWT)          │                     │
    │                     │                                           │                     │
    ├─ 4. 初始化 App ────>│                                           │                     │
    │                     ├─ 5. 请求可用菜单/API ────────────────────>│                     │
    │                     │    (携带 JWT)       │                     │                     │
    │                     │                     ├─ 6. 验证 JWT 签发 ──>│                     │
    │                     │                     │  及角色列表          │                     │
    │                     │                     │                     │                     │
    │                     │                     ├─ 7. 执行合并去重查询 ────────────────---->│
    │                     │                     │  (SQL: ANY + DISTINCT)                    │
    │                     │                     │<─ 8. 返回合并后的干净资源树 ──────────────┤
    │                     │<─ 9. 缓存至内存 ────┤                                           │
    │                     │                                                                 │
    │                     │                                                                 │
    ├─ 10. 点击某个菜单 ─>│ (基于本地缓存极速过滤)                                           │
    │                     │                                                                 │
    ├─ 11. 触发数据查询 ─>│                                                                 │
    │                     ├─ 12. 请求业务 API (携带 JWT) ────────────>│                     │
    │                     │                     │                     │                     │
    │                     │                     ├─ 13. 解析 JWT，并在事务内注入 Session ───>│
    │                     │                     │  (SET LOCAL app.current_tenant_id = ...)  │
    │                     │                     │                     │                     │
    │                     │                     ├─ 14. 执行业务 SQL (触发数据库级 RLS) ────>│
    │                     │                     │<─ 15. 返回安全过滤后的数据行 ─────────────┤
    │                     │<─ 16. 渲染列表 ─────┤                                           │
```

---

## 五、 开发路线图建议

1. **第一阶段：自部署基础设施建立**
   * 使用 Docker Compose 或 Kubernetes 在本地/云端部署开源的 **Logto** 实例，并配置好 SMTP 邮件或手机验证码连接器 [1.1.7]。
   * 建立您的业务 PostgreSQL 数据库（建议参考 Pigsty 的配置）。
2. **第二阶段：基础数据表与配置**
   * 在 PG 中建立业务用户镜像表（`users`、`user_roles`），并编写后端的 **Logto Webhook 校验及数据同步接收器**。
   * 编写 Logto 控制台中的 **Custom JWT Claims 注入脚本**。
3. **第三阶段：无状态鉴权改造**
   * 前端引入 Logto 官方 SDK，登录成功后获取 JWT。
   * 创建 `role_resources` 表，编写支持多角色合并的 `DISTINCT` 聚合 SQL 并提供给前端初始化调用。
4. **第四阶段：数据库内核级 RLS 强化**
   * 在核心业务表（如订单、客户数据、敏感配置等）上开启 `ENABLE ROW LEVEL SECURITY`。
   * 编写基于 `current_setting('app.current_tenant_id')` 的 RLS 策略，进行上线前的压力与安全穿透测试。