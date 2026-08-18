# 关键决策记录

> 本文以 ADR（Architecture Decision Record）形式记录关键选型：每篇按「背景 → 可选方案 → 决策 → 影响与代价」展开。事实依据：历史设计文档（05 号 Logto 方案、00 号项目总纲、05.4/05.5、16 号菜单单表化、36 号迁移基线，均已归档）与当前代码。

## ADR 1：从 casbin/casdoor 迁移到 Logto（认证与授权统一）

### 背景

原架构（04.6 方案 B）用 Casdoor 做认证，需要自建 Go auth-service 做 token exchange（查 PG 后把角色签进 JWT），网关用 authz-casbin 做 API 级鉴权，还用 Go PolicySyncer 把 casbin 策略从 PG 同步到 etcd。实测/核实问题：Casdoor webhook payload 结构与文档不符、update-role 存在 500 风险、用户↔角色分配无可靠事件、组件多（Casdoor + auth-service + Syncer）。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：Casdoor 方案 B 原样落地 | Casdoor + Go auth-service + PolicySyncer | ❌ 组件多、同步链路脆弱 |
| B：Logto OSS + PG 授权（05 号文档 v2.0） | Logto 管认证/组织/角色目录与分配；授权判定在 PG；JWT 由 Logto 签发，Custom Token Claims 脚本从 context 零 fetch 提取角色 | ✅ 采纳 |
| C：混合（角色目录 Logto + 分配在 PG） | 两个真相源需对齐 | ❌ 无收益 |

### 决策

- Logto（自部署 OSS）承担认证 + 组织（租户）容器 + 角色目录 CRUD + 用户↔角色分配；**不参与授权判定**。
- JWT 由 Logto 直接签发（RS256 + JWKS；开发环境可用 HS256 占位），Custom Token Claims 脚本注入 roles / global_roles / org_roles / pg_role（scripts/phase2/init-logto.py）。
- webhook 保留（User.* / Organization.* / Membership / OrganizationRole.* / Role.* / PostSignIn）→ rpc_webhook_logto → sync_*。
- 会话与吊销交 Logto（refresh token revocation），删除 sys_token_blacklist / sys_user_session / check_token_blacklist 整链。

### 影响与代价

- 少一个自建服务（auth-service）与整套 PolicySyncer 管道；授权判定下沉 PG（RLS / has_permission）。
- 组织 token 不能从 code flow 直接获取，必须 refresh token flow（前端 SDK 封装透明）。
- Logto 无"用户↔角色分配"webhook 事件（官方 PR #8674 被拒）→ user_role 镜像走登录 JIT 覆盖 + 每日对账 reconcile-logto.py，允许分钟级延迟。
- pg_role 映射表只覆盖 role_super_admin/role_admin/role_editor/role_guest，租户组织角色（tenant_admin 等）需扩展映射（审查 33 号 N9b，待修）。

## ADR 2：后端吸收部分 casbin 方案（RBAC 数据模型）

### 背景

casbin 的 RBAC 思想（角色 → 资源 → 动作的扁平策略行）有价值，但把 Casbin 引擎放进 APISIX 需要策略同步管道（PG 视图 → pg_notify → Syncer → etcd），与"授权判定在 PG"的目标冲突。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：网关 Casbin 引擎 + PolicySyncer | 策略热加载到 APISIX 内存 | ❌ 同步管道复杂；E3 分析 Redis 缓存收益 ≈ 0.1ms 不值得 |
| B：吸收数据模型 + 判定下沉 PG | 保留 casbin_rule 视图、role_code join key、Role-in-JWT；has_permission/RLS 在 PG 执行 | ✅ 采纳 |
| C：perms-in-JWT（Logto scope） | 角色挂 scope，权限点进 JWT scope claim | 预留演进（P2-14），当前未启用 |

### 决策

- 保留 `casbin_rule` 视图（db/src/public/views/casbin_rule.sql）为双段投影：API 段 = iam_role_menu→button 行（v1=api_url, v2=api_method）+ 菜单段（v1=router, v2='menu'），仅测试/兼容消费。
- 授权判定单通道：`has_permission(p_code)` = claims roles ∩ iam_role_menu → iam_menu.api_code（055 D3 收敛，iam_api/iam_role_api 删除）。
- 055 单表化借鉴 SharpFort：iam_menu 单表承载导航 + 权限点（api_code）+ 端点（api_url/api_method）；角色授权只走 iam_role_menu。
- 用户数彻底退出授权路径（Role-in-JWT）：授权判定只读 claims + 角色×权限小表。

### 影响与代价

- 无策略同步管道、无缓存失效问题；授权路径零用户查询。
- casbin_rule 不再是运行时策略源，仅作兼容投影；若未来要恢复网关端点级拦截，iam_menu 的 api_url/api_method 就是现成策略数据源。

## ADR 3：选择 PostgREST 作为 API 层

### 背景

