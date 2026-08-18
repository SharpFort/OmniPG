# 仓库目录地图

> 定位：OmniPG 仓库各目录职责速查。事实以当前 `docs/wiki-rewrite` 分支工作区为准。

## 顶层速查

| 目录/文件 | 职责 | 关键内容 |
| --- | --- | --- |
| `db/` | 数据库全部资产：迁移、幂等源码、API 暴露层、初始化、测试 | 见下表 |
| `gateway/` | 网关侧 Docker Compose 栈（etcd/APISIX/PostgREST/Swagger/Logto） | `docker-compose.yml`、`apisix/`、`postgrest/`、`.env.example` |
| `infra/` | Pigsty 基础设施配置（WSL/服务器侧） | `pigsty*.yml`、`pg_hba.conf`、`pgbouncer.ini`、`redis.conf` |
| `scripts/` | 部署/迁移/初始化/验证脚本 | 见下表 |
| `wiki/` | 本项目 Wiki（本页面所在） | 01-08 目录 + Home.md |
| `docs/` | 历史设计文档/ADR/审查报告（内容逐步迁往 wiki） | `开发实施方案/`、`审查文档/` |
| `Makefile` | 统一入口：迁移、测试、部署、开发环境 | 见下表 |
| `.env.example` / `.env.development` / `.env.staging` / `.env.production` | 环境变量模板（DB 密码、APISIX 凭据、JWKS 等） | scripts 按 `ENV` 加载；`gateway/.env` 为本地运行配置（gitignored） |
| `backups/` | 一次性数据备份 SQL（如 iam_menu 重建前后快照） | `rebuild_iam_menu_20260814*.sql` |
| `.github/workflows/` | CI/CD | `ci.yml`、`deploy-db.yml`、`deploy-gateway.yml`、`deploy-infra.yml`、`deploy-all.yml`；⚠️ ci.yml 的 syncer-check 作业（db/syncer，Go）与 deploy-gateway.yml 的 syncer 步骤为**历史遗留**（Go syncer 已退役，webhook 同步全在库内） |
| `deployments/` | 空目录（预留） | — |
| `README.md` / `REFACTOR_PROGRESS.md` | 项目说明/重构进度 | — |

## db/（数据库与逻辑层）

| 子目录/文件 | 职责 | 关键内容 |
| --- | --- | --- |
| `migrations/public/` | 表结构与数据迁移（dbmate） | 当前仅基线 `064_v010_mirror_tables.sql`（6 张镜像表）、`065_v010_baseline.sql`（18 张业务表）、`066_v010_seed_data.sql`（80 行种子）；新迁移从 067 起 |
| `migrations/inventory`、`sales` | 历史模块迁移目录（暂空） | 测试模块已退役 |
| `src/public/` | public schema 幂等源码（**代码对象唯一权威**） | `functions/`(37)、`triggers/`(10)、`views/`(2 兼容视图)、`types/`(5 枚举)、`templates/`(审计字段模板)、`privileges/`(rls_policies.sql) |
| `api_v1/` | 对外暴露层（运行态单 schema `api_v1_public`，compose 权威） | Schema 布局 = public / api_v1_public / api_v1_sys（027 兼容，新代码不用）/ net（pg_net 宿主），**无 extensions schema**；目录：`_shared/`(空)、`inventory/`(空 rpc 占位)、`public/`(views 29 / rpc 44 / privileges/zz_grant_all.sql GRANT 集中地)；api_v1_sales/api_v1_inventory 仅存在于 postgrest.conf 参考配置与历史空目录（2026-08-15 退役） |
| `api_1_sys` / `api_1_sales` / `api_1_inventory` | 历史空目录（rpc/views 子目录占位） | 已废弃，勿使用 |
| `init/` | 初始化脚本（bootstrap 阶段） | `01-extensions.sql`（最小集 pg_pwhash/pgcrypto/pg_net/pgtap；Pigsty 集群级 pg_cron/pg_graphql；pgaudit 不启用、pgsodium 2026-08-16 退役、plpython3u/pgjwt 不用）、`02-schemas.sql`（api_v1_public/api_v1_sys/net schema + 角色授权说明） |
| `tests/public/` | pgTAP 测试 | `01_schema_test.sql`、`02_function_test.sql`、`03_trigger_test.sql`、`05_rls_test.sql`、`test_casbin_view.sql`、`test_rls_isolation.sql` |
| `extensions/` | 扩展说明 | `pgtap.md`、`pgcrypto.md` |
| `schema.sql` | pg_dump 整库结构快照（约 6400 行，dbmate dump 产物） | 仅作比对/审计，不是部署入口 |
| `dbmate.toml` | dbmate 配置 | `migrations_dir = "./migrations/public"` |

