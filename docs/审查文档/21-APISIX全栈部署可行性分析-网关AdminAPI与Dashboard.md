# APISIX 全栈部署可行性分析：网关 + Admin API + Dashboard（21号）

> **日期**: 2026-08-03
> **问题来源**: 用户多次尝试部署"APISIX 网关 + APISIX Admin API + APISIX Dashboard"失败，已退而求其次改为仅部署网关（standalone），并提出三个疑问：
> 1. 现有环境（WSL2 + Docker Desktop + Pigsty v4.4.0）能否成功部署全栈？
> 2. 部署"网关 + Admin API"是否必须使用 Dashboard？否则无法可视化管理？
> 3. Dashboard 能可视化地管理插件与配置吗？
> **依据**: APISIX 官方文档 4 份（Dashboard / Control API / Status API / Admin API）+ 部署模式文档 + 安装指南 + `apisix-docker` 官方示例 + APISIX 源码 `conf/config.yaml.example`（3.17 分支）

---

## 〇、结论速览（先给答案）

| 问题 | 结论 |
|:--|:--|
| **Q1：现有环境能部署全栈吗？** | **能，而且比您想象得简单**——APISIX 3.x 起 **Dashboard 已内嵌进 APISIX 本体**（`http://<apisix>:9180/ui`，默认启用），**根本不存在"单独部署 dashboard 容器"这回事了**。您此前反复失败的很可能就是部署了**已废弃的独立 `apache/apisix-dashboard` 容器（3.0.1）**，它官方只兼容 APISIX 3.0，与 3.17 不兼容。真正要做的是：把 APISIX 从 standalone 模式切回 **traditional 模式**（需要 etcd）+ 开放 9180 端口，UI 自动就有了。 |
| **Q2：必须用 Dashboard 吗？** | **不是**。Admin API 是纯 REST API，用 `curl`/脚本/**ADC**（APISIX Declarative CLI）就能 100% 管理全部资源，Dashboard 只是可选的图形化外壳。反过来说：想要可视化界面也不需要额外部署——3.x 已内置。**"必须使用 Dashboard"在两种意义上都不成立。** |
| **Q3：Dashboard 能可视化管理插件/配置吗？** | **能，但要分清两个层面**：① 运行时资源（路由/上游/消费者/SSL/**插件**）→ 官方明确"通过图形界面轻松配置路由、插件、上游服务等"；② **启动配置 `config.yaml`（etcd 地址、监听端口、admin key 等）→ 不能**，只能改文件后重启。另外 UI 对插件采用**白名单制**（旧版 3.0.1 即如此），白名单外的插件字段需走 Admin API。 |

---

## 一、核心概念澄清：五个组件别搞混

APISIX 3.x 有 **5 个端口/API**，功能完全不同，这是理解一切问题的钥匙：

| 组件 | 默认端口 | 角色 | 能否"管理"网关 | 与 Dashboard 的关系 |
|:--|:--:|:--|:--|:--|
| **Gateway（数据面）** | 9080 / 9443 | 处理真实业务流量 | 否 | 被管理的对象 |
| **Admin API（控制面）** | 9180 | **管理 REST API**：增删改路由/上游/消费者/插件等，`X-API-KEY` 认证 | **是（唯一入口）** | Dashboard 是它的"前端皮肤" |
| **Control API** | 9090（默认 127.0.0.1） | 内部运维接口：`/v1/schema`、`/v1/healthcheck`、`/v1/gc`、`/v1/plugin_metadatas` | 否（只读/运维） | 无关 |
| **Status API** | 7085（默认 127.0.0.1） | 健康/就绪探针：`GET /status`、`GET /status/ready` | 否 | 无关 |
| **Dashboard（内置 UI）** | 9180 的 `/ui` 路径 | 可视化操作 Admin API | 是（经 Admin API） | — |

**架构关系（官方文档原文支撑）**：
- [Dashboard 文档](https://apisix.apache.org/zh/docs/apisix/dashboard/)："**APISIX 内置了 Dashboard UI，默认启用**……**Dashboard 通过 Admin API 与 Apache APISIX 交互**，需要正确的 Admin API Key 进行身份验证。"（配置项：`deployment.admin.enable_admin_ui: true`，访问 `http://127.0.0.1:9180/ui`）
- 同一文档"发布周期"节："项目**不再独立发布**……在 Apache APISIX 发布时，将直接基于指定的 Git commit hash 构建 Dashboard，并将产物**嵌入到 Apache APISIX 中**。""旧版本的 Apache APISIX Dashboard **3.0.1 是在重构前，使用旧发布模式的最后一个版本。它仅应与 Apache APISIX 3.0 一起使用**，任何更高或更低版本未进行测试。"
- [部署模式文档](https://apisix.apache.org/zh/docs/apisix/deployment-modes/)：traditional 模式 = 数据面+控制面同一实例（9080 + 9180），配置中心为 **etcd**；standalone 模式 = 仅数据面、**Admin API 被禁用**、配置来自本地 YAML。
- [Control API 文档](https://apisix.apache.org/zh/docs/apisix/control-api/)：暴露内部状态，**"control API server 不应该被配置成监听公网地址"**。
- [Status API 文档](https://apisix.apache.org/zh/docs/apisix/status-api/)：仅健康检查。

> ⚠️ 关键推论：**当前项目的 `gateway/apisix/config.yaml` 是 `role: data_plane` + `config_provider: yaml`（standalone）——在这个模式下 Admin API 是关闭的，任何 Dashboard（内置或独立）都不可能工作。** 这极可能是您此前"部署 dashboard 失败"的直接原因之一（见 §三）。

---

## 二、Q1：现有环境能否部署"网关 + Admin API + Dashboard"？

### 2.1 结论：能。官方全栈最小组成 = APISIX（traditional）+ etcd

官方 `apisix-docker` 仓库的 [example/docker-compose.yml](https://github.com/apache/apisix-docker/blob/master/example/docker-compose.yml)（3.17.0-debian）显示全栈只需两个服务：

```yaml
services:
  apisix:
    image: apache/apisix:3.17.0-debian
    volumes:
      - ./apisix_conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
    depends_on: [etcd]
    ports:
      - "9180:9180/tcp"   # Admin API + 内置 Dashboard UI
      - "9080:9080/tcp"   # 数据面 HTTP
      - "9443:9443/tcp"   # 数据面 HTTPS
  etcd:
    image: bitnamilegacy/etcd:3.5.11
    environment:
      ALLOW_NONE_AUTHENTICATION: "yes"        # 开发环境明文 etcd
      ETCD_ADVERTISE_CLIENT_URLS: "http://etcd:2379"
      ETCD_LISTEN_CLIENT_URLS: "http://0.0.0.0:2379"
    ports: ["2379:2379/tcp"]
```

官方 example 的 `config.yaml` 关键段（与您的 `gateway/apisix/config.yaml` 对比，差异就是失败根源）：

```yaml
deployment:
  admin:
    allow_admin:
      - 0.0.0.0/0            # 必须放行 Docker 网段，否则 Dashboard 请求被 403
    admin_key:
      - name: "admin"
        key: edd1c9f034335f136f87ad84b625c8f1   # ⚠️ 这就是官方示例的默认 key
        role: admin
  etcd:
    host:
      - "http://etcd:2379"   # 明文 etcd（容器内服务名）
    prefix: "/apisix"
    timeout: 30
```

> 注意官方示例中**没有 dashboard 容器**——UI 就在 APISIX 里，`docker compose up` 后浏览器打开 `http://localhost:9180/ui` 输入 Admin Key 即可。

### 2.2 您之前失败的 6 个候选根因（按可能性排序）

| # | 根因 | 说明 | 证据 |
|:--:|:--|:--|:--|
| 1 | **部署了废弃的独立 Dashboard** | `apache/apisix-dashboard` 独立镜像停留在 3.0.1（旧架构：React+Go 后端+数据库），官方声明**仅兼容 APISIX 3.0**。与 3.17 一起跑，UI 的 API 契约对不上（版本校验/插件列表/接口路径全不一致） | Dashboard 文档"发布周期"节 |
| 2 | **config.yaml 停留在 standalone 模式** | `role: data_plane + config_provider: yaml` 时 **Admin API 被禁用**，9180 无服务 → Dashboard 无从连接；若同时映射了 9180 端口，访问是"拒绝/无法连接"而非 UI | 部署模式文档："This makes it possible to disable the Admin API" |
| 3 | **etcd 缺失或连不上** | traditional 模式强依赖 etcd：没有 etcd 容器 → APISIX 起不来或反复报错；复用 Pigsty etcd 但没配 TLS/认证/网络可达（见 §5.2） | 部署模式文档、安装依赖文档（etcd ≥ 3.4，HTTP(S) 通信） |
| 4 | **`allow_admin` 白名单挡住 Dashboard** | 若配置成文档示例的 `127.0.0.0/24`，Docker 容器 IP（172.x）发来的 Admin API 请求全部 403 | Dashboard 文档"限制 IP 访问"节；官方 example 用 `0.0.0.0/0` |
| 5 | **9180 未映射/防火墙未放行** | compose 只映射 9080/9443；或 Pigsty 防火墙端口列表未含 9180 | — |
| 6 | **Admin Key 不匹配** | Dashboard 首次打开要求填 Admin Key；填错即 "failed to check token" | Dashboard 文档"在 Dashboard 中使用"节 |

> 💡 重要安全提醒：您项目里使用的 `edd1c9f034335f136f87ad84b625c8f1` **就是官方示例的默认 Admin Key**（全网公开、可被猜测）。若开放 9180 到局域网/公网，等于裸奔。启用全栈后**务必更换**。

### 2.3 现有环境可行性矩阵

| 条件 | 现状 | 是否满足 |
|:--|:--|:--:|
| Docker Desktop + Compose | ✅ | ✅ |
| 端口可用（9080/9443/9180/2379） | 9080/9443 已用；9180 空闲；2379 被 Pigsty etcd 占用（⚠️ 见下） | ⚠️ 部分 |
| etcd | 有两条路：① compose 内起 docker etcd（官方示例同款）；② 复用 Pigsty etcd（TLS+认证，容器网络可达性复杂） | ✅（推荐①） |
| APISIX 镜像 | `apache/apisix:3.17.0-debian` 已在使用 | ✅ |
| 内置 Dashboard | 3.17 默认启用（`enable_admin_ui: true`） | ✅ |

> ⚠️ 端口冲突提示：**Pigsty etcd 占用了宿主 2379**。若选 docker etcd 方案，**不要**把 etcd 容器 2379 映射到宿主（容器内用 `etcd:2379` 服务名互访即可），或者映射到 2380 备用端口，避免与 Pigsty etcd 冲突。

---

## 三、Q2：部署"网关 + Admin API"必须用 Dashboard 吗？

### 3.1 答案：不需要

Admin API 是标准 REST API（`/apisix/admin/routes`、`/apisix/admin/upstreams`、`/apisix/admin/consumers`……），有 4 种完全等价的"管理方式"：

| 管理方式 | 需要额外部署 | 适合场景 | 说明 |
|:--|:--:|:--|:--|
| **curl / 脚本** | 否 | CI/CD、自动化、批处理 | 与 Dashboard 操作的是同一套 API，能力完全一致 |
| **ADC（APISIX Declarative CLI）** | 否（独立 CLI 工具） | 声明式配置、GitOps | 官方推荐的生产管理方式，yaml 声明 + `adc sync` |
| **内置 Dashboard（3.x）** | **否（已内嵌）** | 人工可视化操作 | `http://<apisix>:9180/ui` |
| 独立 Dashboard 3.0.1 | 是（已废弃） | ❌ 不推荐 | 仅兼容 APISIX 3.0 |

**关键认知**：Dashboard 不是 Admin API 的"开关"，而是它的"皮肤"。**"有没有可视化界面"与"能不能管理"是两件事**——用 curl 一样能完整管理。您的 Syncer 当初设计的"Admin API 动态推送"路径，本质上就是一种无需 Dashboard 的管理方式（只是 standalone 模式下 API 不存在，需要切回 traditional 才能复活，详见 §6）。

### 3.2 官方对两种模式的立场

- **传统模式（etcd + Admin API）**：官方主推的动态配置模式，配置热更新、无重启；
- **Standalone 模式**：官方定位为 "designed specifically for the **APISIX Ingress Controller**"，文件驱动、**变更需改文件**（1 秒轮询热加载）；
- 官方 Dashboard 文档对重构后内置 UI 的定位："回归轻量化设计……与 APISIX 主版本保持版本同步……**生产就绪**"——即内置 UI 是受官方支持的生产可用组件，不再是"玩具"。

---

## 四、Q3：Dashboard 能可视化管理插件与配置吗？

### 4.1 能力矩阵（官方文档 + 版本演进事实）

| 管理对象 | 内置 Dashboard（3.x） | Admin API（curl/ADC） | config.yaml（静态） |
|:--|:--:|:--:|:--:|
| 路由 Routes | ✅ | ✅ | ✅（standalone yaml） |
| 上游 Upstreams | ✅ | ✅ | ✅ |
| 服务 Services | ✅ | ✅ | ✅ |
| 消费者 Consumers / 凭据 | ✅ | ✅ | ✅ |
| **插件 Plugins**（挂到路由/服务/全局） | ✅ 常用插件 | ✅ 全部插件 | ✅ |
| 插件元数据 plugin_metadata（如 jwt-auth 密钥） | ⚠️ 部分 | ✅ | ✅（standalone yaml 支持） |
| SSL 证书 | ✅ | ✅ | ✅ |
| 全局规则 / 插件编排 | ✅ | ✅ | ✅ |
| **启动配置**（etcd 地址、端口、admin key、enable_admin_ui） | ❌ | ❌ | ✅ **只能改文件重启** |

### 4.2 两个必须知道的局限

1. **插件白名单制**：Dashboard（旧版 2.x/3.0.1 及重构后的轻量化 UI）只把**常用插件**做成可视化表单；**不在白名单内的插件无法在 UI 中配置**（需 Admin API 或 ADC）。APISIX 插件数量庞大（当前 100+），UI 覆盖永远滞后于 API。判断方法：UI 的插件列表页能看到的就是支持的，看不到的走 API。
2. **`config.yaml` 不属于 Dashboard 管辖**：Dashboard 管理的是 etcd/内存中的"运行时资源"；网关的启动配置（监听端口、etcd 连接、Admin Key、`enable_admin_ui` 开关本身）只能编辑 `config.yaml` 后**重启容器**生效（standalone 模式下则是改 `apisix.yaml` 热加载）。

### 4.3 对您项目的具体映射

| 您当前要管理的 | 走哪条路 |
|:--|:--|
| jwt-auth 共享密钥（plugin_metadata） | 内置 Dashboard 的插件元数据页（若支持）**或** Admin API `PUT /plugin_metadata/jwt-auth` **或** standalone yaml `plugin_metadata:` 段 |
| authz-casbin 模型/策略 | Admin API `PUT /plugin_metadata/authz-casbin`（传统模式）或文件模式（standalone）；Dashboard 白名单对 casbin 类插件支持有限，建议 API |
| 路由（api-v1 重写等） | 三者皆可；**ADC 声明式最适合版本化管理** |

---

## 五、推荐部署方案（全栈，二选一）

### 方案 A：Docker etcd 容器（**推荐**，官方示例同款，与 WSL2 IP 漂移完全解耦）

在 `gateway/docker-compose.yml` 中新增 etcd 服务并把 APISIX 切回 traditional：

```yaml
services:
  etcd:
    image: bitnamilegacy/etcd:3.5.11
    container_name: app-etcd
    restart: unless-stopped
    networks:
      app-net:
        ipv4_address: 172.20.0.8
    environment:
      ALLOW_NONE_AUTHENTICATION: "yes"        # 仅开发环境；生产改用 ETCD_ROOT_PASSWORD
      ETCD_ADVERTISE_CLIENT_URLS: "http://app-etcd:2379"
      ETCD_LISTEN_CLIENT_URLS: "http://0.0.0.0:2379"
    volumes:
      - etcd_data:/bitnami/etcd
    # 注意：不映射 2379 到宿主（Pigsty etcd 已占用），容器间用 app-etcd:2379 互访

  apisix:
    image: apache/apisix:3.17.0-debian
    container_name: app-apisix
    restart: unless-stopped
    networks:
      app-net:
        ipv4_address: 172.20.0.3
    ports:
      - "9080:9080"
      - "9443:9443"
      - "9180:9180"          # ← Admin API + 内置 Dashboard
      - "7085:7085"          # ← Status API（健康检查）
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml:ro
    depends_on:
      - etcd
```

`gateway/apisix/config.yaml` 改为（**关键：从 standalone 切 traditional**）：

```yaml
apisix:
  node_listen: 9080
  enable_ipv6: false
  enable_control: true
  control:
    ip: "0.0.0.0"
    port: 9092              # 官方 example 用 9092 做 control API（避免与宿主 9090 冲突）
  status:
    ip: "0.0.0.0"
    port: 7085

deployment:
  role: traditional                    # ← 从 data_plane 改回
  role_traditional:
    config_provider: etcd
  admin:
    enable_admin_cors: true
    enable_admin_ui: true              # 内置 Dashboard（默认即 true，显式写出更清晰）
    allow_admin:
      - 0.0.0.0/0                      # 开发环境放行（含 Docker 网段）；生产收窄
    admin_key:
      - name: admin
        key: ${APISIX_ADMIN_KEY}       # ← 务必更换，不要用官方示例默认值
        role: admin
  etcd:
    host:
      - "http://app-etcd:2379"
    prefix: /apisix
    timeout: 30
```

**路由配置迁移**：traditional 模式下不再读 `apisix.yaml`，改为 Admin API 写入（etcd 持久化）。迁移方式：
- 方式 1（推荐）：把当前 `apisix.yaml` 的路由逐个 `PUT /apisix/admin/routes/{id}` 建到新环境；
- 方式 2：用 ADC 声明式迁移（`adc configure` 读取 yaml → `adc sync` 推送到传统模式网关）。

**启动后验证**：
```bash
curl -sf http://localhost:9180/apisix/admin/routes -H "X-API-KEY: <新key>" | head -c 300   # Admin API 通
# 浏览器打开 http://localhost:9180/ui → 填入 Admin Key → 进入可视化界面
```

### 方案 B：复用 Pigsty etcd（进阶，可选）

APISIX 官方 `conf/config.yaml.example`（3.17 分支）明确支持带认证与 TLS 的 etcd：

```yaml
deployment:
  etcd:
    host:
      - "https://127.0.0.1:2379"   # TLS 则用 https 前缀
    prefix: /apisix
    timeout: 30
    user: root                     # Pigsty etcd 已创建 root（fix-apisix-etcd.sh 做过）
    password: Etcd.Root
    tls:
      cert: /etc/pki/ca.crt        # Pigsty CA（容器内需挂载宿主 /etc/pki/ca.crt）
      key: /etc/pki/ca.key         # 仅当 etcd 要求客户端证书时
      verify: false                # 开发可先 false；生产 true 并挂载正确 CA
```

**注意（本方案在您环境里的三个坑）**：
1. **容器 → WSL2 网络**：`127.0.0.1` 在容器内是容器自己；需用 WSL2 发行版 IP（会漂移）或 Windows 11 mirrored 网络模式。这是方案 A 优于 B 的决定性理由；
2. **证书**：Pigsty CA 在 `/etc/pki/ca.crt`，需挂载进 APISIX 容器并保证 `verify` 配置正确；
3. **etcd gRPC gateway**：APISIX 经 HTTP 访问 etcd，需 etcd 开启 gateway（etcd 3.4+ 默认开启，Pigsty 部署的标准 etcd 满足）。

---

## 六、决策建议：全栈 vs 保持 standalone

| 维度 | 全栈（traditional + 内置 UI） | 当前 standalone（仅网关） |
|:--|:--|:--|
| 可视化操作 | ✅ 内置 UI（9180/ui） | ❌ 无（文件驱动） |
| 动态配置（免重启） | ✅ Admin API 热更新 | ⚠️ 改 apisix.yaml，1 秒热加载（也算"热"） |
| 组件数量 | +1（etcd 容器） | 0 |
| 与现有 Syncer 架构 | ✅ 复活（Admin API 推送策略，正是它设计的路径） | ❌ 需改造为写文件模式 |
| 与 CI/CD 集成 | ✅ curl/ADC 声明式 | ✅ 文件即代码，天然 GitOps |
| 复杂度/踩坑 | 中（etcd + 端口 + key 管理） | 低 |
| 官方定位 | 生产主流 | 主要为 Ingress Controller 设计 |

**给您的建议**：
1. **本地开发（WSL2）**：上方案 A 全栈——一个 etcd 容器换来自动化运维 + 可视化 + Syncer 复活，ROI 最高；
2. **若坚持零依赖**：维持 standalone，但需按 20 号文档把 `plugin_metadata`（jwt-auth 密钥）补进 `apisix.yaml`，并接受 Syncer 需改造的事实；
3. **无论哪种**：Admin Key 必须更换默认值；9180 不要暴露到公网；`allow_admin` 生产环境收窄。

---

## 七、参考文档

- [APISIX Dashboard（内置 UI）](https://apisix.apache.org/zh/docs/apisix/dashboard/) — 内嵌 UI、enable_admin_ui、Admin Key、旧版 3.0.1 弃用声明
- [APISIX Admin API](https://apisix.apache.org/zh/docs/apisix/admin-api/) — 管理接口全集（routes/upstreams/consumers/plugin_metadata…）
- [APISIX Control API](https://apisix.apache.org/zh/docs/apisix/control-api/) — 9090 内部运维接口
- [APISIX Status API](https://apisix.apache.org/zh/docs/apisix/status-api/) — 7085 就绪探针
- [APISIX 部署模式](https://apisix.apache.org/zh/docs/apisix/deployment-modes/) — traditional / decoupled / standalone 定义与配置
- [APISIX 安装依赖（etcd 要求）](https://apisix.apache.org/zh/docs/apisix/install-dependencies/) — etcd ≥ 3.4、HTTP(S) 通信、gRPC gateway
- [apisix-docker 官方示例](https://github.com/apache/apisix-docker/tree/master/example) — 全栈 compose + config.yaml（本报告 §2.1 引用）
- [APISIX conf/config.yaml.example（3.17 分支）](https://github.com/apache/apisix/blob/master/conf/config.yaml.example) — admin/enable_admin_ui/etcd(tls+auth) 权威配置键（本报告 §4/§5 引用）
