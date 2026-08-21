# 42 Zitadel 替代 Logto 评审：功能对比与"非 public schema 安装"源码级确认

> **状态**：✅ 核查完成（2026-08-21）。基于 **zitadel/zitadel tag v4.17.1**（用户确认的最新版）源码逐文件核查 + 官方文档
> **核查来源**：`cmd/defaults.yaml`、`cmd/initialise/sql/*.sql`、`cmd/setup/01_sql/*.sql`、`cmd/setup/05.sql`、`internal/database/postgres/pg.go`、`apps/docs/content/self-hosting/{manage/requirements,manage/database/_postgres,deploy/linux,deploy/compose}.mdx`
> **一句话结论**：**功能上 Zitadel 确实比 Logto 更强（企业级 IAM，且是三者中同库落位最干净的）；"自定义 schema"的答案是：Zitadel 没有可配置的 schema 名，但它根本不用 public——自带 5 个专用 schema（`eventstore/projections/system/auth/adminapi`），SQL 全部 schema 限定，官方权限要求只有 `GRANT CONNECT, CREATE ON DATABASE`。所以"装进业务库、与 public 无关"✅ 成立；但"像 better-auth 那样当唯一数据源直读"❌ 不适合（事件溯源架构，官方要求走 API）。**

---

## 1. 三个问题的直接回答

| 问题 | 回答 |
|---|---|
| Zitadel 能替代 Logto 吗？ | ✅ 能。OIDC/OAuth2/SAML、多租户（instance/org）、RBAC（resource-owner 模型）、组织管理、Actions（claims 定制）、审计、服务用户（machine user/PAT）、密钥管理全部覆盖，功能面大于 Logto（§2 对比表）。但 OmniPG 现有 Logto 集成（镜像表 + webhook sync_* + init-logto.py 的 CLAIMS_SCRIPT + 对账）**要全部重写** |
| 功能上比 Logto 更强？ | ✅ 对，强一个档位：SAML 2.0、LDAP/AD 同步、Actions 脚本钩子、实例-组织-项目三层、user grants 细粒度授权、审计事件流、服务用户/机器账号、登录 UI 可自托管改造。代价同样高一档：事件溯源存储（`eventstore.events2` 持续增长）、init/setup 两阶段、学习曲线与运维复杂度更高 |
| 是否像 better-auth 一样支持装到自定义/非 public schema？ | **两段式答案**：① 没有"自定义 schema 名"配置（schema 名写死在 init/setup SQL 里）；② **但 Zitadel 不使用 public**——它自带 `eventstore/projections/system/auth/adminapi` 5 个专用 schema，SQL 全部显式限定，官方预授权只需 `CONNECT + CREATE ON DATABASE`。所以"装进业务库 app_db"天然兼容，**不需要指定 schema、也不碰 public**（§3 源码证据） |

---

## 2. 功能对比：Zitadel vs Logto vs better-auth

| 维度 | Logto | Zitadel v4 | better-auth |
|---|---|---|---|
| 形态 | 独立服务（TS/Node） | 独立服务（Go，含可自托管 Login UI） | 嵌入 TS 库（需 Node 宿主） |
| 认证协议 | OIDC/OAuth2 | OIDC/OAuth2 + **SAML 2.0** + JWT Profile 等 | OIDC 类 API（自建端点） |
| RBAC | ✅ 内建（roles/scopes/resources + org roles） | ✅ 内建（manager roles + user grants + project roles/permissions，资源所有者模型） | ❌ 无内建（业务自研） |
| 组织/租户 | organizations + 模板角色 + JIT | instance → org → project 三层，org 独立域/策略 | organization 插件（轻量） |
| 管理面 | Admin Console + Management API | Console（新）+ API v2/v3 + gRPC | ❌ 无 |
| 扩展钩子 | webhooks + Custom Token Claims 脚本 | **Actions**（token/claims/metadata/SAML 响应脚本） | 代码级（signJWT payload） |
| 企业能力 | 无 SAML/LDAP | **LDAP/AD 同步、审计事件、服务用户、PAT、设备授权** | 无 |
| 数据库形态 | **硬编码 public**（38/39 号核查） | **5 个专用 schema，public 无关**（§3） | schema 可配（官方一等公民） |
| 可直读作唯一数据源 | 可（表透明，40 号方案下） | ❌ 事件溯源 + 投影，官方要求走 API | ✅ 最透明（41 号 §4/§5） |
| 资源占用 | 轻 | 较重（事件表随操作增长，需治理） | 最轻（同进程） |
| 同库落位 | 需 40 号方案（业务迁出）或 38/39 补丁层 | ✅ 直接装（5 个 schema 名避开即可） | ✅ 直接装（auth schema 可配） |

