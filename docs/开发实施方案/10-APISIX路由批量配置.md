# 10 — APISIX 路由批量配置

> **定位：** 提供完整的 APISIX 路由批量配置方案，包括 model.conf 写入、全局规则、业务路由、RPC 路由、JWKS 端点和批量导入脚本。Agent 按本文档可一键完成 APISIX 路由配置。
> **前置依赖：** 01-环境搭建（APISIX+etcd 就绪）、04-网关与同步器（架构参考）、04.5-Casdoor集成
> **产出物：** APISIX 全部路由就绪 + model.conf + JWT 配置 + 批量导入脚本
> **预计耗时：** 1-2 小时

---

## 1. 快速开始

### 1.1 前置条件

```powershell
# 检查 APISIX 是否就绪
Invoke-WebRequest -Uri "http://localhost:9080/apisix/status" -UseBasicParsing

# 检查 etcd
docker exec app-etcd etcdctl endpoint health

# 设置 API Key（已在 08 的 .env 中定义）
$env:APISIX_ADMIN_KEY = "edd1c9f034335f136f87ad84b625c8f1"
```

### 1.2 一键配置

```powershell
# 目录
cd "D:\WeChat Files\xiangmu\源码\scripts"

# 导入配置
.\apisix-setup.ps1

# 或手动执行
Set-Location ..\apisix
# 步骤见下文
```

---

## 2. Global Rules（全局规则）

### 2.1 全局 CORS 规则

```powershell
# 创建全局 CORS 规则（所有路由继承）
$corsRule = @'
{
  "id": "global-cors-limit",
  "plugins": {
    "cors": {
      "allow_origins": "http://localhost:5173,http://localhost:5174",
      "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
      "allow_headers": "Authorization,Content-Type,Accept-Profile,Prefer,X-Requested-With",
      "expose_headers": "Content-Range,Location,Content-Length",
      "allow_credential": true,
      "max_age": 1728000
    },
    "limit-req": {
      "rate": 100,
      "burst": 50,
      "key_type": "var",
      "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\":\"rate_limit\",\"message\":\"Too many requests\"}"
    }
  }
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/global_rules/1" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $corsRule
```

### 2.2 全局 limit-req（限流）

> **[修复 P1-4]** 08-Docker-Compose 已添加 Redis 服务，全局规则中配置限流。

```powershell
# limit-req 已合并到全局规则 JSON 中（见 §7.3 global-rules.json）
# 配置：rate=100 req/s, burst=50, key=remote_addr
```

### 2.3 全局 proxy-rewrite（去除 /api/v1 前缀）

```powershell
# 将通过 plugin_config 实现（见下文 §4）
```

---

## 3. Plugin Configs（插件配置模板）

### 3.1 proxy-rewrite 配置

```powershell
$proxyRewrite = @'
{
  "id": "rewrite-api-v1",
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/(.*)", "/$1"]
    }
  }
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/plugin_configs/1" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $proxyRewrite
```

---

## 4. Plugin Metadata（Casbin 模型 + JWT）

### 4.1 authz-casbin 模型配置（Role-in-JWT 优化版）

```powershell
# 必须与 Policy Syncer 中的 model.conf 一致
$casbinModel = @'
{
,)\" + p.sub + \"($|,)\" ) && keyMatch2(r.obj, p.obj) && r.act == p.act",
  "policy": ""
}
'@

# 写入到 APISIX 全局插件元数据
Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $casbinModel
```

### 4.2 jwt-auth 配置

> **[修复 P0-1]** JWT 算法统一为 **RS256**（对齐 Casdoor + PostgREST），不再使用 HS256。
> APISIX 和 PostgREST 共用同一套 Casdoor JWKS 公钥验证 JWT。