零后端目标：希望表/视图/函数自动生成 REST API，带 OpenAPI、过滤/排序/分页，且鉴权无状态。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：手写后端框架 | Go/Java/Node 写 CRUD + 鉴权中间件 | ❌ 违背零后端，多语言重复实现 |
| B：PostgREST | 暴露对外层 schema（api_v1_public 等，多 schema 声明）；视图=REST 表、函数=/rpc；RLS 为安全边界 | ✅ 采纳 |
| C：pg_graphql 替代 | GraphQL 面 | 作为补充扩展安装（Pigsty 管理），主面仍 REST |

### 决策

- PostgREST v14（gateway/docker-compose.yml postgrest 服务）暴露对外层 schema：docker-compose env 运行时为 `api_v1_public`（env 覆盖 conf），postgrest.conf 声明多 schema（db-schemas = "api_v1_public, api_v1_sales, api_v1_inventory"，sales/inventory 已退役按需重建），extra search path = api_v1_public, public。
- JWT 验签（PGRST_JWT_SECRET = JWKS_JSON），把 claims 注入 `request.jwt.claims`，按 `.pg_role` claim 切换 PG 角色（docker-compose 为运行态权威；postgrest.conf 参考文件写 roles[0]，与运行态不一致）。算法口径：开发 = HS256、staging/production = Logto JWKS RS256（compose/.env 注释写 ES384，口径不一致，需以 Logto 实际配置核实）。
- RLS 是数据级唯一安全边界；写/管理操作经 /rpc/* SECURITY DEFINER 函数 + has_permission。
- E1 决策：pg_session_jwt 扩展不采纳（PostgREST 已做 PG 端解析，功能重复；仅未来出现非 PostgREST 入口时按需评估）。

### 影响与代价

- 业务逻辑必须写成 SQL/PLpgSQL（RPC/视图/触发器）；聚合/复杂事务用 RPC 封装。
- 表级权限 = PG 角色 GRANT（zz_grant_all.sql / rls_policies.sql 集中管理）；新增模块需同步 PGRST_DB_SCHEMAS 与搜索路径。
- max-rows=1000、aggregates 开启等行为由部署配置约束。

## ADR 4：选择 Pigsty 作为基础设施

### 背景

需要 PostgreSQL 高可用（Patroni）、扩展安装、监控（Grafana + VictoriaMetrics）、备份（pgBackRest）、连接池（pgbouncer）与 Redis。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：自建 Docker PG | 单容器 + 手动扩展 | ❌ 无 HA/监控/备份 |
| B：Pigsty | 集群级管理 PGSQL/INFRA/REDIS/DOCKER | ✅ 采纳 |
| C：云托管 RDS | 外部依赖 + 扩展受限 | 生产备选，未采用 |

### 决策

- Pigsty 统一管理 PostgreSQL 集群、pgbouncer（6432）、Redis 与扩展（infra/pigsty.yml 声明 pg_extensions / pg_users / pg_databases）。
- 扩展权威清单：db/init/01-extensions.sql（pg_pwhash、pgcrypto、pg_net、pgtap，幂等兜底）；pg_cron / pg_graphql 由 Pigsty 集群级安装。
- 数据库角色（authenticator / web_anon / authenticated / super_admin / role_admin / role_editor / role_guest / role_super_admin / tenant_admin）为集群级对象，由 Pigsty 管理；参考配置见 db/init/02-schemas.sql 头注。
- 开发环境：Pigsty 部署在 WSL2 宿主，gateway/docker-compose.yml 只跑无状态网关服务（PostgREST 经 host.docker.internal:6432 连 pgbouncer）。

### 影响与代价

- 角色/扩展变更属集群级操作（ADMIN OPTION）；扩展口径：pgaudit 不启用、pgsodium 2026-08-16 退役、plpython3u/pgjwt 不使用；⚠️ infra/pigsty.yml 仍列 pgaudit/pgsodium 等与最小集（01-extensions.sql：pg_pwhash/pgcrypto/pg_net/pgtap + Pigsty 集群级 pg_cron/pg_graphql）冲突——TODO，以 db/init/01-extensions.sql 为准。
- 部署链固化：deploy-db.sh（bootstrap → dbmate up → apply-src）+ deploy-gateway.sh + setup_apisix.sh。

## ADR 5：业务逻辑下沉到数据库（RPC / 触发器 / RLS）

### 背景

零后端下，"应用服务层写 DTO + 校验 + 组装"的 DDD 代码无处安放；权限、审计、webhook 同步都需要落点。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：保留应用服务层 | 多语言后端重复实现 | ❌ 违背零后端 |
| B：全部下沉 PG（05.5 映射） | RPC = Application Service；src 函数 = Domain Service；视图 = DTO/ReadModel；触发器+audit_log = Domain Event；CHECK/约束 = 校验 | ✅ 采纳 |

### 决策

- 形状用视图（CREATE VIEW / RPC 返回 json）、资格用 has_permission、行级用 RLS、快照用物化视图、带行为的输出用 RPC（05.5 决策口诀）。
- **17 号铁律**：迁移文件只承载表结构 + 数据（幂等 IF NOT EXISTS / DO 块）；函数/视图/触发器/类型/RLS 归 db/src/public/ 与 db/api_v1/public/，apply-src 全量幂等重放（含迁移目录代码对象扫描）。
- SECURITY DEFINER 写/管理 RPC 统一门槛（require_permission / require_super_admin）+ search_path 锁定；DEFINER 绕过 RLS，必须函数内自校验。

### 影响与代价

- 版本管理 = SQL 源码 + apply-src；调试依赖数据库日志/测试（pgTAP + PGlite 验证链）。
- 复杂逻辑受 SQL 表达能力约束；性能热点天然在 DB 侧，需索引/物化视图治理。

## ADR 6：按 schema 划分模块而非按服务拆分（单体数据库）

### 背景

多业务域扩展需要物理边界与权限控制；原 v6 文档规划 sales/inventory 等业务域 schema。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：按服务拆分（微服务） | 每域独立服务+库 | ❌ 与零后端冲突，运维重 |
| B：单库多 schema | public（核心+授权+审计）→ api_v1_public（暴露层）→ 扩展 schema | ✅ 采纳 |
| C：单 schema 按目录分模块 | 无物理权限边界 | ❌ 权限粒度不够 |

### 决策

- `public`：核心业务（镜像表 + 自主表 + 授权 + 审计 + 日志）；`api_v1_public`：对外 API 暴露层（视图 + RPC，只放投影不放物理表）；`api_v1_sys`：027 改名链兼容（历史迁移引用）；net/cron：扩展宿主 schema。
- 027 迁移把 api_v1_sys 收敛为 api_v1_public（视图名 = 底层表名）；对外暴露层为多 schema 形态（postgrest.conf 声明 api_v1_public / api_v1_sales / api_v1_inventory；api_v1_sys 为遗留空 schema）；063 迁移退役 inventory/sales 测试模块（路由已移除、目录保留为空、按需重建）。
- dbmate 迁移按 schema 分目录（db/migrations/public/）；PostgREST 暴露层：docker-compose env 运行时为 api_v1_public，postgrest.conf 声明三 schema。

### 影响与代价

- 模块边界 = PG 权限边界（GRANT USAGE + 表级授权）；新模块需同步 postgrest 配置与 apply-src 模块声明。
- 跨模块依赖方向受 apply-src 模块顺序约束（public 先于 api_v1；api_v1 内 privileges 排最后）。

## ADR 7：dbmate 作为迁移工具

### 背景

迁移需要版本化 + schema 快照；历史 62 个迁移文件（001–063）存在互相覆盖的中间态、部分文件有缺陷（NUL 字节、引用已删表），且 schema_migrations 账本只登记了 001–005（006–063 由 psql 手工应用，从未登记）——直接 dbmate up 必然失败。

### 可选方案

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| A：手工合并 62 个文件 | 模拟执行 62 轮 DDL，工作量巨大且大概率出错 | ❌ |
| B：反写 baseline（36 号文档方案 B） | 从现库 pg_dump 终态修剪 → 3 个幂等迁移文件；存量库账本收敛；dbmate 继续管后续增量 | ✅ 采纳 |
| C：换 Flyway/Prisma | 迁移工具迁移成本高 | ❌ |

### 决策

- dbmate（db/dbmate.toml + Makefile migrate/migrate-rollback/migrate-status）管理 db/migrations/public/。
- v0.1.0 squash：`064_v010_mirror_tables.sql`（6 张镜像表）→ `065_v010_baseline.sql`（18 张业务表）→ `066_v010_seed_data.sql`（种子：app_config 14 / dict_type 2 / dict_data 9 / iam_menu 55），共 24 张物理表（另含 schema_migrations）；历史 62 个迁移保存在 git tag v0.1.0。
- 存量库账本收敛：schema_migrations 只记 064/065/066；新库走 bootstrap → dbmate up → apply-src 自然登记。
- db/schema.sql 由 dbmate dump 生成（完整 schema 快照，可快速恢复）。

### 影响与代价

- 064/065/066 必须保持幂等（apply-src 每次部署全量重放）；后续迁移只增不改。
- 回滚路径依赖 git tag 与全库快照（baseline 无 down 语义）。
- 与 17 号铁律配合：迁移只含 DDL + 数据，代码对象归 src/api_v1。

---

> 参考：选型对比细节见 [项目总纲](../01-项目简介/overview.md) 与 [技术栈全景](../01-项目简介/tech-stack.md)；迁移规范见 [数据库迁移](../05-开发指南/migrations.md)；权限模型见 [认证与授权设计](./auth-design.md) 与 [权限开发指南](../05-开发指南/permission-development.md)。
