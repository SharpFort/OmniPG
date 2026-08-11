# 06 — Logto 迁移开发路线与验收清单（v1.0）

> **状态**：待评审（2026-08-04）
> **前置**：`docs/开发实施方案/05-Logto认证与权限架构-完善版.md`（定稿 v2.1，本文件为其**可执行化**与**缺口补全**）
> **环境**：Windows + WSL2 Ubuntu-26.04（Pigsty v4.4.0 + Docker Desktop WSL2 模式），已有 app_db / casdoor 库
> **范围**：Casdoor → Logto 全量替换（认证/组织/角色目录），PG 授权判定层保留；其他组件（APISIX/PostgREST/Swagger/Pigsty）不动
> **引用事实**：本文件 F1-F21 沿用 05 文档编号；新增核实事实 N1-N3（见 §2.2）

---

## 1. 审查结论摘要（对 05 文档 §12 的评审结果）

### 1.1 已核实正确的决策（源码级，2026-08-04）

| 事实 | 结论 | 验证位置 |
|:---|:---|:---|
| F3 Membership 增量数组 + 5000 截断 | ✅ 正确 | `packages/core/src/libraries/hook/utils.ts:158`（truncateMembershipDelta，`MEMBERSHIP_DELTA_CAP` 静默截断） |
| F12 webhook 注册表 | ✅ 正确 | `packages/schemas/src/foundations/jsonb-types/hooks.ts`（`User.Deleted` 为路由内手动触发） |
| F13 角色分配无事件 | ✅ 正确 | `routes/organization/user/role-relations.ts`、`routes/admin-user/role.ts` 均无 `appendDataHookContext` |
| F20 角色名唯一 | ✅ 正确 | `packages/schemas/tables/roles.sql`、`organization_roles.sql`：`unique (tenant_id, name)` |
| F11 v1.42.0 最新 | ✅ 正确 | GitHub releases 2026-07-30 |
| 官方部署形态 | ✅ 正确 | 官方 compose：`svhd/logto` 镜像、端口 3001/3002、`npm run cli db seed -- --swe`、`TRUST_PROXY_HEADER`/`DB_URL`/`ENDPOINT`/`ADMIN_ENDPOINT` |
| pgBouncer 兼容 | ✅ 正确 | `DATABASE_STATEMENT_TIMEOUT=DISABLE_TIMEOUT`（v1.36.0+，官方 compose 注释确认） |
| OSS 单管理员 | ✅ 正确 | 官方文档：首次启动仅可创建 1 个账户 |

### 1.2 内部矛盾 / 决策错误（本路线文档已修正）

