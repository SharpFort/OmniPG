# 手动部署（逐步方案）

本文档按 9 步完成一次从零部署，不依赖 `deploy-all.sh`，便于理解每一步做什么、排查时知道对应哪个脚本。每步都给出「命令/文件」与「对应脚本」，两者行为一致时可直接用脚本代替。

> 前提：WSL2 Ubuntu（systemd）+ Docker Desktop（WSL2 集成）+ 仓库代码已就位。敏感项准备见 [environment-config.md](environment-config.md)。

## Step 1：安装并初始化 Pigsty

目标：在宿主安装 Pigsty v4.4.0 并选择集群配置。

```bash
# 安装（未安装时 deploy-infra.sh 也会自动执行）
curl -fsSL https://pigsty.cc/get | bash -s v4.4.0
cd ~/pigsty
./configure -i $(hostname -I | awk '{print $1}') -n -s

# 选择配置文件并复制（all=单机完整 / db=DB 服务器 / gateway=网关服务器）
cp ~/OmniPG/infra/pigsty.yml ~/pigsty/pigsty.yml        # 单机 all
# cp ~/OmniPG/infra/pigsty.yml ~/pigsty/pigsty.yml   # 唯一 inventory（2026-08-19 方案 A）
#   Phase 2 多机: 同一 pigsty.yml，按官方剧本 + LIMIT 主机限制分角色部署（见 scripts/deploy-infra.sh）

# 执行部署（deploy-infra.sh 等价动作）
./deploy.yml   # INFRA + PGSQL + REDIS + ETCD + DOCKER 等模块
./etcd.yml     # etcd 集群
```

关键配置（`infra/pigsty.yml`）：

| 项 | 值 | 说明 |
| --- | --- | --- |
| pg_version | 18 | PostgreSQL 18 |
| pg_cluster | pg_omnipg | 集群名 |
| pg_users | app_owner / authenticator / web_anon | 应用角色（web_anon NOLOGIN） |
| pg_databases | app_db（owner app_owner） | 主业务库 |
| pg_extensions | pgcrypto/pg_net/pgtap/pg_graphql/pg_cron/safeupdate/plpgsql_check/pg_jsonschema/omni_csv/pgmemento/pg_mockable/jsquery/index_advisor/pg_repack | 集群级扩展（pgaudit/pgsodium 已于 2026-08-19 移除；safeupdate 需 shared_preload + 重启；权威清单见 infra/pigsty.yml） |
| pg_hba_rules | 127.0.0.1/32、::1/128、172.17.0.0/16、172.20.0.0/16（db.yml 另含 10.0.0.0/8） | scram-sha-256 |

