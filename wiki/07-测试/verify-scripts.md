# 冒烟验证脚本

冒烟验证脚本用于部署后自检与迁移前置核查，全部位于 `scripts/`。它们与 pgTAP/E2E 的分工：验证脚本回答“组件是否健康、库能否从零重建、迁移前提是否满足”，不替代业务级测试。

## 脚本总览

| 脚本 | 职责 | 执行方式 | 退出码 |
| --- | --- | --- | --- |
| `scripts/verify-stack.sh` | 全栈 8 项组件健康检查（2026-08-19 更新） | `bash scripts/verify-stack.sh` | 0 = 全过，1 = 有失败项 |
| `scripts/verify-fresh-db.sh` | 全新数据库冷启动验证（8 步） | `bash scripts/verify-fresh-db.sh [dbname]` | 0 = 通过，1 = 失败 |
| `scripts/055-t1-precheck.sql` | 055 迁移 T1 数据前置核查（只读） | `psql -U app_owner -d app_db -f scripts/055-t1-precheck.sql` | —（SQL 脚本） |
| ~~`scripts/verify-webhook/`~~ | ~~webhook payload/JWT 验证工具集（Casdoor 时代）~~ | 2026-08-19 已删除 | — |

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
| 4 | APISIX Status | `http://localhost:7085/status` 返回 `{"status":"ok"}` | 现行 |
| 5 | Dashboard UI | `http://localhost:9180/ui` 返回 HTML | 现行 |
| 6 | 路由清单 | Admin API 路由数 = 7（logto_jwks/logto_proxy/webhook_logto/ensure_user/api_v1_public/rpc_all/catch_all） | 现行 |
| 7 | Logto OIDC | `http://localhost:3001/oidc/.well-known/openid-configuration` 含 `jwks_uri` | 现行 |
| 8 | 架构校验 | compose 服务清单无 docker PG 残留（pgsql/pgbouncer/casdoor-db） | 现行 |

> ✅ 2026-08-19 已更新：verify-stack.sh 已按 Logto 架构重写（8 项检查，路由预期 7 条，登录链路改为 Logto OIDC Discovery）；Casdoor/Syncer 时代项（Casdoor 健康、user_login_sso、policy-syncer）已移除。

## verify-fresh-db.sh：全新数据库冷启动验证

### 用途

验证“从空库到全量结构”可复现（v0.1.0 squash 基线，`db/migrations/public` 仅 064/065/066：064 镜像表 6 张 + 065 业务表 18 张 = 24 张表；066 种子 app_config 14 / dict_type 2 / dict_data 9 / iam_menu 55；历史 62 个迁移在 git tag v0.1.0）。默认 scratch 库 `app_db_verify`（保留复用，每次 DROP+重建），参照库 `REF_DB`（默认 `app_db`）做结构比对。

### 8 步流程

| 步骤 | 内容 | 说明 |
| --- | --- | --- |
| 1 | 重建 scratch 库 | 超级用户 `DROP DATABASE ... WITH (FORCE)` + `CREATE DATABASE ... OWNER app_owner` |
| 2 | 建扩展 | 超级用户内联建最小集（pgcrypto/pg_net/pgtap，SQL 见 verify-fresh-db.sh；扩展权威 = Pigsty infra/*.yml；pgaudit/pgsodium 已于 2026-08-19 从 yml 移除；app_owner 非超管不能建扩展） |
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
- 文档约定（历史文档 18-迁移基线 Squash 指南，已归档）：迁移/部署链变更后 `verify-fresh-db.sh` + `make test` 双闸是发布硬门槛（人工执行，未固化到 workflow）。

## 055-t1-precheck.sql：迁移前置核查

### 用途

055“菜单权限单表化”（`iam_api`/`iam_role_api` 并入 `iam_menu` button 行）T1 数据迁移的前置核查。**全文件只读（仅 SELECT）**，输出存量库现状，用于回填历史文档（16-055-T1 前置核查清单，已归档）。

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

## verify-webhook/（历史遗留，已删除）

`scripts/verify-webhook/` 是历史文档（04.7-§10-扩展验证清单，已归档）的配套脚本集，针对 **Casdoor**（`CASDOOR_URL`）的 webhook payload 结构与 JWT claims 语义验证。**2026-08-19 已随 Casdoor 清理删除**——当前认证授权已迁移到 Logto，webhook 验证由 e2e Phase 6 与 `reconcile-logto.py` 覆盖。

（原目录内容：01_receiver.py / 02_role_events.sh / 03_inspect_payloads.sh / 04_jwt_claims.sh / README.md，历史用法见 git 历史。）
bash 02_role_events.sh            # 触发角色事件
bash 03_inspect_payloads.sh       # 解析 payload
bash 04_jwt_claims.sh             # JWT claims 检查
```

注意：02 脚本故意不 `set -e`（update-role 500 是待观测对象）；Windows git-bash 下需将 `python3` 替换为 `python`。**当前 Logto 架构下对应的验证路径**：webhook 验签与镜像同步见 e2e Phase 6，数据对账用 `scripts/phase2/reconcile-logto.py --dry-run`。

## 在 CI/部署中的使用

- `.github/workflows/` 下（ci.yml / deploy-gateway.yml / deploy-infra.yml）**均未调用** `verify-stack.sh`、`verify-fresh-db.sh` 或 `055-t1-precheck.sql`（已核对）。
- `deploy-gateway.yml`（workflow_dispatch，`skip_tests` 输入）：SSH 到服务器 → `scripts/deploy-gateway.sh <env>` → `scripts/init-apisix-routes.sh` → `scripts/e2e-test.sh`（后两步可用 `skip_tests=true` 跳过）。
- `deploy-infra.yml`：仅 `scripts/deploy-infra.sh`，无验证步骤。
- `verify-fresh-db.sh` + `make test` 作为发布双闸是文档约定（见上），尚未固化为 workflow。
- TODO 建议：① 在 `ci.yml` 增加 pgTAP/E2E job（verify-stack.sh 与 deploy-gateway.yml 已于 2026-08-19 更新/切换）。

---

> 参考：[测试体系总览](testing-overview.md) · [E2E 集成测试](e2e-tests.md) · [部署指南总览](../03-部署指南/deployment-overview.md) · [数据库迁移](../05-开发指南/migrations.md) · [Logto Webhook 接入](../06-API参考/logto-webhook.md)