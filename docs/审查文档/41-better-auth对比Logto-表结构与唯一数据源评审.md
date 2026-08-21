# 41 better-auth vs Logto 功能对比、表结构定位与"唯一数据源复用"评审

> **状态**：✅ 核查完成（2026-08-21）。基于 better-auth **main 分支源码**（version 1.7.1，commit 6442317，2026-08-20）逐文件核查 + 官方文档
> **核查对象**：https://github.com/better-auth/better-auth 、https://better-auth.com/docs/adapters/postgresql
> **结论速览**：
> 1. "better-auth 与 Logto 功能无差别"——**不对**，两者定位不同：Logto = 成品 IAM 服务（自带 Admin Console / Management API / RBAC / 组织角色 / 多租户 / webhook）；better-auth = **嵌入应用的 TypeScript 认证库**（只覆盖认证 + 会话 + 轻量组织/管理插件，**无内建 RBAC、无管理 UI、无 Management API**）。
> 2. "可以指定 public 或 auth schema"——**对**，这是官方一等公民能力（三种配置方式 + CLI 自动检测 search_path），且 better-auth **没有 Logto 那样的 public 硬编码**；放业务库的 `auth` schema 不会有 38/39 号那类问题。
> 3. RBAC / 角色 / 租户——**大部分需要业务自研**（§3/§5 详细）。
> 4. 表结构文件定位与"唯一数据源复用"——见 §4：核心 4 表 + 插件表，**可复用，但要做字段映射与业务补表**，且有一个比表结构更大的前提：**better-auth 需要一个 Node 进程来运行它**（§6）。

---

## 1. 直接回答四个问题

| 问题 | 回答 |
|---|---|
| ① better-auth 与 Logto 功能上无差别，对么？ | ❌ 不对。认证手段两者高度重叠（密码/社交/OTP/2FA/passkey/匿名等），但 Logto 的**授权与管理面**（RBAC 角色-作用域-资源、组织模板与组织角色、租户隔离、Admin Console、Management API、webhook、sign-in experience、connectors、M2M 应用）better-auth 基本没有或只有雏形（§3 对比表） |
| ② better-auth 文档说可以指定 public 或 auth schema，对吧？换成 better-auth 放业务库 auth schema 就没问题，对不对？ | ✅ 对（文档 `Use a non-default schema` 一节：连接串 `?options=-c search_path=auth` / pg.Pool `options` / `ALTER USER SET search_path` 三种方式；CLI `npx auth migrate` 自动检测 search_path、只建在指定 schema、忽略其他 schema）。**且这是官方支持路径，无 Logto 的硬编码 public 负担**。注意：`auth` schema 解决的是"表落在哪"，**不解决"谁运行 better-auth"**——它是个库，需要 Node 宿主进程（§6） |
| ③ 是否仅提供"用户认证与授权"？有无 RBAC？是否只管理 user，角色/租户要业务开发？ | 精确边界：**核心 = 认证 + 会话**（user/session/account/verification 四表）；**授权 = 仅轻量声明式 access/admin 插件（代码内定义角色→权限，不落库）**；**组织/租户 = organization 插件提供 organization/member/invitation（成员角色 owner/admin/member 可自定义，可选 organizationRole(role,permission) 表）**。**全局 RBAC（角色表、角色-菜单/资源/权限矩阵）、角色管理 API/UI、租户级数据隔离（tenant_id）都要业务自研** |
| ④ 表结构文件在哪？能否当唯一数据源复用？ | 定位见 §4；**可以复用为唯一数据源**，但需要：字段映射（username/phone/自定义字段走插件或 additionalFields）+ 业务补表（角色、权限、租户扩展）+ 自建 JWT claims（roles/pg_role）+ 自建管理 API/UI。同库直读后**不需要 webhook/对账同步链路**（比现在 Logto 镜像表方案简单） |

---

## 2. 为什么"功能无差别"不成立：两者定位不同

