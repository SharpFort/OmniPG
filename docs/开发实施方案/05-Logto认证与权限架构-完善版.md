# 05 — Logto 认证 + PostgreSQL 授权架构（完善版）

> **状态**：✅ 已决策（2026-08-04）
> **决策人**：项目负责人
> **分析 / 调研**：Hermes（2026-08-04 多轮架构讨论 + Logto 官方文档与源码核实）
> **前置文档**：`docs/基于 Logto (自部署) 与 PostgreSQL 的高并发无状态认证与权限架构方案.md`（v1，本文档**完善并取代**其中设计内容）、`docs/开发实施方案/04.6-认证授权架构-最终决策.md`（Casdoor 方案，本文档为同一目标的 Logto 实现，决策对比见 §10）、`docs/开发实施方案/04.7-Casdoor托管角色单向Webhook方案-分析与对比-修订版.md`
> **规模基线**：战略目标千万级用户；当前从 0 开发，无存量用户/数据，一次性消除技术债
> **本文档新增决策**（2026-08-04 用户拍板）：
> - N1：**微信小程序不是必需** → Logto 连接器（微信网页/原生）可满足，Casdoor 的小程序优势不构成选型障碍
> - N2：**授权判定在 PG**：RLS / has_permission / 角色→业务权限绑定（iam_role_api / iam_menu）全部在 PG 执行；**角色目录与用户↔角色分配托管给 Logto**（v2.0 修订，原 N2"角色全在 PG"废弃）
> - N3：JWT 由 Logto 签发（RS256），角色经 **Custom Token Claims 脚本从 context 直接提取注入（零 fetch）** → 消灭 Casdoor 方案中自建 Go auth-service 组件，**也无需脚本 fetch PG**
> - N4：**空白业务、无历史数据** → 业务侧授权数据（iam_api / iam_menu / iam_role_api / iam_role_menu）全新设计，**无任何兼容/迁移考虑**；Casdoor 时代资产一律不迁移（§10.2）
>
> **修订记录**：
> - v2.8（2026-08-04）— **P1 管理 CRUD 落地（024/025 迁移）**：CRUD RPC 21 个（部门/岗位/字典/菜单/绑定/用户资料，统一 has_permission + log_operate 审计模式）+ 权限点 seed ×20（iam_api.api_code，超管/租户管理员绑定）+ user_role 分配镜像表 + rpc_sync_user_roles（本人 JIT 防伪造）+ 租户列表/成员 RPC + rpc_get_position_tree + v_dict_list/v_user_roles/v_role_users 视图
> - v2.7（2026-08-04）— **023 迁移（命名定稿 + P0 三项）**：① sys_ 前缀移除（dict_type/dict_data/login_log，iam_ 保留）；② `has_permission(code)` 实现（§6.3 落地：超管短路 + claims roles ∩ iam_role_api→iam_api.api_code）；③ 审计触发器补挂 8 张（系统管理 6 + 授权 2，镜像表不挂）；④ `rpc_search_login_logs`（租户维度登录日志查询）；⑤ iam_api 加 api_code 列（与 iam_menu.perms 对齐）
> - v2.6（2026-08-04）— **05.2 决策落地**：① iam_menu 加按钮级字段（022 迁移：menu_type/perms/component/is_visible）；② 管理端写 Logto 路径**放弃**（建号/禁用/角色分配改 Logto Console + webhook 同步，P1-10 更新）；③ sys_ 前缀移除与 position 树 RPC 模式（05.2 §五/六，待 023）
> - v2.5（2026-08-04）— **021 迁移（pg_cron RPC + GeoLite2 兜底 + 登录日志视图）**：`rpc_list_cron_jobs`/`rpc_list_cron_job_runs`（超管只读，D-E 落地）；`ip_geolite2_city` + staging + `import_geolite2_city()`（P2-24 落地）+ import-geolite2.sh；`geo_locate()` 查询顺序 ip2region→GeoLite2（含 IPv6 兜底）；ip2region 加 `family(ip)=4` 过滤；`v_login_log` 视图（Logto 推送日志 + 实时地理 join）；audit_log 完备性确认（table_name/operation/old_data/new_data 已覆盖变动来源表名）
> - v2.4（2026-08-04）— **登录日志链路落地（020 迁移）**：PostSignIn 平铺 payload 分发（源码核实无 data 包装）+ sync_login_log_write + ip2region(inet) 函数 + import-ip2region.sh 导入脚本；login_log RLS 加本人可见；约束形式按场景选用（PG ENUM 复用型 / TEXT+CHECK 频繁变化，05.1 D-B）
> - v2.3（2026-08-04）— **admin 模块补全决策（05.1 分析定稿）**：命名采纳备选 B（无前缀=平台基础域）；新增 position/user_position（树形）、dict_type/data、login_log、ip_region_v4（019 迁移）；audit_log 扩展为统一审计流（log_type+jsonb，D-5）；日志策略（操作日志业务侧 + 访问日志 APISIX + 异常 PG 日志）；登录日志 = webhook PostSignIn + 失败对账（否决网关/前端独立获取）
> - v2.2（2026-08-04）— **命名修正（E2 细化）**：role / user_role 同为 Logto 镜像表，与其他镜像表统一**无前缀**——命名规则定为"无前缀 = 镜像（Logto 权威，只读）/ `iam_` 前缀 = 自主（PG 权威，可写）"
> - v2.1（2026-08-04）— **第二轮实现决策（§6.7 E1-E5）**：表前缀统一 `iam_`（弃 public_）；casbin_rule 视图与自主表并存（性能等价，Redis 不采纳）；pg_session_jwt 不采纳（PostgREST 已做 PG 端解析，P2 备选）；role_code 生成列
> - v2.0（2026-08-04）— **定稿修订（N2 → 变体 B）**：角色目录+分配改托管 Logto（JWT 脚本零 fetch）；新增 GitHub issues 调查（PR #8674 被拒原因、issue #5099 挂起，F21）；角色名唯一性源码确认（F20）；§6 数据模型重写（Logto 权威 / PG 镜像 / PG 自主三类）
> - v1.0（2026-08-04）— 初稿：基于 Logto v1.42.0 官方文档与源码（logto-io/logto master、logto-io/docs master）核实的事实撰写

---

## 1. 决策摘要

**一句话**：Logto（自部署 OSS）承担认证（AuthN）+ 组织（租户）容器 + **角色目录与角色分配管理**；授权（AuthZ）判定在 PG。JWT 由 Logto 直接签发，**Custom Token Claims 脚本从 context 提取该用户在当前组织的角色注入 `roles` claim（零 fetch，JWT 一步生成）**；网关 `jwt-auth`（Logto JWKS）+ 自定义 Lua 插件 `authz-role-check` 做路由级角色检查；PG RLS 直接消费 `sub / organization_id / roles` claims；角色→业务权限绑定（iam_role_api / iam_menu）为业务侧**全新自主数据**（N4）。**无自建 token-exchange 服务、无脚本 fetch、无角色同步管道**，用户数彻底退出授权路径。

### 1.1 决策点总表

