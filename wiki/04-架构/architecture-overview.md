# 架构概览

> 本文描述 OmniPG 的系统拓扑、请求主链路、分层设计与模块划分总览。所有事实均与当前代码（db/、gateway/、scripts/、infra/）核对，历史方案中的 Casdoor / casbin 网关引擎 / Go PolicySyncer 等组件已退役，不再出现。

## 系统拓扑

```text
┌──────────────┐   OIDC 重定向 / token 交换（认证旁路）   ┌───────────────────────┐
│ 客户端/前端    │ ───────────────────────────────────────▶ │  Logto（自部署 OSS）    │
│ (Vue3 + SDK) │ ◀─────────────────────────────────────── │  认证/组织（租户）/角色目录 │
└──────┬───────┘                                         │  签发 JWT（roles/…）    │
       │ Bearer JWT（组织 token）                          └───────────┬───────────┘
       ▼                                                             │ webhook 事件
┌──────────────────────────────────────────────────────────┐         │ (User.*/Org.*/…)
│ APISIX 网关（traditional 模式，etcd 存路由配置）            │         │
│  · jwt-auth：Logto JWKS 验签（开发 HS256 / 生产 RS256）   │         │
│  · 路由：/api/v1/sys/* 去前缀→schema、/logto/*、/rpc/*  │         │
│  · 全局 CORS；端口 9080(HTTP)/9443(HTTPS)/9180(Admin)/7085 │         │
└──────────────┬───────────────────────────────────────────┘         │
               ▼                                                      ▼
┌──────────────────────────────────────────────────────────┐  ┌───────────────────────┐
│ PostgREST（容器 3000 / 宿主 3100）                        │  │ /rpc/webhook_logto     │
│  · 暴露层 schema：api_v1_public 等（conf 多 schema 声明） │◀─┘（webhook 接收 RPC）     │
│  · 验签：PGRST_JWT_SECRET = JWKS_JSON（Logto 公钥 JSON）   │
│  · 按 JWT claim pg_role 切换 PG 角色（authenticator 登录）  │
│  · 注入 request.jwt.claims（sub/roles/organization_id/…）  │
└──────────────┬───────────────────────────────────────────┘
               ▼ SQL（经 pgbouncer 6432）
┌──────────────────────────────────────────────────────────┐
│ PostgreSQL（Pigsty 统一管理：集群 + pgbouncer + redis）    │
│  · public：业务表/RPC/视图/触发器/RLS（镜像表 + 自主表）    │
│  · api_v1_*：对外 API 视图与 RPC（只放投影，不放物理表）   │
│  · net / cron：pg_net / pg_cron 扩展宿主 schema           │
└──────────────────────────────────────────────────────────┘
```

组件清单（以 gateway/docker-compose.yml 为准）：