| 维度 | Logto（自部署 IAM 产品） | better-auth（TS 认证库 v1.7.1） |
|---|---|---|
| 形态 | 独立服务/镜像，开箱即用 | **嵌入应用的库**，需要 Node 宿主进程 |
| 认证 | 用户名/邮箱/手机/社交/SSO/密码策略/组织 SSO | 邮箱密码/社交 OAuth/用户名/手机号/OTP/魔链/passkey/SIWE/匿名/SSO(第三方) 等（插件） |
| 会话 | 服务端会话 + JWT + refresh token | Cookie 会话（DB session 表）+ jwt 插件（支持 JWKS/ES256/RS256/EdDSA + 自定义 payload signJWT） |
| **RBAC** | **内建**：roles/scopes/resources/用户-角色/应用-角色，权限点体系 | ❌ **无内建**。admin 插件只有 user.role 字符串 + 代码级 hasPermission；access 插件是声明式授权工具（不落库） |
| 组织/租户 | organizations + 组织模板角色 + 成员关系 + JIT | organization/member/invitation 三表（member.role 自由字符串，owner/admin/member 约定）；可选 organizationRole(role,permission)；**无 tenant_id 级数据隔离/RLS** |
| 管理面 | Admin Console + Management API（完整 CRUD） | ❌ 无（admin 插件只有 ban/impersonate/listUsers 等少量端点） |
| 集成面 | webhook（15+ 事件）、connectors、Custom Token Claims 脚本、sign-in experience 配置 | ❌ 无 webhook；claims 需自己写 signJWT payload；体验页要自建 |
| 多租户 | 租户隔离 + 云模式 | ❌ 无（organization 可当轻量租户容器） |
| 数据库 | **硬编码 public**（38/39 号核查） | **schema 可配（官方支持）**，无 public 硬编码 |

**一句话**：better-auth 管好"认证和会话"这一层是优秀的；Logto 的"角色权限、组织租户、管理平台"那一大块，better-auth 交还给业务。

---

## 3. RBAC / 角色 / 租户能力边界（源码级）

- **admin 插件**（`packages/better-auth/src/plugins/admin/schema.ts`）：仅给 user 表加 `role: string`、`banned/banReason/banExpires`，session 加 `impersonatedBy`。`has-permission.ts` 是"角色名 → 静态权限声明"的代码映射（`createAccessControl` 风格），**不是数据库 RBAC**。
- **access 插件**（`packages/better-auth/src/plugins/access/`）：`createAccessControl({ roles, resources })` + `authorize()` —— 纯代码内声明，角色定义在应用代码里，**不落库、无管理 API**。
- **organization 插件**（`packages/better-auth/src/plugins/organization/schema.ts`）：
  - 默认表：`organization(id,name,slug,logo,metadata,createdAt)`、`member(id,organizationId,userId,role,createdAt)`、`invitation(id,organizationId,email,role,status,expiresAt,inviterId,...)`；
  - `dynamicAccessControl: true` 时增加 `organizationRole(organizationId, role, permission)` 表 + `session.activeOrganizationId`；
  - `teams: true` 时增加 `team/teamMember`。
  - **没有**：全局角色表、角色-资源-权限矩阵、租户级行隔离（member 只按 organizationId 关联，业务表要自己带 orgId/tenantId 过滤）。
- **结论**：OmniPG 现有的 `iam_role_menu`（角色-菜单绑定）、`role_super_admin/tenant_admin/editor/viewer` 全局+组织双维度角色、JWT `roles/global_roles/org_roles/pg_role` claims 体系，**全部需要业务自建**（表 + 判定函数 + claims 注入 + 管理 UI）。

---

## 4. 表结构文件定位（GitHub 路径）与表清单

### 4.1 核心表定义（唯一数据源的最小集）

