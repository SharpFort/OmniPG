# 冒烟验证脚本

冒烟验证脚本用于部署后自检与迁移前置核查，全部位于 `scripts/`。它们与 pgTAP/E2E 的分工：验证脚本回答“组件是否健康、库能否从零重建、迁移前提是否满足”，不替代业务级测试。

## 脚本总览

| 脚本 | 职责 | 执行方式 | 退出码 |
| --- | --- | --- | --- |
| `scripts/verify-stack.sh` | 全栈 10 项组件健康检查 | `bash scripts/verify-stack.sh` | 0 = 全过，1 = 有失败项 |
| `scripts/verify-fresh-db.sh` | 全新数据库冷启动验证（8 步） | `bash scripts/verify-fresh-db.sh [dbname]` | 0 = 通过，1 = 失败 |
| `scripts/055-t1-precheck.sql` | 055 迁移 T1 数据前置核查（只读） | `psql -U app_owner -d app_db -f scripts/055-t1-precheck.sql` | —（SQL 脚本） |
| `scripts/verify-webhook/` | webhook payload/JWT 验证工具集（**历史遗留**，Casdoor 时代） | 见下文 | — |

## verify-stack.sh：组件健康检查

### 职责与依赖

- 用途：部署后一键验证全栈（WSL2 + Docker Desktop + Pigsty 宿主环境）。
- 依赖预检：docker、curl、psql（宿主 Pigsty 自带）、python3/python（JSON 解析）；加载 `gateway/.env`（`APISIX_ADMIN_KEY`、`AUTHENTICATOR_PASSWORD` 等，缺失时用默认值）。
- 执行：`bash scripts/verify-stack.sh`；任一失败项都会在结尾列出并 `exit 1`。

### 10 项检查清单

| # | 检查项 | 方法/预期 | 状态 |
| ---: | --- | --- | --- |
| 0 | 依赖预检 | docker/curl/psql/python 可用，gateway/.env 加载 | 现行 |
| 1 | 网络链路 | 容器 → 宿主 pgbouncer(6432) 可达（app-net + host.docker.internal） | 现行 |
| 2 | 宿主 pgbouncer | `authenticator` 角色经 127.0.0.1:6432 登录成功 | 现行 |
| 3 | PostgREST OpenAPI | `http://localhost:3001/` 返回 >2000 字符 | 现行 |
| 4 | Casdoor 健康 | `http://localhost:8000/api/health` | ⚠️ 过时（Casdoor 已退役） |
| 5 | APISIX Status | `http://localhost:7085/status` 返回 `{"status":"ok"}` | 现行 |
| 6 | Dashboard UI | `http://localhost:9180/ui` 返回 HTML | 现行 |
| 7 | 路由清单 | Admin API 路由数 = 8 | ⚠️ 过时（Logto 版 `init-apisix-routes.sh` 为 7 条） |
| 8 | 登录链路 | `POST /rpc/user_login_sso` 拿到 access_token | ⚠️ 过时（该 RPC 已退役） |
| 9 | Policy Syncer | `policy-syncer` 容器运行且近 20 行日志无错误 | ⚠️ 过时（Syncer 已退役） |
| 10 | 架构校验 | compose 服务清单无 docker PG 残留（pgsql/pgbouncer/casdoor-db） | 现行 |

### 已知过时项（TODO）

第 4/7/8/9 项基于 Casdoor 时代设计（Casdoor、`user_login_sso`、policy-syncer、路由数 8），与当前 Logto 架构不一致：当前网关容器为 etcd/apisix/postgrest/swagger-ui/logto；目标路由集 = `scripts/init-apisix-routes.sh` 的 7 条（logto_jwks、logto_proxy、webhook_logto、ensure_user、api_v1_public、rpc_all、catch_all），该脚本尚未接入部署链（部署链仍调用 Casdoor 时代 `setup_apisix.sh`，见 [网关路由](../06-API参考/gateway-routing.md) 的「已知不一致」）。更新方向：改为检查 Logto 容器与 OIDC discovery、Logto JWKS、webhook 路由、`e2e-test.sh` 登录链路。

