# 环境变量配置

OmniPG 的配置分两层：根目录 `.env.*`（部署/数据库/网关公共变量）与 `gateway/.env`（docker-compose 实际消费的网关变量）。`gateway/.env` 由 `scripts/deploy-gateway.sh` 从根目录 `.env.<environment>` 复制生成。

## 配置文件清单

| 文件 | 是否入库 | 说明 |
| --- | --- | --- |
| `.env.example` | ✅ | 变量模板（开发默认值） |
| `.env.development` | ✅ | 开发环境（含实际开发默认值 + APP_DEBUG=true） |
| `.env.staging` | ✅ | 预发布模板，敏感值用 `${VAR}` 占位符 |
| `.env.production` | ✅ | 生产模板，敏感值用 `${VAR}` 占位符 |
| `gateway/.env.example` | ✅ | 网关变量模板 |
| `gateway/.env` | ❌（.gitignore） | 网关实际配置，由 deploy-gateway.sh 复制生成 |

> 根目录 `.env`（不含后缀）与 `gateway/.env` 均被 `.gitignore` 忽略，不入版本库；`.env.*` 模板入库以便新环境快速起步。

## 根目录 .env.* 说明

三个环境的文件结构相同，差异在 `APP_ENV`、`APP_DEBUG` 与敏感值写法：

| 变量 | .env.example | development | staging | production | 说明 |
| --- | --- | --- | --- | --- | --- |
| APP_ENV | development | development | staging | production | 运行环境标识 |
| APP_NAME | zero-backend-rbac | zero-backend-rbac | zero-backend-rbac | zero-backend-rbac | 应用名 |
| APP_DEBUG | — | true | false | false | 调试开关 |
| PG_PORT | 5432 | 5432 | 5432 | 5432 | PostgreSQL 直连端口 |
| DB_USER | app_owner | app_owner | app_owner | app_owner | 应用数据库用户 |
| DB_PASSWORD | dev_password_change_me | dev_password_change_me | `${DB_PASSWORD}` | `${DB_PASSWORD}` | app_owner 密码 |
| DB_NAME | app_db | app_db | app_db | app_db | 主数据库 |
| PG_BOUNCER_PORT | 6432 | 6432 | 6432 | 6432 | pgBouncer 端口 |
| AUTHENTICATOR_PASSWORD | authenticator_dev_pass | authenticator_dev_pass | `${AUTHENTICATOR_PASSWORD}` | `${AUTHENTICATOR_PASSWORD}` | PostgREST 认证角色密码 |
| APISIX_HTTP_PORT | 9080 | 9080 | 9080 | 9080 | 网关数据面 HTTP |
| APISIX_HTTPS_PORT | 9443 | 9443 | 9443 | 9443 | 网关数据面 HTTPS |
| APISIX_ADMIN_PORT | 9180 | 9180 | 9180 | 9180 | Admin API |
| APISIX_ADMIN_KEY | a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6 | a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6 | `${APISIX_ADMIN_KEY}` | `${APISIX_ADMIN_KEY}` | Admin API Key |
| PGRST_PORT | 3001 | 3001 | 3001 | 3001 | ⚠️ 见下方「遗留不一致」 |
| JWKS_JSON | HS256 开发密钥 | HS256 开发密钥 | `${JWKS_JSON}` | `${JWKS_JSON}` | JWT 验签 JWKS（开发=HS256 对称密钥；staging/production=Logto JWKS RS256 公钥；compose/.env 注释写 ES384，需以 Logto 实际配置核实） |
| ETCD_PORT | 2379 | 2379 | 2379 | 2379 | 宿主 etcd |
| SWAGGER_PORT | 8082 | 8082 | 8082 | 8082 | Swagger UI |
| VITE_APP_PORT | 5173 | 5173 | 5173 | 5173 | 前端 dev server |
| DEFAULT_TENANT_ID | tenant_default | tenant_default | tenant_default | tenant_default | RLS 租户配置 |

> ⚠️ 占位符语义：staging/production 文件中的 `${DB_PASSWORD}` 等是「待注入标记」，脚本的 `cp` / `export` 不会自动展开。CI（`.github/workflows/deploy-*.yml`）通过 GitHub Secrets 注入，或部署前人工预展开为真实值。

