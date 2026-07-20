# 04 — 网关与同步器：APISIX 配置 + Policy Syncer 部署

> **定位：** 部署 APISIX 网关的鉴权路由，编译并部署 Go Policy Syncer，验证权限策略的实时同步链路。
> **前置依赖：** 03-API与认证层（PostgREST 就绪、接口可调通）
> **产出物：** APISIX 路由配置就绪 + Policy Syncer 运行 + 全链路同步验证通过
> **预计耗时：** 3-5 小时

---

## 1. model.conf 写入 etcd

将 Role-in-JWT 优化后的 Casbin 模型写入 APISIX 的全局插件元数据：

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/plugin_metadata/authz-casbin \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "[request_definition]\nr = sub, obj, act\n\n[policy_definition]\np = sub, obj, act\n\n[policy_effect]\ne = some(where (p.eft == allow))\n\n[matchers]\nm = regexMatch(r.sub, \"(^|,)\" + p.sub + \"($|,)\") && keyMatch2(r.obj, p.obj) && r.act == p.act",
    "policy": ""
  }'
```

**验证：**
```bash
curl http://127.0.0.1:9180/apisix/admin/plugin_metadata/authz-casbin \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"
```

---

## 2. APISIX 路由配置

### 2.1 创建 JWKS 公钥端点路由

**文件：** `apisix/jwks_route.yaml`

```yaml
uri: /well-known/jwks
plugins:
  mocking:
    content_type: "application/json; charset=utf-8"
    response_status: 200
    response_example: |
      {
        "keys": [
          {
            "kty": "RSA",
            "kid": "key-v1",
            "use": "sig",
            "alg": "RS256",
            "n": "YOUR_RSA_PUBLIC_KEY_MODULUS_BASE64URL",
            "e": "AQAB"
          }
        ]
      }
```

应用：
```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/jwks \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d @apisix/jwks_route.yaml
```

### 2.2 JWT 签名验证配置

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "algorithm": "RS256",
    "key": "{\"keys\": [{\"kty\":\"RSA\", \"kid\":\"key-v1\", \"use\":\"sig\", \"alg\":\"RS256\", \"n\":\"YOUR_RSA_PUBLIC_KEY_MODULUS_BASE64URL\", \"e\":\"AQAB\"}]}"
  }'
```

### 2.3 创建业务路由（核心配置）

