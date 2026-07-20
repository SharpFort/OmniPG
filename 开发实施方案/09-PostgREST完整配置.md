# 09 — PostgREST 完整配置

> **定位：** 提供完整的 PostgREST 配置文件、环境变量方案、启动脚本和接口验收方法。Agent 按本文档可将 PostgREST 服务正确接入 APISIX 网关和 Casdoor 认证体系。
> **前置依赖：** 01-环境搭建（Docker 就绪）、07-Database-Migrations（数据库已部署）
> **产出物：** 完整的 `postgrest.conf` + Docker 启动方式 + 接口验收通过
> **预计耗时：** 30-60 分钟

---

## 1. PostgREST 完整配置文件

**文件：** `postgrest/postgrest.conf`

```ini
# ==============================================================================
# PostgREST 配置文件（开发环境）
# ==============================================================================

# 数据库连接 URI（通过 Pgbouncer 连接）
# 注意：开发环境使用明码，生产环境使用 .env 或 Docker Secrets
db-uri = "postgres://authenticator:***@pgbouncer:6432/app_db?sslmode=disable"

# 暴露的 Schema（仅 api_v1，不暴露 public schema）
db-schemas = "api_v1"

# 额外的搜索路径（用于调用 public schema 中的辅助函数）
db-extra-search-path = "public"

# 匿名角色（未认证用户切换到此角色）
db-anon-role = "web_anon"

# JWT 验证密钥
# 开发环境：使用 Casdoor JWKS（需从 Casdoor 管理面板获取）
# 生产环境：使用 Casdoor JWKS JSON
# [修复 P1-4] 变量名统一为 JWKS_JSON（.env.example 中已删除废弃的 JWK_JSON）
jwt-secret = "$(JWKS_JSON)"

# 请求前拦截：检查 Token 黑名单
db-pre-request = "api_v1.check_token_blacklist"

# 服务端配置
server-host = "0.0.0.0"
server-port = 3000

# OpenAPI 代理 URI（用于 Swagger UI）
openapi-server-proxy-uri = "http://localhost:3000"

# 聚合函数允许（支持 count、sum 等）
db-aggregates-enabled = true

# 最大返回行数（防止全量数据查询导致 OOM）
max-rows = 1000

# 错误级别（开发环境使用 extended 获取详细信息）
pre-error-extended = true

# 事务结束方式
db-tx-end = "commit"

# 是否隐藏内部字段（false 时暴露所有字段）
hide-non-invariant = false

# 预请求 Hook 的超时时间（毫秒）
pre-request-timeout = 5000

# [增强 P2-2] 连接池配置（通过 Pgbouncer 时无需额外配置，注释供参考）
# db-pool = 10
# db-pool-acq-useconds = 5000

# [增强 P2-1] 日志级别（v14.14 推荐使用 log-level 替代 pre-error-extended）
log-level = warn
# db-plan-enabled = true  # 开发环境开启 EXPLAIN 分析

# [修复 P1-5] PostgREST 不直接面向浏览器，由 APISIX 网关处理 CORS
# 直接暴露 PostgREST 端口（3000）时启用，否则应注释掉避免重复 CORS 头
# cors-origins = "http://localhost:5173"
# 生产环境：PostgREST 仅在内网通过 APISIX 访问，无需 CORS
cors-origins = ""

# 如需直接访问（开发调试），取消注释：
# cors-origins = "http://localhost:5173"

# JWT 角色 Claim 键名
# [修复 P1-2] Casdoor 默认在 JWT 中放置 roles 数组
# "roles": ["super_admin", "role_admin"] → roles[0] 提取 "super_admin"
# 注意：02-schemas.sql 中的 PG 角色必须与 roles 数组中的值一一对应
jwt-role-claim-key = "roles[0]"

# ⚠️ 依赖：02-schemas.sql 中必须创建以下 PG 角色（与 sys_role.role_code 一致）：
# super_admin, role_admin, role_editor, role_guest
# 任何在 JWT roles 数组中出现的值都必须对应一个 PG 角色，否则认证失败
```

---

## 2. Docker 启动方式

### 2.1 Docker Compose 配置（已包含在 08 文档中）

PostgREST 在 `docker-compose.yml` 中作为一个服务定义。关键配置：