| # | 决策点 | 结论 |
|:---|:---|:---|
| D1 | Logto 定位 | **认证 + 组织容器 + 角色管理**：登录 / 注册 / 第三方登录（微信网页/原生等）/ 用户状态 / 组织（租户）与成员关系 / **角色目录 CRUD / 用户↔角色分配 / 组织成员↔组织角色分配**，**不参与授权判定** |
| D2 | 角色/权限真相源 | **角色目录与分配 = Logto**（权威）；**角色→业务权限绑定 = PG**（iam_role_api / iam_menu，业务侧全新自主数据，N4）；**授权判定 = PG**（RLS / has_permission） |
| D3 | JWT 签发方 | **Logto 自签**（RS256 + JWKS），Custom Token Claims 脚本**从 context 提取角色注入 `roles`（零 fetch）**；不建 auth-service、**无内部 RPC / service token** |
| D4 | JWT claims | 内置：`sub`（Logto 用户 ID）、`aud`（API 资源）、`organization_id`（组织 token，官方内置）、`scope`；自定义注入：`roles`（Logto 角色名数组 = 全局角色 ∪ 当前组织组织角色）、可选 `dept_id`（P2） |
| D5 | 登录流程 | Logto SDK 重定向登录 → authorization code → refresh token → **refresh token flow 换取组织 token**（官方限制：组织 token 不能从 code flow 直接获取） |
| D6 | 网关授权 | `jwt-auth`（验 Logto JWKS）+ **自定义 Lua 插件 `authz-role-check`**（路由级 required_roles，复用 04.6 插件设计） |
| D7 | 用户同步 | **Webhook 保留**（Logto → PG 单向）：`User.Created / User.Data.Updated / User.Deleted` |
| D8 | 租户同步 | **Webhook**：`Organization.Created / Data.Updated / Deleted` + `Organization.Membership.Updated`（增量数组 `addedUserIds / removedUserIds`，官方设计） |
| D9 | 用户镜像 | **瘦身字段集**（id / username / primaryEmail / primaryPhone / name / avatar / customData / isSuspended / 时间戳等，官方 webhook payload 白名单），**不含任何凭据/MFA 秘密** |
| D10 | 角色同步 | **PG 侧镜像策略**：角色目录（role 镜像）经 `Role.*` 事件同步 + 对账；分配（user_role 镜像）经 **JIT 覆盖 + 管理操作主动同步 + 对账**（官方无分配事件，F13/F21——JWT 永远准确，镜像仅服务管理面，允许延迟） |
| D11 | 角色生效时效 | 角色变更在**下次 token 签发（刷新）时生效**，残留窗口 ≤ access token 寿命（建议 15 分钟），与 04.6 §9.1 语义一致 |
| D12 | 会话/吊销 | Logto 原生会话管理：refresh token 撤销（revocation endpoint）即时失效；access token 残留 ≤ 寿命；可选 `maxAllowedGrants` 并发设备限制（官方事件 `Grant.LimitExceeded`） |
| D13 | RLS | 从 JWT claims 读取 `sub / organization_id / roles`（PostgREST `request.jwt.claims` 注入，官方确认），**零查询** |
| D14 | 微信 | 网页扫码（wechat-web，snsapi_userinfo）+ 原生 App（wechat-native）；**小程序不必须（N1），不引入 Casdoor** |

---

## 2. 背景与需求演变

### 2.1 原始需求
用开源 IdP 解决认证（密码 / 验证码 / 微信等国内第三方登录），业务授权基于 PostgreSQL（RLS 行级安全 + 会话变量）无状态执行；系统为零后端架构：PostgreSQL + PostgREST + APISIX + Vue3 前端。

### 2.2 v1 Logto 方案文档（docs/ 根目录）的问题（本文档的动因）
经源码核实，v1 文档存在以下问题：
1. **机制 1 JWT 脚本有 bug**：`context.organizationRoles` 是**对象数组** `{organizationId, roleId, roleName}`，v1 脚本 `roles.map(r => r.name)` 产出 `undefined`；且 **`context.organizationId` 不存在**（组织上下文在 `context.organization.id`，仅组织 token 存在）。
2. **机制 4 webhook 事件表错误**：`Organization.Membership.Updated` 只携带成员**增删增量**（`addedUserIds / removedUserIds`），**不包含角色分配变更**；且 Logto 的"用户↔角色分配"（`POST /roles/:id/users`、`PUT /users/:userId/roles`）与"组织成员↔组织角色分配"（`PUT /organizations/:id/users/:userId/roles`）**不触发任何 webhook 事件**（源码 `managementApiHooksRegistration` 注册表逐行核实）——v1 依赖 Membership.Updated 同步角色绑定不可行。
3. **授权架构空白**：v1 未决策"角色真相源放 Logto 还是 PG"，导致机制 2 的 `role_resources` 表与机制 4 的角色同步互相矛盾。
4. 未利用 Logto 原生能力：组织上下文 token（`organization_id` 内置 claim）、Custom Token Claims 脚本 fetch 能力、OSS 功能边界（未核实）。

### 2.3 Casdoor 方案（04.6）的决策亮点（本文档继承部分）
| 04.6 亮点 | 本文档处置 |
|:---|:---|
| 授权真相源 = PG sys 模块（D2） | ✅ 继承**判定层**（RLS / has_permission / iam_role_api）；⚠️ 角色目录与分配改托管 Logto（v2.0 定稿） |
| 授权路径不出现按用户展开的数据（§8 规模论证） | ✅ 原样继承：roles-in-JWT，用户数退出授权路径 |
| RLS 读 claims 零查询（§5.7） | ✅ 原样继承 |
| 网关职责边界：只回答"JWT 有效吗 + required_roles 有吗"（§5.6） | ✅ 原样继承 |
| authz-role-check Lua 插件设计（§7.2） | ✅ 原样继承（验签对象改为 Logto JWKS） |
| 镜像表瘦身（§9.4） | ✅ 继承（Logto payload 白名单天然满足） |
| Go auth-service token exchange（§7.1） | ❌ **消灭**：Logto Custom Token Claims 脚本 + context 提取（N3，零 fetch） |
| 应用自签 JWT 即时吊销（D11） | ⚠️ 调整：吊销依赖 Logto 会话管理 + 短 token（D12），语义等价（access token 残留 ≤ 寿命） |
| Casdoor webhook / Database Syncer / password grant 处置（§6） | ✅ 平移：webhook 保留，password grant 不存在（Logto 无此路径），Database Syncer 不需要 |
| Casdoor 无小程序则出局（F6） | ⚠️ 反转：**小程序不必须（N1）→ Logto 入选** |
| 角色分配同步教训（04.7 方案 C：Casdoor update-role 500 风险） | ✅ Logto 版绕开：JWT context 权威 + 镜像 JIT 覆盖/对账（F21 官方 PR 被拒印证该模式） |

### 2.4 规模诉求
千万级用户为战略目标 → 授权路径上不得出现按用户展开的数据，只允许按角色展开的数据。本文档的 roles-in-JWT 由 Logto 签发时**从 context 直接提取（零外部查询，Logto 本地实时计算）**，此后所有请求零授权查询，满足该约束。

---

## 3. 关键认知（支撑决策的已核实事实，2026-08-04）

### 3.1 官方文档核实

| # | 事实 | 来源 |
|:---|:---|:---|
| F1 | Logto webhook 事件三族：用户交互（PostRegister/PostSignIn/PostResetPassword）、数据变更（User.*/Role.*/Scope.*/Organization.*/OrganizationRole.*/OrganizationScope.*）、异常（Identifier.Lockout/Message.RateLimited/Grant.LimitExceeded） | docs.logto.io/developers/webhooks/webhooks-events |
| F2 | 数据变更事件 payload 顶层含 `event` 字段（Casdoor 无此字段）；受影响实体在 `data` 字段；User 实体为白名单字段集（id/username/primaryEmail/primaryPhone/name/avatar/customData/identities/lastSignInAt/createdAt/applicationId/isSuspended） | docs/developers/webhooks/webhooks-request（docs master `webhooks/request.mdx`） |
| F3 | `Organization.Membership.Updated` 顶层携带 `organizationId` + 增量数组 `addedUserIds/removedUserIds/addedApplicationIds/removedApplicationIds`（可选、缺失=无变更）；**每个数组上限 5000 条，超限静默截断且无标记** → 恰好 5000 条时应调 `GET /organizations/:id/users` 对账 | 同上 |
| F4 | 签名：header `logto-signature-sha-256` = HMAC-SHA256 hex(signingKey, **raw body**)；官方明确要求用原始 body 而非解析后 body 验签 | docs/developers/webhooks/secure-webhooks |
| F5 | Custom Token Claims：`getCustomJwtClaims({ token, context, environmentVariables, api })` 返回值合并进 access token；**内置 claims 不可覆盖**（冲突时自定义值被忽略） | docs/developers/custom-token-claims |
| F6 | 组织（Organization）是 Logto 一等实体：组织模板（Organization Template）提供组织角色/组织权限；请求 token 时带 `resource` + `organization_id` → JWT 含内置 `organization_id` claim，`scope` 按组织角色解析 | docs/authorization/organization-level-api-resources |
| F7 | **组织 token 不能从 authorization code flow 直接获取**，必须用 refresh token flow（官方 warning） | docs/authorization/fragments/_organization-token-warning.md |
| F8 | 未带 `resource` 时 access token 为 **opaque**（需 introspection），带 resource 才发 JWT（RFC 8707） | docs/authorization/role-based-access-control |
| F9 | Logto OSS（自部署）限制：Console 多租户 / Console MFA / 内置邮件服务 / Protected App / Bring Your UI / IdP-initiated SSO / SAML（限 3）/ 隐藏 branding 不可用；**Organizations、组织 RBAC、Webhooks、Custom JWT Claims、终端用户 MFA 在 OSS 可用**（官方原文：多租户等能力"you can implement these features in your own product using Logto OSS, making them available to your end users"） | docs/logto-oss/README.mdx |
| F10 | 微信连接器只有 **wechat-web**（网页扫码）与 **wechat-native**（原生 App），**无小程序连接器**（仓库 connectors 目录核实） | docs/integrations/social/wechat-web、wechat-native |
| F11 | 最新版本 v1.42.0（2026-07-30 发布） | github.com/logto-io/logto releases |

