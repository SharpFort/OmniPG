# 03-API与认证层 审查问题清单

> **审查对象：** `03-API与认证层-PostgREST配置与接口验收.md`（345行，11KB）
> **审查方法：** 逐节审查配置正确性，逐条验证 curl 命令可执行性，交叉校验 02 文档中的实际实现
> **审查日期：** 2026-07-07
> **关联上下文：** 02 审查中指出的 `generate_rs256_jwt()` 和 `sha256()` 未定义问题直接影响本文档的联调

---

## 🔴 阻塞级问题

### B1. RPC 函数的 Schema 归属错误 — PostgREST 无法暴露它们

> **02 文档中所有 RPC 函数**（`user_login_sso`、`refresh_token_rtr`、`kick_user`、`check_token_blacklist`、`get_user_menu`、`approve_role_request`）在创建时**未指定 schema**（如 `CREATE OR REPLACE FUNCTION check_token_blacklist()`），因此它们创建在 `public` schema 中。

但 03 文档配置 `db-schemas = "api_v1"`（第 25 行）—— PostgREST **只暴露 `db-schemas` 中 schema 的函数作为 RPC 端点**。

这意味着：
- `POST /rpc/user_login_sso` → **404 Not Found**（函数在 public，不在 api_v1）
- 所有其他 RPC 端点同样 404

- [B1-1] 有两种修复方案：
  - **方案 A**：将所有函数迁移到 `api_v1` schema 中（修改 02 的 migration）
  - **方案 B**：配置 `db-schemas = "api_v1, public"`（但会暴露 public 的所有表为 API）
  - **方案 C**：在 `api_v1` 中创建指向 public 函数的包装函数
  - 请选择方案并统一 02 和 03 文档。

- [B1-2] `check_token_blacklist` 的命名也在 01 和 03 之间不一致：
  - 01 Docker Compose：`PGRST_DB_PRE_REQUEST: api_v1.check_token_blacklist`
  - 03 配置（第 37 行）：`db-pre-request = "public.check_token_blacklist"`
  - 请统一。

### B2. PostgREST JWT Role 映射缺失 — `jwt-role-claim-key` 未配置

> 02 的 JWT payload 中角色是 `roles` 数组：`["super_admin", "role_editor"]`。
> PostgREST 默认从 JWT 的 `.role` claim 读取 PG role 名称（单值字符串），用于切换 `web_anon` → `authenticated`。

数组 `["super_admin"]` ≠ 字符串 `"super_admin"`。PostgREST 无法直接从数组类型的 claim 中提取角色。

- [B2-1] 是否有 `jwt-role-claim-key` 配置（如 `jwt-role-claim-key = ".roles[0]"`）？03 的 postgrest.conf 中没有此配置。
- [B2-2] PostgREST 的 role 映射机制需要 `authenticator` LOGIN 角色（如 01 审查 T2 所述）——JWT 中的 role 被用作 PostgREST 切换的目标 PG role。如果 JWT 的 `roles` 数组对应的是业务角色（如 `role_admin`），那么对应的 PG role 是什么？`authenticated`？`role_admin`（需要创建同名 PG role）？
- [B2-3] 如果 PostgREST 无法从 `roles` 数组自动映射角色，是否需要 `db-pre-request` 函数自行解析 JWT 并调用 `SET ROLE`？请说明认证链路的具体角色切换逻辑。

### B3. `get_user_menu` 的预期响应与实际实现不匹配

> 03 文档第 228-252 行展示了 `get_user_menu` 的**预期响应**：嵌套树结构（含 `children` 字段）。

但 02 文档中 `get_user_menu()` 的实际实现（第 556-576 行）返回的是**扁平数组**（每个元素带 `parent_id` 和 `buttons`，但没有 `children` 字段）。