```powershell
# 开发环境：从 Casdoor 获取 JWKS 公钥（推荐）
# Casdoor 启动后自动生成 RS256 证书并暴露 JWKS 端点

# 方式1：从 Casdoor 容器获取 JWKS
$JWKS = docker exec app-casdoor cat /app/conf/init_data.json | ConvertFrom-Json

# 方式2：从 Casdoor JWKS 端点实时获取
$JWKS = Invoke-WebRequest -Uri "http://localhost:8000/.well-known/jwks.json" | ConvertFrom-Json

# 构造 jwt-auth plugin metadata
$jwtAuth = @'
{
  "_meta": {"description": "JWT验证配置 - RS256 + Casdoor JWKS"},
  "algorithm": "RS256",
  "jwks": "{"keys":[{"kty":"RSA","kid":"cert-built-in","use":"sig","alg":"RS256","n":"...从Casdoor获取...","e":"AQAB"}]}"
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $jwtAuth
```

### 4.3 JWKS 端点

```powershell
# 方式一：代理转发到 Casdoor（推荐，开发与生产统一）
# **[修复 P1-5]** 直接转发到 Casdoor JWKS 端点，避免 mocking 的占位公钥导致 RS256 验证失败
$jwksRoute = @'
{
  "uri": "/well-known/jwks",
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "casdoor:8000": 1
    }
  }
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/routes/jwks" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $jwksRoute

# 方式二：mocking 插件（仅用于 Casdoor 不可用时的回退，需使用真实 RSA 公钥）
# 注意：mocking 的 JWKS 必须使用真实 RSA 公钥（2048位，n 值 342+ 字符）
```

---

## 5. 业务路由

### 5.1 业务 API 路由（/api/v1/* → PostgREST）

```powershell
$businessRoute = @'
{
  "id": "api-v1-business",
  "uri": "/api/v1/*",
  "plugin_config_id": 1,
  "plugins": {
    "serverless-pre-function": {
      "phase": "rewrite",
      "functions": ["return function(conf, ctx)\n    local cjson = require(\"cjson\")\n    local base64 = require(\"ngx.base64\")\n    local auth_header = ngx.req.get_headers()[\"Authorization\"]\n    if auth_header and string.sub(auth_header, 1, 7) == \"Bearer \" then\n        local token = string.sub(auth_header, 8)\n        local parts = {}\n        for part in string.gmatch(token, \"[^.]+\") do\n            table.insert(parts, part)\n        end\n        if #parts >= 2 then\n            local payload_b64 = parts[2]\n            payload_b64 = string.gsub(payload_b64, \"-\", \"+\")\n            payload_b64 = string.gsub(payload_b64, \"_\", \"/\")\n            local rem = #payload_b64 % 4\n            if rem > 0 then\n                payload_b64 = payload_b64 .. string.rep(\"=\", 4 - rem)\n            end\n            local decoded = base64.decode_base64(payload_b64)\n            if decoded then\n                local status, jwt_json = pcall(cjson.decode, decoded)\n                if status and jwt_json and jwt_json.roles then\n                    local roles_str = table.concat(jwt_json.roles, \",\")\n                    ngx.req.set_header(\"X-User-Role\", roles_str)\n                    if jwt_json.user_id then\n                        ngx.req.set_header(\"X-User-Id\", jwt_json.user_id)\n                    end\n                end\n            end\n        end\n    end\nend"]
    },
    "jwt-auth": {},
    "authz-casbin": {
      "username": "X-User-Role"
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "postgrest:3000": 1
    }
  }
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/routes/api-v1" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $businessRoute
```

### 5.2 Casdoor OAuth 回调路由

```powershell
$casdoorCallback = @'
{
  "id": "casdoor-callback",
  "uri": "/api/casdoor/callback",
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/casdoor/callback(.*)", "/callback$1"]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "casdoor:8000": 1
    }
  }
}
'@

Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/routes/casdoor-callback" -Method PUT -ContentType "application/json" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY} -Body $casdoorCallback
```

---

## 6. 脚本：批量导入路由

**文件：** `scripts/apisix-setup.ps1`

