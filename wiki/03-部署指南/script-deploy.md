# 脚本部署（一键方案）

一键部署由 `scripts/deploy-all.sh` 编排五个阶段，每阶段对应一个子脚本。全部脚本遵循 `set -euo pipefail`：任一步失败立即退出。

## 一键部署命令

```bash
# 一键全量部署（默认 development）
bash scripts/deploy-all.sh development

# 或分步（等价于 deploy-all 的前四步）
bash scripts/deploy-infra.sh all development   # 1 基础设施
bash scripts/deploy-db.sh development          # 2 数据库
bash scripts/deploy-gateway.sh development     # 3 网关
bash scripts/setup_apisix.sh                   # 4 APISIX 初始化
bash scripts/e2e-test.sh                       # 5 端到端验收
```

## 总入口 scripts/deploy-all.sh 执行顺序

| 阶段 | 命令 | 失败提示 |
| --- | --- | --- |
| [1/5] 基础设施 | `bash scripts/deploy-infra.sh all $ENV` | 检查 Pigsty 安装/部署日志 |
| [2/5] 数据库 | `bash scripts/deploy-db.sh $ENV` | 检查 bootstrap/迁移/apply-src 日志 |
| [3/5] 网关 | `bash scripts/deploy-gateway.sh $ENV` | 检查 docker compose 与健康检查输出 |
| [4/5] APISIX 初始化 | `cd gateway && bash ../scripts/setup_apisix.sh`（部署链现状，旧脚本；目标为 init-apisix-routes.sh，见下方「网关路由初始化（新旧并存）」） | APISIX Admin API 可达性、`APISIX_ADMIN_KEY` 与 config.yaml 一致、`docker logs app-apisix` |
| [5/5] E2E 测试 | `bash scripts/e2e-test.sh` | 服务状态与 Logto 登录链路 |

> 注：第 4 步前会 `export $(grep -v '^#' .env | xargs)` 加载 `gateway/.env`（`APISIX_ADMIN_KEY`、`JWKS_JSON` 等）。

## deploy-infra.sh：Pigsty 基础设施

```bash
bash scripts/deploy-infra.sh [all|db|gateway] [environment]
```

| 步骤 | 动作 | 说明 |
| --- | --- | --- |
| [1/5] | 检测/安装 Pigsty | `$HOME/pigsty` 不存在则 `curl https://pigsty.cc/get | bash -s v4.4.0` |
| [2/5] | 选择配置文件 | all→`infra/pigsty.yml`；db→`infra/pigsty.db.yml`；gateway→`infra/pigsty.gateway.yml` |
| [3/5] | 复制配置 | pigsty.yml 复制到 `~/pigsty/`；db/all 模式额外复制 `pgbouncer.ini`、`userlist.txt`（/etc/pgbouncer，chmod 640）、`redis.conf`（/etc/redis）；pg_hba 由 pigsty.yml 的 `pg_hba_rules` 生成 |
| [4/5] | 执行部署 | `~/pigsty/deploy.yml`，随后 `./etcd.yml` |
| [5/5] | 验证 | PG 5432 / pgBouncer 6432（app_owner 登录）、`redis-cli ping`、etcd `https://127.0.0.1:2379/health` |

失败计数 >0 则 exit 1。幂等性：Pigsty 已安装时跳过下载；Pigsty playbook 自身可重复执行。

## deploy-db.sh：数据库 schema 与迁移（dbmate）

```bash
bash scripts/deploy-db.sh [environment] [db_port]   # 默认端口 5432
```

连接凭据全部来自 `.env.<environment>`（`DB_USER`/`DB_PASSWORD`/`DB_NAME`/`DB_HOST`），不硬编码密码：

| 步骤 | 动作 | 说明 |
| --- | --- | --- |
| [1/4] | bootstrap | `apply-src.sh $DB_URI --bootstrap`：init（扩展/schema/角色）+ `src/public/types`（枚举）前置——迁移 059/060 引用 src 枚举，必须先建（依赖倒置修复） |
| [2/4] | dbmate up | `export DBMATE_DATABASE_URL=$DB_URI; dbmate up`（在 `db/` 下读取 dbmate.toml，migrations_dir=`./migrations/public`） |
| [3/4] | apply-src 全量 | 幂等源码重放（见下） |
| [4/4] | 验证 | `dbmate status` |