| # | 问题 | 证据 | 修正 |
|:---|:---|:---|:---|
| **B1** | §10.2 声称 `current_user_roles()` "SQL 不变" | 现函数解析 Casdoor **对象数组**（`db/src/public/functions/current_user_roles.sql`：`e->>'name'` + isEnabled 过滤）；Logto roles 为**字符串数组** | **必须重写**为 §5.3.1 版本（`jsonb_array_elements_text`，无 isEnabled 概念），删除 §10.2 "SQL 不变" 表述 |
| **B2** | Logto 默认端口 3001/3002 与 PostgREST 3001 冲突 | 配置说明文档 §二：PostgREST=3001 | **主机映射 8001/8002**（容器内保持 3001/3002） |
| **B3** | **租户主键类型冲突**：Logto organization id = 21 位 nanoid 字符串（服务端生成，不可自定义），现有 `sys_tenant.id` = UUID v7，20+ 张业务表 FK/RLS 依赖 | `packages/shared/src/utils/id.ts`（generateStandardId=21 位小写字母数字）；`db/migrations/public/001_init_tables.sql`；SchemaRouter 创建实体不接受客户端 id | **租户主键统一改为 text = Logto organization id**（N4 空白业务，可接受）。新建 `tenants` 镜像表（id text），业务表 `tenant_id` 改 text；RLS `tenant_id = current_tenant_id()` 零查询成立 |
| **B4** | **用户主键类型冲突**：Logto user id = 21 位字符串（非 UUID）；`casdoor_user_mirror.id` uuid、`sys_user_profile.user_id` uuid、所有 `*_by` 审计 FK uuid | `packages/shared/src/utils/id.ts` | 新建 `users` 镜像表（id text PK）；`sys_user_profile.user_id` 改 text FK→users；审计列 `*_by` 改 text（FK→users 或仅存 id 无 FK，见 T4 决策） |
| **B5** | PostgREST 角色映射未决：现 `PGRST_JWT_ROLE_CLAIM_KEY=".roles[0].name"`（Casdoor 对象数组首个 name）；Logto roles 为字符串数组且角色名（role_super_admin）≠ PG 角色名（super_admin） | `gateway/docker-compose.yml:88` | **方案 R1（推荐）**：Custom Claims 脚本注入 `pg_role` claim（纯内存映射：roles 含 role_super_admin→super_admin；否则 role_admin→role_admin；role_editor→role_editor；默认 role_guest），`PGRST_JWT_ROLE_CLAIM_KEY=".pg_role"`。方案 R2（备选）：统一 `authenticated` 角色 + RLS 全按 claims 判定（改动 GRANT 面大） |
| **B6** | 新镜像表（users/tenants/user_tenants）与现有 sys_user_profile/sys_tenant 关系未定义 | 05 §6.3 | sys_user_profile 保留（业务档案：tenant_id/dept_id/nickname），`user_id` 改 text FK→users，`tenant_id` 改 text FK→tenants；`sys_tenant` 退役（数据迁 tenants 镜像表） |

### 1.3 §12 遗漏任务补全（本路线文档新增）

1. **Pigsty 侧基础设施**：logto 数据库 + 专用登录用户 + pg_hba 条目 + pgbouncer userlist（T1）
2. **Logto 数据库初始化**（db seed，T2）
3. **移除 Casdoor 完整清单**（T7）：compose 服务、casdoor 库、APISIX `/casdoor/*` 路由、`.env` CASDOOR_* 变量、`sys_secret.casdoor_webhook_secret`、casbin-syncer systemd 退役、legacy 脚本归档
4. `PGRST_DB_PRE_REQUEST=check_token_blacklist` 处置（sys_token_blacklist 不启用 → 移除该配置；函数保留空实现）
5. casbin_rule 视图重建（sys_role_api 投影 → iam_role_api/iam_role_menu 投影）
6. sys_role/sys_user_role/sys_user_role_request/sys_user_session 等 Casdoor 时代表处置（T4 决策：退役 + 归档）
7. webhook 验签实现位置（**RPC 内验签**，沿用 Casdoor 时代 x-webhook-secret 模式；APISIX 仅做来源限制可选）
8. Logto Console 配置自动化脚本（`scripts/phase2/init-logto.py`，T3）
9. CORS 处理（开发期：APISIX `/logto/*` 同源代理，复用 casdoor_proxy 思路；生产：Logto Console 配置 allowed origins）
10. e2e 验证命令化（T6 决策门槛表）
11. **范围裁剪**：仓库无前端工程（`frontend/` 不存在）→ P0-8 前端 SDK 接入降级为 "API 级 OIDC 流程验证（curl）+ 前端接入指南"，前端工程化移 P1

### 1.4 新增核实事实（2026-08-04）

| # | 事实 | 验证位置 |
|:---|:---|:---|
| N1 | Logto 用户/组织/角色 id = `generateStandardId()`：21 位小写字母+数字（nanoid），**非 UUID 无前缀** | `packages/shared/src/utils/id.ts` |
| N2 | SchemaRouter 创建实体不接受客户端指定 id（`generateStandardId` 服务端生成）→ 组织 id 不可自定义为 UUID | `packages/core/src/utils/SchemaRouter.ts:120` |
| N3 | Pigsty v4.4 `app/` 模板**无 Logto**（也无 Casdoor）→ Logto 需自建 compose 服务 | `github.com/pgsty/pigsty` tree |