| 文件 | 内容 |
|---|---|
| `packages/core/src/db/schema/shared.ts` | 所有表的公共字段 `id/createdAt/updatedAt` |
| `packages/core/src/db/schema/user.ts` | `user`：id、email、emailVerified、name、image、createdAt、updatedAt（**就这些**，其余靠插件/自定义） |
| `packages/core/src/db/schema/session.ts` | `session`：id、userId、expiresAt、token、ipAddress、userAgent |
| `packages/core/src/db/schema/account.ts` | `account`：id、providerId、issuer、accountId、userId、accessToken、refreshToken、idToken、accessTokenExpiresAt、refreshTokenExpiresAt、scope、password（OAuth 绑定 + 本地密码哈希都在这里） |
| `packages/core/src/db/schema/verification.ts` | `verification`：id、value、expiresAt、identifier（邮箱验证/重置令牌等） |
| `packages/core/src/db/schema/rate-limit.ts` | `rateLimit`：key、count、lastRequest（可选，`rateLimit.storage="database"` 时） |
| `packages/core/src/db/get-tables.ts` | **汇总入口**：`getAuthTables(options)` 合并核心 + 全部插件的 schema/modelName（要看"整个项目表结构"，先看这里再看各 schema.ts） |

### 4.2 插件贡献的表/字段（按需启用）

| 插件 | schema 文件 | 贡献 |
|---|---|---|
| username | `packages/better-auth/src/plugins/username/schema.ts` | `user.username`（unique） |
| phone-number | 同目录 | `user.phoneNumber`、`phoneNumberVerified` |
| admin | `.../plugins/admin/schema.ts` | `user.role/banned/banReason/banExpires` + `session.impersonatedBy` |
| two-factor | `.../plugins/two-factor/schema.ts` | `user.twoFactorEnabled` + `twoFactor` 表（secret/backupCodes/userId/verified/锁定字段） |
| organization | `.../plugins/organization/schema.ts` | `organization/member/invitation`（+可选 organizationRole/team/teamMember） |
| jwt | `.../plugins/jwt/schema.ts` | `jwks` 表（publicKey/privateKey/alg/crv，key 持久化与轮换） |
| anonymous | 同目录 | `user.isAnonymous` |
| passkey | `packages/passkey`（外部包） | `passkey` 表 |

### 4.3 CLI 生成的落地 SQL

- 生成器：`packages/core/src/db/get-migration.ts`；命令 `npx auth@latest migrate` / `generate`（文档 `docs/content/docs/adapters/postgresql.mdx`）。
- 生成 SQL 建在**当前 search_path 首位 schema**（配 `auth` 即建 `auth.` 前缀表），自动忽略其他 schema 的同名表——**官方明确"Tables in other schemas (e.g., public) are ignored, preventing conflicts"**。

---

## 5. 能否当"唯一数据源"复用：字段映射与缺口

以 OmniPG 现有镜像表（064）为对照：

| 现有业务需求 | better-auth 侧落点 | 结论 |
|---|---|---|
| 用户 id（12 位 nanoid） | `user.id`（默认生成 id，可自定义 generateId） | ✅ 直用 |
| 用户名 | username 插件 `user.username` | ✅ 插件 |
| 主邮箱/主手机 | `user.email` / phone-number 插件 `user.phoneNumber` | ✅ |
| name/avatar | `user.name/image` | ✅ |
| 密码散列 | `account.password`（credential provider） | ✅ 不暴露给业务层 |
| 社交身份 identities | `account` 行（providerId/accountId/issuer） | ✅ 语义不同但等价 |
| 登录日志 | 无内建（session 表有 ipAddress/userAgent/expiresAt 可近似） | ⚠️ 业务补表或改语义 |
| 用户扩展（custom_data/profile/sso_identities） | `user.additionalFields` 自定义列 或 业务 `user_profile` | ✅ 可扩展 |
| 全局角色/组织角色/权限矩阵 | ❌ 无 | 🔴 **业务自建表**（iam_role / iam_role_menu 等已在业务侧） |
| 租户/组织 | organization 插件（org/member/invitation）或业务 tenants 表 | ⚠️ 二选一；建议沿用业务 tenants（已有 FK 体系） |
| JWT claims（roles/org_roles/pg_role） | jwt 插件 `signJWT(payload)` 可注入任意 payload + `/jwks` 验签 | ⚠️ 需自写 claims 组装逻辑（对应现在 init-logto.py 的 CLAIMS_SCRIPT） |
| PostgREST 验签 | 支持 ES256/RS256/EdDSA/HS256，`/jwks` 或对称 secret | ✅ 与 PGRST_JWT_SECRET 兼容 |