## gateway/（网关侧 Docker Compose 栈）

| 文件 | 职责 | 说明 |
| --- | --- | --- |
| `docker-compose.yml` | 五服务编排：etcd(app-etcd)、apisix(app-apisix)、postgrest(app-postgrest)、swagger-ui(app-swagger)、logto(app-logto) | 网络 `app-net`（172.20.0.0/16）；数据库走 `host.docker.internal` 连 Pigsty pgBouncer（6432/5433） |
| `apisix/config.yaml` | APISIX traditional 模式配置（etcd 存储 + Admin API + Dashboard） | Admin API 9180、Status 7085、Control 9092 |
| `apisix/apisix.yaml` | standalone 模式路由**过时残留**（当前不加载） | Casdoor 时代路由（user_login_sso/refresh_token_rtr/jwks/sales/inventory），`config.yaml` 注释明确"不再读取 apisix.yaml" |
| `postgrest/postgrest.conf` | PostgREST **参考文件**（与运行态不一致） | `db-schemas = "api_v1_public, api_v1_sales, api_v1_inventory"`（多 schema 列表，api_v1_sales/inventory 已退役）；运行态权威 = compose 环境变量（`PGRST_DB_SCHEMAS: api_v1_public`、`jwt-role-claim-key: .pg_role`） |
| `logto-csp-patch.js` | Logto CSP frame-ancestors 补丁（启动时注入） | 供 OmniAdmin 3006/3007 嵌入登录页 |
| `.env.example` | 网关环境变量模板 | `APISIX_ADMIN_KEY`、`JWKS_JSON`、`AUTHENTICATOR_PASSWORD`、`LOGTO_DB_PASSWORD` 等 |

对外端口速查：APISIX 9080(HTTP)/9443(HTTPS)/9180(Admin API+Dashboard)/7085(Status) · PostgREST 3100（容器内 3000）· Logto 3001(core)/3002(console) · Swagger UI 8082 · PostgreSQL 5432 · pgBouncer 6432 · Redis 6379 · Logto 业务库走宿主 5433。

组件版本：Pigsty v4.4.0 · PostgreSQL 18 · PostgREST v14.15（postgrest/postgrest:v14.15）· APISIX 3.17.0（apache/apisix:3.17.0-debian）· etcd 3.5.11（bitnamilegacy/etcd:3.5.11）· Logto OSS v1.42（compose 镜像 latest）· Swagger UI v5.2.0 · dbmate · pgTAP · GitHub Actions。

**已知不一致 / 待收敛**：① 路由——`setup_apisix.sh`（部署链在用）与 `apisix.yaml`（留档）仍是 Casdoor 时代路由；Logto 时代目标路由（7 条）在 `scripts/init-apisix-routes.sh`（未接入部署链）；api_v1_sales/inventory 路由 2026-08-15 已退役。② Schema——postgrest.conf 参考配置声明多 schema（api_v1_public/api_v1_sales/api_v1_inventory），compose 运行态权威为单 schema api_v1_public。③ JWT 算法——开发 HS256，staging/production 指向 Logto JWKS（init-apisix-routes.sh 用 RS256；compose/.env 注释写 ES384，需以 Logto 实际配置核实）。④ CI——ci.yml 的 syncer-check 作业与 deploy-gateway.sh 的 syncer build 段为历史遗留（Go syncer 已退役，db/syncer 不存在）。详细路由集见 [../06-API参考/gateway-routing.md](../06-API参考/gateway-routing.md)（该页应以此为准）。

## infra/（Pigsty 基础设施配置）

| 文件 | 职责 |
| --- | --- |
| `pigsty.yml` | Pigsty 主配置（集群/节点/组件；pg_cron、pg_graphql 集群级安装） | ⚠️ 仍列出 pgaudit/pgsodium（12/14/46/48 行），与 01-extensions.sql 最小集冲突——**以 01-extensions.sql 为准，待收敛（TODO）** |
| `pigsty.db.yml` | 数据库节点配置 |
| `pigsty.gateway.yml` | 网关节点配置 |
| `pg_hba.conf` | PostgreSQL 客户端认证 |
| `pgbouncer.ini` | 连接池配置（PostgREST 经 6432 连接） |
| `postgresql.conf` | PostgreSQL 服务端参数 |
| `redis.conf` | Redis 配置 |
| `userlist.txt` | pgbouncer 用户清单 |

## scripts/（部署与运维脚本）