**文件：** `apisix/routes.yaml`

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/routes/api-v1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/api/v1/*",
    "plugins": {
      "serverless-pre-function": {
        "phase": "rewrite",
        "functions": [
          "-- ⚠️ 安全警告：此函数仅做 Base64 解码，不验证 JWT 签名\n-- 签名验证由 jwt-auth 插件在 access 阶段执行\n-- 禁止将 X-User-Role/X-User-Id 用于签名验证前的任何信任判定\nreturn function(conf, ctx)\n    local cjson = require(\"cjson\")\n    local base64 = require(\"ngx.base64\")\n    local auth_header = ngx.req.get_headers()[\"Authorization\"]\n    if auth_header and string.sub(auth_header, 1, 7) == \"Bearer \" then\n        local token = string.sub(auth_header, 8)\n        local parts = {}\n        for part in string.gmatch(token, \"[^.]+\") do\n            table.insert(parts, part)\n        end\n        if #parts >= 2 then\n            local payload_b64 = parts[2]\n            payload_b64 = string.gsub(payload_b64, \"-\", \"+\")\n            payload_b64 = string.gsub(payload_b64, \"_\", \"/\")\n            local rem = #payload_b64 % 4\n            if rem > 0 then\n                payload_b64 = payload_b64 .. string.rep(\"=\", 4 - rem)\n            end\n            local decoded = base64.decode_base64(payload_b64)\n            if decoded then\n                local status, jwt_json = pcall(cjson.decode, decoded)\n                if status and jwt_json and jwt_json.roles then\n                    local roles_str = table.concat(jwt_json.roles, \",\")\n                    ngx.req.set_header(\"X-User-Role\", roles_str)\n                    if jwt_json.user_id then\n                        ngx.req.set_header(\"X-User-Id\", jwt_json.user_id)\n                    end\n                end\n            end\n        end\n    end\nend"
        ]
      },
      "jwt-auth": {},
      "authz-casbin": {
        "username": "X-User-Role"
      },
      "cors": {
        "allow_origins": "${CORS_ORIGINS:http://localhost:5173}",
        "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
        "allow_headers": "Authorization,Content-Type,Accept-Profile,Prefer",
        "expose_headers": "Content-Range,Location",
        "allow_credential": true,
        "max_age": 1728000
      },
      "limit-req": {
        "rate": 100,
        "burst": 50,
        "key_type": "var",
        "key": "remote_addr"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "postgrest_server:3000": 1
      }
    }
  }'
```

### 2.4 代理重写路由（去除 /api/v1 前缀）

```bash
curl -X PUT http://127.0.0.1:9180/apisix/admin/plugin_configs/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -H "Content-Type: application/json" \
  -d '{
    "plugins": {
      "proxy-rewrite": {
        "regex_uri": ["^/api/v1/(.*)", "/$1"]
      }
    }
  }'
```

---

## 3. Policy Syncer 编译与部署

### 3.1 Go 源码

**文件：** `syncer/main.go`

```go
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/lib/pq"
)

// ==============================================================================
// 配置参数（部署时修改）
// ==============================================================================
const (
	PostgresDSN    = "postgres://app_owner:***@127.0.0.1:${DB_PORT:-5432}/app_db?sslmode=${SSL_MODE:-disable}"
	ApisixAdminURL = "http://127.0.0.1:9180/apisix/admin/plugin_metadata/authz-casbin"
	ApisixAdminKey = "edd1c9f034335f136f87ad84b625c8f1"
	CasbinModelConf = "[request_definition]\nr = sub, obj, act\n\n[policy_definition]\np = sub, obj, act\n\n[policy_effect]\ne = some(where (p.eft == allow))\n\n[matchers]\nm = regexMatch(r.sub, \"(^|,)\" + p.sub + \"($|,)\") && keyMatch2(r.obj, p.obj) && r.act == p.act"
)

type ApisixMetadata struct {
	Model  string `json:"model"`
	Policy string `json:"policy"`
}

type ApisixResponse struct {
	Value ApisixMetadata `json:"value"`
}

type PolicyRow struct {
	Ptype string
	V0    sql.NullString
	V1    sql.NullString
	V2    sql.NullString
	V3    sql.NullString
	V4    sql.NullString
	V5    sql.NullString
}

type Syncer struct {
	db     *sql.DB
	client *http.Client
}

func main() {
	log.Println("Initializing Policy Syncer...")

	// 从环境变量读取配置
	dsn := fmt.Sprintf("postgres://app_owner:%s@%s:%s/app_db?sslmode=%s",
		os.Getenv("DB_PASSWORD"),
		os.Getenv("DB_HOST"),
		os.Getenv("DB_PORT"),
		os.Getenv("SSL_MODE"),
	)

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	// Advisory Lock 选主（00 总纲要求多实例选主）
	tx, err := db.Begin()
	if err != nil {
		log.Fatalf("Failed to begin transaction: %v", err)
	}
	defer tx.Rollback() // 退出时释放锁

	var acquired bool
	if err := tx.QueryRow("SELECT pg_try_advisory_lock(12345)").Scan(&acquired); err != nil {
		log.Fatalf("Failed to acquire advisory lock: %v", err)
	}
	if !acquired {
		log.Println("Another instance is running as leader. This instance will stand by.")
		return
	}
	log.Println("Acquired advisory lock. Acting as leader.")

	syncer := &Syncer{
		db:     db,
		client: &http.Client{Timeout: 5 * time.Second},
	}

	// 初始全量同步
	log.Println("Performing initial reconciliation...")
	if err := syncer.Reconcile(); err != nil {
		log.Printf("Initial reconciliation failed: %v", err)
	}

	// 启动事件循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 信号监听（优雅关闭）
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		log.Println("Shutdown signal received. Cleaning up...")
		cancel()
		time.Sleep(1 * time.Second) // 等待进行中的同步完成
		os.Exit(0)
	}()

	reportProblem := func(event pq.ListenerEventType, err error) {
		if err != nil {
			log.Printf("Postgres Listener Status Change: Event=%v, Error=%v", event, err)
		}
	}
	listener := pq.NewListener(dsn, 10*time.Second, 10*time.Minute, reportProblem)
	defer listener.Close()

	if err := listener.Listen("casbin_channel"); err != nil {
		log.Fatalf("Failed to listen on channel: %v", err)
	}
	log.Println("Successfully listening on PostgreSQL channel 'casbin_channel'...")

	syncer.StartEventLoop(ctx, listener.Notify)
}

func (s *Syncer) StartEventLoop(ctx context.Context, notifyChan <-chan *pq.Notification) {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()

	var debounceTimer *time.Timer
	var debounceChan <-chan time.Time
	const debounceDuration = 1 * time.Second

	log.Println("Event loop started. Monitoring events...")

	for {
		select {
		case <-ctx.Done():
			log.Println("Event loop stopped.")
			return

		case n := <-notifyChan:
			if n == nil {
				continue
			}
			log.Printf("Received DB notify trigger (channel: %s), delaying sync for debouncing...", n.Channel)
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			debounceTimer = time.NewTimer(debounceDuration)
			debounceChan = debounceTimer.C

		case <-debounceChan:
			log.Println("Debounce timer fired. Executing coalesced synchronization...")
			if err := s.Sync(); err != nil {
				log.Printf("Coalesced sync failed: %v", err)
			}
			debounceTimer = nil
			debounceChan = nil

		case <-ticker.C:
			log.Println("10-minute ticker fired. Initiating reconciliation check...")
			if err := s.Reconcile(); err != nil {
				log.Printf("Periodic reconciliation error: %v", err)
			}
		}
	}
}

func (s *Syncer) Sync() error {
	rows, err := s.fetchPoliciesFromDB()
	if err != nil {
		return fmt.Errorf("fetch db failed: %w", err)
	}
	policyStr := s.formatToCSV(rows)
	return s.pushToApisix(policyStr)
}

func (s *Syncer) Reconcile() error {
	// 计算数据库侧的 SHA256 指纹
	var dbHash string
	query := `SELECT encode(digest(COALESCE(string_agg(
		concat_ws(',', ptype, v0, v1, v2, v3, v4, v5), E'\n' 
		ORDER BY ptype, v0, v1, v2, v3, v4, v5
	), ''), 'sha256'), 'hex') FROM casbin_rule;`
	err := s.db.QueryRow(query).Scan(&dbHash)
	if err != nil {
		return fmt.Errorf("calculate DB policy hash failed: %w", err)
	}

	// 获取 APISIX 当前策略的 SHA256 指纹
	apisixPolicy, err := s.fetchActivePolicyFromApisix()
	if err != nil {
		log.Printf("Failed to fetch active policy from APISIX: %v", err)
		return s.Sync()
	}

	apisixHash := fmt.Sprintf("%x", sha256.Sum256([]byte(apisixPolicy)))
	log.Printf("Reconciliation Hash Check -> DB: %s | APISIX: %s", dbHash, apisixHash)

	if dbHash != apisixHash {
		log.Println("Hash mismatch detected! Triggering full synchronization...")
		return s.Sync()
	}

	log.Println("Hash matched. APISIX cache is consistent with Database.")
	return nil
}

func (s *Syncer) fetchPoliciesFromDB() ([]PolicyRow, error) {
	query := `SELECT ptype, v0, v1, v2, v3, v4, v5 FROM casbin_rule ORDER BY ptype, v0, v1, v2, v3, v4, v5;`
	rows, err := s.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []PolicyRow
	for rows.Next() {
		var r PolicyRow
		if err := rows.Scan(&r.Ptype, &r.V0, &r.V1, &r.V2, &r.V3, &r.V4, &r.V5); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, nil
}

func (s *Syncer) formatToCSV(rows []PolicyRow) string {
	var builder strings.Builder
	for _, r := range rows {
		parts := []string{r.Ptype}
		cols := []*sql.NullString{&r.V0, &r.V1, &r.V2, &r.V3, &r.V4, &r.V5}

		// 找到最后一个非 NULL 列（与 concat_ws 行为一致）
		lastValidIdx := -1
		for i := len(cols) - 1; i >= 0; i-- {
			if cols[i].Valid {
				lastValidIdx = i
				break
			}
		}

		// 只追加非 NULL 值（与 concat_ws 行为一致）
		for i := 0; i <= lastValidIdx; i++ {
			if cols[i].Valid {
				parts = append(parts, cols[i].String)
			}
		}

		builder.WriteString(strings.Join(parts, ",")) // 逗号无空格，与 DB concat_ws 一致
		builder.WriteString("\n")
	}
	return builder.String()
}

func (s *Syncer) fetchActivePolicyFromApisix() (string, error) {
	req, err := http.NewRequest("GET", ApisixAdminURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("X-API-KEY", ApisixAdminKey)

	resp, err := s.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "", nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %w", err)
	}
	var apisixResp ApisixResponse
	if err := json.Unmarshal(body, &apisixResp); err != nil {
		return "", err
	}
	return apisixResp.Value.Policy, nil
}

func (s *Syncer) pushToApisix(policy string) error {
	metadata := ApisixMetadata{
		Model:  CasbinModelConf,
		Policy: policy,
	}
	payload, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	req, err := http.NewRequest(http.MethodPut, ApisixAdminURL, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("X-API-KEY", ApisixAdminKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("apisix returned non-200: %d, failed to read body: %w", resp.StatusCode, err)
		}
		return fmt.Errorf("apisix returned non-200: %d, body: %s", resp.StatusCode, string(body))
	}

	log.Printf("Successfully synchronized %d characters of policy to APISIX etcd.", len(policy))
	return nil
}
```

### 3.2 编译

```bash
cd syncer/
go mod init syncer
go get github.com/lib/pq
go build -o policy-syncer main.go
```

### 3.2.1 容器化构建（推荐）

**文件：** `syncer/Dockerfile`

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY . .
RUN go mod init syncer && go get github.com/lib/pq
RUN go build -o policy-syncer main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
COPY --from=builder /app/policy-syncer /usr/local/bin/
ENTRYPOINT ["policy-syncer"]
```

**文件：** `docker-compose.yml` 新增 syncer 服务

```yaml
syncer:
  build:
    context: ./syncer
    dockerfile: Dockerfile
  container_name: policy-syncer
  restart: unless-stopped
  environment:
    DB_HOST: postgres
    DB_PORT: 5432
    DB_PASSWORD: ${DB_PASSWORD:-dev_password_change_me}
    SSL_MODE: disable
    APISIX_ADMIN_URL: http://apisix:9180/apisix/admin/plugin_metadata/authz-casbin
    APISIX_ADMIN_KEY: ${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}
  depends_on:
    postgres:
      condition: service_healthy
    apisix:
      condition: service_started
  networks:
    - app-net
```

### 3.3 部署

```bash
# Docker Compose 方式（推荐，已在 docker-compose.yml 中定义）
docker compose up -d syncer

# 或直接运行
export DB_HOST=127.0.0.1
export DB_PORT=5432
export DB_PASSWORD=dev_password_change_me
export SSL_MODE=disable
export APISIX_ADMIN_URL=http://127.0.0.1:9180/apisix/admin/plugin_metadata/authz-casbin
export APISIX_ADMIN_KEY=edd1c9f034335f136f87ad84b625c8f1
./policy-syncer

# 或 systemd 服务
# 创建 /etc/systemd/system/policy-syncer.service
```

> **⚠️ 注意：** 当前版本通过 Advisory Lock 选主，仅支持单实例运行。如需多实例高可用，需额外实现 leader 选举和 standby 自动接管。

---

## 4. 全链路验证

### 4.1 验证 Policy Syncer 启动

```bash
tail -f /var/log/policy-syncer.log
```

应看到：
```
Initializing Policy Syncer...
Performing initial reconciliation...
Successfully synchronized X characters of policy to APISIX etcd.
Successfully listening on PostgreSQL channel 'casbin_channel'...
Event loop started.
```

### 4.2 验证鉴权：未授权请求 → 403

```bash
# 不带 JWT
curl -v http://localhost:9080/api/v1/sys_user
# 预期：403 Forbidden
```

### 4.3 验证鉴权：授权请求 → 200

```bash
# 1. 登录获取 Token
TOKEN=$(curl -s -X POST http://localhost:3000/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"p_username":"admin","p_password":"admin123"}' | jq -r '.access_token')

# 2. 带 Token 访问
curl -H "Authorization: Bearer $TOKEN" http://localhost:9080/api/v1/sys_user
# 预期：200 OK + JSON 用户列表
```

### 4.4 验证无权限请求 → 403

```bash
# 用 admin 访问一个未授权的 API
# （需先确保 admin 角色在 sys_role_api 中没有该 API 的记录）
curl -H "Authorization: Bearer $TOKEN" -X DELETE http://localhost:9080/api/v1/sys_user?id=eq.SOME_UUID
# 如果 admin 没有 DELETE sys_user 权限 → 403
```

### 4.5 验证 pg_notify 实时同步

```bash
# 1. 打开 Syncer 日志
tail -f syncer.log &

# 2. 在数据库中添加新角色-API 关联
psql -d app_db -c "
INSERT INTO sys_role_api (role_id, api_id) 
VALUES ('00000000-0000-0000-0000-200000000001', '00000000-0000-0000-0000-400000000004');
"

# 3. 观察 Syncer 日志
# 应看到：
# "Received DB notify trigger (channel: casbin_channel), delaying sync for debouncing..."
# "Debounce timer fired. Executing coalesced synchronization..."
# "Successfully synchronized X characters of policy to APISIX etcd."
```

### 4.6 验证 10 分钟对账

```bash
# 等待 10 分钟后检查日志
# 应看到：
# "10-minute ticker fired. Initiating reconciliation check..."
# "Hash matched. APISIX cache is consistent with Database."
```

### 4.7 验证 Syncer 重连机制

```bash
# 1. 停止 PostgreSQL
# 观察日志：Postgres Listener Status Change: Event=..., Error=...

# 2. 启动 PostgreSQL
# 观察日志：自动重连成功、LISTEN 恢复
```

### 4.8 验证 JWKS 端点

```bash
curl http://localhost:9080/well-known/jwks
# 预期：返回 JWKS JSON
```

### 4.9 验证限流（limit-req）

```bash
# 快速发送 110 个请求（burst=50，rate=100/s），预期部分返回 429
for i in $(seq 1 110); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9080/api/v1/sys_user &
done | sort | uniq -c
# 预期：约 100 个 200/403 + 约 10 个 429
```

### 4.10 验证 CORS 响应头

```bash
# 预检请求
curl -X OPTIONS http://localhost:9080/api/v1/sys_user \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization,Content-Type" \
  -v 2>&1 | grep -i "access-control"
# 预期：返回 Access-Control-Allow-Origin: http://localhost:5173
```

### 4.11 验证代理重写（proxy-rewrite）

```bash
# 请求 /api/v1/sys_user 应被重写为 /sys_user 转发到 PostgREST
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  http://localhost:9080/api/v1/sys_user
# 预期：200（PostgREST 收到 /sys_user 请求）
```

---

## 5. 验收清单

| # | 验收项 | 验证方法 | 通过 |
|:---:|:---|:---|:---:|
| G1 | model.conf 已写入 etcd | `GET /apisix/admin/plugin_metadata/authz-casbin` → 返回 Role-in-JWT 版 model.conf | ☐ |
| G2 | 未授权请求返回 403 | `curl http://localhost:9080/api/v1/sys_user`（不带 JWT）→ 403 | ☐ |
| G3 | 授权请求正常通过 | 带 admin JWT 访问 `/api/v1/sys_user` → 200 | ☐ |
| G4 | 无权限请求返回 403 | 带 JWT 调用未授权的 API → 403 | ☐ |
| G5 | JWKS 端点可访问 | `curl http://localhost:9080/well-known/jwks` → 200 + JWKS JSON | ☐ |
| G6 | Policy Syncer 启动并监听 | 日志含 "Successfully listening on PostgreSQL channel" | ☐ |
| G7 | pg_notify 触发实时同步 | INSERT sys_role_api → Syncer 日志含 "Debounce timer fired" → APISIX 策略更新 | ☐ |
| G8 | 10 分钟定时对账正常 | 日志含 "Hash matched"（或 Hash mismatch → forced sync） | ☐ |
| G9 | Syncer 断线重连正常 | 停 PG → 日志含重连日志 → 启 PG → 自动恢复 LISTEN | ☐ |
| G10 | 冷启动 LoadPolicy 性能可接受 | Syncer 首次同步耗时 < 3 秒 | ☐ |
| G11 | 限流功能正常 | 超限请求返回 429 | ☐ |
| G12 | CORS 配置正确 | OPTIONS 预检返回 Access-Control-Allow-Origin | ☐ |
| G13 | 代理重写正确 | `/api/v1/sys_user` → PostgREST 收到 `/sys_user` | ☐ |
| G14 | Advisory Lock 选主正常 | 日志含 "Acquired advisory lock. Acting as leader." | ☐ |
| G15 | 优雅关闭正常 | 发送 SIGTERM → 日志含 "Shutdown signal received" → 进程退出 | ☐ |

> **通过标准：** 15/15 项全部打勾。G7 尤其关键——确认从数据库变更到网关策略更新的完整链路通畅。