---

## 2. 关键决策补充（D15+，05 文档 §1.1 之外）

| # | 决策点 | 结论 |
|:---|:---|:---|
| D15 | Logto 端口 | 容器内 3001/3002 不变；主机映射 **8001**（core/API）/ **8002**（admin console）；`ENDPOINT=http://localhost:8001`、`ADMIN_ENDPOINT=http://localhost:8002` |
| D16 | Logto 数据库 | Pigsty 新建 `logto` 库 + `logto` 用户（专用低权限）；`DB_URL=postgres://logto:***@host.docker.internal:6432/logto`（pgBouncer）+ `DATABASE_STATEMENT_TIMEOUT=DISABLE_TIMEOUT` |
| D17 | 租户主键 | **业务租户主键统一 = Logto organization id（text）**；新建 `tenants` 镜像表；`sys_tenant` 退役（数据迁移）；业务表 `tenant_id` 改 text；RLS 零查询成立 |
| D18 | 用户主键 | 新建 `users` 镜像表（id text PK = Logto user id）；`sys_user_profile.user_id` text；审计列 `*_by` 改 text 无 FK（保留 id 语义，Logto 用户即权威） |
| D19 | PostgREST 角色映射 | **R1**：脚本注入 `pg_role` claim（角色优先级映射），`PGRST_JWT_ROLE_CLAIM_KEY=".pg_role"`；`roles` claim 保持完整角色数组供 RLS/has_permission 消费 |
| D20 | webhook 验签 | **PostgREST RPC 内验签**：`logto-signature-sha-256` = HMAC-SHA256(signingKey, rawBody) 恒定时间比较；signingKey 存 `sys_secret.logto_webhook_signing_key`（部署配置注入）；APISIX 不加载 Lua（减少插件面） |
| D21 | CORS | 开发期 APISIX `/logto/*` 同源代理（regex_uri 去前缀）；前端 SDK endpoint 指向 `http://localhost:9080/logto`；生产改用 Console 级 allowed origins 或保持代理 |
| D22 | 微信/SMTP 连接器 | **后置 P1**（依赖外部 AppID/Secret 凭据，不阻塞 P0）；P0 用密码 + 验证码登录验证 |
| D23 | 镜像表字段集 | users：id/username/primary_email/primary_phone/name/avatar/custom_data(jsonb)/identities(jsonb)/last_sign_in_at/created_at/is_suspended + 审计列；tenants：id/name/description/custom_data/created_at；user_tenants：organization_id+user_id 复合 PK；iam_role：id/name/role_code(生成列)/type/is_default |
| D24 | 自主表命名 | `iam_api`/`iam_menu`/`iam_role_api`/`iam_role_menu`（E2 采纳）；`casbin_rule` 视图重建为自主表投影（E3） |
| D25 | sys_token_blacklist | 不启用；移除 `PGRST_DB_PRE_REQUEST`；`check_token_blacklist` 函数保留（恒真，防回归） |
| D26 | 种子数据 | Logto 侧：全局角色 `role_super_admin`；组织模板 `default` 含组织角色 `tenant_admin`/`editor`/`viewer`；PG 侧：iam_api 从现有 `sys_api` 数据迁移（API 目录属业务自主数据，非 Casdoor 资产）；iam_role_api/iam_role_menu 按新角色模型重建（role_code=Logto 角色名） |
| D27 | 范围裁剪 | P0 = 后端链路（Logto↔APISIX↔PostgREST↔PG）+ Casdoor 移除；前端 SDK 接入 → API 级验证 + 接入指南（仓库无前端工程）；微信/SMTP → P1 |

---

## 3. 开发路线（任务级：目标 / 操作 / 验证 / 完成标准）