**结论**：功能强度 Zitadel > Logto > better-auth；**数据库落位友好度 better-auth ≈ Zitadel >> Logto**；**直读复用友好度 better-auth > Logto >> Zitadel**。

---

## 3. "非 public schema"的源码级证据（v4.17.1）

### 3.1 配置面：没有 Schema 配置项，只有 DSN/Options

`cmd/defaults.yaml` `Database.postgres` 段（L234-275）只有 `DSN / Host / Port / Database / Options / User / Admin` 等字段——**没有 schema 字段**。`DSN` 模式注释明确："In DSN mode, zitadel init cannot use the Admin connection to create a separate target database/user. The DB and user from the DSN must already exist and have sufficient privileges"。

### 3.2 init 阶段：自建 3 个专用 schema（不碰 public）

`cmd/initialise/sql/04_eventstore.sql / 05_projections.sql / 06_system.sql`：

```sql
CREATE SCHEMA IF NOT EXISTS eventstore;
GRANT ALL ON ALL TABLES IN SCHEMA eventstore TO "%[1]s";
CREATE SCHEMA IF NOT EXISTS projections;
GRANT ALL ON ALL TABLES IN SCHEMA projections TO "%[1]s";
CREATE SCHEMA IF NOT EXISTS system;
GRANT ALL ON ALL TABLES IN SCHEMA system TO "%[1]s";
```

表也全部限定：`system.encryption_keys`、`eventstore.events2`、`eventstore.unique_constraints`（07/08/10 号 SQL）。

### 3.3 setup 阶段：再建 auth/adminapi 两个 schema，SQL 全限定

`cmd/setup/01_sql/auth.sql` 与 `adminapi.sql` 开头即 `CREATE SCHEMA auth;` `CREATE TABLE auth.locks (...)`、`CREATE SCHEMA adminapi;` `CREATE TABLE adminapi.locks (...)`；`05.sql` 建索引也是 `adminapi.current_sequences` / `auth.current_sequences` / `projections.current_sequences` 全限定。**全库无一处依赖 `search_path` 或 `public`**。

### 3.4 官方权限要求（requirements / database 文档）

`apps/docs/content/self-hosting/manage/database/_postgres.mdx`：admin 用户仅安装阶段需要，可预先准备来避免；最小准备即：

```sql
CREATE ROLE zitadel LOGIN;
CREATE DATABASE zitadel;
GRANT CONNECT, CREATE ON DATABASE zitadel TO zitadel;
```

支持 **PostgreSQL 14–18**（Pigsty PG18 ✅）。

### 3.5 落到 OmniPG app_db 的同库形态

```
app_db
 ├─ public          —— 业务已迁出（40 号方案）或按需；Zitadel 完全不使用
 ├─ omnipg          —— 业务表
 ├─ api_v1_public   —— PostgREST 暴露层
 ├─ eventstore / projections / system / auth / adminapi —— Zitadel 自建自管
```

前置仅需：`GRANT CONNECT, CREATE ON DATABASE app_db TO zitadel`（按官方 SQL 原样），然后 `zitadel init` + `zitadel setup` 自动完成。**无 options 魔法、无 schema 冲突、无 public 争夺——比 Logto 的 38/39/40 号全部问题都干净。** 唯一约束：业务 schema 不能叫这 5 个名字。

---

## 4. 对 OmniPG 的两条重要修正与注意事项