### 3.2 源码核实（logto-io/logto master）

| # | 事实 | 源码位置 |
|:---|:---|:---|
| F12 | **`managementApiHooksRegistration` 完整注册表**：`POST /users→User.Created`、`PATCH /users/:userId*→User.Data.Updated`、`PATCH /users/:userId/is-suspended→User.SuspensionStatus.Updated`、`POST/DELETE/PATCH /roles*→Role.*`、`POST/DELETE/PATCH /resources/:resourceId/scopes*→Scope.*`、`POST/DELETE/PATCH /organizations*→Organization.*`、`POST/DELETE/PATCH /organization-roles*→OrganizationRole.*`、`POST/DELETE/PATCH /organization-scopes*→OrganizationScope.*`。**无任何"用户↔角色分配"路由**（`/roles/:id/users`、`/users/:userId/roles`、`/organizations/:id/users/:userId/roles` 均不在注册表） | `packages/schemas/src/foundations/jsonb-types/hooks.ts` |
| F13 | **用户↔角色分配路由不触发任何事件**：`admin-user/role.ts` 与 `role.user.ts` 的 POST/PUT/DELETE 均无 `appendDataHookContext` 调用；组织成员↔组织角色分配（`organization/user/role-relations.ts`）同样无调用 → **角色分配变更在 Logto 中无 webhook 事件**（官方 PR #8674 曾尝试实现但被拒，F21）——本方案采用"JWT context 权威 + PG 分配镜像 JIT 覆盖"模式绕开该缺口 | `packages/core/src/routes/admin-user/role.ts`、`role.user.ts`、`organization/user/role-relations.ts` |
| F14 | **仅成功请求触发 data hooks**：`koa-management-api-hooks.ts` 在 `await next()` 成功后触发；源码注释 "these hooks are only triggered for successful requests"；失败请求只走 exception hooks（Identifier.Lockout 等）→ 不存在 Casdoor H4"失败也触发"问题 | `packages/core/src/middleware/koa-management-api-hooks.ts`、`libraries/hook/context-manager.ts` |
| F15 | webhook 投递：重试 3 次、超时 10s、fire-and-forget（不阻塞业务）、失败记录审计日志 | `packages/core/src/libraries/hook/utils.ts` |
| F16 | **Custom Token Claims 脚本沙箱**：OSS 版用 `node:vm` 本地执行，**注入 `fetch`（可调外部 HTTP）**，3 秒超时，运行在 Logto 进程内（安全提示：仅可信管理员可编辑脚本）；`blockIssuanceOnError` 配置控制脚本出错是否阻断签发 | `packages/core/src/utils/local-vm/index.ts`、`packages/schemas/src/types/logto-config/jwt-customizer.ts` |
| F17 | **customizer context 结构**（access-token 类型）：`{ user: {…, roles[], organizations[], organizationRoles[{organizationId, roleId, roleName}]}, grant?, interaction?, application?, organization: {id, name, description, customData}? }`；`context.organization` **仅当请求带 organization_id 时存在**（组织 token） | `packages/schemas/src/types/logto-config/jwt-customizer.ts`（`accessTokenJwtCustomizerGuard`） |
| F18 | **customizer 类型只有两种**：`access-token` 与 `client-credentials`（M2M）——组织 token 复用 access-token customizer，无独立类型 | 同上（`LogtoJwtTokenKeyType`） |
| F19 | `organization_id` claim 由 `extraTokenClaims` 添加，仅当 `resource` 与 `organization_id` 参数同时存在 | `packages/core/src/oidc/extra-token-claims.ts` |
| F20 | **角色名唯一性（join key 根基）**：`roles.name` 与 `organization_roles.name` 均为 `unique (tenant_id, name)` → 单实例（单 Logto tenant）下**角色名全局唯一**，可安全作为 PG `role_code` 与 iam_role_api/iam_role_menu 的 join key | `packages/schemas/tables/roles.sql`、`organization_roles.sql` |
| F21 | **GitHub 官方动态（分配事件短期无计划）**：① PR #8674「added user role update event」（2026-04-19）实现 `User.Roles.Updated`/`Organization.UserRoles.Updated` 事件，**2026-07-27 关闭未合并**——maintainer wangsijie 拒绝理由：事件只覆盖显式分配 API 子集，仍漏 5 条隐式路径（建号默认角色 / JIT 供应 / 接受邀请 / 首管理员供应 / 外键级联删除），且提交相同角色集也发假事件；② issue #5099（2023-12 提出）官方回应 "not an easy one, may require some time to be scheduled"，**挂起近 3 年** → 结论：官方推荐"全量查询 + 对账"模式（与 Membership 5000 截断文档同款思路），**JWT context 层永远准确（含全部隐式路径），镜像 JIT 收敛是正确模式** | github.com/logto-io/logto PR #8674、issue #5099 |

---

## 4. 目标架构

### 4.1 组件图

```
┌─ 前端 Vue3/Nuxt ─────────────────────────────────────────────────────┐
│  Logto SDK 重定向登录（密码 / 验证码 / 微信扫码 / 微信原生 App）            │
│  SDK getAccessToken(resource, organizationId) 拿组织 token              │
│  axios 拦截器：携带 JWT；401 → refresh / 重登                            │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ ① OIDC authorization code + PKCE
                               ▼
                        ┌─ Logto（自部署 OSS）───────────────┐
                        │ 认证：登录/注册/MFA/第三方/用户状态     │
                        │ 组织：租户容器 + 成员关系              │
                        │ 角色：目录 CRUD + 用户/成员角色分配     │
                        │ ② Custom Token Claims 脚本           │
                        │    读 context 提取角色（零 fetch）      │
                        └──────────┬──────────────────────────┘
                                   │ ③ Logto 签发 JWT（RS256）
                                   │    sub / organization_id / roles / aud
                                   ▼
                        ┌─ APISIX ───────────────────────────────┐
                        │ jwt-auth（验 Logto JWKS）               │
                        │ authz-role-check（Lua：路由级角色）       │
                        └──────────┬─────────────────────────────┘
                                   │ ④ 转发（附 JWT claims）
                                   ▼
                        ┌─ PostgREST ──┐        ┌─ PostgreSQL ────────────────────┐
                        │ 验 Logto JWKS │──────▶ │ 自主：iam_api/iam_menu/         │
                        │ 注入 claims   │        │       iam_role_api/iam_role_menu │
                        └──────────────┘        │ 镜像：users/tenants/user_tenants │
                                                │       role/user_role      │
                                                │ RLS：读 claims → 数据隔离          │
                                                └──────────────────────────────────┘
```

### 4.2 组件清单

| 组件 | 职责 | 关键配置 |
|:---|:---|:---|
| Logto（自部署 OSS v1.42） | 认证（密码/验证码/微信/第三方）、组织（租户）与成员管理、**角色目录 CRUD / 用户↔角色分配**、签发 JWT | Application（clientId/secret、redirectUri）、社交连接器（wechat-web/native）、webhook 指向 PostgREST RPC、组织模板角色（tenant_admin/editor/viewer 等）、全局角色、access-token Custom Token Claims 脚本（context 版）、access token 寿命 15 分钟 |
| APISIX | jwt-auth（Logto JWKS 验签）+ authz-role-check（required_roles） | Logto `/.well-known/jwks`；路由级 `required_roles`（静态配置） |
| PostgREST | 业务 API 层 | JWKS 指向 Logto；`request.jwt.claims` 注入（组织 token 的 organization_id） |
| PostgreSQL | 业务数据 + 授权判定（RLS/has_permission）+ 镜像表 + 业务自主绑定表 + admin 系统管理表 | 镜像：users/tenants/user_tenants/role/user_role；授权：iam_api/iam_menu/iam_role_api/iam_role_menu；系统管理：app_config/audit_log/cron_job_log/department/user_profile/position/user_position/dict_type/dict_data/login_log/ip_region_v4（019 迁移，05.1 定稿）；RLS 策略 |
| 前端 | Logto SDK 登录 + token 管理 + 菜单缓存 | SDK（react/vue）、axios 拦截器、`rpc_get_user_permissions` 登录时查一次 |

---

## 5. 核心机制设计（v1 修正版）

### 机制 1：无状态认证与 JWT 自定义 Claims 注入（修正 v1 脚本）

#### 1.1 配置 Custom Token Claims（Console → API 资源 → Custom JWT Claims，tokenType=access-token）