> 每任务含 **验证命令** 与 **完成标准（决策门槛）**。全部完成后按 §5 二次核实清单逐项评估。

### T1 — Pigsty 侧：logto 数据库与连接就绪

- **目标**：Logto 可用的专用库/用户/连接路径（pgBouncer 6432）
- **操作**：
  1. WSL2 内以 postgres 身份：`CREATE ROLE logto LOGIN PASSWORD '...'`、`CREATE DATABASE logto OWNER logto`
  2. pg_hba.conf 追加（如缺）：`host all logto 172.20.0.0/16 scram-sha-256`、`host all logto 172.17.0.0/16 scram-sha-256`；reload
  3. pgbouncer `userlist.txt` 追加 logto 用户密码；`pgbouncer -R`（reload 或重启）
- **验证**：
  ```bash
  # WSL2 内
  sudo -u postgres psql -tAc "SELECT datname FROM pg_database" | grep logto
  # 容器内模拟（app-postgrest 有 pg 客户端依赖；或 WSL2 内经 6432）
  PGPASSWORD=xxx psql -h 127.0.0.1 -p 6432 -U logto -d logto -c "SELECT 1"
  ```
- **完成标准**：库存在；logto 用户可经 6432 登录；Docker 网段可达（后续容器实测）

### T2 — Logto 容器部署 + 数据库初始化

- **目标**：Logto v1.42.0 容器运行，Console 可访问
- **操作**：
  1. `gateway/docker-compose.yml` 新增 `logto` 服务：
     - image `svhd/logto:1.42.0`（DockerHub 镜像 tag 需实测，fallback `ghcr.io/logto-io/logto:1.42.0`）
     - ports `8001:3001`、`8002:3002`
     - env：`TRUST_PROXY_HEADER=1`、`DB_URL=postgres://logto:${LOGTO_DB_PASSWORD}@host.docker.internal:6432/logto?sslmode=disable`、`DATABASE_STATEMENT_TIMEOUT=DISABLE_TIMEOUT`、`ENDPOINT=http://localhost:8001`、`ADMIN_ENDPOINT=http://localhost:8002`
     - `extra_hosts: host.docker.internal:host-gateway`；network app-net（静态 IP 172.20.0.9）
     - 首次启动 entrypoint 需含 seed：`npm run cli db seed -- --swe && npm start`（官方 compose 模式；幂等验证见下）
  2. `.env` 新增 `LOGTO_DB_PASSWORD`；`gateway/.env` 同
  3. 启动：`docker compose up -d logto`；观察日志
- **验证**：
  ```bash
  curl -sf http://localhost:8002/ | grep -i logto   # Console
  curl -sf http://localhost:8001/oidc/.well-known/openid-configuration | python -m json.tool   # OIDC 发现
  docker exec app-logto npm run cli db seed -- --swe   # 幂等验证（重跑不报错）
  ```
- **完成标准**：OIDC discovery 返回 issuer=`http://localhost:8001/oidc`；`jwks_uri` 存在；Console 可创建管理员账户（仅一次）
- **⚠️ 坑**：seed 需在首次启动前完成（`--swe` 跳过 webhook 依赖）；若 8001/8002 被占调整映射；Console 单管理员限制（OSS）

### T3 — Logto Console 初始化 + 配置自动化（init-logto.py）

