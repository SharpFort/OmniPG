# E2E 集成测试

E2E 集成测试的唯一入口是 `scripts/e2e-test.sh`（Logto 版），覆盖“Logto OIDC 登录 → APISIX 网关（jwt-auth 验签）→ PostgREST（运行态暴露 api_v1_platform 单 schema，compose 环境变量为权威；postgrest.conf 的多 schema 仅为参考）→ PostgreSQL（RLS）”的完整链路。历史文档（12-端到端集成测试方案，已归档）中的 PowerShell 脚本（Casdoor / `user_login_sso` / policy-syncer 时代）已被本脚本取代，不作为当前依据。

## 前置条件

| 项 | 要求 | 验证方式 |
| --- | --- | --- |
| 网关栈 | `gateway/docker-compose.yml` 服务运行：etcd、apisix、postgrest、swagger-ui、logto | `cd gateway && docker compose ps` |
| 数据库 | Pigsty PostgreSQL + pgbouncer，迁移已应用 | `make migrate`；`psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1"` |
| APISIX 路由 | 运行 Logto 版路由初始化脚本（要求 `gateway/.env` 含 `LOGTO_WEBHOOK_SIGNING_KEY`，缺失时 fail-closed 拒绝） | `bash scripts/init-apisix-routes.sh` |
| Logto 种子 | 测试应用（默认 `CLIENT_ID`）、组织（`ORG_ID`）、管理员用户（`E2E_USER`/`E2E_PASSWORD`）已就绪 | Logto Console（localhost:3002） |
| 工具 | curl、jq、python3、psql | `command -v` 检查 |
| 环境文件 | `gateway/.env`（脚本 psql 检查用到 `DB_PASSWORD`） | `cp gateway/.env.example gateway/.env` 后按需修改 |

## 环境变量（脚本默认值）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BASE_URL` | `http://localhost:9080` | APISIX 网关数据面 |
| `PGRST_URL` | `http://localhost:3100` | PostgREST（compose 映射 3100:3000） |
| `LOGTO_URL` | `http://localhost:3001` | Logto Core（OIDC / Management API） |
| `CLIENT_ID` | `lbrkbi552ndpp22o339p4` | Logto 测试应用 client id |
| `REDIRECT_URI` | `http://localhost:5173/auth/callback` | OIDC 回调地址 |
| `ORG_ID` | `fmr1j72k3htk` | 登录时 consent 的组织 |
| `RESOURCE` | `https://default.logto.app/api` | RFC 8707 resource 参数，**必须携带**，否则 Logto 签发 opaque token，APISIX 无法验签 |
| `E2E_USER` / `E2E_PASSWORD` | `admin` / `Admin@112104` | Logto 登录账号 |
| `APISIX_ADMIN_KEY` | `edd1c9f034335f136f87ad84b625c8f1` | Admin API 密钥（Phase 0 检查路由用） |
| `LOGTO_M2M_APP_ID` / `LOGTO_M2M_SECRET` | 空 | 配置后启用“对账 dry-run”用例（`scripts/phase2/reconcile-logto.py --dry-run`） |

## 执行流程

### 登录实现（`logto_login()`）

脚本用纯 curl + python3 走完整 PKCE OIDC code flow：

1. 生成 verifier/challenge（S256）；
2. `GET /oidc/auth` 建立会话 cookie；
3. `PUT /api/interaction`（SignIn，username/password）→ `POST /api/interaction/submit` 拿 redirectTo；
4. 访问 redirectTo 后 `POST /api/interaction/consent`（携带 `organizationIds`）拿二次 redirectTo；
5. 从最终 Location 提取 `code`；
6. `POST /oidc/token`（authorization_code + code_verifier + **resource**）换取 JWT access_token。

### 测试框架与输出

- `run_test` 帮助函数逐条 `eval` 断言命令，输出 `[分类] 名称: ✅ PASS / ❌ FAIL`；
- 临时目录 `TMPD`（mktemp）存 cookie/中间响应，`trap ... EXIT` 自动清理；
- 结尾汇总通过/失败数，`exit $FAILED`（退出码 = 失败用例数）。

### 阶段总览

| Phase | 主题 | 固定用例数 |
| --- | --- | ---: |
| 0 | 环境就绪检查（ENV） | 5 |
| 1 | 认证流程（AUTH） | 5 |
| 2 | 权限与只读保障（RBAC） | 5 |
| 3 | API 鉴权（API） | 5 |
| 4 | 角色与同步链路（REALTIME） | 2 |
| 5 | 多租户隔离（TENANT） | 3 |
| 6 | Webhook 同步链路（SYNC） | 5 + 2 可选 |
| 7 | 异常恢复（RESILIENCE） | 3 |

## 覆盖场景清单