| 脚本 | 用途 |
| --- | --- |
| `deploy-db.sh` | 数据库四步部署链：bootstrap（init + src types）→ dbmate up → apply-src 全量 → 验证 |
| `deploy-gateway.sh` | 网关部署 |
| `deploy-infra.sh` / `deploy-all.sh` | 基础设施/全栈部署 |
| `apply-src.sh` | **全量幂等重放**（含 §6.3 迁移代码对象扫描 + 3 遍收敛）；`--bootstrap` 子集 |
| `migrate.sh` | dbmate 快捷入口（up/down/status/create） |
| `setup_apisix.sh` | APISIX 初始化（被 Makefile `dev` / deploy-all.sh / deploy-gateway.sh / CI 引用）——⚠️ **内部仍是 Casdoor 时代路由**（jwks→app-casdoor 已死、user_login_sso/refresh_token_rtr、api_v1_sales/inventory 重写），与 Logto 部署不一致，待收敛 |
| `init-apisix-routes.sh` | **Logto 时代目标路由初始化**：logto_jwks（→app-logto）、logto_proxy（/logto/*）、webhook_logto（HMAC 验签）、ensure_user、api_v1_public（/api/v1/sys/*→/$1）、rpc_all、catch_all | ⚠️ 当前未接入部署链（仅 e2e-test.sh 注释提及），为目标事实标准 |
| `start.sh` / `stop.sh` | 一键启停开发环境 |
| `e2e-test.sh` | 端到端测试（Logto OIDC code flow 登录 → APISIX/PostgREST 全链路） |
| `verify-stack.sh` | 全栈冒烟验证（10 项） |
| `verify-fresh-db.sh` | 全新库冷启动验证（结构比对 + 幂等两遍 + pgTAP） |
| `import-geolite2.sh` / `import-ip2region.sh` | IP 归属地数据导入 |
| `wsl-portproxy.ps1` | WSL 端口转发辅助 |
| `phase2/` | Logto 初始化/对账脚本（`init-logto.py`、`reconcile-logto.py`） |
| `verify-webhook/` | webhook 调试工具（`01_receiver.py`、`02_role_events.sh`、`03_inspect_payloads.sh`、`04_jwt_claims.sh`） |
| `055-t1-precheck.sql` | 历史迁移前置核查 SQL（留档） |
| `README.md` | 脚本使用说明 |

## Makefile：统一入口

| 目标 | 作用 |
| --- | --- |
| `make dev` / `make dev-down` | 启动/停止本地环境（gateway compose + setup_apisix） |
| `make migrate` / `make migrate-rollback` / `make migrate-status` | 迁移应用/回滚/状态（dbmate，目录 migrations/public） |
| `make test` | 全部测试（test-db + test-e2e） |
| `make test-db` | pgTAP（pg_prove -r tests/） |
| `make test-e2e` | 端到端（scripts/e2e-test.sh） |
| `make deploy-db ENV=staging` / `make deploy-gateway ENV=staging` | 部署入口（转发 scripts/deploy-*.sh） |

## .env.*（环境变量模板）

- 根目录 `.env.example`（开发默认）、`.env.development`、`.env.staging`、`.env.production`：`DB_PASSWORD`、`DB_USER`、`AUTHENTICATOR_PASSWORD`、`APISIX_ADMIN_KEY`、`JWKS_JSON`、`PG_BOUNCER_PORT` 等。
- `gateway/.env`（gitignored）：本地网关运行配置，由 `cp .env.development gateway/.env` 生成；Makefile 迁移目标从中读取 `DB_PASSWORD`。
- 安全提示：`JWKS_JSON` 示例为开发 HS256 密钥，任何非本地部署前必须更换（见 gateway/.env.example 头部警告）。

## wiki/ 与 docs/ 的关系

- `wiki/` 是**现行文档**（本仓库维护的中文 Markdown 手册），按 01-08 分章。
- `docs/` 是**历史设计文档与 ADR**（如 17 号铁律、18 号 squash 指南、35 号审查），内容逐步迁入 wiki；写 wiki 时以 `docs/` 为背景、以 `db/` 等当前代码为准。

---

> 参考：新增 API 流程见 [adding-api.md](adding-api.md)，编码规范见 [coding-standards.md](coding-standards.md)，迁移规范见 [migrations.md](migrations.md)，权限开发见 [permission-development.md](permission-development.md)；部署细节见 [../03-部署指南/deployment-overview.md](../03-部署指南/deployment-overview.md)，架构总览见 [../04-架构/architecture-overview.md](../04-架构/architecture-overview.md)。