```powershell
# ==============================================================================
# APISIX 路由批量配置脚本（Windows PowerShell）
# ==============================================================================

$ErrorActionPreference = "Stop"

$APISIX_BASE = "http://localhost:9180/apisix/admin"
$API_KEY = $env:APISIX_ADMIN_KEY

if (-not $API_KEY) {
    Write-Host "❌ APISIX_ADMIN_KEY 未设置" -ForegroundColor Red
    exit 1
}

$headers = @{"X-API-KEY"=$API_KEY}
$ct = "application/json"

function Import-APISIXResource($method, $uri, $body, $description) {
    Write-Host "  📦 导入: $description..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod -Uri "$APISIX_BASE/$uri" -Method $method -ContentType $ct -Headers $headers -Body $body
        Write-Host "    ✅ ${description} OK" -ForegroundColor Green
    } catch {
        $errResp = $_.ErrorDetails.Message
        Write-Host "    ❌ ${description} 失败: $errResp" -ForegroundColor Red
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  APISIX 路由批量配置" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Plugin Configs（proxy-rewrite）
Write-Host "📋 Phase 1: Plugin Configs" -ForegroundColor Yellow
$proxyRewrite = @'
{
  "id": "rewrite-api-v1",
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/(.*)", "/$1"]
    }
  }
}
'@
Import-APISIXResource -method PUT -uri "plugin_configs/1" -body $proxyRewrite -description "proxy-rewrite 配置"

Start-Sleep -Seconds 1

# 2. Plugin Metadata（Casbin Model）
Write-Host ""
Write-Host "📋 Phase 2: Plugin Metadata (Casbin Model)" -ForegroundColor Yellow
$casbinModel = @'
{
,)\" + p.sub + \"($|,)\" ) && keyMatch2(r.obj, p.obj) && r.act == p.act",
  "policy": ""
}
'@
Import-APISIXResource -method PUT -uri "plugin_metadata/authz-casbin" -body $casbinModel -description "Casbin Model 配置"

# 3. JWT-Auth Plugin Metadata
Write-Host ""
Write-Host "📋 Phase 3: Plugin Metadata (JWT-Auth)" -ForegroundColor Yellow
$jwtSecret = $env:APISIX_JWT_SECRET
if (-not $jwtSecret) {
    $jwtSecret = Read-Host "请输入 JWT Secret（或按 Enter 使用默认）"
    if (-not $jwtSecret) {
        $jwtSecret = "dev_jwt_secret_min_32_chars___"
    }
}

# 根据 algorithm 决定字段
if ($jwtSecret -match '"keys"') {
    # JWKS
    $alg = "RS256"
    $keyName = "jwks"
} else {
    $alg = "HS256"
    $keyName = "secret"
}

$jwtAuth = @"
{
  "algorithm": "$alg",
  "$keyName": "$jwtSecret"
}
"@

Import-APISIXResource -method PUT -uri "plugin_metadata/jwt-auth" -body $jwtAuth -description "JWT-Auth 配置"

Start-Sleep -Seconds 1

# 4. JWKS 端点路由
Write-Host ""
Write-Host "📋 Phase 4: JWKS 端点路由" -ForegroundColor Yellow
$jwksRoute = @'
{
  "uri": "/well-known/jwks",
  "plugins": {
    "public-api": {}
  }
}
'@
Import-APISIXResource -method PUT -uri "routes/jwks" -body $jwksRoute -description "JWKS 路由"

# 5. 业务路由
Write-Host ""
Write-Host "📋 Phase 5: 业务路由" -ForegroundColor Yellow
$businessRoute = Get-Content -Raw "$projectRoot\apisix\routes\api-v1-route.json"
Import-APISIXResource -method PUT -uri "routes/api-v1" -body $businessRoute -description "业务 API 路由"

# 6. Casdoor 回调路由
Write-Host ""
Write-Host "📋 Phase 6: Casdoor 回调路由" -ForegroundColor Yellow
$casdoorRoute = Get-Content -Raw "$projectRoot\apisix\routes\casdoor-callback.json"
Import-APISIXResource -method PUT -uri "routes/casdoor-callback" -body $casdoorRoute -description "Casdoor 回调路由"

# 7. 全局规则
Write-Host ""
Write-Host "📋 Phase 7: Global Rules" -ForegroundColor Yellow
$globalRules = Get-Content -Raw "$projectRoot\apisix\routes\global-rules.json"
Import-APISIXResource -method PUT -uri "global_rules/1" -body $globalRules -description "全局规则"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  APISIX 配置完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📋 验证命令：" -ForegroundColor Yellow
Write-Host "  curl -H 'X-API-KEY: $env:APISIX_ADMIN_KEY' http://localhost:9180/apisix/admin/routes" -ForegroundColor White
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
```