### 4.1 不能把 Zitadel 当"唯一数据源直读"（与 better-auth 的关键差异）

Zitadel 是**事件溯源**架构：权威数据在 `eventstore.events2`（append-only 事件流），业务可读的表是投影（`projections.users` 等），内部结构官方不承诺稳定、含加密列与 instance_id 维度，**官方明确要求通过 API（v2/v3）访问**。因此：

- "同库 schema"红利对 Zitadel 主要是**部署/运维层面**（一个实例一个库），**不是数据直读层面**；
- OmniPG 现有的"镜像表 + sync_* + 对账"链路形态要保留（改为 Zitadel Management API/事件 API 驱动），不能像 better-auth 那样"直读退役同步链路"；
- JWT claims（roles/pg_role）定制走 **Actions**（类似现在 Logto 的 Custom Token Claims 脚本），org roles/user grants 可注入 token。

### 4.2 资源与运维

- `eventstore.events2` 随每次操作增长，需要纳入备份/清理策略（Zitadel 有压缩/清理机制，运维面大于 Logto）；
- 迁移需要 init + setup 两阶段（官方有 `start-from-init` 与 phases 指南）；
- v4 部署 = ZITADEL API（Go）+ ZITADEL Login（Next.js）两个容器（compose.mdx），资源占用高于 Logto 单容器。

---

## 5. 三方选型小结（针对 OmniPG"同库 schema + 直读复用"目标）

| 目标 | 推荐 | 理由 |
|---|---|---|
| 最小改动、同库 schema 落地 | **Logto + 40 号方案**（业务迁 omnipg、public 给 Logto） | 现有集成全保留 |
| 认证库化、同库直读唯一数据源、接受自研 RBAC/租户 | **better-auth** | schema 官方可配 + 表透明直读；代价是新增 Node 服务 + 自研管理面 |
| 功能最强、同库部署最干净、接受"API 同步 + 事件表运维" | **Zitadel** | 5 个专用 schema 与 public 无关；代价是集成重写 + 不可直读 + 资源/复杂度最高 |

---

## 6. 需要拍板的点

| # | 决策点 | 建议 |
|---|---|---|
| D26 | 替代动机 | 若仅为"同库 schema"→ Logto 40 号方案已解决；若要"企业级功能升级"→ Zitadel 立项评估 |
| D27 | Zitadel 同库前置 | 业务 schema 命名避开 eventstore/projections/system/auth/adminapi；`GRANT CONNECT, CREATE ON DATABASE app_db TO zitadel`；pg_hba 放行 |
| D28 | 数据访问面 | 明确走 Zitadel API（v2/v3）同步，不直读投影表；同步链路（镜像+对账）保留改造 |
| D29 | 集成迁移清单 | 前端 OIDC 换 discovery、init-logto.py → Zitadel API/Actions 等价物、claims 注入改用 Actions、webhook 事件 → API 轮询/事件流 |

---

## 7. 证据索引

- zitadel/zitadel **v4.17.1**：`cmd/defaults.yaml` L234-275（Database.postgres，无 schema 配置）、`cmd/initialise/sql/04/05/06_eventstore|projections|system.sql`、`cmd/initialise/sql/07/08/10_*.sql`、`cmd/setup/01_sql/{auth,adminapi,projections}.sql`（`CREATE SCHEMA auth/adminapi` + 全限定建表）、`cmd/setup/05.sql`、`internal/database/postgres/pg.go`（DSN 原样使用 + Options 字段）、`cmd/initialise/init.go`（init 步骤与幂等 verify）
- 官方文档（v4.17.1 内嵌 docs）：`apps/docs/content/self-hosting/manage/database/_postgres.mdx`（`GRANT CONNECT, CREATE ON DATABASE` 预授权、PG 14-18）、`manage/requirements.mdx`、`deploy/linux.mdx`（DSN 直连示例）、`deploy/compose.mdx`（API + Login 双容器）
- 对比参照：38/39/40 号（Logto public 硬编码与同库方案）、41 号（better-auth schema 可配 + 表结构清单）