- **目标**：Logto 侧全部配置就绪且**脚本化可重建**（角色/组织模板/组织/webhook/claims 脚本/M2M 应用）
- **操作**：
  1. Console 手动创建管理员（一次性）
  2. 编写 `scripts/phase2/init-logto.py`（参考 `init-casdoor-app.py` 模式，走 Management API）：
     - 创建 M2M 应用（管理端集成用）+ 授予管理 API role
     - 创建全局角色 `role_super_admin`（type=User）
     - 创建组织模板 `default`：组织角色 `tenant_admin`/`editor`/`viewer`
     - 创建组织（租户）`default` 并关联模板；创建演示用户 + 分配组织角色
     - 创建 webhook（订阅事件集，见 T4）+ signing key 输出到部署配置
     - **Custom Token Claims 脚本**（access-token 类型）：
       ```javascript
       const getCustomJwtClaims = async ({ token, context }) => {
         const globalRoles = (context.user?.roles ?? []).map((r) => r.name);
         const orgId = context.organization?.id;
         const orgRoles = orgId
           ? (context.user?.organizationRoles ?? []).filter((r) => r.organizationId === orgId).map((r) => r.roleName)
           : [];
         const roles = [...new Set([...globalRoles, ...orgRoles])];
         // D19: pg_role 映射（最高优先级角色 → PostgREST DB 角色）
         const priority = ['role_super_admin', 'role_admin', 'role_editor'];
         const pgRole = priority.find((r) => roles.includes(r)) ?? 'role_guest';
         const pgRoleMap = { role_super_admin: 'super_admin', role_admin: 'role_admin', role_editor: 'role_editor', role_guest: 'role_guest' };
         return { roles, pg_role: pgRoleMap[pgRole] };
       };
       ```
     - access token 寿命 15 分钟
  3. 脚本幂等（资源存在则跳过/更新）；signing key 存 `sys_secret.logto_webhook_signing_key`（T4 用）
- **验证**：
  ```bash
  python scripts/phase2/init-logto.py --endpoint http://localhost:8001 --verify
  # 输出: 角色清单 / 组织清单 / webhook 清单 / claims 脚本 test 结果
  ```
- **完成标准**：脚本 `--verify` 输出全部配置存在；Console 手工核对；claims 脚本 Console test 通过（roles 数组正确）

### T4 — PG 侧改造（迁移 009/010/011 + 源码重写）

- **目标**：镜像表/自主表/RLS helper/webhook RPC 全部切换 Logto 语义，Casdoor 资产退役
- **操作**：
  1. **迁移 009_logto_mirror.sql**（新表，D17/D18/D23/D24）：
     - `users`（id text PK、username、primary_email、primary_phone、name、avatar、custom_data jsonb、identities jsonb、last_sign_in_at timestamptz、created_at、is_suspended bool + 审计列）
     - `tenants`（id text PK、name、description、custom_data jsonb、created_at + 审计列）
     - `user_tenants`（organization_id text FK→tenants、user_id text FK→users、PRIMARY KEY(organization_id, user_id)）
     - `iam_role`（id text PK、name、role_code 生成列 GENERATED ALWAYS AS (name)、type varchar、is_default bool）
     - `iam_api`（id uuid PK、path、method、name、description、status + 审计列）← 从 sys_api 迁移
     - `iam_menu`（id uuid PK、parent_id、menu_name、path、icon、order_num、status + 审计列）← 从 sys_menu 迁移
     - `iam_role_api`（id uuid PK、role_code text、api_id uuid FK→iam_api、UNIQUE(role_code, api_id)）
     - `iam_role_menu`（id uuid PK、role_code text、menu_id uuid FK→iam_menu、UNIQUE(role_code, menu_id)）
  2. **RLS helper 重写**（B1 修正）：`current_user_roles()` → `jsonb_array_elements_text(claims->'roles')`；`current_tenant_id()` 保持（读 organization_id）；`current_user_id()` 保持（读 sub）；`is_super_admin()` 改读 `roles @> ARRAY['role_super_admin']`
  3. **webhook RPC 重写**：`rpc_webhook_logto(payload jsonb)`（§4.3 分发逻辑）：
     - 事件：User.Created / User.Data.Updated / User.Deleted / Organization.Created / Organization.Data.Updated / Organization.Deleted / Organization.Membership.Updated / Role.Created / Role.Data.Updated / Role.Deleted
     - 验签（D20）：`logto-signature-sha-256` 恒定时间比较；signingKey 从 `sys_secret.logto_webhook_signing_key` 读取；**rawBody 验签需 PostgREST 侧拿原始 body**——实现方式：APISIX 透传 header `X-Logto-Signature` + RPC 对 `payload` 的 **jsonb 规范化**存在边界风险 → **改用 APISIX `serverless-pre-function` Lua 验签**（见 T5 补充，D20 修订：验签在网关，RPC 只按事件分发）
     - 幂等：ON CONFLICT DO UPDATE；Membership 5000 截断 → 触发对账标记（写 `sys_config` 对账待办）
     - 响应守卫：`{ok:true}`；未知事件忽略
  4. **ensure_user JIT 重写**：claims 来源改 Logto 字段（sub/username/primaryEmail/name/avatar）→ users 表
  5. **兼容视图**：`public.sys_user` 重建为 users + sys_user_profile 投影；`casbin_rule` 视图重建为 iam_role_api/iam_role_menu 投影（E3）
  6. **sys_user_profile 改造**：user_id text FK→users、tenant_id text FK→tenants；存量行迁移（旧 uuid → Logto id 映射由 T3 脚本产出 CSV）
  7. **Casdoor 资产退役**（.deprecated 标记 + REVOKE，沿用 008 模式）：casdoor_user_mirror、rpc_webhook_user_upsert/delete、rpc_create_user、user_login_sso/refresh_token_rtr（已 deprecated）、sys_token_blacklist 相关、sys_role/sys_user_role/sys_user_role_request（审批流已 revoke）、sys_secret.casdoor_webhook_secret
  8. **业务表 tenant_id 改 text**：sys_department、sales.*、inventory.* 等全部 `ALTER COLUMN tenant_id TYPE text` + FK→tenants（N4 无历史数据；fixtures 同步更新）