`scripts/apply-src.sh` 全量重放顺序与规则：

```
§6.3 迁移目录代码对象扫描（CREATE FUNCTION/VIEW/TRIGGER/TYPE/POLICY 命中即失败）
→ src/public/types（枚举）→ src/public 其余（functions/triggers/views/privileges）
→ api_v1/_shared + api_v1/public 的 rpc → views → 其余（privileges/zz_grant_all.sql 排最后）
→ db/init → db/migrations/public 重放（幂等性验证）
每遍失败文件进重试队列，最多 3 遍收敛；3 遍仍失败 = 真错误，终止。
```

## deploy-gateway.sh：PostgREST / APISIX / Logto

```bash
bash scripts/deploy-gateway.sh [environment]
```

| 步骤 | 动作 | 说明 |
| --- | --- | --- |
| [1/5] | 复制环境配置 | `cp .env.$ENV gateway/.env`（⚠️ 占位符不展开，见 [environment-config.md](environment-config.md)） |
| [2/5] | 拉取/构建镜像 | `docker compose pull --ignore-pull-failures` + `docker compose build syncer` |
| [3/5] | 重启服务 | `docker compose down && docker compose up -d` |
| [4/5] | 等待 | sleep 15 + 加载 gateway/.env |
| [5/5] | 健康检查 | APISIX `http://localhost:7085/status`、PostgREST `http://localhost:3100/`、Logto `http://localhost:3001/oidc/.well-known/openid-configuration`、Swagger `http://localhost:8082/` |

> ⚠️ 遗留（TODO）：`docker compose build syncer` 引用 compose 中已不存在的 `syncer` 服务（当前服务仅 etcd/apisix/postgrest/swagger-ui/logto），该步会报错；健康检查里 `policy-syncer` 容器检查同样失效。运行前需移除该行（或忽略构建失败）。

## 网关路由初始化（新旧并存）

**目标架构事实（Logto 版路由集）**：由 `scripts/init-apisix-routes.sh` 定义，共 7 条——

| 路由 ID | 路径 | 优先级 | 要点 |
| --- | --- | ---: | --- |
| `logto_jwks` | `/.well-known/jwks` | 100 | 代理 Logto JWKS（app-logto:3001），公开 |
| `logto_proxy` | `/logto/*` | 60 | Logto 同源代理，`^/logto/(.*)` → `/$1` |
| `webhook_logto` | `POST /rpc/webhook_logto` | 95 | HMAC-SHA256 验签（`logto-signature-sha-256` vs rawBody），无 jwt-auth |
| `ensure_user` | `POST /rpc/ensure_user` | 80 | JWT auth（`key_claim_name: sub`），登录 JIT 建档 |
| `api_v1_public` | `/api/v1/sys/*` | 50 | 重写 `^/api/v1/sys/(.*)` → `/$1`，JWT auth |
| `rpc_all` | `/rpc/*` | 40 | 全部 RPC，JWT auth |
| `catch_all` | `/*` | 10 | 兜底，JWT auth |

同时写入 RS256 + Logto JWKS 的 `plugin_metadata/jwt-auth` 与全局 CORS（global_rules/1）。执行：`bash scripts/init-apisix-routes.sh`（需 `gateway/.env` 的 `APISIX_ADMIN_KEY` 与 `LOGTO_WEBHOOK_SIGNING_KEY`，后者缺失 fail-closed `exit 1`）。完整路由表与优先级说明见 [网关路由](../06-API参考/gateway-routing.md)。