```yaml
postgrest:
  image: postgrest/postgrest:v14.14
  container_name: app-postgrest
  restart: unless-stopped
  environment:
    PGRST_DB_URI: postgres://authenticator:***@pgbouncer:6432/app_db?sslmode=disable
    PGRST_DB_SCHEMAS: "api_v1"
    PGRST_DB_ANON_ROLE: web_anon
    PGRST_DB_EXTRA_SEARCH_PATH: "public"
    PGRST_JWT_SECRET: "${JWKS_JSON}"
    PGRST_DB_PRE_REQUEST: "api_v1.check_token_blacklist"
    PGRST_OPENAPI_SERVER_PROXY_URI: "http://localhost:3000"
    PGRST_SERVER_PORT: "3000"
    PGRST_DB_AGGREGATES_ENABLED: "true"
    PGRST_MAX_ROWS: "1000"
    PGRST_PRE_ERROR_EXTENDED: "true"
    PGRST_DB_TX_END: "commit"
  ports:
    - "${PGRST_PORT:-3000}:3000"
  networks:
    - app-net
  depends_on:
    pgbouncer:
      condition: service_started
```

### 2.2 Docker Run 方式（备用）

```powershell
# 开发环境：验证用
docker run --rm -it `
  --name app-postgrest `
  -p 3000:3000 `
  -e PGRST_DB_URI="postgres://authenticator:***@host.docker.internal:5433/app_db?sslmode=disable" `
  -e PGRST_DB_SCHEMAS="api_v1" `
  -e PGRST_DB_ANON_ROLE="web_anon" `
  -e PGRST_JWT_SECRET="***" `
  -e PGRST_DB_PRE_REQUEST="api_v1.check_token_blacklist" `
  -e PGRST_OPENAPI_SERVER_PROXY_URI="http://localhost:3000" `
  -e PGRST_MAX_ROWS="1000" `
  postgrest/postgrest:v14.14
```

### 2.3 本地运行方式（调试用）

```bash
# 需要先安装 PostgREST
brew install postgrest  # macOS
# 或下载二进制

# 导出环境变量
export PGRST_DB_URI="postgres://authenticator:***@localhost:5433/app_db?sslmode=disable"
export PGRST_DB_SCHEMAS="api_v1"
export PGRST_JWT_SECRET='{"keys":[...]}'

# 运行
postgrest postgrest.conf
```

---

## 3. JWT 配置详解

### 3.1 开发环境 JWT（临时方案）

在开发环境中，PostgREST 需要验证 JWT 签名。由于生产环境依赖 Casdoor RS256 签发，开发环境可使用以下简化方案：

#### 方案 A：从 Casdoor JWKS 端点获取公钥（推荐）

07 migration 已移除 `plpython3u` 内签方案，JWT 签发统一委托 **Casdoor**。Casdoor 启动后自动生成 RS256 证书并暴露 JWKS 端点。

**获取 JWKS 的方式：**

```powershell
# 从 Casdoor 容器获取 JWKS（Casdoor v3.108.0+）
 ConvertFrom-Json

# 或从 Casdoor 管理面板 (http://localhost:8000) → Certificates → 复制公钥

# 或从 Casdoor JWKS 端点实时获取
Invoke-WebRequest -Uri "http://localhost:8000/.well-known/jwks.json"
```

**PostgREST 配置中的 JWKS：**
```ini
jwt-secret = {"keys":[{"kty":"RSA","kid":"cert-built-in","use":"sig","alg":"RS256","n":"...从Casdoor获取...","e":"AQAB"}]}
```

#### 方案 B：开发环境 HS256 对称密钥（仅用于快速验证）

```ini
# [修复 P0-1] 开发环境：使用预生成的 HS256 对称密钥
jwt-secret = {"keys":[{"kty":"oct","kid":"dev-hs256","alg":"HS256","k":"c2VjcmV0X2RldmVsb3BtZW50X2tleV9hdF9sZWFzdF9zZXZlbl9jaGFyYWN0ZXJzIQ=="}]}
```

> **⚠️ 注意：** 方案 B 仅用于开发快速验证，不支持 Casdoor RS256 签发的 JWT。团队开发时建议统一使用方案 A。

### 3.2 生产环境 JWT（Casdoor）