- **验证**：
  ```bash
  make test    # 既有测试套件（预期部分失败 → 逐项修复）
  scripts/apply-src.sh   # 幂等重跑
  # 手工：psql 检查表结构/RLS 函数
  ```
- **完成标准**：apply-src 全绿；`current_user_roles()` 对 Logto 字符串数组 claims 返回正确；webhook RPC 各事件分发正确（T6 实测）；旧 Casdoor RPC 全部 REVOKE

### T5 — 网关/API 层切换（APISIX + PostgREST）

- **目标**：JWT 验签切 Logto JWKS；webhook 验签前置；Casdoor 路由移除
- **操作**：
  1. 获取 Logto JWKS：`curl http://localhost:8001/oidc/jwks`（或 discovery 的 jwks_uri）→ 存 `gateway/.env` JWKS_JSON（RS256）
  2. `scripts/init-apisix-routes.sh` 更新：
     - jwt-auth plugin_metadata：`{algorithm: RS256, key: <JWKS_JSON>}`
     - 移除 `/rpc/user_login_sso`、`/rpc/refresh_token_rtr`、`/casdoor/*` 路由
     - 新增 `/logto/*` 同源代理（D21）：upstream app-logto:3001，proxy-rewrite 去前缀
     - webhook 路由：`POST /rpc/webhook_logto`（web_anon 可调）挂 `serverless-pre-function` Lua 验签（D20 修订：HMAC-SHA256 rawBody，signingKey 注入 conf 环境变量）
  3. `gateway/docker-compose.yml` postgrest 服务：
     - `JWKS_JSON` / `PGRST_JWT_SECRET` → Logto JWKS（RS256）
     - `PGRST_JWT_ROLE_CLAIM_KEY=".pg_role"`（D19）
     - 移除 `PGRST_DB_PRE_REQUEST=check_token_blacklist`（D25）
  4. `.env` 清理 CASDOOR_*（T7 一并）；新增 LOGTO_*、LOGTO_WEBHOOK_SIGNING_KEY