```javascript
// Logto Custom Token Claims 脚本（v2.0 定稿：零 fetch，直接从 context 提取 Logto 权威角色）
const getCustomJwtClaims = async ({ token, context }) => {
  // ① 全局角色：context.user.roles（Logto roles 表，type=User）
  const globalRoles = (context.user?.roles ?? []).map((r) => r.name);

  // ② 组织角色：仅组织 token 存在 context.organization（F17）
  const orgId = context.organization?.id;
  const orgRoles = orgId
    ? (context.user?.organizationRoles ?? [])
        .filter((r) => r.organizationId === orgId)
        .map((r) => r.roleName)
    : [];

  // ③ 并集注入（全局角色 + 当前组织组织角色）；无角色时为空数组
  return { roles: [...new Set([...globalRoles, ...orgRoles])] };
};
```

**脚本要点（v2.0）**：
- **零 fetch、零外部依赖**：`context.user.roles` / `context.user.organizationRoles` 由 Logto 在签发时实时计算（含建号默认角色 / JIT 供应 / 邀请接受 / 级联删除等**全部隐式路径**，F21 印证 context 层无遗漏）——JWT 一步生成
- 内置 claims 不可覆盖（F5）：`organization_id` / `scope` / `sub` / `aud` 由 Logto 保证，脚本只注入 `roles`（与内置无冲突）
- **无 `blockIssuanceOnError` 需求**：脚本纯同步内存提取，无外部失败点，远低于 3s 超时
- 脚本执行频率：仅登录/刷新/换 token 时；纯内存计算，**无 QPS 压力、无 PG 依赖**（Logto 不可用时本就不签发 token）

#### 1.2 生成的 JWT Payload 结构样例（组织 token）

```json
{
  "iss": "https://logto.example.com/oidc",
  "sub": "logto_user_uuid_123456",
  "aud": "https://api.citywalk.example.com",
  "exp": 1712345678,
  "organization_id": "org_tenant_abc_789",
  "scope": "",
  "roles": ["tenant_admin", "editor"],
  "jti": "…"
}
```

- `organization_id`：Logto 内置（F19），RLS 租户隔离直接消费
- `roles`：脚本注入的 **Logto 角色名数组**（全局角色 ∪ 当前组织组织角色，F20 唯一性保证与 `iam_role_api.role_code` 对齐）
- `scope`：Logto 原生 RBAC 的权限点——本方案**未使用 Logto 角色↔scope 绑定**，该 claim 为空；如 P2 启用（角色挂 scope，perms-in-JWT 原生），可作 has_permission 的零查询来源（可选演进，§12 P2-14）

#### 1.3 组织 token 获取流程（官方限制的落地，F7）

```text
1. 前端未登录 → 重定向 Logto 登录页（SDK signIn，含 PKCE；scope 含 offline_access 以获取 refresh token）
2. 用户完成认证（密码 / 验证码 / 微信扫码 / 微信原生 App）
3. 回调 → 前端获得 authorization code → SDK 换 token（此步拿到的是普通 access token + refresh token）
4. 前端用 refresh token 调 SDK getAccessToken(resource, organizationId)
   → Logto 签发组织 token（organization_id + roles 脚本注入）
5. 前端以组织 token 调业务 API；过期 → SDK 自动 refresh（角色变更在此时生效，D11）
```

> 说明：组织 token 不能从 code flow 直接获取（F7），SDK 的 getAccessToken(resource, organizationId) 内部即 refresh token flow，对业务组件透明。
> 全局 token（无 organization_id）：用于无租户上下文的 API（如登录态查询）；`roles` 脚本注入该用户的**全局角色**（context.user.roles，Logto roles 表 type=User）。

### 机制 2：前端资源加载与数据库级并集去重（保留 v1 设计，落地到 sys 模块）

前端登录后调用 `rpc_get_user_permissions`（PG 侧函数，04.6 已设计），基于 JWT `roles` claims 过滤角色→菜单/API 绑定表，**单条 SQL 并集去重**返回权限树，前端缓存（Pinia/Redux），后续 UI 渲染零请求：

```sql
-- rpc_get_user_permissions 核心查询（沿用 04.6 casbin_rule 视图 / iam_role_api + iam_menu）
SELECT DISTINCT resource_type, resource_id, action
FROM role_resources
WHERE role_name = ANY (current_user_roles());  -- current_user_roles() 读 JWT claims（机制 3）
```

- v1 的 `role_resources` 扁平表可保留为资源目录视图；生产实现直接使用业务自主表（iam_role_api / iam_menu，N4 全新建），`role_name` 列与 Logto 角色名（role_code）对齐（见 §6.4 join key）
- **网关不查此表**（04.6 §5.6 职责边界不变）

### 机制 3：后端无状态 RLS 行级安全隔离（修正 claims 来源）

#### 3.1 claims helper（PostgREST 验签后注入 `request.jwt.claims`，官方确认；零查询）

```sql
-- 租户 ID：组织 token 的内置 claim
CREATE FUNCTION current_tenant_id() RETURNS text AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'organization_id', '')
$$ LANGUAGE sql STABLE;

-- 角色：脚本注入的 Logto 角色名数组（全局角色 ∪ 当前组织组织角色）
CREATE FUNCTION current_user_roles() RETURNS text[] AS $$
  SELECT COALESCE(ARRAY(
    SELECT jsonb_array_elements_text(current_setting('request.jwt.claims', true)::jsonb->'roles')
  ), ARRAY[]::text[])
$$ LANGUAGE sql STABLE;

-- 用户 ID
CREATE FUNCTION current_user_id() RETURNS text AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'sub', '')
$$ LANGUAGE sql STABLE;
```

> 注：v1 文档使用 `app.current_user_id` 会话变量 + 事务内 `set_config` —— 在零后端架构下该注入由 PostgREST 完成（`request.jwt.claims`），**无需后端代码 set_config**；若存在非 PostgREST 入口（如内部任务），保留 set_config 兜底路径（04.6 同款）。

#### 3.2 RLS 策略（租户隔离 + 角色例外）

```sql
ALTER TABLE business_data ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_user_isolation_policy ON business_data
AS RESTRICTIVE
USING (
  tenant_id = current_tenant_id()
  AND (
    owner_id = current_user_id()
    OR current_user_roles() @> ARRAY['role_super_admin']   -- 全局超管例外
    OR current_user_roles() @> ARRAY['tenant_admin']       -- 租户管理员例外
  )
);
```

- 全程读 claims，字符串比较微秒级，无角色/用户表查询（04.6 §5.7 同款）
- `has_permission(code)`：RPC 内显式调用，claims roles + iam_role_api 小表索引查询（角色数×权限数 ≤ 5 万行，与用户数无关）

### 机制 4：实体数据同步（Logto Webhooks，v1 事件表修正版）

#### 4.1 禁止使用 `CREATE ROLE`（保留 v1 要点）
所有用户/组织/角色均存储为**业务表数据行**，绝不映射为 PG 系统角色（防系统表膨胀/锁争抢/连接池失效）。

#### 4.2 Webhook 事件订阅设计（v2.0：4 类事件，含角色目录）

| 业务实体 | 订阅的 Logto 事件（F1/F2） | 后端 PG 对应行为 | 说明 |
|:---|:---|:---|:---|
| **用户 (User)** | `User.Created`<br>`User.Data.Updated`<br>`User.Deleted` | `INSERT ... ON CONFLICT DO UPDATE`（users 镜像） | payload `data` 为 UserEntity 白名单（F2），天然无凭据 |
| **租户/组织 (Org)** | `Organization.Created`<br>`Organization.Data.Updated`<br>`Organization.Deleted` | 同步维护 `tenants` 物理表（id = Logto organization id） | `data` 为 Organization 实体（id/name/description/customData/createdAt） |
| **租户成员关系** | `Organization.Membership.Updated` | **增量 diff 同步** `user_tenants`：`addedUserIds`→insert、`removedUserIds`→delete | 增量数组缺失=无变更（F3）；**不含角色绑定**（F12/F13） |
| **角色目录 (Role)** | `Role.Created`<br>`Role.Deleted`<br>`Role.Data.Updated` | 同步维护 `role` 镜像（id/name/type/isDefault） | role_code = Role.name（F20 唯一）；**授权判定不依赖此镜像**（claims 直连 iam_role_api），镜像服务管理端展示/对账 |
| **登录事件 (D-C, v2.4)** | `PostSignIn` | `sync_login_log_write` → `login_log`（含 region 解析） | ⚠️ **interaction payload 顶层平铺、无 data 包装**（源码核实 `libraries/hook/index.ts`）：`{event, interactionEvent, sessionId, applicationId, userIp, userAgent, userId, user, hookId, createdAt}`；tenant_id 留 NULL（事件无组织上下文）；失败登录 → P1 对账 |

