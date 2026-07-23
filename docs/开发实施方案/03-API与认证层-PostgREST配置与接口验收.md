# 03 — API 与认证层：PostgREST 配置与接口验收

> **定位：** 配置 PostgREST 将数据库暴露为 RESTful API，联调认证和权限管理接口，验证 Swagger 自动文档。
> **前置依赖：** 02-数据库建模（所有 migration 已执行、验收通过）
> **产出物：** PostgREST 配置文件 + Swagger UI 可访问 + 所有接口已联调
> **预计耗时：** 2-4 小时

---

## 1. PostgREST 完整配置

### 1.1 postgrest.conf

```properties
# ==============================================================================
# PostgREST 服务配置
# ==============================================================================
server-host = "0.0.0.0"
server-port = 3000

# ==============================================================================
# 数据库连接
# ==============================================================================
db-uri = "postgresql://authenticator:${DB_PASSWORD:-postgres}@${DB_HOST:-127.0.0.1}:${DB_PORT:-5432}/app_db?sslmode=${SSL_MODE:-disable}"
db-schemas = "api_v1"
db-anon-role = "web_anon"

# ==============================================================================
# JWT 安全配置（RS256 非对称加密，Casdoor JWKS 公钥）
# ==============================================================================
# 从 Casdoor JWKS 端点获取公钥 JSON，通过环境变量注入
# 格式：{"keys": [{"kty":"RSA","kid":"...","use":"sig","alg":"RS256","n":"...","e":"AQAB"}]}
jwt-secret = "${JWKS_JSON}"
# 从 JWT 的 roles 数组取第一个角色作为 PostgREST 切换目标
jwt-role-claim-key = ".roles[0]"

# ==============================================================================
# 前置请求拦截：Token 黑名单检查
# ==============================================================================
db-pre-request = "api_v1.check_token_blacklist"

# ==============================================================================
# Swagger / OpenAPI 配置
# ==============================================================================
openapi-server-proxy-uri = "http://127.0.0.1:3000"

# ==============================================================================
# CORS 配置（开发环境）
# ==============================================================================
cors-origins = "http://localhost:5173,http://localhost:8080"
cors-headers = "Authorization,Content-Type,Prefer,Range,Range-Unit,If-None-Match"

# ==============================================================================
# 安全：不暴露 casbin_rule 和其他内部对象
# ==============================================================================
# db-extra-search-path 默认已包含 public，无需显式声明
# 如需引用其他 schema 中的扩展（如 PostGIS），可在此添加
```

### 1.2 环境变量说明

| 变量 | 说明 | 示例 |
|:---|:---|:---|
| `DB_PASSWORD` | authenticator 角色密码 | `postgres` |
| `DB_HOST` | 数据库主机地址 | `127.0.0.1`（开发）/ `pgbouncer`（生产） |
| `DB_PORT` | 数据库端口 | `5432`（开发）/ `6432`（生产 Pgbouncer） |
| `SSL_MODE` | SSL 模式 | `disable`（开发）/ `verify-full`（生产） |
| `JWKS_JSON` | Casdoor JWKS 公钥 JSON | `{"keys":[{"kty":"RSA",...}]}` |

### 1.3 创建 API Schema