生产环境中 PostgREST 的 JWT 验证由 Casdoor 的 JWKS 端点提供公钥：

```
PGRST_JWT_SECRET={"keys":[{"kty":"RSA","kid":"cert-built-in","use":"sig","alg":"RS256","n":"...","e":"AQAB"}]}
```

JWKS 获取方式：
```
GET https://your-casdoor-domain.com/.well-known/jwks
```

---

## 4. db-pre-request 安全拦截

### 4.1 拦截原理

PostgREST 在执行任何 API 请求前，先调用 `db-pre-request` 指定的函数。该函数如果抛出异常（`RAISE EXCEPTION`），PostgREST 会返回错误响应。

### 4.2 check_token_blacklist 实现

> **⚠️ 依赖：** 此函数依赖 07 Migration 005 在 `public` schema 创建 `check_token_blacklist()`，以及 08 `02-schemas.sql` 中的 `api_v1.check_token_blacklist` 包装函数。请确保 07 migrations 和 08 初始化脚本已正确执行。

`public.check_token_blacklist()` 的实现已在 07 Migration 005 中创建。

```sql
CREATE OR REPLACE FUNCTION check_token_blacklist()
RETURNS void AS $$
DECLARE
    v_jti varchar;
BEGIN
    -- 从请求上下文中提取 JWT 的 jti
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    -- [修复 P1-3] 仅拦截未过期的黑名单 jti（过期 jti 自动失效）
    IF v_jti IS DISTINCT FROM NULL AND EXISTS (
        SELECT 1 FROM sys_token_blacklist WHERE jti = v_jti AND expired_at > now()
    ) THEN
        RAISE EXCEPTION 'Token Has Been Revoked' USING ERRCODE = 'P0001';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

> **⚠️ 依赖：** 此修改需同步更新 07 Migration 005 中的函数定义，并添加 `cleanup_expired_tokens()` 清理函数（07 P1-8）。

### 4.3 异常码映射

 场景 |
:---|
 Token 吊销、无效凭证 |
 安全违规、账户禁用 |
 配置错误（密钥缺失） |

---

## 5. API 接口验收

### 5.1 OpenAPI 端点

```powershell
# 验证 PostgREST 响应
$response = Invoke-WebRequest -Uri "http://localhost:3000/" -UseBasicParsing
# 响应：OpenAPI JSON（包含所有表和函数的定义）
```

### 5.2 未认证请求（应返回 403/401）

```powershell
# 未授权访问 sys_user
Invoke-WebRequest -Uri "http://localhost:3000/sys_user" -UseBasicParsing
# 预期：401 Unauthorized（web_anon 角色无 SELECT 权限）
```

### 5.3 登录接口

```powershell
# 方式一：PowerShell
$body = '{"p_username":"admin","p_password":"admin123"}'
$response = Invoke-RestMethod -Uri "http://localhost:3000/rpc/user_login_sso" -Method POST -ContentType "application/json" -Body $body
$token = $response.access_token
Write-Host "Token: ${token:0:20}..."

# 方式二：curl
 jq -r '.access_token')
```

### 5.4 使用 Token 访问受保护资源

```powershell
# 方式一：PowerShell
$response = Invoke-RestMethod -Uri "http://localhost:3000/sys_user" -Headers @{"Authorization"="Bearer $token"}
# 预期：200 + 用户 JSON 数组

# 方式二：curl
# curl -H "Authorization: Bearer ***" http://localhost:3000/sys_user
```

### 5.5 Token 刷新

```powershell
# 注意：PostgREST 通过 response.headers 发送 Set-Cookie
# 开发环境直接使用 RT 明文调用

$refreshBody = '{"p_old_rt":"' + $refreshToken + '"}'
$response = Invoke-RestMethod -Uri "http://localhost:3000/rpc/refresh_token_rtr" -Method POST -ContentType "application/json" -Body $refreshBody
```

### 5.6 菜单接口

```powershell
$menu = Invoke-RestMethod -Uri "http://localhost:3000/rpc/get_user_menu" -Headers @{"Authorization"="Bearer $token"}
# 预期：菜单树 JSON（含按钮权限）
```

### 5.7 PostgREST 过滤器示例

```powershell
# 查询用户列表（带过滤）
# 注意：PostgREST 使用特殊查询语法：?column=operator.value
Invoke-RestMethod -Uri "http://localhost:3000/sys_user?select=id,username&tenant_id=eq.tenant_default" -Headers @{"Authorization"="Bearer $token"}