**关键澄清（v2.0 修正）**：
- **`Organization.Membership.Updated` 不携带任何角色绑定信息**（只含成员增删增量）——v1 表格中"同步维护 user_roles 关联表"的描述**删除**；user_roles 由 Logto 分配（权威），PG 镜像经 §6.5 策略收敛
- **用户↔角色分配、组织成员↔组织角色分配在 Logto 中无 webhook 事件（F13/F21）**：JWT 永远准确（context 实时计算，含全部隐式路径），PG 分配镜像（user_role）通过 **JIT 覆盖 + 管理操作主动同步 + 对账** 收敛（§6.5），允许分钟级延迟——镜像仅服务管理面查询，不进授权路径
- 组织角色（OrganizationRole.* / OrganizationScope.*）事件：**可选订阅**（P2，如需同步组织角色目录到 PG 管理端展示）

#### 4.3 Webhook 接收端设计（PostgREST RPC）

```sql
-- 接收 RPC（v1 的 (event, user) 签名是 Casdoor 遗留，Logto payload 结构不同，重写）
CREATE OR REPLACE FUNCTION rpc_webhook_logto(payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_event text := payload->>'event';
BEGIN
  -- 验签在网关层完成（APISIX 校验 logto-signature-sha-256，或 PostgREST 前置校验）
  CASE v_event
    WHEN 'User.Created' THEN PERFORM sync_user_upsert(payload->'data');
    WHEN 'User.Data.Updated' THEN PERFORM sync_user_upsert(payload->'data');
    WHEN 'User.Deleted' THEN PERFORM sync_user_delete(payload->'data'->>'id');
    WHEN 'Organization.Created' THEN PERFORM sync_tenant_upsert(payload->'data');
    WHEN 'Organization.Data.Updated' THEN PERFORM sync_tenant_upsert(payload->'data');
    WHEN 'Organization.Deleted' THEN PERFORM sync_tenant_delete(payload->'data'->>'id');
    WHEN 'Organization.Membership.Updated' THEN
      PERFORM sync_membership_delta(
        payload->>'organizationId',
        COALESCE(payload->'addedUserIds', '[]'::jsonb),
        COALESCE(payload->'removedUserIds', '[]'::jsonb));
    WHEN 'Role.Created' THEN PERFORM sync_role_upsert(payload->'data');
    WHEN 'Role.Data.Updated' THEN PERFORM sync_role_upsert(payload->'data');
    WHEN 'Role.Deleted' THEN PERFORM sync_role_delete(payload->'data'->>'id');
    ELSE NULL; -- 忽略其他事件（Scope.*/OrganizationRole.* 等，P2 可选扩展）
  END CASE;
  RETURN jsonb_build_object('ok', true);
END $$;
```

#### 4.4 Webhook 安全验证（修正 v1：签名算法细节）

- 签名 header：`logto-signature-sha-256`（F4）
- 算法：`HMAC-SHA256(signingKey, rawBody)` 十六进制输出，与 header 值**恒定时间比较**
- **必须使用原始请求体**（raw body）计算，不可用解析后的 JSON 字符串（官方明确要求，F4）
- 建议在 APISIX 前置校验（自定义 Lua 或 `serverless-pre-function` 插件），PostgREST RPC 内不再重复验签
- 补充：投递重试 3 次、超时 10s（F15），接收端应幂等（ON CONFLICT / 增量删除天然幂等）

#### 4.5 一致性兜底（新增）

| 兜底 | 说明 |
|:---|:---|
| 增量 5000 截断（F3） | 收到恰好 5000 条的数组 → 触发 `GET /organizations/:id/users` 全量对账 |
| 投递失败监控 | webhook 执行统计在 Logto Console 可查（executionStats）；失败告警（P2） |
| JIT 建档 | 用户首次出现（webhook 遗漏/并发竞态）→ 登录后按 claims 补建 users 镜像（ensure_user 逻辑，04.6 同款） |
| 角色目录对账 | 每日低频对账 role 镜像（Role.* 事件为主、对账兜底） |
| 分配镜像收敛 | user_role 经 **JIT 覆盖（按 claims 全量覆盖）+ 管理操作主动同步 + 每日对账**（§6.5）；镜像延迟不影响授权（判定读 claims） |
| 定期对账 | 每日低频全量对账 users/tenants/user_tenants 镜像（增量事件为主、对账兜底） |

---

## 6. 授权真相源与数据模型（v2.0 定稿：Logto 权威 + PG 镜像 + PG 自主）

### 6.1 三类数据总览（空白业务全新设计，N4）

| 类别 | 数据 | 权威方 | 业务 PG 侧 | 同步方式 |
|:---|:---|:---|:---|:---|
| **① Logto 权威** | 用户、组织（租户）、组织成员、**角色目录**、**用户↔角色分配**、组织成员↔组织角色分配 | Logto | — | 经 webhook / JIT / Management API 投影到 ② |
| **② PG 镜像**（只读投影） | users、tenants、user_tenants、role（角色目录）、user_role（分配） | Logto | 镜像表（业务只读） | User.* / Organization.* / Membership / Role.* webhook + JIT 建档 + 分配 JIT 覆盖 + 对账（§4.5、§6.5） |
| **③ PG 自主**（业务真相源，**全新建**） | iam_api（权限点目录）、iam_menu（菜单树）、iam_role_api（角色→API 绑定）、iam_role_menu（角色→菜单绑定） | **业务 PG** | 业务直接写 | 无（不依赖 Logto） |
| **④ 授权判定** | 网关 required_roles / RLS / has_permission | PG 执行 | 读 claims + ③ 小表 | 零查询（claims）+ 小表索引 |

**关键原则**：
- **授权判定绝不读镜像表**（②）：② 只服务管理端查询/报表/前端菜单，允许分钟级延迟；JWT claims 永远准确（context 由 Logto 实时计算，含建号默认角色/JIT/邀请/级联删除等全部隐式路径，F21 印证）
- 角色码（role_code）= Logto 角色名（Role.name / OrganizationRole.name），**单实例下全局唯一（F20）**，是 ③ 的 join key
- 空白业务 → ③ 全新建，无兼容约束（N4）；Casdoor 时代资产一律不迁移（§10.2）

### 6.2 角色模型（Logto 侧，v2.0）

```
Logto roles 表（全局角色，type=User）      → 全局角色（如 role_super_admin）
Logto organization_roles 表（组织模板）    → 租户角色（如 tenant_admin / editor / viewer）
   ↑ 组织模板全局共享：所有组织同一套组织角色定义，
     租户差异 = 各组织内的成员角色分配（Organization 成员页分配）
```

- JWT `roles` claim = 全局角色名 ∪ 当前组织组织角色名（脚本 §5.1.1 并集注入）
- 管理入口：Logto Console（Roles / Organization template / Organization 成员页），或业务管理端调 Management API（`POST /api/roles`、`POST /api/roles/:id/users`、`PUT /api/organizations/:id/users/:userId/roles`——低频管理操作，且 Management API 调用同样触发 webhook，F2 触发表）
- 角色↔权限点（scope）绑定：**不使用 Logto 原生 RBAC 绑定**（scope claim 留空）；绑定在 ③（iam_role_api）由业务侧管理——授权判定层与 v1 相同（N2 判定层不变）

### 6.3 授权判定链路（不变）

| 层 | 判定位置 | 回答的问题 | 成本 |
|:---|:---|:---|:---|
| 路由级 | 网关 authz-role-check | required_roles 在 claims roles 里吗 | 读 claims O(1) |
| API 级 | PG has_permission(code) | claims roles + iam_role_api 有该权限点吗 | 小表索引（角色×权限 ≤ 5 万行，与用户数无关） |
| 数据级 | PG RLS | 行 tenant_id = organization_id 且 owner/角色例外 | 读 claims 零查询 |

### 6.4 join key 与角色码约束

- JWT `roles` 数组元素 = Logto 角色名（即 role_code，字符串）
- **唯一性由 Logto 保证**（F20：`unique (tenant_id, name)`，单实例即全局唯一）——无需 PG 侧再维护唯一约束逻辑
- **约束**：角色名一经创建不可变更（变更=新建+迁移 iam_role_api/iam_role_menu 绑定 + 网关 required_roles 配置 + RLS 策略）——沿用 04.7 H7 的教训；Logto 角色重命名（Role.Data.Updated）时应拒绝或走"新建+迁移"流程（P1 管理端约束）
- 角色码命名规范：`role_` 前缀 + 语义名（如 `role_super_admin` / `tenant_admin`），避免与 Logto 内置概念混淆