```sql
-- 在数据库中创建 api_v1 schema
CREATE SCHEMA IF NOT EXISTS api_v1;

-- 创建访问视图（指向 public schema 中的表）
-- 注意：显式排除敏感列（如 password_hash）
CREATE OR REPLACE VIEW api_v1.sys_user AS
SELECT id, username, tenant_id, dept_id, email, phone, status, created_at, updated_at
FROM public.sys_user;

CREATE OR REPLACE VIEW api_v1.sys_role AS
SELECT id, role_code, role_name, tenant_id, is_active, created_at, updated_at
FROM public.sys_role;

CREATE OR REPLACE VIEW api_v1.sys_menu AS
SELECT id, parent_id, name, title, type, path, component, icon, sort_order, permission_code, is_active, created_at, updated_at
FROM public.sys_menu;

CREATE OR REPLACE VIEW api_v1.sys_api AS
SELECT id, path, method, api_name, tenant_id, is_active, created_at, updated_at
FROM public.sys_api;

CREATE OR REPLACE VIEW api_v1.sys_user_role AS
SELECT id, user_id, role_id, created_at
FROM public.sys_user_role;

CREATE OR REPLACE VIEW api_v1.sys_role_api AS
SELECT id, role_id, api_id, created_at
FROM public.sys_role_api;

CREATE OR REPLACE VIEW api_v1.sys_role_menu AS
SELECT id, role_id, menu_id, created_at
FROM public.sys_role_menu;

CREATE OR REPLACE VIEW api_v1.sys_user_role_request AS
SELECT id, user_id, role_id, status, reason, created_at, updated_at
FROM public.sys_user_role_request;

-- 将 RPC 函数迁移到 api_v1 schema（通过 ALTER FUNCTION 或重新创建）
-- 注意：以下函数需要在 api_v1 schema 中创建，PostgREST 才能暴露为 /rpc/* 端点
CREATE OR REPLACE FUNCTION api_v1.check_token_blacklist()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_jti TEXT;
    v_blacklisted BOOLEAN;
BEGIN
    -- 从 JWT claims 中提取 jti
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    IF v_jti IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1 FROM public.sys_token_blacklist
            WHERE jti = v_jti AND expired_at > now()
        ) INTO v_blacklisted;

        IF v_blacklisted THEN
            RAISE sqlstate 'PT401' USING
                message = 'Token has been revoked',
                detail = '{"status":401,"reason":"token_blacklisted"}';
        END IF;
    END IF;
END;
$$;

-- 包装函数：将 public schema 中的 RPC 函数暴露给 api_v1
CREATE OR REPLACE FUNCTION api_v1.user_login_sso(p_username TEXT, p_password TEXT)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.user_login_sso(p_username, p_password) $$;

CREATE OR REPLACE FUNCTION api_v1.refresh_token_rtr(p_old_rt TEXT)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.refresh_token_rtr(p_old_rt) $$;

CREATE OR REPLACE FUNCTION api_v1.kick_user(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.kick_user(p_user_id) $$;

CREATE OR REPLACE FUNCTION api_v1.get_user_menu()
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.get_user_menu() $$;

CREATE OR REPLACE FUNCTION api_v1.approve_role_request(p_request_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.approve_role_request(p_request_id) $$;

CREATE OR REPLACE FUNCTION api_v1.submit_role_request(p_role_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request_id UUID;
    v_user_id UUID;
BEGIN
    -- 从 JWT 中提取当前用户 ID
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'sub')::UUID;

    INSERT INTO public.sys_user_role_request (user_id, role_id, status, reason)
    VALUES (v_user_id, p_role_id, 'pending', p_reason)
    RETURNING id INTO v_request_id;

    RETURN v_request_id;
END;
$$;
```

### 1.4 角色权限授予

```sql
-- 允许 authenticator 角色切换到 web_anon（匿名访问）
GRANT web_anon TO authenticator;

-- 允许 authenticator 角色切换到 authenticated（已认证用户）
GRANT authenticated TO authenticator;

-- 允许 authenticator 在 api_v1 schema 中执行
GRANT USAGE ON SCHEMA api_v1 TO authenticator;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA api_v1 TO authenticator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1 TO authenticator;

-- 允许 authenticator 在 public schema 中执行 RPC 函数（用于包装函数内部调用）
GRANT USAGE ON SCHEMA public TO authenticator;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticator;

-- 允许 web_anon 在 api_v1 schema 中执行（匿名访问）
GRANT USAGE ON SCHEMA api_v1 TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO web_anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1 TO web_anon;

-- 允许 authenticated 角色在 api_v1 schema 中执行
GRANT USAGE ON SCHEMA api_v1 TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA api_v1 TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1 TO authenticated;
```

### 1.5 启动 PostgREST

```bash
# 方式一：直接运行配置文件
postgrest /path/to/postgrest.conf

# 方式二：Docker
docker run --rm -p 3000:3000 \
  -v /path/to/postgrest.conf:/etc/postgrest.conf \
  -e DB_PASSWORD=postgres \
  -e JWKS_JSON='{"keys":[...]}' \
  postgrest/postgrest:v14

# 方式三：Docker Compose（推荐，见 01-环境搭建）
```

验证：`curl http://localhost:3000/` 应返回 Swagger JSON。

---

## 2. JWT 认证链路

### 2.1 认证流程

```
用户 → APISIX (9080)
         │
         ├─ 未登录 → authz-casdoor 插件 → 重定向到 Casdoor 登录页
         │                                    │
         │                          ┌─────────┴──────────┐
         │                          │ GitHub / Google /   │
         │                          │ WeChat / LDAP / ... │
         │                          └─────────┬──────────┘
         │                                    │ 认证成功
         │                                    ▼
         │                              Casdoor 签发 JWT
         │                              (含 roles 数组, RS256)
         │                                    │
         └─ 已登录 ← JWT ←────────────────────┘
              │
              ├─ jwt-auth 插件 (RS256 验签，Casdoor JWKS 公钥)
              ├─ authz-casbin 插件 (API 鉴权)
              └─ → PostgREST → PG (RLS)
```