- **验证**：
  ```bash
  bash scripts/init-apisix-routes.sh
  curl -s http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth -H "X-API-KEY: ..."   # RS256 + Logto JWKS
  # 伪造 HS256 token 应 401；Logto 签发 token 应通过（T6 全链路）
  ```
- **完成标准**：jwt-auth 元数据 = Logto RS256 JWKS；`/logto/*` 代理可达（`curl localhost:9080/logto/oidc/.well-known/openid-configuration`）；旧路由 404

### T6 — e2e 验证（决策门槛实测）

- **目标**：全链路验证，逐项给出通过/失败
- **验证清单**（每项含命令与预期）：

| # | 验证项 | 命令/方法 | 预期 |
|:---|:---|:---|:---|
| V1 | Logto 登录（密码） | OIDC code flow（curl 模拟 PKCE 或浏览器）+ token 端点 | 200，得 access/refresh token |
| V2 | 组织 token 获取（F7） | refresh token + `resource` + `organization_id` → token 端点 | JWT 含 organization_id；`roles` claim = 全局∪组织角色 |
| V3 | Custom Claims 脚本生效 | 解码 JWT（jwt.io 或 python） | `roles` 字符串数组正确；`pg_role` 正确 |
| V4 | PostgREST 验签 | 带组织 token 调 `GET /api/v1/sys/health`（若需）或业务视图 | 200；claims 注入（`current_setting('request.jwt.claims')` 含 organization_id） |
| V5 | RLS 租户隔离 | 两个组织用户互查对方数据 | 各自只见本租户行 |
| V6 | 角色变更生效（D11） | Logto 改用户组织角色 → 刷新 token | 新 roles 生效；≤15 分钟残留窗口 |
| V7 | webhook 用户同步 | Console 建用户 → 观察 rpc_webhook_logto 调用 | users 镜像表新增；createdAt 正确 |
| V8 | webhook 成员同步 | Console 组织添加成员 | user_tenants 增量正确（addedUserIds） |
| V9 | webhook 角色目录同步 | Console 建角色 | iam_role 镜像新增（role_code 生成列） |
| V10 | 验签失败 | 伪造 signingKey 重放 payload | 401/拒绝；审计记录 |
| V11 | 吊销语义 | 撤销 refresh token → 刷新 | 401，前端重登 |
| V12 | 5000 截断对账（F3） | 构造 >5000 成员变更（或 mock） | 触发对账标记（sys_config 待办） |
| V13 | Casdoor 已移除 | docker ps / curl 8000 | 无 casdoor 容器；8000 无响应 |
| V14 | 幂等重放 | 重放同一 webhook payload | 无重复行（ON CONFLICT） |

- **完成标准**：V1-V14 全部通过（或明确记录未达标项 + 决策）

### T7 — Casdoor 移除（用户明确要求）

- **操作**：
  1. `gateway/docker-compose.yml` 删除 casdoor 服务块
  2. `docker compose up -d`（确认其余服务正常）→ `docker rm app-casdoor`（如残留）
  3. WSL2：`sudo -u postgres dropdb casdoor`（先备份：`pg_dump casdoor > casdoor_backup.sql` 归档到 `scripts/legacy/` 或 docs）
  4. `scripts/init-apisix-routes.sh` 已无 casdoor 路由（T5）；`scripts/legacy/casdoor_integration.sh` 移入 `scripts/legacy/`（已归档）
  5. casbin-syncer：`systemctl disable --now casbin-syncer`（退役）；源码目录 `db/casbin-syncer/` 归档标记
  6. `.env`/`gateway/.env` 删除 CASDOOR_*；`db/init/03-casdoor-db.sql` 归档标记
  7. 文档同步：配置说明文档 §二/§3.2/§7.5 Casdoor 条目更新
- **验证**：V13；`grep -ri casdoor gateway/ db/ scripts/` 仅剩 legacy/历史注释
- **完成标准**：无 casdoor 容器/库/路由/环境变量；syncer 停止