| 组件 | 镜像/版本 | 容器端口 | 宿主端口 | 职责 |
| --- | --- | --- | --- | --- |
| etcd | bitnamilegacy/etcd:3.5.11 | 2379（容器内，不映射宿主） | — | APISIX 配置中心（traditional 模式路由/插件元数据存储） |
| apisix | apache/apisix:3.17.0-debian | 9080/9443/9180/7085 | 9080/9443/9180/7085 | 网关：JWT 验签、路由、CORS；9180 为 Admin API + Dashboard，7085 为 Status API |
| postgrest | postgrest/postgrest:v14.15 | 3000 | 3100 | REST 引擎：api_v1_public schema 自动映射 + /rpc/* 函数端点 |
| swagger-ui | swaggerapi/swagger-ui:v5.2.0 | 8080 | 8082 | OpenAPI 文档（浏览器端直连拉取 PostgREST spec） |
| logto | ghcr.io/logto-io/logto:latest（OSS v1.42） | 3001/3002 | 3001/3002 | 认证/授权 IdP：OIDC、组织（租户）、角色目录、签发 JWT、webhook |

> 注：gateway/docker-compose.yml 头部注释仍保留 "Casdoor/Syncer" 字样，属历史遗留；实际 compose 服务只有上表 5 个。PostgreSQL / pgbouncer / Redis 不在 compose 内，由宿主 Pigsty 管理（PostgREST 经 host.docker.internal:6432 连接 pgbouncer）。

端口速查：APISIX 9080(HTTP)/9443(HTTPS)/9180(Admin)/7085(Status) · PostgREST 3100（容器内 3000）· Logto 3001(Core)/3002(Console) · Swagger 8082 · PostgreSQL 5432 · pgBouncer 6432 · Redis 6379 · Logto 业务库走宿主 5433（logto 容器 DB_URL 指向 host.docker.internal:5433/logto）。

版本口径（与 tech-stack 一致）：Pigsty v4.4.0 / PostgreSQL 18 / PostgREST v14.15 / APISIX 3.17.0 / etcd 3.5.11 / Logto OSS v1.42 / Swagger v5.2.0 / dbmate / pgTAP / GitHub Actions。

## 请求主链路

1. **认证（旁路，不经过业务 API）**：前端 Logto SDK 重定向到 Logto 登录页 → 用户完成认证 → authorization code → SDK 换 access token + refresh token → 用 refresh token flow 换取组织 token（携带 resource + organization_id；组织 token 不能从 code flow 直接获取）。
2. **JWT 签发**：Logto 在签发时执行 Custom Token Claims 脚本（scripts/phase2/init-logto.py 的 CLAIMS_SCRIPT），从 context 零 fetch 提取角色，注入 roles（全局角色 ∪ 当前组织组织角色）、global_roles、org_roles 与 pg_role（PostgREST 角色映射）。
3. **网关鉴权**：客户端携带 Authorization: Bearer <JWT> 请求 APISIX → jwt-auth 插件用 Logto JWKS 验签 → 命中路由（如 /api/v1/sys/* 经 proxy-rewrite 去掉前缀，映射到 api_v1_public 等 schema 对象）→ 全局 CORS 处理 → 转发 PostgREST。
4. **API 层**：PostgREST 再次验签（PGRST_JWT_SECRET），按 JWT pg_role claim 切换数据库角色，把 JWT claims 注入 request.jwt.claims，解析 /rpc/<函数> 或表/视图查询。
5. **数据访问**：SQL 进入 PostgreSQL：RLS 策略按 request.jwt.claims 强制行过滤（租户/本人/角色例外）；RPC 内部再用 has_permission / require_permission / require_super_admin 做操作级判定。
6. **webhook 旁路**：Logto 事件（用户/组织/成员/角色/登录）异步 POST 到 http://host.docker.internal:9080/rpc/webhook_logto（经网关进入 PostgREST），由 api_v1_public.webhook_logto 分发到 sync_* 函数写镜像表。

路由表（**目标架构：scripts/init-apisix-routes.sh 的 Logto 时代路由集**，通过 Admin API 写入 etcd；gateway/apisix/apisix.yaml 为 Casdoor 时代 standalone 留档、已不再加载）：

| 路由 id | URI | 上游 | 插件 | 优先级 | 说明 |
| --- | --- | --- | --- | --- | --- |
| logto_jwks | /.well-known/jwks | app-logto:3001 | —（公开） | 100 | Logto JWKS 公钥代理（前端 SDK / OIDC 客户端拉取） |
| logto_proxy | /logto/* | app-logto:3001 | proxy-rewrite（公开） | 60 | Logto 同源代理 ^/logto/(.*) → /$1（CORS 规避） |
| webhook_logto | /rpc/webhook_logto（POST） | app-postgrest:3000 | serverless-pre-function（无 jwt-auth） | 95 | webhook 接收入口；HMAC-SHA256(rawBody) vs logto-signature-sha-256 验签，缺 LOGTO_WEBHOOK_SIGNING_KEY 时 fail-closed（N15） |
| ensure_user | /rpc/ensure_user（POST） | app-postgrest:3000 | jwt-auth（key_claim_name=sub） | 80 | 登录 JIT 建档 |
| api_v1_public | /api/v1/sys/* | app-postgrest:3000 | proxy-rewrite + jwt-auth | 50 | 去掉前缀 ^/api/v1/sys/(.*) → /$1，映射 api_v1_public 等 schema 对象 |
| rpc_all | /rpc/* | app-postgrest:3000 | jwt-auth | 40 | 其余 RPC（/rpc/webhook_logto 优先级更高先命中） |
| catch_all | /* | app-postgrest:3000 | jwt-auth | 10 | 兜底（未匹配请求交给 PostgREST 返回 404） |

> api_v1_sales / api_v1_inventory 路由已随 063 退役移除（init-apisix-routes.sh 注释：测试模块退役，后续按需重建）；`/api/v1/sys/*` 是历史 URL 前缀（sys 模块收敛到 api_v1_public 后保留），表名本身无 sys_ 前缀。

### 已知不一致 / 待收敛（路由脚本新旧并存，务必区分）

| 对象 | 现状 | 判定 |
| --- | --- | --- |
| gateway/apisix/config.yaml | traditional 模式（etcd + Admin API + 内置 Dashboard），注释明确"不再读取 apisix.yaml" | ✅ 现行配置 |
| gateway/apisix/apisix.yaml | Casdoor 时代 standalone 路由（/rpc/user_login_sso、/rpc/refresh_token_rtr、/.well-known/jwks→Casdoor、/api/v1/sales/*、/api/v1/inventory/*） | ❌ 过时残留，不作现行路由表 |
| scripts/setup_apisix.sh | 被部署链使用（Makefile dev、deploy-all.sh、deploy-gateway.sh、CI deploy-gateway.yml、verify-stack.sh 预期 8 条路由），但内部仍是 Casdoor 时代路由（jwks 上游 app-casdoor:8000 已死、user_login_sso/refresh_token_rtr、api_v1_sales/inventory 重写） | ⚠️ 旧脚本残留，与 Logto 部署不一致 |
| scripts/init-apisix-routes.sh | Logto 时代新脚本（上表路由集 + webhook 验签 fail-closed），**未接入 Makefile/部署链**，仅被 scripts/e2e-test.sh 注释引用 | ✅ 目标架构事实；接入部署链为待办（TODO） |

> 收敛方向：以 init-apisix-routes.sh 为目标路由集；setup_apisix.sh 与 apisix.yaml 的 Casdoor 时代内容待清理/替换（TODO，需在部署侧执行，wiki 不改代码）。

## 分层说明

| 层 | 组件 | 职责 | 配置位置 |
| --- | --- | --- | --- |
| 网关层 | APISIX + etcd | JWT 验签、路由/重写、CORS、webhook 验签（目标）；Admin API/Dashboard 管理配置 | gateway/apisix/config.yaml；scripts/setup_apisix.sh（部署链在用，旧）/ scripts/init-apisix-routes.sh（Logto 目标路由） |
| 认证层（旁路） | Logto | 登录/注册/MFA/第三方、组织（租户）容器、角色目录与分配、签发 JWT、webhook | gateway/docker-compose.yml（logto 服务）、scripts/phase2/init-logto.py |
| API 层 | PostgREST | 把对外暴露层 schema（运行态 api_v1_public；conf 参考文件声明多 schema）暴露为 REST；/rpc/* 函数端点；注入 request.jwt.claims；OpenAPI 生成 | gateway/docker-compose.yml（postgrest 环境变量，运行态权威）、gateway/postgrest/postgrest.conf（参考文件） |
| 数据层 | PostgreSQL（Pigsty 集群 + pgbouncer + redis） | 业务表 + 镜像表、视图、RPC、触发器、RLS、审计；pg_cron 定时任务 | db/（迁移 + src/api_v1 幂等源码）、infra/pigsty.yml、infra/pgbouncer.ini |

PostgREST 运行配置（gateway/docker-compose.yml 环境变量，覆盖同名 conf）：

| 配置 | 值 | 说明 |
| --- | --- | --- |
| PGRST_DB_URI | postgres://authenticator:…@host.docker.internal:6432/app_db | 经 pgbouncer 连接 |
| PGRST_DB_SCHEMAS | api_v1_public（compose env，运行时生效） | 运行时以 env 为准；postgrest.conf 声明多 schema：api_v1_public, api_v1_sales, api_v1_inventory（sales/inventory 已退役，按需重建） |
| PGRST_DB_EXTRA_SEARCH_PATH | api_v1_public,public | 函数解析搜索路径 |
| PGRST_DB_ANON_ROLE | web_anon | 匿名角色（无默认表权限） |
| PGRST_JWT_SECRET | ${JWKS_JSON} | 开发环境 = HS256 对称密钥（.env.example 占位）；staging/production = Logto JWKS 公钥，RS256（05 文档与 init-apisix-routes.sh 口径；compose/.env 注释写 ES384，口径不一致，需以 Logto 实际配置核实） |
| PGRST_JWT_ROLE_CLAIM_KEY | .pg_role | JSPath 语法，取 Logto customizer 注入的 pg_role claim |
| PGRST_DB_PRE_REQUEST | （空） | 旧 token 黑名单预请求已退役（D12：会话/吊销交 Logto） |
| PGRST_MAX_ROWS | 1000 | 单请求最大行数 |
| PGRST_DB_TX_END | commit | 事务结束方式 |
| PGRST_CORS_ORIGINS | * | 供 Swagger 浏览器拉取 spec |

> 配置来源说明：**运行态以 gateway/docker-compose.yml 为权威**（单 schema api_v1_public、.pg_role、extra search path = api_v1_public,public、max-rows 1000、pre-request 已清空、宿主 3100）；postgrest.conf 为参考文件（db-schemas 多 schema、jwt-role-claim-key=roles[0]、jwt-secret="$(JWKS_JSON)" 由 gateway/.env 注入），与运行态不一致处以后者为准。

## 模块划分总览（按 schema）

| Schema | 职责 | 目录 |
| --- | --- | --- |
| public | 核心业务：镜像表（users/tenants/role/…）、自主表（iam_menu/iam_role_menu/…）、全部业务函数/触发器/视图/RLS、审计与日志 | db/src/public/、db/migrations/public/ |
| api_v1_public | 对外暴露层（现行）：视图投影（视图名 = 底层表名）与 RPC 包装（api_v1_public.*） | db/api_v1/public/ |
| api_v1_sales / api_v1_inventory | 对外暴露层声明（仅 postgrest.conf）；**schema 不存在**（063 已退役），路由已移除，目录保留为空，按需重建 | db/api_v1/inventory/（空） |
| api_v1_sys | 兼容历史迁移引用（027 改名链）；非最终使用对象 | db/init/02-schemas.sql |
| net | pg_net 扩展宿主 schema（owner=postgres；已对 authenticated 收紧权限） | 扩展管理，项目不驻留对象 |
| cron | pg_cron 扩展宿主 schema（任务定义 cron.job、运行历史 cron.job_run_details） | 扩展管理（Pigsty 集群级安装） |
| 扩展（非 schema） | 不存在 extensions schema：pg_pwhash/pgcrypto/pgtap 装在 public，pg_net 宿主 net，pg_cron 宿主 cron；ip2region/GeoLite2 离线表在 public；db/extensions/ 为扩展说明文档目录 | db/extensions/、db/init/01-extensions.sql |

> schema 现实（以 db/init/02-schemas.sql 为准）：public、api_v1_public、api_v1_sys（027 改名链兼容，新代码不用）、net（pg_net 宿主）——**不存在 extensions schema**，也不存在 api_v1_sales / api_v1_inventory schema（063 已退役，仅 postgrest.conf 声明残留、db/api_v1/inventory 目录保留为空、按需重建）。运行态暴露层为单 schema api_v1_public。db/api_v1/ 目录含 _shared（空，apply-src API 模块排序前缀）、inventory（空）、public（实际内容）。兼容视图 public.sys_user 与 public.casbin_rule 是刻意保留的兼容层（非未清理的 sys_ 残留）。db/api_v1/public/privileges/zz_grant_all.sql 与 db/src/public/privileges/rls_policies.sql 是授权/策略的集中清单。详见 [模块划分](./module-breakdown.md)。

## 架构关键特性：数据库即后端、RLS 数据隔离

- **数据库即后端**：全部业务逻辑（认证授权判定、菜单树、审计、IP 归属、webhook 同步）以表/RPC/视图/触发器形式落在 PostgreSQL；PostgREST 自动生成 REST 面，前端直接消费，无自建业务服务。
- **三层授权（05.4 定稿）**：前端缓存管"看不看得到"（UX）、has_permission 管"能不能做"（操作级）、RLS 管"能看到哪些行"（数据级）。网关 jwt-auth 为前置防御。
- **RLS 集中清单**：db/src/public/privileges/rls_policies.sql 共 20 个策略（租户隔离 RESTRICTIVE、全局共享只读、超管豁免等），全部读取 PostgREST 注入的 request.jwt.claims，零查询。
- **SECURITY DEFINER + search_path 锁定**：写/管理 RPC 与 helper 一律 SECURITY DEFINER SET search_path = public, pg_temp，函数内自校验（has_permission / require_super_admin）——DEFINER 会绕过 RLS，必须函数内兜底。
- **17 号铁律（代码对象归位）**：迁移文件只承载表结构 + 数据（幂等 IF NOT EXISTS / DO 块）；函数/视图/触发器/类型/RLS 归 db/src/public/ 与 db/api_v1/public/；scripts/apply-src.sh 全量幂等重放（含 §6.3 迁移目录代码对象扫描，命中即失败）。
- **部署链**：scripts/deploy-db.sh = bootstrap（init 扩展/schema + src types 枚举）→ dbmate up（迁移）→ apply-src 全量重放；scripts/deploy-gateway.sh = compose 起服务 + 路由初始化（部署链当前调用 scripts/setup_apisix.sh，为 Casdoor 时代旧脚本；目标为 scripts/init-apisix-routes.sh，见上文「已知不一致 / 待收敛」）。CI 见 .github/workflows/ci.yml、deploy-gateway.yml、deploy-infra.yml；其中 ci.yml 的 syncer-check 作业与 deploy-gateway.sh 的 syncer build 段为历史遗留（Go syncer 已退役，webhook 同步全在数据库内）。

---

> 参考：分层/RLS/防御思想源自 [项目总纲](../01-项目简介/overview.md)；技术栈细节见 [技术栈全景](../01-项目简介/tech-stack.md)；网关路由见 [网关路由](../06-API参考/gateway-routing.md)；PostgREST 配置见 [PostgREST 配置](../06-API参考/postgrest.md)；模块归属见 [模块划分](./module-breakdown.md)。