### 2.2 JWT Claims 映射

| JWT Claim | PostgREST 用途 | 说明 |
|:---|:---|:---|
| `sub` | 用户 ID | 用户唯一标识 |
| `roles[0]` | `jwt-role-claim-key` | PostgREST 切换到的 PG 角色 |
| `roles` | APISIX Casbin 鉴权 | 完整角色数组 |
| `tenant_id` | RLS 策略 | 多租户隔离 |
| `jti` | Token 黑名单检查 | Token 唯一标识 |
| `exp` | Token 过期验证 | 过期时间戳 |

### 2.3 Casdoor JWKS 获取

```bash
# 获取 Casdoor JWKS 公钥
curl https://your-casdoor-domain.com/.well-known/jwks

# 输出格式：
# {
#   "keys": [
#     {
#       "use": "sig",
#       "kty": "RSA",
#       "kid": "cert-built-in",
#       "alg": "RS256",
#       "n": "sInpb5E1_ym0f1Rf...",
#       "e": "AQAB",
#       "x5c": ["MIIE+TCCAuGgAwIBAgIDAeJAMA0G..."]
#     }
#   ]
# }
```

---

## 3. 接口联调

### 3.1 认证接口

#### 登录

```bash
# Linux/macOS
curl -v -X POST http://localhost:3000/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"p_username": "admin", "p_password": "admin123"}'

# Windows PowerShell
Invoke-RestMethod -Uri "http://localhost:3000/rpc/user_login_sso" -Method POST -ContentType "application/json" -Body '{"p_username": "admin", "p_password": "admin123"}'
```

**预期响应：**
- HTTP 200
- Body: `{"access_token": "eyJ...", "username": "admin"}`
- Response Header: `Set-Cookie: refresh_token=xxx; Path=/rpc/refresh_token; HttpOnly; Secure; SameSite=Strict; Max-Age=604800`

提取 `access_token` 的值，后续请求使用：

```bash
# Linux/macOS
export TOKEN="eyJ..."

# Windows PowerShell
$env:TOKEN = "eyJ..."
```

#### 刷新 Token

```bash
# Linux/macOS
curl -v -X POST http://localhost:3000/rpc/refresh_token_rtr \
  -H "Content-Type: application/json" \
  -d '{"p_old_rt": "RT_VALUE"}'

# Windows PowerShell
Invoke-RestMethod -Uri "http://localhost:3000/rpc/refresh_token_rtr" -Method POST -ContentType "application/json" -Body '{"p_old_rt": "RT_VALUE"}'
```

**预期响应：**
- HTTP 200
- Body: `{"access_token": "eyJ...(新)", "username": "admin"}`
- Response Header: 新的 `Set-Cookie`（新的 refresh_token）

#### 踢用户下线

```bash
# Linux/macOS
curl -X POST http://localhost:3000/rpc/kick_user \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"p_user_id": "目标用户UUID"}'

# Windows PowerShell
Invoke-RestMethod -Uri "http://localhost:3000/rpc/kick_user" -Method POST -ContentType "application/json" -Headers @{"Authorization"="Bearer $env:TOKEN"} -Body '{"p_user_id": "目标用户UUID"}'
```

**预期响应：**
- HTTP 200
- Body: `true`
- 被踢用户的旧 Token 立即失效（下一个请求返回 401）

### 3.2 权限管理 CRUD 接口

PostgREST 自动将表映射为 RESTful 接口，使用标准 HTTP 方法和路径：

#### 用户管理

```bash
# 查询用户列表（带过滤）
# Linux/macOS
curl "http://localhost:3000/sys_user?select=id,username,tenant_id&tenant_id=eq.tenant_default" \
  -H "Authorization: Bearer $TOKEN"

# Windows PowerShell
Invoke-RestMethod -Uri "http://localhost:3000/sys_user?select=id,username,tenant_id&tenant_id=eq.tenant_default" -Headers @{"Authorization"="Bearer $env:TOKEN"}

# 新增用户
curl -X POST http://localhost:3000/sys_user \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: return=representation" \
  -d '{"username": "new_user", "password_hash": "$2a$...", "tenant_id": "tenant_default"}'

# 更新用户
curl -X PATCH http://localhost:3000/sys_user?id=eq.USER_UUID \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"username": "updated_user"}'

# 删除用户（软删除，实际执行 UPDATE SET deleted_at = now()）
curl -X DELETE http://localhost:3000/sys_user?id=eq.USER_UUID \
  -H "Authorization: Bearer $TOKEN"
```