## verify-fresh-db.sh：全新数据库冷启动验证

### 用途

验证“从空库到全量结构”可复现（v0.1.0 squash 基线，`db/migrations/public` 仅 064/065/066：064 镜像表 6 张 + 065 业务表 18 张 = 24 张表；066 种子 app_config 14 / dict_type 2 / dict_data 9 / iam_menu 55；历史 62 个迁移在 git tag v0.1.0）。默认 scratch 库 `app_db_verify`（保留复用，每次 DROP+重建），参照库 `REF_DB`（默认 `app_db`）做结构比对。

### 8 步流程

| 步骤 | 内容 | 说明 |
| --- | --- | --- |
| 1 | 重建 scratch 库 | 超级用户 `DROP DATABASE ... WITH (FORCE)` + `CREATE DATABASE ... OWNER app_owner` |
| 2 | 建扩展 | 超级用户执行 `db/init/01-extensions.sql`（pg_pwhash/pgcrypto/pg_net/pgtap；pg_cron/pg_graphql 由 Pigsty 集群级安装；pgaudit 不启用、pgsodium 已退役，infra/pigsty.yml 仍列出——以 01-extensions.sql 为准，TODO 收敛；app_owner 非超管不能建扩展） |
| 3 | bootstrap 子集 | `02-schemas.sql` + `db/src/public/types/*.sql`（枚举前置） |
| 4 | dbmate up | 基线迁移（`--no-dump-schema`，防止 scratch 快照覆盖 `db/schema.sql`） |
| 5 | apply-src 全量 | 幂等重放（脚本 CRLF，先做 LF 临时副本再执行） |
| 6 | apply-src 二遍 | 幂等性验证 |
| 7 | 结构比对 | 表/列/约束/种子/函数/视图/触发器/策略/索引 与 REF_DB diff（/tmp/verify_compare.sql 生成） |
| 8 | pgTAP | `pg_prove` 跑 `db/tests/`；“112/115 + casbin 3 条预期差异”判为通过 |

### 执行方式与注意事项

```bash
bash scripts/verify-fresh-db.sh          # 默认 scratch: app_db_verify
bash scripts/verify-fresh-db.sh my_check # 自定义库名
```

- 需要超级用户能力：默认 `sudo -u postgres psql`；生产 Pigsty 无 sudo 时用 `PG_SUPER_CMD` / `PG_SUPER_POSTGRES_CMD` 覆盖（如 `PG_SUPER_CMD='psql "postgres://dbuser_dba:xxx@host:5432/${DB_NAME}"'`）。
- `PGPASSWORD` 自动从 `gateway/.env` 提取；`REF_DB` 可用环境变量覆盖。
- pg_prove 未安装时跳过第 8 步（提示安装 pgtap 或 `TAP::Parser::SourceHandler::pgTAP`）。
- 文档约定（`docs/开发实施方案/18-迁移基线Squash与冷启动验证指南.md`）：迁移/部署链变更后 `verify-fresh-db.sh` + `make test` 双闸是发布硬门槛（人工执行，未固化到 workflow）。

## 055-t1-precheck.sql：迁移前置核查

### 用途

055“菜单权限单表化”（`iam_api`/`iam_role_api` 并入 `iam_menu` button 行）T1 数据迁移的前置核查。**全文件只读（仅 SELECT）**，输出存量库现状，用于回填 `docs/开发实施方案/16-055-T1前置核查-存量数据清单.md`。

### 11 段内容

| 段 | 内容 |
| --- | --- |
| §0 | 总览：api_total / api_with_code / api_no_code / api_orphan / menu_buttons / button_no_code / role_api_bindings |
| §1 | `iam_api` 全表清单（带归属菜单名） |
| §2 | 无码行清单（D9 清除对象） |
| §3 | 有码行清单（含 role_api 绑定数） |
| §4 | 死端点判定（对照 `api_v1_public` 实际暴露的视图/RPC） |
| §5 | button 行挂接数核查（>1 为冲突清单） |
| §6 | 孤儿行清单（menu_id IS NULL） |
| §7 | role_api 绑定分布（有码/无码） |
| §8 | 一码多行核查（023 部分唯一索引下应为 0） |
| §9 | 菜单树 button 全量（055 转换目标载体） |
| §10 | 转换映射预期（10.1 需新建 button 行；10.2 回填 api_url/api_method） |
| §11 | 历史迁移 NOTICE 对照（040/043 时点事实） |