## gateway/.env 说明

`gateway/docker-compose.yml` 通过 `${VAR}` 引用 `gateway/.env`；`scripts/deploy-gateway.sh` 第 1 步执行 `cp .env.$ENV gateway/.env`。

| 变量 | gateway/.env.example 默认 | 用途 |
| --- | --- | --- |
| DB_HOST | host.docker.internal | 宿主接入（WSL2/Windows 网络） |
| DB_PORT | 5432 | PostgreSQL 直连端口 |
| DB_USER | app_owner | 数据库用户 |
| DB_PASSWORD | dev_password_change_me | app_owner 密码 |
| PG_BOUNCER_PORT | 6432 | pgBouncer 端口 |
| AUTHENTICATOR_PASSWORD | authenticator_dev_pass | PostgREST 认证角色密码 |
| APISIX_HTTP_PORT / APISIX_HTTPS_PORT / APISIX_ADMIN_PORT | 9080 / 9443 / 9180 | APISIX 端口 |
| APISIX_ADMIN_KEY | edd1c9f034335f136f87ad84b625c8f1 | Admin API Key（⚠️ 与根目录 development 默认 a1b2… 不一致，部署以 gateway/.env 实际值为准） |
| PGRST_PORT | 3001 | ⚠️ 见「遗留不一致」 |
| JWKS_JSON | HS256 开发密钥 | PostgREST `PGRST_JWT_SECRET`（开发环境） |
| SWAGGER_PORT | 8082 | Swagger UI 宿主端口 |

**缺失项（TODO）**：compose 中 Logto 使用 `LOGTO_DB_PASSWORD`（默认 `logto_dev_pass_2026`），`scripts/init-apisix-routes.sh` 要求 `LOGTO_WEBHOOK_SIGNING_KEY`（webhook 验签，fail-closed），前端 CSP 需要 `LOGTO_EXTRA_FRAME_ANCESTOR`（compose 默认 `http://localhost:3006 http://localhost:3007`）——这些变量未出现在 `gateway/.env.example` 与根目录 `.env.*` 中，使用 Logto webhook / 内嵌登录前需手工补充。

## 数据库连接串

| 用途 | 连接串 | 出处 |
| --- | --- | --- |
| app_owner 直连（迁移/脚本） | `postgres://app_owner:<DB_PASSWORD>@127.0.0.1:5432/app_db?sslmode=disable` | `scripts/deploy-db.sh`、`scripts/migrate.sh`、`db/dbmate.toml` |
| PostgREST（经 pgBouncer） | `postgres://authenticator:<AUTHENTICATOR_PASSWORD>@host.docker.internal:6432/app_db?sslmode=disable` | `gateway/docker-compose.yml`（postgrest 服务） |
| Logto 库 | `postgres://logto:<LOGTO_DB_PASSWORD>@host.docker.internal:5433/logto?sslmode=disable` | `gateway/docker-compose.yml`（logto 服务） |
| Makefile 迁移 | `postgres://app_owner:<gateway/.env DB_PASSWORD>@127.0.0.1:5432/app_db?sslmode=disable` | `Makefile`（从 `gateway/.env` 读取 DB_PASSWORD） |

**端口事实**：PostgreSQL 5432、pgBouncer 6432。compose 中 PostgREST 容器端口映射为 `3100:3000`（宿主机 3100，e2e 与 deploy-gateway 健康检查均用 3100）。

> ⚠️ 遗留不一致（TODO）：
> 1. compose 中 Logto `DB_URL` 走宿主 **5433**（运行态事实；compose 注释写 6432 属注释过时）。`infra/*.yml` 未定义 `logto` 库/用户，首次使用前需在宿主 PG 预创建（TODO）；
> 2. 根目录与 gateway 的 `PGRST_PORT=3001`、Swagger `API_URL`（`http://localhost:${PGRST_PORT:-3001}/`）仍引用 3001，但 compose 实际映射 3100；`verify-stack.sh` 的 PostgREST 检查也写 3001。以 3100 为运行时事实。

