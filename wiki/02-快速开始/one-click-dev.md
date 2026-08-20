# 一键搭建本地开发环境

> 目标：从克隆仓库到跑通第一个接口。最小命令序列见下；`make dev` 与迁移/验证的内部细节见后文拆解。

## 最小操作序列

```bash
git clone <repo-url> OmniPG && cd OmniPG
git checkout feature/logto-authn        # 当前主线

# 1. 配置网关环境变量（必须）
cp gateway/.env.example gateway/.env
vim gateway/.env                        # 按本机实际修改密码/密钥

# 2. 一键启动网关栈
make dev

# 3. 数据库迁移
make migrate

# 4. 验证
make test-db
```

> 数据库（Pigsty 宿主）须已就绪；未安装基础设施请看 [前置条件](prerequisites.md)。各步骤失败的表现与排查见 [常见问题排查](troubleshooting.md)。

## 第 1 步：克隆与分支

- 仓库主线：`feature/logto-authn`（Logto 认证授权改造）。
- 本 wiki 编写完成于 `docs/wiki-rewrite` 分支，现已合并至 `master`；主线不变。

## 第 2 步：复制环境变量

```bash
cp gateway/.env.example gateway/.env
```

也可按脚本注释/文档惯例使用 `cp .env.development gateway/.env`（两者变量集一致）。

`gateway/.env` 是网关栈的**唯一配置源**：docker compose 自动读取；`make migrate` 读取 `DB_PASSWORD`；`init-apisix-routes.sh` 读取 `APISIX_ADMIN_KEY` / `LOGTO_WEBHOOK_SIGNING_KEY`，并从 Logto :3001 拉取 JWKS（RS256）。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| DB_HOST / DB_PORT / DB_USER / DB_NAME | host.docker.internal / 5432 / app_owner / app_db | 网关侧参考值（PostgREST 实际经 pgbouncer 6432） |
| AUTHENTICATOR_PASSWORD | authenticator_dev_pass | PostgREST 连接 pgbouncer 的密码，必须与 Pigsty `pg_users` / `userlist.txt` 一致 |
| DB_PASSWORD | dev_password_change_me | `make migrate` 拼连接串用，必须与 Pigsty 中 app_owner 密码一致 |
| APISIX_ADMIN_KEY | edd1c9f...（示例默认） | 非本地环境必须更换（`openssl rand -hex 16`） |
| JWKS_JSON | HS256 dev key（占位） | 开发环境为 HS256 对称密钥；staging/production 指向 Logto JWKS 公钥（RS256 口径，见 [第一个 API 调用](first-api-call.md)；compose 与 .env.staging/.production 注释写 ES384，口径不一致，需以 Logto 实际配置核实） |
| PGRST_PORT | 3001 | ⚠️ 与 compose 中 PostgREST 实际映射 3100 不一致（历史遗留，见 troubleshooting） |
| SWAGGER_PORT | 8082 | Swagger UI 端口 |

> TODO（代码事实）：`gateway/.env.example` 尚未包含 `LOGTO_DB_PASSWORD` 与 `LOGTO_WEBHOOK_SIGNING_KEY`。compose 中 Logto 的 `DB_URL` 使用 ${LOGTO_DB_PASSWORD:-logto_dev_pass_2026}；`scripts/init-apisix-routes.sh` 在缺少 `LOGTO_WEBHOOK_SIGNING_KEY` 时 fail-closed 拒绝部署。使用 Logto webhook 链路时需手工补这两项到 `gateway/.env`。

根目录 `.env.example` / `.env` 不是 `make dev` 的输入（脚本均读取 `gateway/.env`），本地开发只需复制 `gateway/.env.example`。

## 第 3 步：make dev（内部拆解）

`Makefile` 的 `dev` 目标等价于：

```bash
cd gateway && docker compose up -d      # ①
sleep 10                                # ②
cd gateway && bash -c '[ -f .env ] && export $(grep -v "^#" .env | xargs); bash ../scripts/init-apisix-routes.sh'   # ③
```

### ① docker compose up -d

拉起 5 个容器（`gateway/docker-compose.yml`）：