### 6.5 分配镜像同步策略（官方无分配事件的落地，F13/F21）

```text
Logto（权威：Console / Management API 分配）        PG user_role（镜像）
  │ 分配变更
  ├─ ① 管理操作主动同步：业务管理端调 Management API 成功后
  │      → 立即调 rpc_sync_user_roles(user_id, roles[]) 更新 PG 镜像
  ├─ ② JIT 覆盖：用户携带新 token 访问管理端查询时，
  │      → 按 claims roles 全量覆盖该用户镜像（幂等 upsert + 删除不在列表的）
  ├─ ③ 每日对账：低频全量对账（活跃组织范围），兜底 Console 直改/webhook 丢失
  └─ ④ JWT 层永远准确：授权判定读 claims，不依赖镜像
       → 镜像延迟分钟级可接受（仅管理端查询/报表消费）
```

- **P0 阶段可不建 user_role 镜像**：授权不依赖它；管理端"查某用户角色/某角色用户"先走 Logto Management API（`GET /api/users/:id/roles`、`GET /api/roles/:id/users`）
- P1 按管理端报表需求再建镜像（§12 P1-11）

### 6.6 角色管理面决策记录（2026-08-04 定稿）

- 原 N2（角色目录/分配全在 PG + 脚本 fetch PG）→ **v2.0 废弃**
- **定稿（变体 B）**：角色目录/分配托管 Logto——JWT 脚本零 fetch（context 权威）、管理 UI 直接用 Logto Console、无 service token/内部 RPC、无角色同步管道（镜像仅管理面）
- **GitHub 官方动态（F21）**：PR #8674（分配事件实现）被官方拒绝——事件无法覆盖 5 条隐式分配路径（建号默认角色 / JIT 供应 / 接受邀请 / 首管理员供应 / 外键级联删除），且提交相同角色集会发假事件；issue #5099 挂起近 3 年，官方短期无计划 → 印证"JWT context 权威 + 镜像 JIT 收敛 + 对账"是官方认可模式（对账推荐与 Membership 5000 截断文档同款思路）
- 混合模式（角色目录 Logto + 分配 PG）不采用：两个真相源需对齐，无收益

### 6.7 实现决策补充（2026-08-04 v2.1，第二轮评审结论）

| # | 议题 | 结论 | 理由 |
|:---|:---|:---|:---|
| E1 | pg_session_jwt 替代网关 jwt-auth + authz-role-check | ❌ **不采纳** | PG 端解析已由 PostgREST 完成（验签 + 注入 `request.jwt.claims`），pg_session_jwt（Supabase 扩展）功能重复且面向"无 PostgREST 直连"场景；网关是分层防御（未授权请求不占 PG 连接、保护 PostgREST 表级暴露端点、统一 401/限流/审计）。**P2 备选**：仅当出现非 PostgREST 入口（如内部任务需带身份）时按需引入 |
| E2 | 表前缀（v2.3 定稿：备选方案 B） | ✅ **无前缀 = 平台基础域（Logto 镜像只读 + 系统管理可写），`iam_` = 授权域** | `public_` 与 PG 保留概念冲突。**命名规则：无前缀 = 平台基础域：`users` / `tenants` / `user_tenants` / `role` / `user_role`（Logto 镜像，只读）+ `app_config` / `audit_log` / `cron_job_log` / `department` / `user_profile` / `position` / `dict_type` / `dict_data` / `login_log` / `ip_region_v4`（系统管理，可写）；`iam_` 前缀 = 授权域（可写）：`iam_api` / `iam_menu` / `iam_role_api` / `iam_role_menu`**（v2.2 修正镜像统一无前缀；v2.3 采纳备选 B，系统表保持无前缀） |
| E3 | casbin_rule 视图 vs 直接自主表；Redis 缓存 | ✅ **视图并存（表真相源 + 视图投影）；❌ Redis 不采纳** | 视图查询时内联 = 底层表查询，**性能等价**；`casbin_rule` 视图（v0=role_code, v1=资源, v2=action，排除用户维度）作为 iam_role_api/iam_role_menu 的只读投影供 rpc_get_user_permissions 消费。Redis 收益 ≈ 0.1ms 小表索引查询，成本 = 缓存失效管道 + 一致性负担，违背无状态原则；**正确演进方向 = perms-in-JWT**（P2-16，Logto scope claim 原生，授权判定零查询且无缓存一致性问题） |
| E5 | role 镜像加 role_code 列 | ⚠️ **部分采纳（生成列，勿独立映射）** | role_code = Logto 角色名（F20 唯一），绑定表（iam_role_api/iam_role_menu）直接以 role_code 为 join key（已是现状）；镜像表如需语义化列名用**生成列** `role_code text GENERATED ALWAYS AS (name) STORED`，单一真相源，不引入独立映射 |

---

## 7. 完整业务时序与数据流

```
[ 终端用户 ]      [ 前端 App ]        [ Logto IAM ]      [ APISIX/PostgREST ]   [ PostgreSQL ]
    │                  │                   │                    │                    │
    ├─ 1. 点击登录 ───>│                   │                    │                    │
    │                  ├─ 2. 重定向登录 ───>│                    │                    │
    │                  │<─ 3. 认证完成 ────┤ (密码/验证码/微信)   │                    │
    │                  │    (code → token + refresh_token)      │                    │
    │                  ├─ 4. 换组织 token ─>│                    │                    │
    │                  │  (refresh + resource + organization_id)│                    │
    │                  │                   ├─ 5. 执行 custom     │                    │
    │                  │                   │    claims 脚本      │                    │
    │                  │                   │    （读 context，   │                    │
    │                  │                   │     零 fetch）      │                    │
    │                  │<─ 7. 组织 token ──┤ (sub/org_id/roles)  │                    │
    │                  │                   │                    │                    │
    ├─ 8. 初始化 ─────>│                   │                    │                    │
    │                  ├─ 9. rpc_get_user_permissions ─────────────────────────────>│
    │                  │<─ 10. 权限树缓存 ──┤                    │                    │
    │                  │                   │                    │                    │
    ├─ 11. 业务请求 ──>│                   │                    │                    │
    │                  ├─ 12. 请求业务 API ─────────────────────>│                    │
    │                  │  (Bearer 组织 token)                    │                    │
    │                  │                   │ 13. jwt-auth 验签   │                    │
    │                  │                   │ 14. authz-role-check│                    │
    │                  │                   │ 15. PostgREST 注入   │                    │
    │                  │                   │     claims ────────>│ 16. RLS 行级过滤   │
    │                  │<─ 17. 渲染结果 ────┤<─ 18. 安全数据 ─────┤                    │
```

**Webhook 同步链路（异步，与业务请求并行）**：Logto 事件（User.*/Organization.*/Membership）→ 签名校验（APISIX）→ PostgREST RPC → PG 镜像表。

---

## 8. 规模论证（千万级用户）

| 维度 | 数值 | 说明 |
|:---|:---|:---|
| 授权判定成本 | **O(1)** | 网关/RLS/has_permission 全部读 JWT claims；唯一小表查询 iam_role_api（角色×权限 ≤ 5 万行，与用户数无关） |
| token 签发成本 | **零外部查询** | 脚本纯内存读 context（Logto 本地实时计算角色，无 fetch、无 QPS 压力）；签发 QPS ≈ 活跃用户数 ÷ token 寿命，Logto 自身可水平扩展 |
| 网关内存 | O(1) | 只读 JWT，无策略表（04.6 §8 对比同款结论） |
| PG 授权表规模 | 角色×权限（5 万行封顶） | ③ 自主表（iam_role_api/iam_role_menu），不随用户数增长 |
| 镜像表规模 | users / user_tenants / role / user_role 随用户数线性增长 | 属常规业务表（水平扩展），**不进授权路径** |
| 用户数影响面 | 仅 Logto 用户库 + PG 业务表 | Logto 可多副本 + 共享 PG/Redis 横向扩展（登录 QPS 瓶颈，04.6 §9.6 同款备注） |

**结论**：用户数（千万级）仅影响身份存储与业务表规模，**不进入授权判定路径**。与 04.6 方案 B 同等保证，且少一个自建服务组件。

---

## 9. 安全设计