#### 角色管理

```bash
# 查询
curl "http://localhost:3000/sys_role" -H "Authorization: Bearer $TOKEN"

# 新增
curl -X POST http://localhost:3000/sys_role \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: return=representation" \
  -d '{"role_code": "role_custom", "role_name": "自定义角色"}'
```

#### 菜单管理

```bash
# 获取菜单列表
curl "http://localhost:3000/sys_menu?order=sort_order" -H "Authorization: Bearer $TOKEN"

# 新增菜单/按钮
curl -X POST http://localhost:3000/sys_menu \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: return=representation" \
  -d '{"name": "NewMenu", "title": "新菜单", "type": "MENU", "parent_id": "PARENT_UUID", "path": "new-path", "component": "views/new/index", "sort_order": 10}'
```

#### API 管理

```bash
# 新增 API 资源
curl -X POST http://localhost:3000/sys_api \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: return=representation" \
  -d '{"path": "/api/v1/orders/:id", "method": "GET", "api_name": "查询订单详情"}'
```

### 3.3 关联表接口

```bash
# 给用户分配角色
curl -X POST http://localhost:3000/sys_user_role \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"user_id": "USER_UUID", "role_id": "ROLE_UUID"}'

# 给角色分配 API 权限
curl -X POST http://localhost:3000/sys_role_api \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"role_id": "ROLE_UUID", "api_id": "API_UUID"}'

# 给角色分配菜单权限
curl -X POST http://localhost:3000/sys_role_menu \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"role_id": "ROLE_UUID", "menu_id": "MENU_UUID"}'
```

### 3.4 菜单树接口

```bash
# 获取当前用户的可访问菜单树
curl "http://localhost:3000/rpc/get_user_menu" \
  -H "Authorization: Bearer $TOKEN"
```

**预期响应格式（扁平数组，含 parent_id）：**

```json
[
  {
    "id": "...",
    "parent_id": null,
    "name": "System",
    "path": "/system",
    "component": "Layout",
    "meta": {"title": "系统管理", "icon": "setting"},
    "buttons": [],
    "sort_order": 1
  },
  {
    "id": "...",
    "parent_id": "...",
    "name": "UserList",
    "path": "user",
    "component": "system/user/index",
    "meta": {"title": "用户管理", "icon": "user"},
    "buttons": ["user:add", "user:edit", "user:delete"],
    "sort_order": 1
  }
]
```

> **说明：** 前端需根据 `parent_id` 自行构建嵌套树结构。

### 3.5 审批接口

```bash
# 提交角色申请
curl -X POST http://localhost:3000/rpc/submit_role_request \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"p_role_id": "ROLE_UUID", "p_reason": "申请理由"}'

# 审批通过
curl -X POST http://localhost:3000/rpc/approve_role_request \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"p_request_id": "REQUEST_UUID"}'
```

---

## 4. Swagger UI 验证

> **注意：** Swagger UI 的 Docker Compose 配置见 01-环境搭建文档。如果已在 01 中配置，则跳过本节。

### 4.1 验证项

- 浏览器打开 `http://localhost:8080`
- 所有表（sys_user、sys_role、sys_menu、sys_api）应出现在文档中
- 所有 RPC 函数（user_login_sso、refresh_token_rtr、kick_user、get_user_menu、approve_role_request、submit_role_request）应出现在文档中
- COMMENT ON 的中文注释应显示为字段和接口的描述
- 使用 "Try it out" 功能可在线测试接口

---

## 5. httpOnly Cookie 验证

```bash
# Linux/macOS
curl -v -X POST http://localhost:3000/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"p_username": "admin", "p_password": "admin123"}' 2>&1 | grep -i "set-cookie"

# Windows PowerShell
(Invoke-WebRequest -Uri "http://localhost:3000/rpc/user_login_sso" -Method POST -ContentType "application/json" -Body '{"p_username": "admin", "p_password": "admin123"}').Headers["Set-Cookie"]
```

应看到：
```
< Set-Cookie: refresh_token=xxx; Path=/rpc/refresh_token; HttpOnly; Secure; SameSite=Strict; Max-Age=604800
```

---

## 6. Token 黑名单拦截验证

```bash
# 1. 正常请求
curl http://localhost:3000/sys_user -H "Authorization: Bearer $TOKEN"
# → 200 OK

# 2. 踢下线
curl -X POST http://localhost:3000/rpc/kick_user \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"p_user_id": "USER_UUID"}'

# 3. 再次请求（应返回 401）
curl http://localhost:3000/sys_user -H "Authorization: Bearer $TOKEN"
# → 401 Unauthorized
```