# 模糊搜索
# username=like.*admin*

# 范围查询
# id=gt.10&id=lt.50

# 包含查询
# id=in.(1,2,3)

# 排序 & 分页
# ?order=created_at.desc&limit=20&offset=0
```

---

## 6. PostgREST 常见查询语法

### 6.1 操作符

 示例 |
:---|
 `?id=eq.1` |
 `?id=neq.5` |
 `?age=gt.18` |
 `?age=gte.18` |
 `?age=lt.65` |
 `?age=lte.65` |
 `?name=like.*John*` |
 `?name=ilike.*john*` |
 `?id=in.(1,2,3)` |
 `?deleted_at=is.null` |
 `?id=not.eq.1` |

### 6.2 水平过滤（Horizontal Filtering）

```
# 多条件 AND
?tenant_id=eq.tenant_default&is_active=eq.true

# 列选择
?id,username,email

# 计数
Prefer: count=exact
```

### 6.3 垂直过滤（Embedding）

```
# 嵌入关联表（PostgREST 自动识别外键）
# 假设 sys_user_role 有外键关联：
?select=*,sys_user_role(*sys_role(*))
```

### 6.4 Upsert + 返回结果

```
# 新增（返回新增的行）
Invoke-RestMethod -Uri "http://localhost:3000/sys_user" -Method POST `
  -Headers @{"Authorization"="Bearer $token";"Prefer"="return=representation"} `
  -ContentType "application/json" `
  -Body '{"username":"newuser","password_hash":"...","tenant_id":"tenant_default"}'
```

---

## 7. 性能优化

### 7.1 最常用查询的索引建议

```powershell
# 在 psql 中执行
docker exec -it app-postgres psql -U app_owner -d app_db
```

```sql
-- 按用户名 + 租户查询（登录时频繁调用）
CREATE INDEX CONCURRENTLY idx_user_username_tenant 
ON sys_user(username, tenant_id);

-- 按 session hash 查询（刷新时频繁调用）
CREATE INDEX CONCURRENTLY idx_session_hash_used 
ON sys_user_session(refresh_token_hash, is_used) 
WHERE is_used = FALSE;

-- 按过期时间查询（清理任务）
CREATE INDEX CONCURRENTLY idx_session_expiry_active 
ON sys_user_session(expired_at) 
WHERE is_used = FALSE;
```

---

## 8. 运维命令

### 8.1 查看日志

```powershell
# Docker
docker logs -f app-postgrest

# Pigsty
journalctl -u postgrest -f

# 本地
tail -f /var/log/postgrest.log
```

### 8.2 重载配置（无中断）

```powershell
# 启动方式重载（非零停机，PostgREST 支持热重载）
docker kill -s HUP app-postgrest
```

### 8.3 健康检查

```powershell
# 简单检查
Invoke-WebRequest -Uri "http://localhost:3000/" -UseBasicParsing

# OpenAPI 深度检查
# 返回 JSON 应包含 "paths" 字段
```

### 8.4 统计信息

```powershell
# 查看所有暴露的表/视图
 keys'
```

---

## 9. 配置文件清单

在 `源码/postgrest/` 目录下创建以下文件：

 是否必需 |
:---|
 否（可用环境变量替代） |

> **说明：** Docker Compose 配置已使用环境变量方式传递 PostgREST 配置。如果本地运行 PostgREST 二进制（非 Docker），可使用 `postgrest.conf`。

---

## 10. 下一步

完成本文档后，Agent 可以：

1. ✅ 执行 `04-网关与同步器.md` 中的 APISIX 配置
2. ✅ 启动 `Policy Syncer`
3. ✅ 执行 `05-前端Admin.md` 中的 ART-D Pro 集成

---

**✅ 阶段完成标志：** PostgREST 可正确响应 API 请求，Token 认证通过，db-pre-request 拦截正常。
**➡ 下一阶段：** `04-网关与同步器-APISIX配置与PolicySyncer.md` → APISIX 路由配置。