### 9.1 Token 生命周期与吊销（D12）
- access token：15 分钟（Logto Console 可配置，建议按 04.6 基线）
- refresh token：Logto 原生管理（轮换、撤销端点 `POST /oidc/token/revocation`）
- 吊销语义：
  - 用户禁用/删除（Logto 侧操作）→ 下次刷新被拒（Logto 校验用户状态）；Webhook `User.SuspensionStatus.Updated` 同步 PG 镜像（可选订阅）
  - 会话即时吊销：调 Logto 撤销 refresh token → 前端 401 → 重登
  - access token 残留 ≤ 15 分钟（标准 JWT 语义，04.6 §9.1 一致；如需秒级吊销需网关黑名单，P2 按需）
- 可选：应用级 `maxAllowedGrants`（并发设备上限）→ 超限自动撤销最旧授权 + `Grant.LimitExceeded` 事件（可订阅做风控）

### 9.2 Webhook 安全
- HMAC-SHA256 原始 body 验签（F4）+ 恒定时间比较；signingKey 仅存部署配置
- 接收端点建议限制来源 IP（Logto 出口）或仅经网关暴露

### 9.3 Custom Token Claims 脚本安全（v2.0：无外部调用面）
- 脚本**零外部调用**（纯 context 提取，无 fetch/无 environmentVariables 敏感值）→ 攻击面最小化；仅可信管理员可编辑（官方安全提示）
- 输出仅 `roles` 角色名数组，无 PII、无敏感字段
- 内置 claims 不可覆盖（F5），脚本无法伪造 `sub` / `organization_id` / `aud`

### 9.4 最小权限
- Logto webhook 接收 RPC：仅写镜像表（users/tenants/user_tenants/role）+ login_log（PostSignIn 同步，D-C），无业务表权限
- ③ 授权表（iam_role_api/iam_menu 等）：业务角色管理，仅管理端经 RPC 写（带 has_permission 检查）
- 系统管理表（app_config/audit_log/department/position/sys_dict_*/login_log 等）：管理端经 RPC 写（带 has_permission）；audit_log 触发器写经 SECURITY DEFINER
- 镜像表无任何凭据字段（F2 白名单天然保证）；Logto 管理凭据（M2M client secret）仅存部署配置

### 9.5 降级策略
- **脚本无外部失败点**（纯内存提取）→ 签发路径无新增依赖
- Logto 不可用：已签发 token 有效期内业务不受影响（无每请求依赖）；登录/刷新降级提示
- webhook 投递失败：镜像延迟（分钟级），授权不受影响（判定读 claims）；Console 健康监控 + 对账兜底

---

## 10. 与 Casdoor 方案（04.6/04.7）的对比与资产处置

### 10.1 架构对比

| 维度 | 04.6 方案 B（Casdoor） | 本方案（Logto） | 评价 |
|:---|:---|:---|:---|
| 认证 | Casdoor（密码/微信/小程序/支付宝…） | Logto（密码/验证码/微信 web+native） | Logto **缺小程序**（N1 已决策不必须）；连接器生态 Casdoor 更全（国内） |
| JWT 签发 | 自建 Go auth-service（~300 行，token exchange） | **Logto 自签 + Custom Claims 脚本** | Logto 消灭一个服务组件（N3）；代价：吊销语义从"应用自签可控"变为"Logto 会话管理"（等价，D12） |
| 角色注入 | auth-service 查 PG 后签入 | 脚本读 context 直接提取（**零 fetch**） | Logto 一步生成 JWT，无跨服务查询 |
| 授权真相源 | PG sys 模块 | **角色目录/分配 = Logto；角色→权限绑定与判定 = PG** | 判定层一致，角色管理面移到 Logto（v2.0） |
| 网关 | jwt-auth（应用 JWKS）+ authz-role-check | jwt-auth（Logto JWKS）+ authz-role-check | 一致（插件复用） |
| 用户同步 | webhook（Casdoor payload 结构与文档不符，Phase 1 RPC 签名从未命中） | webhook（payload 结构官方明确：有 event 字段、data 白名单、仅成功触发） | **Logto 显著更优**（F2/F14） |
| 租户 | PG 自建 tenants + 分配 | Logto Organization（原生容器）+ Membership webhook | Logto 白送租户管理 UI/邀请/成员管理（OSS 可用，F9） |
| 角色分配同步 | 无事件（Casdoor update-role 500 风险）→ 方案 C 受阻 | 分配无事件（F13/F21）→ **JWT context 权威 + 镜像 JIT 覆盖/对账** | JWT 永远准确（context 实时计算），镜像延迟容忍；官方 PR #8674 被拒印证该模式 |
| 会话/吊销 | 自建 sys_user_session + 黑名单 | Logto 原生会话 + revocation | Logto 少一套自建表 |
| 组件数 | Casdoor + auth-service + APISIX + PostgREST + PG | **Logto + APISIX + PostgREST + PG** | 少 1 个自建服务 |

### 10.2 资产处置清单（相对 04.6 实施状态；空白业务 N4：旧资产一律不迁移）

| 资产 | 处置 | 说明 |
|:---|:---|:---|
| `db/api_v1/sys/rpc/rpc_webhook_user_upsert/delete.sql`（Casdoor） | **不迁移** | 重写为 `rpc_webhook_logto(payload jsonb)` 按 event 分发（§4.3，含 Role.* 事件） |
| `rpc_ensure_user.sql`（JIT） | 改造复用 | JIT 建档（用户首次出现补建 users 镜像，§4.5） |
| `rpc_create_user.sql`（pg_net → Casdoor add-user） | **删除** | 管理端建号改调 Logto Management API（`POST /api/users`，M2M 管理 token） |
| `user_login_sso.sql` / `refresh_token_rtr.sql` | **删除** | Casdoor password grant 遗留（04.6 D10）；Logto 无此路径 |
| `current_tenant_id.sql` / `current_user_roles()` 等 RLS helper | 保留设计 | claims 来源：`organization_id`（F19）+ 自定义 `roles`（§5.3.1），SQL 不变 |
| `casbin_rule` 视图 / sys 模块旧授权表（Casdoor 时代） | **不迁移** | ③ 自主表（iam_api/iam_menu/iam_role_api/iam_role_menu）按 v2.0 全新设计（N4）；**casbin_rule 视图（v0=role_code, v1=资源, v2=action，排除用户维度）重建为自主表的只读投影**，供 rpc_get_user_permissions 消费（E3） |
| `authz-role-check.lua` 插件 | 保留 | 验签对象换 Logto JWKS；逻辑不变 |
| `casbin-syncer`（Go 工程） | **退役/删除** | auth-service 方案取消（N3）；v2.0 连 fetch 端点都不需要 |
| `rpc_get_user_roles`（v1 fetch 端点） | **不需要** | v2.0 脚本零 fetch（§5.1.1） |
| `sys_user_session` / `sys_token_blacklist` | 不启用 | 会话管理交给 Logto（D12） |
| `008_mirror_slim.sql`（Casdoor 镜像瘦身） | 不需要 | 新镜像表按 Logto 白名单字段建（F2） |
| `scripts/verify-webhook/`（Casdoor 验证脚本） | 归档 | Logto 验证改为 §12 P0-8 的 e2e 清单 |

---

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|:---|:---|:---|
| Logto OSS 依赖（单点） | 登录/刷新不可用 | 多副本 + 共享 PG/Redis（OSS 官方支持 central cache）；已签发 token 不受影响（无每请求依赖） |
| Custom Claims 脚本在 Logto 进程内执行 | 脚本 bug 影响签发 | 脚本极简（纯 context 提取，无外部调用）+ 3s 超时 + 脚本入仓版本管理（Logto 支持导入导出） |
| 管理端查角色分配依赖 Logto Management API | 管理查询延迟/限流 | P1 建 user_role 镜像（JIT 覆盖 + 主动同步 + 对账，§6.5）+ 查询缓存 |
| 无小程序登录 | 小程序场景缺失 | N1 决策不必须；未来需要时：Logto custom connector（自研 ~60 行微信小程序 OAuth 桥，参考 goth 调研）或引入 Casdoor 仅作小程序登录代理（不推荐双 IdP，P2 再议） |
| 组织 token 需 refresh flow（F7） | 前端多一步换取 | SDK getAccessToken(resource, organizationId) 封装，对业务透明 |
| Logto 升级兼容 | 版本升级破坏脚本/webhook | 锁版本 + 升级演练；webhook payload 结构有版本演进（delta 数组为 additive 设计，F3 注释） |
| 角色名重命名破坏 join key | iam_role_api/菜单绑定失效 | 角色名不可变更约束（§6.4）：管理端拒绝重命名或走"新建+迁移"流程 |
| 分配镜像延迟误导管理端 | 管理报表短暂不准确 | 授权判定不读镜像（JWT 权威）；管理端展示标注"延迟分钟级"或直接走 Management API |