> ⚠️ 对齐项（TODO）：① `db/init/02-schemas.sql` 头注给出角色分层参考（super_admin/role_admin/role_editor/role_guest/role_super_admin/tenant_admin 及 authenticator 的 roles 成员关系），当前 `infra/*.yml` 的 pg_users 尚未包含；② 扩展权威 = `infra/pigsty.yml`（唯一 inventory，2026-08-19 方案 A；`pg_extensions` + `pg_databases[].extensions`），`db/init/01-extensions.sql` 已于 2026-08-19 移除；pgaudit 未启用、pgsodium 2026-08-16 退役并已于 2026-08-19 从 yml 移除，plpython3u / pgjwt 不用。生产部署前请按 02-schemas 头注与 infra/*.yml 补齐。

**对应脚本**：`scripts/deploy-infra.sh`（模式 all/db/gateway，步骤 1-4）。

## Step 2：启动 PostgreSQL 集群与 pgbouncer、redis

目标：确认宿主服务就绪（Pigsty 模块部署完成后即已运行）。

```bash
# 服务状态
systemctl status postgresql@18-main redis-server etcd 2>/dev/null | head -20
pgrep -x pgbouncer && echo "pgbouncer running"

# 复制 pgbouncer / redis 配置（deploy-infra.sh 步骤 3 的等价动作）
sudo mkdir -p /etc/pgbouncer
sudo cp ~/OmniPG/infra/pgbouncer.ini /etc/pgbouncer/
sudo cp ~/OmniPG/infra/userlist.txt /etc/pgbouncer/ && sudo chmod 640 /etc/pgbouncer/userlist.txt
sudo cp ~/OmniPG/infra/redis.conf /etc/redis/redis.conf

# 验证
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"
PGPASSWORD=authenticator_dev_pass psql -h 127.0.0.1 -p 6432 -U authenticator -d app_db -c "SELECT 1"
redis-cli ping   # PONG
```

要点：
- `infra/pgbouncer.ini`：监听 0.0.0.0:6432，`auth_type = scram-sha-256`，`auth_file = /etc/pgbouncer/userlist.txt`，session 池模式，路由 `app_db`；
- `infra/pg_hba.conf` 为参考文件（pigsty.yml 的 `pg_hba_rules` 才是生成源），Docker 网段 172.17.0.0/16 与 172.20.0.0/16 必须放行 scram-sha-256；
- 容器访问宿主经 `host.docker.internal`（Windows 用 mirrored 网络或 `scripts/wsl-portproxy.ps1`）。

**对应脚本**：`scripts/deploy-infra.sh`（步骤 5 验证）。

## Step 3：应用数据库初始化（db/init）

目标：创建扩展、Schema、角色授权与枚举（迁移的前置依赖）。

```bash
cd ~/OmniPG

# 1) 扩展（需超级用户；app_owner 无权限）——权威 = Pigsty（infra/pigsty.yml 声明装包 + 库内启用）
#    Pigsty 部署后扩展即就绪；手动补建仅用于本地验证环境兜底（2026-08-19 起无 01-extensions.sql）：
sudo -u postgres psql -d app_db -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_net";
CREATE EXTENSION IF NOT EXISTS "pgtap";
SQL
#    （pg_cron/pg_graphql 等集群级扩展由 Pigsty 安装；safeupdate 仅装包 + preload，无 CREATE EXTENSION）

# 2) Schema 与授权（app_owner 执行）
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db \
  -v ON_ERROR_STOP=1 -f db/init/02-schemas.sql
#    => api_v1_sys（027 改名链兼容，新代码不用）/ api_v1_public / net；USAGE 授权；pg_net 收紧（不存在 extensions schema）

# 3) 枚举前置（bootstrap 子集；迁移 059/060 引用 src 枚举）
for f in db/src/public/types/*.sql; do
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db \
    -v ON_ERROR_STOP=1 -f "$f"
done
```

说明：扩展与角色属于集群级资源（Pigsty 权威管理），init 脚本只是幂等兜底；`db/schema.sql` 是 pg_dump 参考快照，不属于部署输入。

**对应脚本**：`scripts/apply-src.sh <db_uri> --bootstrap`（deploy-db.sh 第 [1/4] 步）。

## Step 4：dbmate 迁移（db/migrations/public）

```bash
cd ~/OmniPG/db
export DBMATE_DATABASE_URL="postgres://app_owner:dev_password_change_me@127.0.0.1:5432/app_db?sslmode=disable"
dbmate up          # 应用 064_v010_mirror_tables → 065_v010_baseline → 066_v010_seed_data
dbmate status      # Applied 3 / Pending 0
```

当前基线（v0.1.0 squash 结果，2026-08-16；064 镜像 6 张 + 065 业务 18 张 = 合计 24 张表）：

| 迁移 | 内容 |
| --- | --- | --- |
| 064_v010_mirror_tables.sql | Logto 镜像/绑定表 6 张（users、tenants、role、organization_role、user_tenants、user_role，text id） |
| 065_v010_baseline.sql | 业务表 18 张 + 2 序列 + 30 索引 + 31 约束（department、users、role、iam_menu、iam_role_menu、audit_log、cron_job_log、config、app_config、login_log、log_operate、user_position 等，无 sys_ 前缀） |
| 066_v010_seed_data.sql | 种子数据 80 行（app_config 14、dict_type 2、dict_data 9、iam_menu 55），全部 `ON CONFLICT (id) DO NOTHING` |

铁律（17 号文档）：迁移只承载表结构 + 数据；函数/视图/触发器/枚举/RLS 一律归 `db/src/` 或 `db/api_v1/`（apply-src 部署）。

**对应脚本**：`scripts/migrate.sh up development`、`scripts/deploy-db.sh`（第 [2/4] 步）、Makefile `make migrate`。

## Step 5：配置并启动 PostgREST

目标：把对外暴露层（多 schema）暴露为 REST API。

```bash
cd ~/OmniPG/gateway
cp ../.env.development .env          # 或手工写 gateway/.env
docker compose up -d postgrest
curl -sf http://localhost:3100/ | head -c 100   # OpenAPI JSON
```

运行时配置以 `gateway/docker-compose.yml` 为准（`gateway/postgrest/postgrest.conf` 是本地二进制运行的参考文件，未挂载进容器；2026-08-19 已与 compose 对齐）：

| 参数 | compose 实际值 | postgrest.conf（参考） |
| --- | --- | --- |
| PGRST_DB_URI | `postgres://authenticator:${AUTHENTICATOR_PASSWORD}@host.docker.internal:6432/app_db` | 同左（经 pgBouncer） |
| PGRST_DB_SCHEMAS | `api_v1_public` | `api_v1_public`（2026-08-19 对齐） |
| PGRST_DB_EXTRA_SEARCH_PATH | `api_v1_public,public` | `api_v1_public, public`（2026-08-19 对齐） |
| PGRST_DB_ANON_ROLE | `web_anon` | `web_anon` |
| PGRST_MAX_ROWS | `1000` | max-rows = 1000 |
| PGRST_JWT_SECRET | `${JWKS_JSON}` | `$(JWKS_JSON)` |
| PGRST_JWT_ROLE_CLAIM_KEY | `.pg_role` | `.pg_role`（2026-08-19 对齐） |
| PGRST_DB_PRE_REQUEST | （空） | （已退役移除，2026-08-19 对齐） |
| 端口映射 | 3100:3000 | server-port 3000 |

**暴露层（当前事实）**：运行态单 schema `api_v1_public`（`db/api_v1/` 目录含 `_shared`（模块排序前缀）/ `public`）。`db/init/02-schemas.sql` 还创建遗留空 schema `api_v1_sys`（027 改名链兼容，新代码不用）；**不存在 extensions schema**。sales/inventory 测试模块已退役（063；相关声明与占位目录已于 2026-08-19 清理，按需重建时再补）。

**JWT 算法**：开发环境 HS256（`JWKS_JSON` 对称密钥）；staging/production 指向 Logto JWKS 公钥（RS256——compose 与 .env 注释写 ES384，口径不一致，需以 Logto 实际配置核实）。

`db/init/02-schemas.sql` 已注释：原 `check_token_blacklist` 预请求函数退役，会话/吊销交 Logto。

**对应脚本**：`scripts/deploy-gateway.sh`（步骤 1-5 的一部分）。

## Step 6：配置并启动 APISIX

目标：启动 etcd + APISIX（traditional 模式，配置存 etcd），再写入 jwt-auth 元数据与路由。

```bash
cd ~/OmniPG/gateway
docker compose up -d etcd apisix
curl -sf http://localhost:7085/status   # {"status":"ok"}

# 目标路由初始化（Logto 时代新脚本）：
bash ../scripts/init-apisix-routes.sh   # 需 gateway/.env 的 APISIX_ADMIN_KEY 与 LOGTO_WEBHOOK_SIGNING_KEY
```

`gateway/apisix/config.yaml` 关键点：`deployment.role = traditional`、`config_provider = etcd`（etcd 地址 `http://app-etcd:2379`）、Admin API 9180 + 内嵌 Dashboard（`/ui`）、Status API 7085、Control API 9092、`admin_key` 来自环境变量 `APISIX_ADMIN_KEY`。`gateway/apisix/apisix.yaml`（standalone 时代留档，含 Casdoor 路由）已于 2026-08-19 删除。

**目标路由集**（`scripts/init-apisix-routes.sh`，Logto 时代，共 7 条）：

| 路由 ID | 路径 | 优先级 | 要点 |
| --- | --- | ---: | --- |
| logto_jwks | `/.well-known/jwks` | 100 | 代理 Logto JWKS（app-logto:3001），公开 |
| logto_proxy | `/logto/*` | 60 | Logto 同源代理，`^/logto/(.*)` → `/$1` |
| webhook_logto | `POST /rpc/webhook_logto` | 95 | HMAC-SHA256 验签（`logto-signature-sha-256` vs rawBody），无 jwt-auth |
| ensure_user | `POST /rpc/ensure_user` | 80 | jwt-auth（`key_claim_name: sub`），登录 JIT 建档 |
| api_v1_public | `/api/v1/sys/*` | 50 | 重写 `^/api/v1/sys/(.*)` → `/$1`，jwt-auth（URL 前缀 /api/v1/sys/* 映射 api_v1_public） |
| rpc_all | `/rpc/*` | 40 | 全部 RPC，jwt-auth |
| catch_all | `/*` | 10 | 兜底，jwt-auth |

同时写入 RS256 + Logto JWKS 的 `plugin_metadata/jwt-auth` 与全局 CORS（放行 `logto-signature-sha-256`），并幂等清理 Casdoor 时代旧路由（jwks / user_login_sso / refresh_token_rtr / casdoor_proxy / api_v1_sys）。

> ✅ **部署链已收敛（2026-08-19）**：`Makefile` dev、`deploy-all.sh`、CI deploy-gateway.yml 已统一切换到 Logto 版 `scripts/init-apisix-routes.sh`（RS256 + Logto JWKS、`/logto/*` 代理、`/rpc/webhook_logto` HMAC 验签、`/rpc/ensure_user`）；Casdoor 时代 `setup_apisix.sh` / `apisix.yaml` 已删除。

**对应脚本**：`scripts/deploy-gateway.sh`（拉起服务）+ `scripts/init-apisix-routes.sh`（路由初始化，2026-08-19 起唯一入口）。

## Step 7：接入 Logto（应用注册、webhook 配置）

```bash
cd ~/OmniPG/gateway
docker compose up -d logto
# Console: http://localhost:3002  Core: http://localhost:3001
curl -sf http://localhost:3001/oidc/.well-known/openid-configuration

# 首次使用需先通过 Console 创建管理员（OSS 单管理员），然后执行配置自动化
python3 scripts/phase2/init-logto.py --endpoint http://localhost:3001
python3 scripts/phase2/init-logto.py --verify   # 核对
```

`scripts/phase2/init-logto.py`（全部幂等）完成：

1. 创建 M2M 应用并授予 Management API 角色；
2. 创建全局角色 `role_super_admin`；
3. 创建组织模板 default（组织角色 tenant_admin / editor / viewer）与演示组织；
4. 创建/更新 webhook（订阅 User.* / Organization.* / Membership / OrganizationRole.* / Role.* / PostSignIn），事件最终经 `/rpc/webhook_logto` 由 `sync_*` 函数落库；
5. 配置 Access Token Custom Token Claims 脚本（注入 `roles` / `global_roles` / `org_roles` / `pg_role`，PostgREST 用 `.pg_role` 切换数据库角色）。

容器事实：compose 中 Logto `DB_URL` 为 `postgres://logto:${LOGTO_DB_PASSWORD:-logto_dev_pass_2026}@host.docker.internal:5433/logto`（运行态走宿主 5433），entrypoint 会先 `npm run cli db seed -- --swe` 再执行 `logto-csp-patch.js` 后启动。⚠️ `logto` 库/用户未定义在 `infra/*.yml` 中，首次部署前需在宿主 PG 预创建（见 [environment-config.md](environment-config.md)）。

**对应脚本**：`scripts/phase2/init-logto.py`（不在 deploy-all 链中）；webhook 链路见 [06-API参考/Logto Webhook](../06-API参考/logto-webhook.md)。

## Step 8：导入辅助数据（ip2region / geolite2）

```bash
# ip2region（默认 GitHub 免费版 ~52 万行；可换本地文件或远程 URL）
bash scripts/import-ip2region.sh [数据源] [PG_DSN]

# GeoLite2-City（需 MaxMind license key；ip2region 兜底，含全球经纬度/IPv6）
MAXMIND_LICENSE_KEY=xxxx bash scripts/import-geolite2.sh [PG_DSN]
```

两个脚本都幂等（TRUNCATE 后全量重灌），依赖 `ip_region_v4` / `ip_geolite2_*` 表与 `ip2region(inet)` / `geo_locate(inet)` 函数（由 apply-src 建，扩展由 Pigsty 管理）；导入后抽样验证：

```sql
SELECT ip2region('1.0.1.0'::inet);
SELECT geo_locate('8.8.8.8'::inet);
```

**对应脚本**：`scripts/import-ip2region.sh`、`scripts/import-geolite2.sh`（不在 deploy-all 链中，按需执行）。

## Step 9：验证

```bash
# 1) 全栈验证（8 项，2026-08-19 起无 Casdoor/Syncer 检查）
bash scripts/verify-stack.sh

# 2) 全新库冷启动验证（迁移/部署链变更后的硬门槛）
bash scripts/verify-fresh-db.sh

# 3) Logto 版端到端验收（PKCE code flow → 镜像表/菜单 RPC）
bash scripts/e2e-test.sh

# 4) 手工冒烟
curl -sf http://localhost:7085/status
curl -sf http://localhost:3100/ | head -c 200
curl -sf http://localhost:3001/oidc/.well-known/openid-configuration | head -c 200
curl -sf http://localhost:8082/ | head -c 100
curl -sf http://localhost:9180/apisix/admin/routes -H "X-API-KEY: $APISIX_ADMIN_KEY"
```

验收重点：PostgREST OpenAPI 完整（>2000 字符）、APISIX 路由 8 条、Logto OIDC discovery 可访问、`/api/v1/sys/*` 无 token 401 / 带 Logto token 200、镜像表只读。

## 与脚本的对应关系

| Step | 内容 | 对应脚本 |
| --- | --- | --- |
| 1 | Pigsty 安装与配置 | `scripts/deploy-infra.sh`（[1/5]-[4/5]） |
| 2 | PG 集群 / pgbouncer / redis 启动与验证 | `scripts/deploy-infra.sh`（[5/5]） |
| 3 | db/init 初始化（扩展/schema/types） | `scripts/apply-src.sh --bootstrap`（deploy-db [1/4]） |
| 4 | dbmate 迁移 | `scripts/migrate.sh up` / `scripts/deploy-db.sh`（[2/4]） |
| 5 | PostgREST | `scripts/deploy-gateway.sh` |
| 6 | APISIX | `scripts/deploy-gateway.sh` + `scripts/init-apisix-routes.sh` |
| 7 | Logto | `scripts/phase2/init-logto.py`（手工） |
| 8 | 辅助数据 | `scripts/import-ip2region.sh` / `import-geolite2.sh`（手工） |
| 9 | 验证 | `scripts/verify-stack.sh` / `verify-fresh-db.sh` / `e2e-test.sh` |

## 相关页面

- [部署指南总览](deployment-overview.md)
- [环境变量配置](environment-config.md)
- [脚本部署（一键方案）](script-deploy.md)
- [升级与回滚](upgrade-rollback.md)
- [05-开发指南/数据库迁移](../05-开发指南/migrations.md)
- [06-API参考/PostgREST](../06-API参考/postgrest.md)
- [06-API参考/网关路由](../06-API参考/gateway-routing.md)
- [07-测试/验证脚本](../07-测试/verify-scripts.md)

> 参考：本页步骤与 `scripts/` 目录、`infra/`、`gateway/docker-compose.yml`、`db/init/`、`db/migrations/public/` 当前代码一一对应；历史文档（17/19/20 号）中的 standalone 模式与 Casdoor 内容已过时。