> ⚠️ **已知不一致 / 待收敛**：`setup_apisix.sh` 与 `gateway/apisix/apisix.yaml` 仍是 Casdoor 时代残留（standalone 留档，不再加载）；`init-apisix-routes.sh` 目前**未接入** Makefile / deploy-all / deploy-gateway / deploy-gateway.yml（仅 e2e-test.sh 注释提及），属“预期新脚本、尚未接线”——部署链仍调用下方旧脚本。详见 [网关路由](../06-API参考/gateway-routing.md) 的「已知不一致 / 待收敛（新旧并存）」与 [测试体系总览](../07-测试/testing-overview.md)。

### setup_apisix.sh（Casdoor 时代旧残留，部署链仍在调用）

```bash
bash scripts/setup_apisix.sh   # 依赖 gateway/.env 的 APISIX_ADMIN_KEY 与 JWKS_JSON，缺任一即退出
```

| 步骤 | 动作 |
| --- | --- |
| [1/4] | 等待 APISIX Status API（http://localhost:7085/status 返回 ok，30 次 × 2s） |
| [2/4] | PUT `plugin_metadata/jwt-auth`：HS256 + `JWKS_JSON` 的 `k` 字段（base64_secret） |
| [3/4] | 创建 8 条业务路由（jwks / user_login_sso / refresh_token_rtr / api_v1_public / api_v1_sales / api_v1_inventory / rpc_all / catch_all，均为 Admin API PUT，幂等） |
| [4/4] | PUT `global_rules/1`：全局 CORS |

完成后输出 Dashboard（http://localhost:9180/ui）、Admin API（http://localhost:9180/apisix/admin）、Status API（http://localhost:7085/status）与路由数量。

> ⚠️ 遗留（TODO）：本脚本 jwks 路由的上游仍是 `app-casdoor:8000`，且 `user_login_sso`/`refresh_token_rtr` 为 Casdoor 时代字段名；Logto 架构应改用 `scripts/init-apisix-routes.sh`（RS256 + Logto JWKS、`/logto/*` 代理、`/rpc/webhook_logto` HMAC 验签、`/rpc/ensure_user`）。两脚本并存，deploy-all 目前调用的是 setup_apisix.sh。

## 初始化数据

| 数据 | 来源 | 说明 |
| --- | --- | --- |
| 种子数据 | `db/migrations/public/066_v010_seed_data.sql` | app_config(14)、dict_type(2)、dict_data(9)、iam_menu(55)，`ON CONFLICT (id) DO NOTHING` 幂等；iam_menu 按 parent_id 拓扑序 |
| 幂等源码 | `db/src/` + `db/api_v1/` | apply-src 全量重放（函数/视图/触发器/RLS/枚举/授权） |
| ip2region | `bash scripts/import-ip2region.sh [数据源] [PG_DSN]` | TRUNCATE 后全量重灌 `ip_region_v4`（默认 GitHub 免费版 ~52 万行） |
| GeoLite2 | `MAXMIND_LICENSE_KEY=xxx bash scripts/import-geolite2.sh [PG_DSN]` | 下载 GeoLite2-City-CSV → COPY staging → `import_geolite2_city()` 转换（ip2region 兜底） |

种子数据在 deploy-db 的 dbmate 阶段自动写入；ip2region/geolite2 不在 deploy-all 链中，按需执行。

## 部署后验证：verify-stack.sh / verify-fresh-db.sh / e2e-test.sh

### verify-stack.sh（全栈 10 项）

```bash
bash scripts/verify-stack.sh
```

覆盖：依赖预检（docker/curl/psql/python3）、容器→宿主 pgbouncer 网络链路、宿主 pgbouncer（authenticator 登录）、PostgREST OpenAPI、APISIX Status、Dashboard、路由清单（预期 8 条）、登录链路（user_login_sso）、Syncer、无 docker PG 残留。

> ⚠️ 遗留：第 4 项 Casdoor（:8000）与第 9 项 Syncer（policy-syncer 容器）在当前 Logto 架构下**必然失败**——以 [e2e-test.sh](../07-测试/e2e-tests.md) 与手工冒烟为准，脚本待更新。

### verify-fresh-db.sh（全新库冷启动）