### T8（P1）— 管理端 Management API 集成

- 建号/禁用/角色分配走 Logto Management API（M2M token）；iam_role_api/iam_menu 管理 UI（自研，带 has_permission）
- 组织生命周期：POST /organizations + 邀请流程
- iam_user_role 分配镜像（§6.5：JIT 覆盖 + 主动同步 + 对账）
- 角色名不可变更约束落地
- 微信/SMTP 连接器（凭据就绪后）
- 前端工程初始化 + Logto SDK 接入（P0-8 落地）

### T9（P2）— 加固与观测

- 每日镜像对账任务；perms-in-JWT 评估（scope claim）；秒级吊销评估；性能基准；pg_session_jwt 备选评估

---

## 4. 部署顺序与依赖

```
T1 (PG 基建) → T2 (Logto 容器) → T3 (Console 配置)
     ↘ T4 (PG 改造，可与 T2/T3 并行)
                  ↘ T5 (网关切换，依赖 T2/T3 产出 JWKS/路由)
                        ↘ T6 (e2e) → T7 (Casdoor 移除)
                                    ↘ T8 (P1) → T9 (P2)
```

**回滚路径**：T5 前 Casdoor 仍在运行（双轨）；任一步失败 → 回滚 APISIX/PostgREST 配置 + 停止 logto 容器即可恢复

---

## 5. 二次核实清单（开发完成后的最终验收表）

> 逐项执行 §3 中对应任务的验证命令，结果记入 `docs/部署记录-<date>.md`

| 任务 | 验收项 | 检查方式 | 通过标准 | 结果 |
|:---|:---|:---|:---|:---|
| T1 | logto 库/用户/网络 | psql 6432 登录 | 可连接 | ☐ |
| T2 | Logto 运行 | OIDC discovery | issuer/jwks_uri 正确 | ☐ |
| T3 | 配置完整 | init-logto.py --verify | 角色/组织/webhook/脚本全在 | ☐ |
| T4 | 迁移 009-011 | apply-src + 表结构检查 | RLS helper 对字符串数组正确 | ☐ |
| T4 | 旧资产退役 | REVOKE 检查 + .deprecated | 无 Casdoor RPC 暴露 | ☐ |
| T5 | 网关切换 | jwt-auth 元数据 | RS256 + Logto JWKS | ☐ |
| T5 | 路由收敛 | curl 旧路由 | /casdoor/* 404 | ☐ |
| T6 | e2e V1-V14 | 命令逐项 | 全部通过 | ☐ |
| T7 | Casdoor 移除 | docker ps / grep | 无残留 | ☐ |
| T8 | 管理端 | Management API 冒烟 | 建号/分配成功 | ☐（P1） |
| T9 | 加固 | 对账任务运行 | 日志无异常 | ☐（P2） |

---

## 6. 风险与缓解（05 §11 补充）

| 风险 | 缓解 |
|:---|:---|
| svhd/logto:1.42.0 tag 不存在 | 实测 `docker manifest inspect svhd/logto:1.42.0`；fallback ghcr.io 镜像 + `latest` tag |
| webhook rawBody 验签在 RPC 内不可行（jsonb 重排） | D20 已修订：验签在 APISIX serverless-pre-function（Lua），RPC 只分发 |
| Logto 组织 id 与业务耦合后，组织重命名/删除影响 FK | tenants 镜像只增不改（Logto Organization.Data.Updated 同步 name 等展示字段）；业务 FK 引用 id 稳定 |
| 租户主键 text 化改动面大 | N4 无历史数据；fixtures 重写；迁移脚本逐表 ALTER + FK 重建（幂等） |
| Console 配置手工步骤多 | T3 脚本化 + --verify；signing key 等敏感值只入部署配置不入仓 |
| Logto OSS 升级破坏 webhook/claims | 锁版本 1.42.0；升级演练（05 §11） |