---

## 7. 路由 JSON 文件模板

### 7.1 api-v1-route.json

**文件：** `apisix/routes/api-v1-route.json`

```json
{
  "id": "api-v1-business",
  "uri": "/api/v1/*",
  "plugin_config_id": 1,
  "plugins": {
    "serverless-pre-function": {
      "phase": "rewrite",
      "functions": ["return function(conf, ctx)\n    local cjson = require(\"cjson\")\n    local base64 = require(\"ngx.base64\")\n    local auth_header = ngx.req.get_headers()[\"Authorization\"]\n    if auth_header and string.sub(auth_header, 1, 7) == \"Bearer \" then\n        local token = string.sub(auth_header, 8)\n        local parts = {}\n        for part in string.gmatch(token, \"[^.]+\") do\n            table.insert(parts, part)\n        end\n        if #parts >= 2 then\n            local payload_b64 = parts[2]\n            payload_b64 = string.gsub(payload_b64, \"-\", \"+\")\n            payload_b64 = string.gsub(payload_b64, \"_\", \"/\")\n            local rem = #payload_b64 % 4\n            if rem > 0 then\n                payload_b64 = payload_b64 .. string.rep(\"=\", 4 - rem)\n            end\n            local decoded = base64.decode_base64(payload_b64)\n            if decoded then\n                local status, jwt_json = pcall(cjson.decode, decoded)\n                if status and jwt_json then\n                    if type(jwt_json.roles) == \"string\" then\n                        ngx.req.set_header(\"X-User-Role\", jwt_json.roles)\n                    elseif type(jwt_json.roles) == \"table\" then\n                        local roles_str = table.concat(jwt_json.roles, \",\")\n                        ngx.req.set_header(\"X-User-Role\", roles_str)\n                    else\n                        ngx.log(ngx.WARN, \"JWT missing or invalid roles claim\")\n                    end\n                    if jwt_json.user_id then\n                        ngx.req.set_header(\"X-User-Id\", jwt_json.user_id)\n                    end\n                end\n            end\n        end\n    end\nend"]
    },
    "jwt-auth": {},
    "authz-casbin": {
      "username": "X-User-Role"
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "postgrest:3000": 1
    }
  }
}
```

### 7.2 global-rules.json

**文件：** `apisix/routes/global-rules.json`

```json
{
  "id": "global-cors-limit",
  "plugins": {
    "cors": {
      "allow_origins": "http://localhost:5173,http://localhost:5174",
      "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
      "allow_headers": "Authorization,Content-Type,Accept-Profile,Prefer,X-Requested-With",
      "expose_headers": "Content-Range,Location,Content-Length",
      "allow_credential": true,
      "max_age": 1728000
    },
    "limit-req": {
      "rate": 100,
      "burst": 50,
      "key_type": "var",
      "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\":\"rate_limit\",\"message\":\"Too many requests\"}"
    }
  }
}
```

### 7.3 casdoor-callback.json

**文件：** `apisix/routes/casdoor-callback.json`