- [B3-1] 前端需要树结构（03 的预期响应），后端返回扁平数组（02 的实现）。这个差距谁来填？修改 02 的 SQL 构造嵌套 JSON？还是前端自行重建树？
- [B3-2] 如果是前端重建树，03 文档的预期响应应更新为扁平格式以避免误导。

---

## 🟡 重要级问题

### M1. `db-uri` 端口与 01 不一致

> 03 第 24 行：`db-uri = "...@127.0.0.1:5433/..."`（对应 HAProxy VIP 端口）
> 01 端口规划表：5432 = PG 直连，5433 = HAProxy 写端口

但 01 的 Docker Compose **没有部署 HAProxy**。PG 只暴露在 5432。

- [M1-1] 开发环境（Docker Compose）中，`db-uri` 应该用 5432 还是 5433？如果用 5433，会因为端口不通导致 PostgREST 无法启动。
- [M1-2] 是否应该有两个版本的 postgrest.conf（dev 用 5432，prod 用 5433 HAProxy VIP）？

### M2. `submit_role_request` RPC 不存在

> 03 第 258 行引用 `POST /rpc/submit_role_request`，但 02 的 9 个 migration 中**没有定义这个函数**。

- [M2-1] 02 中只有 `sys_user_role_request` 表和 `approve_role_request` 函数。`submit_role_request` 是遗漏了，还是计划用 PostgREST 的标准 INSERT（`POST /sys_user_role_request`）替代？
- [M2-2] 如果使用标准 INSERT，不需要单独的函数——直接从 03 中移除对这个 RPC 的引用。

### M3. `sslrootcert` 路径是占位符

> 第 24 行：`sslrootcert=/path/to/ca.crt` + `sslmode=verify-full`

- [M3-1] 开发环境（Docker Compose）中没有配置 TLS/SSL 证书。`sslmode=verify-full` 会导致 PostgREST 无法连接 PG。是否应该提供两套配置：
  - dev：`sslmode=disable`
  - prod：`sslmode=verify-full&sslrootcert=/etc/ssl/ca.crt`

### M4. `api_v1` 视图绕过 RLS — 安全问题

> 第 57-64 行创建 `api_v1` 视图：`CREATE OR REPLACE VIEW api_v1.sys_user AS SELECT * FROM public.sys_user`

- [M4-1] 这些视图的 owner 是 `app_owner`（超级用户），PostgREST 通过 `web_anon`/`authenticated` 角色访问这些视图时，RLS 策略基于 `current_tenant_id()` 从 JWT 中提取租户 ID。但如果 JWT 中没有有效的 role 导致 PostgREST 切换角色失败，请求会以什么身份执行？
- [M4-2] 敏感表（如 `sys_secret`、`sys_token_blacklist`、`sys_user_session`）是否也在 `api_v1` 中暴露？从第 57-64 行的视图列表看，只暴露了 8 张业务表，但需要在文档中**明确声明不暴露哪些表**以及原因。

### M5. JWKS 公钥配置需要具体说明

> 第 32 行：`jwt-secret = "{\"keys\": [...]}"` — `n` 字段是占位符 `YOUR_RSA_PUBLIC_KEY_MODULUS_BASE64URL`

- [M5-1] 公钥从哪里生成？如果私钥由 `generate_rs256_jwt()` 内部使用（可能是 plpython3u 调用 PyJWT），那么对应的公钥如何导出并填入此配置？
- [M5-2] 密钥轮换时，JWKS 支持多个 key（通过 `kid` 区分）。当前配置只有 `key-v1` 一个 key。密钥轮换流程中的 JWKS 更新策略是什么？

### M6. 03 文档与 01 Docker Compose 中 PostgREST 配置不一致