| Phase | 用例 | 断言要点 |
| --- | --- | --- |
| 0 | PostgREST Running | `curl -sf $PGRST_URL/` 返回 OpenAPI |
| 0 | APISIX Running | Admin API 路由列表含 `api_v1_platform` |
| 0 | Logto Running | `$LOGTO_URL/oidc/.well-known/openid-configuration` 含 issuer |
| 0 | Backend Health / Logto JWKS | Swagger :8082 可用；Logto JWKS 含 `keys[0].kty` |
| 1 | Admin Login | `logto_login` 拿到长度 >100 的 token |
| 1 | Invalid Password Rejected | 错误密码的登录流程拿不到 JWT |
| 1 | Unauthorized Request | 无 token 请求 `/api/v1/platform/role` 返回 401/403 |
| 1 | Authorized Request | 带 token 查询 `sys/role` 返回 `role_code` |
| 1 | Menu Loaded | `/api/v1/platform/rpc/get_user_menu` 可调用（断言较宽松：length >= 0） |
| 2 | Users/Role/Tenant Readonly | 对镜像表 `sys/users`、`sys/role`、`sys/tenants` POST 被拒（4xx/5xx） |
| 2 | User List / Role List | `v_user_list`、`v_role_list` 视图可查询 |
| 3 | GET role / users | 镜像表只读可查 |
| 3 | RPC get_current_user | JWT claims 解析出 `.id` |
| 3 | JWKS Endpoint | 网关 `/logto/oidc/jwks` 代理可用 |
| 3 | 404 for Not Found | 不存在路由返回 401/403（catch-all 拦截） |
| 4 | JWT Roles Claim | token payload 的 `roles` 含 `role_super_admin` |
| 4 | Role List API | `v_role_list` 反映 Logto 角色 |
| 5 | Tenant Isolation | RLS 按租户过滤，department/audit_log 可读 |
| 5 | Dept / audit_log Scoped | 带 token 查询返回 200 且可解析 |
| 6 | webhook RPC 存在 | `pg_proc` 中存在 `webhook_logto` 函数 |
| 6 | users / role 镜像有数据 | `sys/users`、`sys/role` 至少 1 行 |
| 6 | Webhook 无签名头被拒 | POST `/rpc/webhook_logto` 无 `logto-signature-sha-256` → 401 |
| 6 | Webhook 错误签名被拒 | 错误 HMAC → 401 |
| 6 | （可选）对账 dry-run | `reconcile-logto.py --dry-run` 正常退出（需 M2M 配置） |
| 6 | （手工）N17 删除/封禁同步 | Logto Console 删除/封禁用户后查 `is_suspended` |
| 7 | Bad Token Rejected | `invalid.token.value` → 401/403 |
| 7 | Missing Auth Header | 无 Authorization → 401/403 |
| 7 | Wrong Method | PUT 镜像表 → 401/403/405 |

## 失败定位

1. **全部失败先看 Phase 0**：网关栈未起、路由未初始化或 Logto 未就绪时后续阶段必然失败。
2. **登录失败（Phase 1）**：检查 Logto 是否运行（`curl http://localhost:3001/oidc/.well-known/openid-configuration`）、`CLIENT_ID`/`ORG_ID`/`E2E_USER`/`E2E_PASSWORD` 是否与种子一致；token 为空时确认 `RESOURCE` 参数未被改动（opaque token 会导致 APISIX 验签失败）。
3. **401 类失败（Phase 3/7）**：APISIX `jwt-auth` 元数据未同步 Logto JWKS → 重跑 `bash scripts/init-apisix-routes.sh`；或路由被 catch-all/旧路由抢占（Phase 0 的 APISIX 检查会暴露）。
4. **webhook 401（Phase 6）**：`LOGTO_WEBHOOK_SIGNING_KEY` 与 Logto 控制台配置不一致；注意该路由不可叠加 request-validation（JSON 重排会破坏 rawBody 签名）、大 body 走临时文件回退（见 `init-apisix-routes.sh` 注释）。
5. **镜像数据断言失败**：`users`/`role` 为空 → Logto 侧 webhook 事件未触发或 `sync_*` RPC 未执行；手工触发 Logto 用户变更后重跑，或直接 psql 查表确认同步状态。
6. **日志**：`docker logs app-apisix`（路由/验签）、`docker logs app-postgrest`（SQL 错误）、`docker logs app-logto`（登录/consent）。
7. **退出码语义**：脚本 `exit $FAILED`；`make test-e2e` 直接透传该退出码，非 0 即存在失败用例。

## 与 verify-stack.sh 的关系

| 脚本 | 定位 | 失败时能回答的问题 |
| --- | --- | --- |
| `verify-stack.sh` | 组件级健康冒烟（10 项） | 哪个组件没起来（端口/进程/路由数） |
| `e2e-test.sh` | 业务级链路（8 阶段） | 整条业务链路是否可用（登录→鉴权→同步） |

部署流水线 `.github/workflows/deploy-gateway.yml` 中两者衔接：`deploy-gateway.sh` 部署并做健康检查 → `init-apisix-routes.sh` 初始化路由 → `e2e-test.sh`；`skip_tests=true` 可跳过路由初始化与 E2E。

> ✅ 2026-08-19：`deploy-gateway.yml` 已引用 Logto 版 `scripts/init-apisix-routes.sh`（Casdoor 时代 setup_apisix.sh 已删除）。

---

> 参考：[测试体系总览](测试体系总览.md) · [冒烟验证脚本](冒烟验证脚本.md) · [网关路由](../06-API参考/网关路由.md) · [Logto Webhook 接入](../06-API参考/LogtoWebhook接入.md) · [PostgREST 使用指南](../06-API参考/PostgREST使用指南.md)