---

## 7. RLS 多租户隔离验证

```bash
# 1. 使用租户 A 的 Token 查询用户
curl "http://localhost:3000/sys_user?select=id,username,tenant_id" \
  -H "Authorization: Bearer $TOKEN_TENANT_A"
# → 仅返回 tenant_id = 'tenant_a' 的用户

# 2. 使用租户 B 的 Token 查询用户
curl "http://localhost:3000/sys_user?select=id,username,tenant_id" \
  -H "Authorization: Bearer $TOKEN_TENANT_B"
# → 仅返回 tenant_id = 'tenant_b' 的用户

# 3. 尝试跨租户访问（应返回空结果或 403）
curl "http://localhost:3000/sys_user?tenant_id=eq.tenant_b" \
  -H "Authorization: Bearer $TOKEN_TENANT_A"
# → 空结果（RLS 过滤）
```

---

## 8. 验收清单

| # | 验收项 | 验证方法 | 通过 |
|:---:|:---|:---|:---:|
| A1 | PostgREST 启动并响应 | `curl http://localhost:3000/` → 返回 Swagger JSON | ☐ |
| A2 | 登录接口返回 AT + Set-Cookie | `curl -v POST /rpc/user_login_sso -d '{"p_username":"admin","p_password":"admin123"}'` → 200 + JSON + Set-Cookie 头 | ☐ |
| A3 | Swagger UI 可访问并展示所有接口 | 浏览器 http://localhost:8080 → 所有表/RPC 可见 | ☐ |
| A4 | COMMENT 注释正确显示 | Swagger UI 中字段描述为中文 | ☐ |
| A5 | CRUD 全部可用 | 对 sys_user/sys_role/sys_menu/sys_api 各执行一次增删改查 | ☐ |
| A6 | 关联表写入正常 | POST sys_user_role / sys_role_api / sys_role_menu 各一次 | ☐ |
| A7 | 菜单树接口返回正确 JSON | GET /rpc/get_user_menu → 含 parent_id 和 buttons 的扁平 JSON | ☐ |
| A8 | 踢下线生效 | kick_user → 被踢用户下一个请求 → 401 | ☐ |
| A9 | Token 刷新成功 | 用登录的 Cookie 调用 refresh_token_rtr → 新双 Token | ☐ |
| A10 | 未认证请求被拒绝 | 不带 Authorization 的请求 → 401 | ☐ |
| A11 | JWT RS256 公钥验签验证 | 篡改 JWT 签名后请求 → 401 | ☐ |
| A12 | RLS 多租户隔离验证 | 不同 tenant_id 的 Token 只能看本租户数据 | ☐ |
| A13 | Token 过期验证 | 等待 exp 过期后请求 → 401 | ☐ |
| A14 | CORS 跨域请求验证 | 从 http://localhost:5173 发起请求 → 成功 | ☐ |
| A15 | 字段级权限验证 | GET /sys_user?select=password_hash → 列不存在或空 | ☐ |

> **通过标准：** 15/15 项全部打勾。

---

## 9. 与 04-网关与同步器的衔接

本节说明 03 文档与 04-网关与同步器文档的衔接关系。

### 9.1 APISIX 路由配置

APISIX 路由配置（authz-casdoor / authz-casbin 插件参数）见 **04-网关与同步器** 文档。

### 9.2 Policy Syncer

Policy Syncer（Go）监听 pg_notify → 写入 APISIX Casbin 策略的实现见 **04-网关与同步器** 文档。

### 9.3 pg_graphql

pg_graphql 扩展已在 Pigsty 中安装，但本方案默认不启用 GraphQL 端点。如需启用，参考：

```sql
-- 启用 pg_graphql（可选）
CREATE EXTENSION IF NOT EXISTS pg_graphql;

-- GraphQL 端点通过 PostgREST 的 /graphql 路径访问
-- 注意：需配置 db-pre-request 进行权限过滤
```

---

## 10. 安全注意事项

1. **JWT 私钥管理**：私钥由 Casdoor 内部管理，不存储在 PG 或 PostgREST 配置中。
2. **Token 黑名单**：`check_token_blacklist` 函数在每次请求前执行，发现黑名单中的 jti 立即返回 401。
3. **CORS 白名单**：生产环境应严格限制 `cors-origins` 为前端域名。
4. **SSL/TLS**：生产环境应使用 `sslmode=verify-full` 并配置证书。
5. **密码哈希**：`password_hash` 列已通过视图排除，不会通过 API 暴露。
6. **RLS 策略**：所有业务表均启用 RLS，确保多租户数据隔离。