---

## 12. 开发路线图

### P0（核心链路）
1. [ ] 部署 Logto OSS（Docker Compose，Pigsty 同机或独立容器）；配置 SMTP/短信连接器（阿里云短信等）、微信 web/native 连接器；**确认 OSS 版 Custom Token Claims 配置入口可用**（v1.42 实测）
2. [ ] Logto Console 初始化：创建全局角色（role_super_admin）；组织模板配置组织角色（tenant_admin / editor / viewer）；创建租户（组织）并分配成员角色
3. [ ] PG：新建镜像表 `users`（Logto 白名单字段，id=Logto user id 主键）、`tenants`（id=Logto organization id）、`user_tenants`、`role`；**全新建** ③ 授权表 `iam_api` / `iam_menu` / `iam_role_api` / `iam_role_menu`（role_code = Logto 角色名，N4）+ admin 系统管理表（019 迁移：position/user_position/dict_type/dict_data/login_log/ip_region_v4 + audit_log 扩展）；`rpc_webhook_logto(payload)`（§4.3，含 Role.* 与 PostSignIn 分发）；RLS helper（§5.3.1）
4. [ ] Logto Console：配置 access-token Custom Token Claims 脚本（§5.1.1 context 版，**零 fetch**）；access token 寿命 15 分钟；**测试脚本**（Console 自带 test 功能）
5. [ ] Logto 应用配置：webhook（订阅 User.Created/Data.Updated/Deleted + Organization.Created/Data.Updated/Deleted + Organization.Membership.Updated + Role.Created/Deleted/Data.Updated + **PostSignIn**（登录日志，D-C），signing key 入部署配置）
6. [ ] APISIX：jwt-auth 切 Logto JWKS；authz-role-check 挂载（复用 04.6 插件源码）；webhook 验签前置（自定义 Lua 或 serverless-pre-function）
7. [ ] PostgREST：JWKS 指向 Logto；`request.jwt.claims` 验证（组织 token 的 organization_id 注入）
8. [ ] 前端：Logto SDK 接入（signIn → getAccessToken(resource, organizationId) → axios 拦截器）；登录后 `rpc_get_user_permissions`（claims roles + iam_role_api/iam_menu）缓存权限树
9. [ ] e2e 验证：登录/刷新/**Logto 改角色分配→刷新→新 roles 生效**/吊销/RLS 隔离/组织切换/webhook 用户与成员与角色目录同步/5000 截断对账触发

### P1（管理面与加固）
10. [ ] ~~管理端建号/禁用/角色分配走 Logto Management API~~ → ✅ **改决策（v2.6）**：**Logto Console 管理**（建号/禁用/角色分配直接在 Logto 操作，业务端 webhook 同步镜像）；③ 绑定表管理（iam_role_api/iam_menu）自研 UI 直接写 PG（带 has_permission 检查）；原 Management API 路径 P2 备选（05.2 §4.1）
11. [ ] 组织（租户）生命周期：Console 或 Management API（`POST /api/organizations`）+ 邀请流程（Organization.Membership.Updated 自动同步）
12. [ ] **user_role 分配镜像**（§6.5）：管理操作主动同步 RPC（rpc_sync_user_roles）+ JIT 覆盖 + 每日对账（管理端报表需要时启用）
13. [ ] 角色名不可变更约束落地：管理端拒绝重命名或走"新建+迁移"流程（§6.4）
14. [ ] 审计：登录/登出/角色变更审计（Logto audit logs + PG 既有审计表）
15. [ ] **登录日志补全（D-C）**：ip2region 数据导入（ipv4_source.txt → ip_region_v4）+ login_log 写时解析 region；失败登录对账（Management API `GET /logs` 低频增量拉失败事件 → login_log result=fail）
16. [ ] ~~**pg_cron 只读 RPC**~~ → ✅ **已实现（021）**：`rpc_list_cron_jobs()` / `rpc_list_cron_job_runs()`（SECURITY DEFINER + 超管门槛，包装 cron.job + cron.job_run_details，管理端查看已设置任务/运行历史，不建 sys_job 表，D-E）

### P2（加固与观测）
17. [ ] 镜像对账任务：每日低频全量对账 users/tenants/user_tenants/role（增量事件为主、对账兜底）
18. [ ] 可选 Logto scope 绑定评估：角色挂 scope → JWT scope claim 原生携带权限点（perms-in-JWT），has_permission 改读 claims 零查询（§5.1.2 注）
19. [ ] 秒级吊销评估：网关黑名单（jti）— 与零查询原则冲突，按需启用（04.6 §9.1 同款）
20. [ ] 可选 `dept_id` claim：context 无部门数据 → 需脚本 fetch（回退 v1 模式）或 RLS helper 查小表，按业务需要评估
21. [ ] 性能基准：签发延迟、网关吞吐压测（千万级容量验证，§8）
22. [ ] 小程序需求若出现：评估 Logto custom connector 自研桥（~60 行）
23. [ ] 非 PostgREST 入口出现时（如内部定时任务需带身份）评估 pg_session_jwt（E1 备选，仅按需引入，不替代网关）
24. [ ] ~~登录地点经纬度~~ → ✅ **已实现基础版（021）**：`ip_geolite2_city`（GeoLite2-City CSV 导入：network/经纬度/时区/城市）+ `geo_locate()`（查询顺序 ip2region 优先 → GeoLite2 兜底，含 IPv6）+ `v_login_log` 视图实时输出；数据更新经 `import-geolite2.sh`（MaxMind license key）；剩余：高德/腾讯 IP 定位 API 异步补充（按需评估）

---

## 13. 附录：调研来源（2026-08-04 核实）

**Logto 官方文档**
- Webhook 事件：https://docs.logto.io/zh-CN/developers/webhooks/webhooks-events
- Webhook 请求结构：https://docs.logto.io/developers/webhooks/webhooks-request
- Webhook 签名：https://docs.logto.io/developers/webhooks/secure-webhooks
- Custom Token Claims：https://docs.logto.io/developers/custom-token-claims
- 组织（多租户）：https://docs.logto.io/organizations/understand-how-organizations-work
- 组织级 API 资源（organization_id claim）：https://docs.logto.io/authorization/organization-level-api-resources
- RBAC：https://docs.logto.io/authorization/role-based-access-control
- OSS 功能边界：https://docs.logto.io/logto-oss/
- 微信连接器：https://docs.logto.io/integrations/social/wechat-web、/wechat-native

**Logto 源码（logto-io/logto master，2026-08-04）**
- `packages/schemas/src/foundations/jsonb-types/hooks.ts` — hookEvents 枚举 + managementApiHooksRegistration 注册表（F12）
- `packages/core/src/routes/admin-user/role.ts`、`role.user.ts`、`organization/user/role-relations.ts` — 角色分配路由无事件（F13）
- `packages/core/src/middleware/koa-management-api-hooks.ts`、`libraries/hook/context-manager.ts` — 仅成功触发（F14）
- `packages/core/src/libraries/hook/utils.ts` — 投递重试/超时（F15）
- `packages/core/src/utils/local-vm/index.ts` — 脚本沙箱 fetch + 3s 超时（F16）
- `packages/schemas/src/types/logto-config/jwt-customizer.ts` — context 结构与 token 类型（F17/F18）
- `packages/core/src/oidc/extra-token-claims.ts` — organization_id claim（F19）
- `packages/core/src/libraries/jwt-customizer.ts` — getUserContext 实现（context.roles/organizationRoles 权威计算）
- `packages/schemas/tables/roles.sql`、`organization_roles.sql` — 角色名唯一约束（F20）

**GitHub issues / PR（2026-08-04 实时核实）**
- PR #8674「added user role update event」— 分配事件社区实现，2026-07-27 关闭未合并（maintainer 拒绝理由：5 条隐式分配路径无法覆盖 + 假事件问题）
- Issue #5099「Ability to notify users of permission changes」— 2023-12 提出，挂起近 3 年，官方排期无期

**仓库内关联文档**
- `docs/基于 Logto (自部署) 与 PostgreSQL 的高并发无状态认证与权限架构方案.md`（v1，本文档取代其设计内容）
- `docs/开发实施方案/04.6-认证授权架构-最终决策.md`（Casdoor 方案 B，对比基准）
- `docs/开发实施方案/04.7-Casdoor托管角色单向Webhook方案-分析与对比-修订版.md`（方案 C，角色分配同步教训）