## 敏感项管理

| 敏感项 | 存放位置 | 环境要求 |
| --- | --- | --- |
| DB_PASSWORD（app_owner） | 根 .env.* + `infra/pigsty.yml` pg_users + `infra/userlist.txt` + gateway/.env | 三处必须一致 |
| AUTHENTICATOR_PASSWORD | 根 .env.* + pigsty.yml + userlist.txt + gateway/.env | 同上 |
| APISIX_ADMIN_KEY | 根 .env.* + gateway/.env + CI Secret | 非本地环境必须更换默认值（`openssl rand -hex 16`） |
| JWKS_JSON | 根 .env.* + gateway/.env | 生产用 Logto JWKS（RS256 公钥；注释中的 ES384 需以 Logto 实际配置核实） |
| LOGTO_DB_PASSWORD | gateway/.env（缺失，TODO） | compose 默认值仅限开发 |
| LOGTO_WEBHOOK_SIGNING_KEY | gateway/.env（缺失，TODO） | webhook 验签（HMAC-SHA256），init-apisix-routes.sh 缺它即拒绝部署 |
| CI Secrets | SSH_PRIVATE_KEY / DB_SERVER_HOST / GATEWAY_SERVER_HOST / SERVER_USER / DBMATE_DATABASE_URL / DB_URI / APISIX_ADMIN_KEY | GitHub Actions 注入 |

管理原则（沿用 ci-cd v2.1 三层模型）：本地 `.env` → CI GitHub Secrets → 服务器环境变量。开发默认密码仅限本地；staging/production 一律注入。改密码时同步修改 pigsty.yml、pgbouncer userlist.txt、根 .env.*、gateway/.env，否则认证链断裂（scram-sha-256 下 pgBouncer 与 PG 必须一致）。

## 环境切换注意事项

1. **占位符不会自动展开**：`deploy-gateway.sh` 用 `cp` 复制 `.env.staging/.env.production`，文件内的 `${DB_PASSWORD}` 会原样进入 `gateway/.env`——必须由 CI 注入（先展开再拷贝）或人工预展开。
2. **Admin Key 默认值不一致**：根目录 `.env.development` 为 `a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6`，`gateway/.env.example` 与 compose 默认值为 `edd1c9f034335f136f87ad84b625c8f1`；deploy-gateway 复制后以 gateway/.env 为准，但 `verify-stack.sh` 的兜底默认是后者。建议统一。
3. **PostgREST 端口**：compose 硬编码 `3100:3000`，`.env` 的 `PGRST_PORT` 未参与映射；Swagger/verify-stack 的 3001 引用属遗留。
4. **Logto CSP**：compose 将 `LOGTO_EXTRA_FRAME_ANCESTOR` 注入 `logto-csp-patch.js`（容器启动时对编译产物打补丁）；改前端端口后需同步该变量并 `docker compose up -d --force-recreate logto`（补丁幂等，不会自动更新旧值）。
5. **切换环境后必须重建网关**：`deploy-gateway.sh` 会 `docker compose down && up -d` 使新环境变量生效；APISIX 路由需重跑 `init-apisix-routes.sh`。
6. **logto 库准备**：当前 infra 配置未创建 `logto` 库/用户，首次使用 Logto 前需在宿主 PG 手工创建（`CREATE DATABASE logto OWNER logto;`），并核对 compose `DB_URL` 端口。

## 相关页面

- [部署指南总览](deployment-overview.md)
- [手动部署（逐步方案）](manual-deploy.md)
- [脚本部署（一键方案）](script-deploy.md)
- [04-架构/认证设计](../04-架构/auth-design.md)
- [06-API参考/PostgREST](../06-API参考/postgrest.md)
- [06-API参考/网关路由](../06-API参考/gateway-routing.md)
- [08-运维/安全](../08-运维/security.md)

> 参考：本页以根目录 `.env.*`、`gateway/.env.example`、`gateway/docker-compose.yml`、`Makefile` 与 `scripts/deploy-*.sh` 当前代码为准；历史文档（配置说明文档，已归档）中的 Casdoor 变量（CASDOOR_*）已过时，不再使用。