| 服务 | 容器名 | 端口映射 | 说明 |
| --- | --- | --- | --- |
| etcd | app-etcd | 无 | APISIX 配置中心（traditional 模式），容器内 `app-etcd:2379` |
| apisix | app-apisix | 9080 / 9443 / 9180 / 7085 | 数据面 + Admin API + Dashboard + Status API |
| postgrest | app-postgrest | 3100 → 3000 | 暴露 `api_v1_public` schema；连接 pgbouncer 6432 |
| swagger-ui | app-swagger | 8082 → 8080 | 浏览器端拉取 PostgREST OpenAPI |
| logto | app-logto | 3001 / 3002 | 首次启动执行 `db seed -- --swe` + CSP 补丁后 `npm start` |

关键环境变量（compose 内，代码事实）：

- PostgREST（运行态以 compose 环境变量为权威）：`PGRST_DB_URI=postgres://authenticator:***@host.docker.internal:6432/app_db`；`PGRST_DB_SCHEMAS=api_v1_public`（单 schema）；`PGRST_DB_EXTRA_SEARCH_PATH=api_v1_public,public`；`PGRST_JWT_SECRET=${JWKS_JSON}`；`PGRST_JWT_ROLE_CLAIM_KEY=.pg_role`（DB 角色取自 JWT 的 `pg_role` claim）；`PGRST_MAX_ROWS=1000`；`PGRST_DB_PRE_REQUEST` 为空（不启用黑名单）。`gateway/postgrest/postgrest.conf` 仅为参考文件（2026-08-19 已与运行态对齐：单 schema、.pg_role），不挂载进容器。
- Logto：`DB_URL=postgres://logto:***@host.docker.internal:5433/logto`；`DATABASE_STATEMENT_TIMEOUT=DISABLE_TIMEOUT`（pgBouncer 兼容）；`ENDPOINT=http://localhost:3001`、`ADMIN_ENDPOINT=http://localhost:3002`。

### ② 等待 10 秒

compose 没有健康检查 gate，纯 `sleep 10` 后即进入路由初始化。

### ③ scripts/init-apisix-routes.sh

传统模式（etcd + Admin API）初始化（Logto 版 `init-apisix-routes.sh`），共 5 步：

1. 幂等清理 Casdoor 时代旧路由（jwks / user_login_sso / refresh_token_rtr / casdoor_proxy / api_v1_sys / api_v1_sales / api_v1_inventory）。
2. 轮询 `http://localhost:7085/status` 直到 `{"status":"ok"}`（15 次 × 1s）。
3. 从 Logto OIDC discovery（:3001）拉取 JWKS，`PUT /apisix/admin/plugin_metadata/jwt-auth`（RS256）。
4. `PUT` 业务路由 7 条：`logto_jwks`、`logto_proxy`（`/logto/*`）、`webhook_logto`（`/rpc/webhook_logto`，HMAC 验签）、`ensure_user`（`/rpc/ensure_user`）、`api_v1_public`（`/api/v1/public/*`）、`rpc_all`（`/rpc/*`）、`catch_all`（`/*`）。
5. `PUT /apisix/admin/global_rules/1`：全局 CORS（含 `logto-signature-sha-256` header）。

> ✅ 2026-08-19：部署链（`make dev`）已切换为 Logto 版 `scripts/init-apisix-routes.sh`（清理旧路由、Logto JWKS RS256、`/logto/*` 同源代理、`/rpc/webhook_logto` HMAC 验签、`/rpc/ensure_user`、`/api/v1/public/*` 重写为 `/$1`）；Casdoor 时代 `setup_apisix.sh` 已删除。

```bash
bash scripts/init-apisix-routes.sh   # 需要 gateway/.env 含 LOGTO_WEBHOOK_SIGNING_KEY
```

### 前置条件检查

- `gateway/.env` 不存在时，`init-apisix-routes.sh` 因 `APISIX_ADMIN_KEY` 或 `LOGTO_WEBHOOK_SIGNING_KEY` 缺失直接退出（fail-closed，❌）。
- APISIX 起不来通常是 etcd 未就绪或镜像拉取失败。

## 第 4 步：make migrate

`Makefile` 中的定义（代码事实）：