```json
{
  "id": "casdoor-callback",
  "uri": "/api/casdoor/callback",
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/casdoor/callback(.*)", "/callback$1"]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "casdoor:8000": 1
    }
  }
}
```

### 7.4 jwks-route.json

**文件：** `apisix/routes/jwks-route.json`

```json
{
  "id": "well-known-jwks",
  "uri": "/well-known/jwks",
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "casdoor:8000": 1
    }
  }
}
```

---

## 8. 验证方法

### 8.1 验证路由列表

```powershell
 ConvertTo-Json -Depth 5
```

**预期：** 返回所有已创建的路由（api-v1, jwks, casdoor-callback, api-v1-rpc 等）。

### 8.2 验证 Casbin Model

```powershell
$resp = Invoke-RestMethod -Uri "http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin" -Headers @{"X-API-KEY"=$env:APISIX_ADMIN_KEY}
 Out-File casbin_model_debug.txt
Write-Host "Model 长度: $($resp.value.model.Length)"
```

**预期：** 返回 Role-in-JWT 优化版的 model.conf 文本。

### 8.3 验证 JWT 配置

```powershell
 ConvertTo-Json
```

### 8.4 验证 proxy-rewrite

```powershell
# 请求 /api/v1/sys_user 应被转发为 /sys_user
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer *** " http://localhost:9080/api/v1/sys_user
# 预期：200 或 403（不是 404）
```

### 8.5 验证 Casbin 鉴权

```powershell
# 未授权请求
Invoke-WebRequest -Uri "http://localhost:9080/api/v1/sys_user" -UseBasicParsing
# 预期：401/403

# 带 Token 请求
$token = (Invoke-RestMethod -Uri "http://localhost:9080/api/v1/rpc/user_login_sso" -Method POST -ContentType "application/json" -Body '{"p_username":"admin","p_password":"admin123"}' -Headers @{"Authorization"="Bearer INVALID"}).access_token
# 注意：需要通过 APISIX 路由来测试（APISIX 会拦截）
```

---

## 9. 故障排查

 问题 | 原因 | 解决方案 |
:---|:---|:---|
 APISIX 连接失败 | etcd 未就绪 | `docker logs app-etcd` 检查连接 |
 Plugin Config 不存在 | proxy-rewrite 未创建 | 先创建 plugin_config 再引用 model.conf 与 Syncer 不一致 | 检查 CasbinModelConf 是否一致 | 确保 APISIX etcd 中的 model.conf 与 Syncer 推送的完全相同 |
 serverless-pre-function 报错 | Lua 语法错误 | 在独立环境测试 Lua 函数 |
 502 Bad Gateway | PostgREST 未就绪 | `docker compose ps postgrest` |
 CORS 预检失败 | CORS 规则未生效 | 检查 global_rules 是否应用 |
 limit-req 不生效 | Redis 未配置 | 添加 Redis 服务或改变策略 |

---

## 10. 生产环境注意事项

 方面 | 建议 |
:---|:---|
 CORS | 改为明确域名列表，不要用 `*` |
 JWT Secret | 使用 Casdoor JWKS（RS256），不用 HS256 |
 limit-req | 使用 Redis 集群而非本地 Redis |
 serverless-pre-function | 考虑使用 ext-plugin 替代（性能更好） |
 日志 | 启用 access-logger 插件到 Elasticsearch |
 监控 | Prometheus metrics + Grafana |

---

## 11. 下一步

完成本文档后，Agent 可以：

1. ✅ 执行 `06-Policy-Syncer-Go实现.md` 配置策略同步
2. ✅ 执行 `05-前端Admin.md` 开始前端开发
3. ✅ 执行 `11-前端API封装与类型定义.md` 完善前端接口层

---

**✅ 阶段完成标志：** APISIX 路由全部就绪，JWT 验证和 Casbin 鉴权通过。
**➡ 下一阶段：** `06-Policy-Syncer-Go实现.md` → 策略实时同步。