**结论**：把 better-auth 的 4+N 张表作为唯一数据源**可行**；角色/权限/租户关联仍由业务表承载（本来就是业务资产），且**同库直读 + 无 webhook/对账**比 Logto 镜像同步链路更简单。工作量重心不在表结构，而在：① Node 宿主服务（§6）；② 管理 API/UI 自研；③ claims 组装与角色同步逻辑。

---

## 6. 最大的架构差异：better-auth 是"库"不是"服务"

OmniPG 是零后端架构（APISIX + PostgREST + 前端）。Logto 以容器形态存在，前端直接对接其 OIDC 端点。换成 better-auth 意味着：

- 必须**新增一个常驻 Node 进程**（better-auth handler + Postgres 连接池 + jwt/jwks），并有部署/健康检查/升级面——这是引入的新后端；
- **没有 Admin Console**：用户管理、角色管理、组织管理、邀请、封禁等界面全部自研（Logto Console 免费提供）；
- **没有 Management API / webhook**：对账、同步逻辑要么同库直读（更简单）要么自写 API；
- 体验页（登录/注册/重置密码）需要自建 UI（Logto 提供可配置 sign-in experience）；
- 好处：单进程、无独立镜像、schema 官方可配、表结构透明可控、同库直读零同步。

**决策视角**：
- 如果动机只是"把认证数据放进业务库的独立 schema"——40 号方案（Logto 留 public + 业务迁出，或 38/39 的补丁层）已经达成，**换 better-auth 不划算**；
- 如果动机是"去 Logto 化、要一个轻量可嵌入的认证库、愿意自研 RBAC/租户/管理面"——better-auth 是合理选择，但需把 §3/§5 的自研清单纳入计划，并接受新增一个 Node 服务。

---

## 7. 需要拍板的点

| # | 决策点 | 建议 |
|---|---|---|
| D21 | 换库动机确认 | 仅为 schema 落库 → 不建议换（40 号已解决）；去 Logto 化/轻量化 → 继续 D22 以下评估 |
| D22 | Node 宿主 | 新增独立 auth 服务（推荐，职责单一）还是并入现有网关侧服务——需立项评估 |
| D23 | RBAC/租户归属 | 沿用业务侧 iam_role/iam_role_menu/tenants 体系（已有），better-auth 只当身份源；不做 organization 插件与业务租户的双轨 |
| D24 | schema 名 | `auth`（官方示例）即可；与业务 `omnipg`、暴露层 `api_v1_public` 三 schema 结构 |
| D25 | claims 注入 | jwt 插件 signJWT 自定义 payload 注入 roles/global_roles/org_roles/pg_role，PostgREST 用 /jwks（ES256）验签 |

---

## 8. 证据索引

- better-auth main 分支（v1.7.1，commit 6442317）：`packages/core/src/db/schema/{shared,user,session,account,verification,rate-limit}.ts`、`packages/core/src/db/get-tables.ts`、`packages/core/src/db/get-migration.ts`、`packages/better-auth/src/plugins/{admin,access,organization,username,two-factor,jwt,anonymous}/schema.ts`（organization 还含 dynamicAccessControl/teams 分支）、`packages/kysely-adapter/src/kysely-adapter.ts`（L689 支持 `<schema>.<model>` 命名）
- 官方文档：`docs/content/docs/adapters/postgresql.mdx`（"Use a non-default schema"：连接串 options / Pool options / ALTER USER 三种方式 + CLI 自动检测 search_path + 忽略其他 schema）、`docs/content/docs/concepts/database.mdx`
- 对比参照：38/39/40 号文档（Logto 硬编码 public 核查、四道墙、业务迁出方案）