```makefile
DB_PASSWORD := $(shell sed -n 's/^DB_PASSWORD=//p' gateway/.env)
DB_URL := postgres://app_owner:$(DB_PASSWORD)@127.0.0.1:5432/app_db?sslmode=disable

migrate:
	cd db && DATABASE_URL="$(DB_URL)" dbmate -d migrations/public up
```

- 连接**宿主 PG 直连端口 5432**（不走 pgbouncer），用户 `app_owner`，密码取自 `gateway/.env` 的 `DB_PASSWORD`（注意不是 `AUTHENTICATOR_PASSWORD`）。
- 迁移目录 `db/migrations/public`；当前为 squash 基线三件套（共 24 张表）：
  - `064_v010_mirror_tables.sql` — Logto 镜像表 6 张（users/tenants/user_tenants/role 等）
  - `065_v010_baseline.sql` — 业务表 18 张（表结构基线）
  - `066_v010_seed_data.sql` — 种子数据：app_config(14)、dict_type(2)、dict_data(9)、iam_menu(55)，全部 `ON CONFLICT DO NOTHING`；镜像表与运行时数据不入库
- 历史 62 个迁移在 git tag `v0.1.0`（squash 前的增量历史）。
- 函数/视图/触发器/RLS 不在迁移里：它们位于 `db/src`、`db/api_v1`，由 `scripts/apply-src.sh` 全量幂等重放。完整部署链（bootstrap → dbmate up → apply-src → status）用 `bash scripts/deploy-db.sh development`；本地快速开发可只跑 `make migrate`（前提是 src 已刷入）。
- 相关目标：`make migrate-status`（查看状态）、`make migrate-rollback`（回滚最近一次）。

## 第 5 步：验证

```bash
make test-db     # pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r db/tests/
make test-e2e    # bash scripts/e2e-test.sh（见下）
```

- `make test-db`：运行 `db/tests/` 下 pgTAP 用例（schema/函数/触发器/RLS 等）。注意 Makefile 带 `|| true`——用例失败不会令 make 退出非零，需看输出中 FAIL 项。
- `make test-e2e`：Logto OIDC code flow 登录 → APISIX → PostgREST → 只读镜像表/RLS/webhook 验签全链路。前置：Logto 已配置（脚本头默认 `CLIENT_ID=lbrkbi552ndpp22o339p4`、`ORG_ID=fmr1j72k3htk`、`E2E_USER=admin`、`E2E_PASSWORD=Admin@112104` 等，需与你的 Logto 实例一致）；webhook 路由已初始化（`init-apisix-routes.sh`）；PostgREST :3100、APISIX :9080 可达。详见 [E2E 集成测试](../07-测试/e2e-tests.md)。
- 快速冒烟（不等测试套件）：

```bash
curl -s http://localhost:3100/ | head -c 200          # PostgREST OpenAPI
curl -s http://localhost:7085/status                  # {"status":"ok"}
curl -sf http://localhost:3001/oidc/.well-known/openid-configuration | python3 -m json.tool   # Logto OIDC
curl -sf http://localhost:8082/ | head -c 100         # Swagger UI
```

> `scripts/verify-stack.sh` 可做全栈验证，但其 PostgREST 检查仍用 :3001、仍检查 Casdoor :8000 与 Syncer 容器——属历史遗留（代码事实），以 `e2e-test.sh` 的 3100/Logto 检查为准，详见 troubleshooting。

## 第 6 步：停止环境

```bash
make dev-down    # cd gateway && docker compose down（保留 etcd_data 卷）
# 或完整脚本（额外停 pgbouncer/grafana；保留 PG/Redis/etcd 核心）：
bash scripts/stop.sh
```

- `docker compose down` 不删卷；`docker compose down -v` 才会清除 etcd 数据卷（路由配置会丢，需重跑初始化脚本）。
- 宿主 Pigsty 服务不受影响。

## 下一步

- 登录并调用第一个接口 → [第一个 API 调用](first-api-call.md)
- 各步骤失败排查 → [常见问题排查](troubleshooting.md)

---

> 参考：[前置条件](prerequisites.md) · [第一个 API 调用](first-api-call.md) · [常见问题排查](troubleshooting.md) · [脚本部署](../03-部署指南/script-deploy.md) · [数据库迁移](../05-开发指南/migrations.md)