### 执行

```bash
psql -U app_owner -d app_db -f scripts/055-t1-precheck.sql
```

## verify-webhook/（历史遗留）

`scripts/verify-webhook/` 是 `docs/开发实施方案/04.7-§10-扩展验证清单.md` 的配套脚本集，针对 **Casdoor**（`CASDOOR_URL`）的 webhook payload 结构与 JWT claims 语义验证。当前认证授权已迁移到 Logto，本目录为历史保留，**不再参与当前链路**。

| 脚本 | 作用 | 对应验证项 |
| --- | --- | --- |
| `01_receiver.py` | webhook 接收器：请求原样落盘 `out/`，返回 200（端口默认 8099） | 全部（payload 采集） |
| `02_role_events.sh` | 管理员会话驱动 add/update(挂摘用户)/改名/delete/失败请求 | V1–V7 |
| `03_inspect_payloads.sh` | 汇总解析 `out/` payload（action/operator/requestUri/response/users 完整性） | V1–V7 判定 |
| `04_jwt_claims.sh` | password grant 取 token → 解码检查 roles 结构/顺序/isEnabled/凭据泄漏 | V8–V10、V13 |
| `README.md` | 运行顺序、注意事项、手工验证项（V4 UI 保存、V11 SingleOrgOnly、V12 重试/Replay、V10 tokenFormat） | — |

运行顺序（历史用法）：

```bash
cd scripts/verify-webhook
python3 01_receiver.py 8099      # 另开终端
export CASDOOR_URL=... ORG=... ADMIN_USER=... ADMIN_PASS=... TEST_USER=...
export CLIENT_ID=... CLIENT_SECRET=... USERNAME=... PASSWORD=...
bash 02_role_events.sh            # 触发角色事件
bash 03_inspect_payloads.sh       # 解析 payload
bash 04_jwt_claims.sh             # JWT claims 检查
```

注意：02 脚本故意不 `set -e`（update-role 500 是待观测对象）；Windows git-bash 下需将 `python3` 替换为 `python`。**当前 Logto 架构下对应的验证路径**：webhook 验签与镜像同步见 e2e Phase 6，数据对账用 `scripts/phase2/reconcile-logto.py --dry-run`。

## 在 CI/部署中的使用

- `.github/workflows/` 下（ci.yml / deploy-gateway.yml / deploy-infra.yml）**均未调用** `verify-stack.sh`、`verify-fresh-db.sh` 或 `055-t1-precheck.sql`（已核对）。
- `deploy-gateway.yml`（workflow_dispatch，`skip_tests` 输入）：SSH 到服务器 → `scripts/deploy-gateway.sh <env>` → `scripts/setup_apisix.sh` → `scripts/e2e-test.sh`（后两步可用 `skip_tests=true` 跳过）。
- `deploy-infra.yml`：仅 `scripts/deploy-infra.sh`，无验证步骤。
- `verify-fresh-db.sh` + `make test` 作为发布双闸是文档约定（见上），尚未固化为 workflow。
- TODO 建议：① 更新 `verify-stack.sh` 过时项（Logto 容器/JWKS/路由数）；② 将 `deploy-gateway.yml` 的路由初始化切到 Logto 版 `init-apisix-routes.sh`；③ 在 `ci.yml` 增加 pgTAP/E2E job。

---

> 参考：[测试体系总览](testing-overview.md) · [E2E 集成测试](e2e-tests.md) · [部署指南总览](../03-部署指南/deployment-overview.md) · [数据库迁移](../05-开发指南/migrations.md) · [Logto Webhook 接入](../06-API参考/logto-webhook.md)