```bash
bash scripts/verify-fresh-db.sh [dbname]   # 默认 app_db_verify，参照库 app_db
```

8 步：DROP+CREATE scratch 库（WITH FORCE）→ superuser 建扩展（01-extensions）→ 02-schemas + src types → `dbmate up`（--no-dump-schema）→ apply-src 全量 → apply-src 二遍（幂等验证）→ 与参照库结构比对（表/列/约束/种子/函数/视图/触发器/策略/索引，排除 pg_cron）→ pgTAP。

生产无 sudo 时用 `PG_SUPER_CMD` / `PG_SUPER_POSTGRES_CMD` 覆盖超级用户执行方式。

### e2e-test.sh（Logto 版端到端）

```bash
bash scripts/e2e-test.sh
```

走 Logto OIDC authorization code + PKCE 全流程（`logto_login()` 模拟浏览器交互），随后验证：环境就绪（PostgREST 3100 / APISIX 路由 / Logto discovery / Swagger / Logto JWKS）、认证流程（登录拿 token、错误密码拒绝、无 token 401、带 token 访问镜像表、get_user_menu）、权限与镜像表只读（写操作被拒）等。可配置 `BASE_URL` / `PGRST_URL` / `LOGTO_URL` / `CLIENT_ID` / `ORG_ID` / `E2E_USER` / `E2E_PASSWORD` 等环境变量。

## 幂等性与重跑注意事项

| 脚本/阶段 | 幂等性设计 | 重跑注意事项 |
| --- | --- | --- |
| deploy-infra.sh | Pigsty 已安装检测；playbook 可重跑 | 配置变更后重跑会覆盖 `~/pigsty/pigsty.yml` 与 /etc 下配置文件 |
| deploy-db.sh | bootstrap 全 IF NOT EXISTS；dbmate 跳过已应用；apply-src 全量重放两遍不炸（DDL 均幂等）；§6.3 扫描零容忍 | 迁移若含非幂等 DDL 会在 apply-src 重放时暴露；先 `dbmate status` 确认账本 |
| deploy-gateway.sh | `down`+`up` 重建容器，环境变量即配置 | `docker compose build syncer` 遗留会失败；healthcheck 中 Syncer 项失效 |
| setup_apisix.sh | Admin API PUT 幂等（同 id 覆盖） | 与 Logto 版 init-apisix-routes.sh 混用会导致 jwt-auth 元数据/路由互相覆盖，二选一 |
| import-*.sh | TRUNCATE 后全量重灌 | 会清空 ip_region_v4 / ip_geolite2_* 再导入，非增量 |
| verify-fresh-db.sh | scratch 库 DROP+重建 | 参照库 app_db 需与目标版本一致，否则结构比对差异属预期 |

整体结论：deploy-all 可以在同环境重复执行（数据库阶段幂等、网关阶段重建容器），但 Logto 初始化（phase2/init-logto.py）与辅助数据导入不在自动链内，需按需手工补跑。

## CI/CD 部署入口（简述）

`.github/workflows/deploy-all.yml`（staging/production 手工触发）在服务器上执行 `git pull` + `bash scripts/deploy-all.sh <env>` + e2e；`deploy-db.yml`、`deploy-gateway.yml`、`deploy-infra.yml` 提供分步部署。详见 [部署指南总览](deployment-overview.md) 的 CI/CD 小节。

## 相关页面

- [部署指南总览](deployment-overview.md)
- [环境变量配置](environment-config.md)
- [手动部署（逐步方案）](manual-deploy.md)
- [升级与回滚](upgrade-rollback.md)
- [07-测试/验证脚本](../07-测试/verify-scripts.md)
- [07-测试/E2E 测试](../07-测试/e2e-tests.md)
- [06-API参考/网关路由](../06-API参考/gateway-routing.md)

> 参考：本页以 `scripts/` 各脚本、`gateway/docker-compose.yml`、`gateway/apisix/config.yaml` 当前代码为准；ci-cd v2.1 文档中的 syncer/standalone 描述已被 21/22 号文档与传统模式演进取代。