| 配置项 | 01 Docker Compose | 03 postgrest.conf | 是否一致 |
|:---|:---|:---|:---:|
| `db-uri` | `postgres://app_owner:***@postgres:5432/app_db` | `...@127.0.0.1:5433/...` | ❌ 主机+端口都不同 |
| `db-schemas` | `api_v1` | `api_v1` | ✅ |
| `db-anon-role` | `web_anon` | `web_anon` | ✅ |
| `jwt-secret` | `${JWT_SECRET}` (环境变量) | JWKS JSON 硬编码 | ⚠️ 格式不同 |
| `db-pre-request` | `api_v1.check_token_blacklist` | `public.check_token_blacklist` | ❌ Schema 不同 |

- [M6-1] 应该以哪个为准？01 Docker Compose 是可直接启动的，03 的配置文件是"理想生产配置"。两者需要声明差异或合并为多环境配置。

---

## 🟢 增强级问题

### E1. curl 命令使用 Linux/macOS 语法

- [E1-1] `export TOKEN="..."`（第 99 行）在 Windows PowerShell 中是 `$env:TOKEN = "..."`。
- [E1-2] `grep -i "set-cookie"`（第 300 行）在 PowerShell 中是 `Select-String "set-cookie"`。
- [E1-3] 所有 curl 示例中 `Authorization: Bearer ***` 缺少闭合引号（如第 121、139、144 行等）—— `-H "Authorization: Bearer ***` 缺少结尾的 `"`。
- [E1-4] 文档应该增加 Windows PowerShell 版本的命令，或者统一使用 PowerShell 语法。

### E2. Swagger UI 配置重复

> 03 第 274-282 行再次定义了 Swagger UI 的 Docker Compose 片段，但 01 文档中已经有完全相同的配置。如果两份文档独立执行，会导致重复配置。

- [E2-1] 建议在 03 中引用 01 的配置而非重复定义，或明确说明"如果已在 01 中配置则跳过"。

### E3. api_v1 视图未处理字段权限

- [E3-1] `SELECT *` 视图暴露了所有列——包括敏感字段如 `sys_user.password_hash`。前端查询用户列表时是否会在响应中看到密码哈希？建议：
  - 要么用列白名单代替 `SELECT *`
  - 要么依赖 PostgREST 的列级权限（GRANT SELECT(col1, col2) ON ...）

### E4. 缺少 `authenticator` 角色的权限授予

- [E4-1] 01 审查 T2 提到缺少 `authenticator` LOGIN 角色。在 03 中这个角色依然不存在。如果 02 的 RPC 函数需要以 `authenticated` 角色执行，那么需要：
  ```sql
  GRANT USAGE ON SCHEMA api_v1 TO authenticated;
  GRANT EXECUTE ON FUNCTION api_v1.user_login_sso TO authenticated;
  -- （以及其他函数和表的权限）
  ```
  这些 GRANT 语句应该在哪一个 migration 中？01？02？03？

---

## 与 02 审查的交叉依赖

| 02 问题 | 03 影响 |
|:---|:---|
| 🔴 `generate_rs256_jwt()` 未定义 | 登录/刷新接口必报错（A2/A9 验收失败） |
| 🔴 `sha256()` 未定义 | 同上 |
| 🔴 RLS 用 `role` 而非 `roles` | RLS 超级管理员豁免失效（数据隔离可能出问题） |
| 🟡 `get_user_menu()` 返回扁平数组 | 03 预期响应展示嵌套树，不匹配（B3） |
| 🟡 `sys_api` 缺唯一约束 | seed 数据重入会重复，但不影响 03 联调 |

---

## 总结概况

| 类别 | 数量 | 最关键的 3 个问题 |
|:---|:---:|:---|
| 🔴 阻塞级 | 3 | ① RPC 函数在 public 但 PostgREST 暴露 api_v1 ② JWT role 映射缺 jwt-role-claim-key ③ get_user_menu 响应格式与实际不匹配 |
| 🟡 重要级 | 6 | 端口不一致、submit_role_request 不存在、ssl 配置、视图安全、JWKS 密钥、01/03 配置冲突 |
| 🟢 增强级 | 4 | curl 语法、Swagger 重复、视图字段、权限授予 |
| **合计** | **13** | |
