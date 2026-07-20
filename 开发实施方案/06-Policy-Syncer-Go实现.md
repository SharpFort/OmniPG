# 06 — Policy Syncer Go 完整实现

> **定位：** 提供 Policy Syncer 的完整 Go 实现代码、Docker 构建配置、运维脚本和验证方法。Agent 按本文档可编译、部署并验证策略实时同步链路。
> **前置依赖：** 01-环境搭建（Go 1.22+）、04-网关与同步器（APISIX 就绪、model.conf 已写入 etcd）
> **产出物：** 可运行的 Policy Syncer 二进制 + Docker 镜像 + 运维脚本
> **预计耗时：** 1-2 小时（含编译和问题排查）

---

## 1. 架构概述

```
┌─────────────────────────────────────────────────────────┐
│                    Policy Syncer 架构                     │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────┐    pg_notify    ┌──────────────────┐     │
│  │ PostgreSQL │ ─────────────► │  Event Loop      │     │
│  │ casbin_   │                │  - 1s 防抖        │     │
│  │ channel   │                │  - 10min 对账     │     │
│  └──────────┘                │  - 冷启动同步     │     │
│                               └────────┬─────────┘     │
│                                        │               │
│                    ┌───────────────────┼────────┐      │
│                    │                   │        │      │
│              ┌─────▼─────┐      ┌─────▼──┐  ┌──▼────┐ │
│              │ Sync()    │      │Reconci-│  │Advisory│ │
│              │ 全量同步  │      │cile()  │  │Lock   │ │
│              │           │      │SHA256  │  │选主   │ │
│              └─────┬─────┘      │对账    │  └───────┘ │
│                    │            └─────┬──┘             │
│                    │                  │                │
│                    └─────────┬────────┘                │
│                              │                         │
│                    ┌─────────▼─────────┐               │
│                    │ APISIX Admin API  │               │
│                    │ PUT plugin_meta   │               │
│                    └───────────────────┘               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Go 源码

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
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/lib/pq"
)

// ==============================================================================
// 配置参数（通过环境变量读取）
// ==============================================================================

// 数据库连接配置
var (
	DBHost     = getEnv("DB_HOST", "localhost")
	DBPort     = getEnv("DB_PORT", "5432")
	DBUser     = getEnv("DB_USER", "app_owner")
	DBPassword = getEnv("DB_PASSWORD", "dev_password_change_me")
	DBName     = getEnv("DB_NAME", "app_db")
	SSLMode    = getEnv("SSL_MODE", "disable")
)

// APISIX 配置
var (
	ApisixAdminURL  = getEnv("APISIX_ADMIN_URL", "http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin")
	ApisixAdminKey  = getEnv("APISIX_ADMIN_KEY", "edd1c9f034335f136f87ad84b625c8f1")
)

// Casbin 模型配置（必须与 etcd 中的 model.conf 一致）
const CasbinModelConf = `[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
)" + p.sub + "(,|$)") && keyMatch2(r.obj, p.obj) && r.act == p.act`

// 防抖时长
const DebounceDuration = 1 * time.Second

// 定时对账间隔
const ReconcileInterval = 10 * time.Minute

// Advisory Lock Key（用于多实例选主）
const AdvisoryLockKey = 12345

// ==============================================================================
// 数据模型
// ==============================================================================

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

// ==============================================================================
// 主函数
// ==============================================================================

func main() {
 log.Lshortfile)
	log.Println("========================================")
	log.Println("  Policy Syncer — 初始化中...")
	log.Println("========================================")

	// 1. 构建数据库连接
	// [修复 P1-4] DSN 密码需要进行 URL 编码，避免特殊字符解析错误
	dsn := fmt.Sprintf("postgres://%s:***@%s:%s/%s?sslmode=%s",
		url.QueryEscape(DBUser), url.QueryEscape(DBPassword), DBHost, DBPort, DBName, SSLMode)
	
	log.Printf("连接数据库: %s:%s/%s", DBHost, DBPort, DBName)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("数据库连接失败: %v", err)
	}
	defer db.Close()

	// 测试数据库连接
	if err := db.Ping(); err != nil {
		log.Fatalf("数据库 ping 失败: %v", err)
	}
	log.Println("✅ 数据库连接成功")

	// [修复 N-2] 确保 pgcrypto 扩展存在（digest() 函数依赖）
	if _, err := db.Exec("CREATE EXTENSION IF NOT EXISTS pgcrypto;"); err != nil {
		log.Fatalf("pgcrypto 扩展不可用（digest() 函数需要）: %v", err)
	}
	log.Println("✅ pgcrypto 扩展确认就绪")

	// 2. Advisory Lock 选主（多实例部署时只有一个 leader）
	tx, err := db.Begin()
	if err != nil {
		log.Fatalf("开启事务失败: %v", err)
	}
	// 注意：defer 不自动释放锁，进程退出时连接断开自动释放

	var acquired bool
	if err := tx.QueryRow("SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&acquired); err != nil {
		log.Fatalf("获取 Advisory Lock 失败: %v", err)
	}
	if !acquired {
		log.Println("⚠️  另一个实例正在运行作为 leader。当前实例将退出（standby 模式）")
		tx.Rollback()
		return
	}
	log.Println("✅ 已获取 Advisory Lock，当前实例为 leader")
	// [修复 P1-2] 启动心跳协程，定期验证 Advisory Lock 是否仍被持有
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for {
			<-ticker.C
			var stillLeader bool
			err := db.QueryRow("SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&stillLeader)
			if err != nil || !stillLeader {
				log.Println("⚠️  Advisory Lock 已丢失！安全退出...")
				os.Exit(1)
			}
		}
	}()
	// tx 保持打开状态直到进程退出

	// 3. 构建 Syncer 实例
	syncer := &Syncer{
		db:     db,
		client: &http.Client{Timeout: 10 * time.Second},
	}

	// 4. 初始全量同步（冷启动）
	log.Println("🔄 执行初始全量同步...")
	if err := syncer.Sync(); err != nil {
		log.Printf("⚠️  初始同步失败（可能是 APISIX 未就绪）: %v", err)
		log.Println("将在事件循环重试...")
	} else {
		log.Println("✅ 初始同步完成")
	}

	// 5. 启动 HTTP 健康检查端点（/healthz）
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			log.Printf("/healthz 失败: %v", err)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})
	go func() {
		log.Println("✅ /healthz 健康检查端点已启动 (port 8080)")
		if err := http.ListenAndServe(":8080", nil); err != nil {
			log.Printf("/healthz 服务器错误: %v", err)
		}
	}()

	// 6. 启动事件循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 信号监听（优雅关闭）
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		log.Println("\n🛑 收到终止信号，正在优雅关闭...")
		cancel()
		time.Sleep(1 * time.Second) // 等待进行中的同步完成
		tx.Rollback()
		db.Close()
		os.Exit(0)
	}()

	// 6. 启动 PostgreSQL LISTENER
	reportProblem := func(event pq.ListenerEventType, err error) {
		if err != nil {
			log.Printf("PostgreSQL Listener 状态变更: Event=%v, Error=%v", event, err)
		}
	}
	
	listener := pq.NewListener(dsn, 10*time.Second, 10*time.Minute, reportProblem)
	defer listener.Close()

	if err := listener.Listen("casbin_channel"); err != nil {
		log.Fatalf("监听 casbin_channel 失败: %v", err)
	}
	log.Println("✅ 正在监听 PostgreSQL casbin_channel...")

	// 7. 进入事件循环
	log.Println("📡 事件循环已启动。实时同步就绪。")
	syncer.StartEventLoop(ctx, listener.Notify)
}

// ==============================================================================
// 事件循环
// ==============================================================================

func (s *Syncer) StartEventLoop(ctx context.Context, notifyChan <-chan *pq.Notification) {
	ticker := time.NewTicker(ReconcileInterval)
	defer ticker.Stop()

	var debounceTimer *time.Timer
	var debounceChan <-chan time.Time

	for {
		select {
		case <-ctx.Done():
			log.Println("事件循环已停止。")
			return

		case n := <-notifyChan:
			if n == nil {
				// 连接断开重连
				log.Println("⚠️  PostgreSQL 连接可能断开，等待重连...")
				continue
			}
			log.Printf("📨 收到 DB 通知 (channel: %s)，开始防抖...", n.Channel)
			
			// 防抖逻辑：重置定时器，1 秒内的多次触发合并为一次
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			debounceTimer = time.NewTimer(DebounceDuration)
			debounceChan = debounceTimer.C

		case <-debounceChan:
			log.Println("⏰ 防抖定时器触发，执行同步...")
			if err := s.Sync(); err != nil {
				log.Printf("❌ 同步失败: %v", err)
			} else {
				log.Println("✅ 同步完成")
			}
			debounceTimer = nil
			debounceChan = nil

		case <-ticker.C:
			log.Println("🔍 定时对账触发...")
			if err := s.Reconcile(); err != nil {
				log.Printf("⚠️  对账失败: %v", err)
			}
		}
	}
}

// ==============================================================================
// 同步方法
// ==============================================================================

// Sync：全量同步（从 DB 读取策略 → 写入 APISIX）
// [修复 P2-3] 添加冷启动优化：策略表为空时跳过
func (s *Syncer) Sync() error {
	rows, err := s.fetchPoliciesFromDB()
	if err != nil {
		return fmt.Errorf("从 DB 读取策略失败: %w", err)
	}

	// 冷启动优化：策略表为空则跳过同步
	if len(rows) == 0 {
		log.Println("ℹ️  策略表为空，跳过全量同步")
		return nil
	}

	policyStr := s.formatToCSV(rows)
	if err := s.pushToApisix(policyStr); err != nil {
		return fmt.Errorf("推送到 APISIX 失败: %w", err)
	}

	log.Printf("✅ 已同步 %d 条策略到 APISIX", len(rows))
	return nil
}

// Reconcile：SHA256 对账（比较 DB 和 APISIX 的策略哈希）
func (s *Syncer) Reconcile() error {
	// 1. 计算数据库侧的 SHA256 指纹
	var dbHash string
	query := `SELECT encode(digest(COALESCE(string_agg(
		concat_ws(',', ptype, v0, v1, v2, v3, v4, v5), E'\n' 
		ORDER BY ptype, v0, v1, v2, v3, v4, v5
	), ''), 'sha256'), 'hex') FROM casbin_rule;`
	
	err := s.db.QueryRow(query).Scan(&dbHash)
	if err != nil {
		return fmt.Errorf("计算 DB 策略哈希失败: %w", err)
	}

	// 2. 获取 APISIX 当前策略的 SHA256 指纹
	apisixPolicy, err := s.fetchActivePolicyFromApisix()
	if err != nil {
		// [修复 P1-5] 区分网络错误与 APISIX 未初始化
		errStr := err.Error()
		if strings.Contains(errStr, "connection refused") ||
			strings.Contains(errStr, "timeout") ||
			strings.Contains(errStr, "no such host") ||
			strings.Contains(errStr, "context deadline exceeded") {
			log.Printf("⚠️  APISIX 暂时不可用（网络抖动），跳过本次对账: %v", err)
			return nil // 下次对账再试，不触发全量同步
		}
		log.Printf("❌ 读取 APISIX 策略失败: %v", err)
		return s.Sync()
	}

	apisixHash := fmt.Sprintf("%x", sha256.Sum256([]byte(apisixPolicy)))
 APISIX: %s", dbHash[:16], apisixHash[:16])

	// 3. 比较哈希
	if dbHash != apisixHash {
		log.Println("⚠️  哈希不匹配！触发全量同步...")
		return s.Sync()
	}

	log.Println("✅ 哈希匹配，APISIX 与 DB 一致")
	return nil
}

// ==============================================================================
// 数据库操作
// ==============================================================================

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
	return result, rows.Err()
}

// ==============================================================================
// APISIX 交互
// ==============================================================================

func (s *Syncer) fetchActivePolicyFromApisix() (string, error) {
	req, err := http.NewRequest("GET", ApisixAdminURL, nil)
	if err != nil {
		return "", fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", ApisixAdminKey)

	resp, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("HTTP 请求失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		// APISIX 尚未写入策略，返回空（首次同步）
		return "", nil
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("APISIX 返回 %d: %s", resp.StatusCode, string(body))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("读取响应体失败: %w", err)
	}

	var apisixResp ApisixResponse
	if err := json.Unmarshal(body, &apisixResp); err != nil {
		return "", fmt.Errorf("解析 JSON 失败: %w", err)
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
		return fmt.Errorf("序列化 JSON 失败: %w", err)
	}

	req, err := http.NewRequest(http.MethodPut, ApisixAdminURL, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", ApisixAdminKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("HTTP 请求失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("APISIX 返回 %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// ==============================================================================
// 策略格式化
// ==============================================================================

// [修复 P0-1] formatToCSV 去掉尾部换行，与 SQL string_agg 行为一致
func (s *Syncer) formatToCSV(rows []PolicyRow) string {
	var builder strings.Builder
	for _, r := range rows {
		parts := []string{r.Ptype}
		cols := []*sql.NullString{&r.V0, &r.V1, &r.V2, &r.V3, &r.V4, &r.V5}

		lastValidIdx := -1
		for i := len(cols) - 1; i >= 0; i-- {
			if cols[i].Valid {
				lastValidIdx = i
				break
			}
		}

		for i := 0; i <= lastValidIdx; i++ {
			if cols[i].Valid {
				parts = append(parts, cols[i].String)
			}
		}

		builder.WriteString(strings.Join(parts, ","))
		builder.WriteString("\n")
	}
	// 去掉尾部换行符，确保与 PostgreSQL string_agg 输出完全一致
	return strings.TrimSuffix(builder.String(), "\n")
}

// ==============================================================================
// 辅助函数
// ==============================================================================

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
```

---

## 3. Go Module 配置

**文件：** `syncer/go.mod`

```
module policy-syncer

go 1.22

require github.com/lib/pq v1.10.9
```

**文件：** `syncer/go.sum`（自动生成）

```bash
# 进入 syncer 目录
cd syncer

# 初始化 go mod
| true

# 添加依赖
go get github.com/lib/pq@v1.10.9

# 整理依赖
go mod tidy
```

---

## 4. Docker 构建

### 4.1 Dockerfile

**文件：** `syncer/Dockerfile`

```dockerfile
# ==============================================================================
# Policy Syncer Docker 构建
# 多阶段：Go Builder (golang:1.22-alpine) + 运行时 (alpine:3.19)
# ==============================================================================

# 第一阶段：编译 Go 二进制
FROM golang:1.22-alpine AS builder

# 安装编译依赖
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# 复制源码
COPY main.go .

# 初始化模块并下载依赖
| true
RUN go get github.com/lib/pq@v1.10.9

# 编译为静态二进制（CGO_ENABLED=0）
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags='-w -s -extldflags "-static"' \
    -o policy-syncer main.go

# 第二阶段：运行时镜像
FROM alpine:3.19

# 安装 CA 证书和时区数据
RUN apk add --no-cache ca-certificates tzdata

# 从 builder 阶段复制二进制
COPY --from=builder /app/policy-syncer /usr/local/bin/policy-syncer

# 创建非 root 用户（安全最佳实践）
RUN addgroup -S syncer && adduser -S syncer -G syncer
USER syncer

# 入口点
ENTRYPOINT ["policy-syncer"]
```

### 4.2 .dockerignore

**文件：** `syncer/.dockerignore`

```
.git
.gitignore
Dockerfile
README.md
*.md
*.test
```

---

## 5. 启动方式

### 5.1 Docker Compose（推荐）

已在 `08-Docker-Compose` 文档中定义 syncer 服务：

```powershell
# 启动 syncer
docker compose up -d syncer

# 查看日志
docker compose logs -f syncer
```

### 5.2 Docker Run（备用）

```powershell
docker build -t policy-syncer:latest ./syncer

docker run -d --name policy-syncer `
  --network app-net `
  -e DB_HOST=postgres `
  -e DB_PORT=5432 `
  -e DB_PASSWORD=dev_password_change_me `
  -e SSL_MODE=disable `
  -e APISIX_ADMIN_URL=http://apisix:9180/apisix/admin/plugin_metadata/authz-casbin `
  -e APISIX_ADMIN_KEY=edd1c9f034335f136f87ad84b625c8f1 `
  policy-syncer:latest
```

### 5.3 本地运行（开发调试）

```powershell
# 进入 syncer 目录
cd syncer

# 设置环境变量
$env:DB_HOST = "localhost"
$env:DB_PORT = "5432"
$env:DB_PASSWORD = "dev_password_change_me"
$env:SSL_MODE = "disable"
$env:APISIX_ADMIN_URL = "http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin"
$env:APISIX_ADMIN_KEY = "edd1c9f034335f136f87ad84b625c8f1"

# 运行
go run main.go
```

---

## 6. 运维脚本

### 6.1 Windows PowerShell

**文件：** `scripts/syncer-status.ps1`

```powershell
# ==============================================================================
# Policy Syncer 状态检查
# ==============================================================================

$ErrorActionPreference = "SilentlyContinue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Policy Syncer 状态检查" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. 检查容器状态
$containerStatus = docker inspect --format='{{.State.Status}}' policy-syncer 2>$null
if ($containerStatus -eq "running") {
    Write-Host "✅ 容器状态: running" -ForegroundColor Green
} else {
    Write-Host "❌ 容器状态: $containerStatus" -ForegroundColor Red
}

# 2. 检查最近日志
Write-Host ""
Write-Host "📋 最近 10 行日志：" -ForegroundColor Yellow
docker logs --tail=10 policy-syncer

# 3. 检查关键日志关键字
Write-Host ""
Write-Host "🔍 关键状态：" -ForegroundColor Yellow
$logs = docker logs policy-syncer 2>$null
if ($logs -match "Successfully listening") {
    Write-Host "  ✅ PostgreSQL 监听已建立" -ForegroundColor Green
}
if ($logs -match "Acquired advisory lock") {
    Write-Host "  ✅ 已成为 leader" -ForegroundColor Green
}
if ($logs -match "Successfully synchronized") {
    Write-Host "  ✅ 策略已同步" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
```

**文件：** `scripts/syncer-restart.ps1`

```powershell
# ==============================================================================
# Policy Syncer 重启
# ==============================================================================

Write-Host "🔄 重启 Policy Syncer..." -ForegroundColor Yellow
docker compose restart syncer
Start-Sleep -Seconds 3
docker compose logs -f syncer
```

### 6.2 Linux/macOS bash

**文件：** `scripts/syncer-status.sh`

```bash
#!/bin/bash
echo "========================================"
echo "  Policy Syncer 状态检查"
echo "========================================"

# 检查容器状态
status=$(docker inspect --format='{{.State.Status}}' policy-syncer 2>/dev/null)
if [ "$status" = "running" ]; then
    echo "✅ 容器状态: running"
else
    echo "❌ 容器状态: $status"
fi

# 最近日志
echo ""
echo "📋 最近 10 行日志："
docker logs --tail=10 policy-syncer

# 关键状态
echo ""
echo "🔍 关键状态："
logs=$(docker logs policy-syncer 2>/dev/null)
 grep -q "Successfully listening"; then
    echo "  ✅ PostgreSQL 监听已建立"
fi
 grep -q "Acquired advisory lock"; then
    echo "  ✅ 已成为 leader"
fi

echo "========================================"
```

---

## 7. 验证方法

### 7.1 验证 Syncer 启动

```powershell
# 查看日志
docker logs -f policy-syncer

# 预期输出：
# Initializing Policy Syncer...
# 连接数据库: postgres:5432/app_db
# ✅ 数据库连接成功
# ✅ 已获取 Advisory Lock，当前实例为 leader
# 🔄 执行初始全量同步...
# ✅ 初始同步完成
# ✅ 正在监听 PostgreSQL casbin_channel...
# 📡 事件循环已启动。实时同步就绪。
```

### 7.2 验证实时同步

```powershell
# 1. 打开日志
docker logs -f policy-syncer &

# 2. 在数据库中添加新的角色-API 关联
docker exec -it app-postgres psql -U app_owner -d app_db -c "
INSERT INTO sys_role_api (role_id, api_id) 
VALUES ('00000000-0000-0000-0000-200000000001', '00000000-0000-0000-0000-400000000004');
"

# 3. 观察日志（应看到防抖+同步）
# 预期：
# 📨 收到 DB 通知 (channel: casbin_channel)，开始防抖...
# ⏰ 防抖定时器触发，执行同步...
# ✅ 已同步 XX 条策略到 APISIX
# ✅ 同步完成
```

### 7.3 验证 SHA256 对账

```powershell
# 等待 10 分钟（对账周期）
# 或对账日志中出现：
 Select-String "对账"
# 预期：
# 🔍 定时对账触发...
 APISIX: xxxx
# ✅ 哈希匹配，APISIX 与 DB 一致
```

### 7.4 验证断线重连

```powershell
# 1. 停止 PostgreSQL
docker stop app-postgres

# 2. 观察日志
# 预期：
# ⚠️  PostgreSQL 连接可能断开，等待重连...

# 3. 启动 PostgreSQL
docker start app-postgres

# 4. 观察日志
# 预期：
# ✅ PostgreSQL 连接恢复（pq 库自动重连）
```

---

## 8. 故障排查

 问题 | 原因 | 解决方案 |
:---|:---|:---|
 `Failed to open database` | 数据库未就绪或 DSN 错误 | 检查 `.env` 配置，确认 PG 容器已 healthy |
 `Failed to acquire advisory lock` | 另一个实例正在运行 | `docker compose down syncer` 后重启 |
 `APISIX returned non-200` | model.conf 不一致 | 检查 APISIX 插件元数据中的 model |
 `Failed to listen on channel` | pg_net 扩展未启用 | `CREATE EXTENSION pg_net;` |
 同步延迟超过 1 秒 | 防抖定时器阻塞 | 检查 APISIX 网络连通性 |
 SHA256 持续不匹配 | 数据编码不一致 | 检查 formatToCSV 函数与 DB concat_ws 的一致性 |

---

## 9. 性能优化

### 9.1 冷启动优化

```go
// 如果策略表为空，跳过首次同步
if len(rows) == 0 {
    log.Println("策略表为空，跳过同步")
    return nil
}
```

### 9.2 防抖时长调整

```go
// 高频写入场景可将防抖从 1 秒调整为 2-5 秒
const DebounceDuration = 2 * time.Second
```

### 9.3 对账间隔调整

```go
// 对一致性要求高的场景可缩短为 5 分钟
const ReconcileInterval = 5 * time.Minute
```

---

## 10. 生产环境建议

 方面 | 建议 |
:---|:---|
 **多实例部署** | 保持单实例 + Advisory Lock 选主。如需多活，可使用 etcd 选主 |
 **监控** | 暴露 `/metrics` 端点（Prometheus），监控同步延迟和失败次数 |
 **告警** | 对账连续失败 3 次时触发告警 |
 **日志** | 接入 ELK/Loki，trace_id 串联每次同步 |
 **配置** | 通过 Kubernetes ConfigMap 或环境变量注入 |
 **资源限制** | CPU: 0.5 核，内存: 128MB（轻量级 Go 服务） |
 **健康检查** | HTTP `/healthz` 返回 200 |

---

## 11. 下一步

完成本文档后，Agent 可以：

1. ✅ 执行 `05-前端Admin.md` 中的 ART-D Pro 集成
2. ✅ 执行全系统端到端验收（30 项）

---

**✅ 阶段完成标志：** Policy Syncer 运行正常，策略实时同步链路验证通过。
**➡ 下一阶段：** `05-前端Admin-开发与整体集成验收.md` → 前端开发。

---

# 二次审查报告（2026-07-10）

> **审查对象：** `D:\WeChat Files\xiangmu\06-Policy-Syncer-Go实现.md`
> **原始审查报告：** `D:\WeChat Files\xiangmu\审查文档\06-审查报告.md`
> **审查日期：** 2026-07-10
> **审查范围：** 对照原始审查报告（P0/P1/P2 + 新发现问题）逐项验证修复状态

---

## 修复状态汇总

```diff
原始问题                                     状态    说明
─────────────────────────────────────────────────────────────────────────
P0-1  CSV尾部换行符导致SHA256失败             ❌ 未修复  仍在第467行写尾部\n
P1-1  无/healthz端点                          ❌ 未修复  代码无HTTP服务器
P1-2  Advisory Lock断连后失效                ❌ 未修复  无心跳验证锁状态
P1-3  事件循环竞态条件                        ❌ 未修复  无syncing原子标志
P1-4  DSN密码未URL编码                       ❌ 未修复  第152行直接拼接
P1-5  Reconcile错误降级为全量Sync             ❌ 未修复  未区分错误类型
P2-1  无Prometheus指标                       ❌ 未修复  无metrics端点
P2-2  无单元测试                              ❌ 未修复  无*_test.go文件
P2-3  冷启动优化未集成                        ❌ 未修复  Sync()未检查空策略表
P2-4  优雅关闭超时硬编码                      ❌ 未修复  第214行仍Sleep(1s)
─────────────────────────────────────────────────────────────────────────
N-1   Reconcile SQL缺少ptype='p'过滤          🆕 新发现  防御性设计缺失
N-2   digest()依赖pgcrypto扩展                🆕 新发现  启动时未CREATE EXTENSION
N-3   Docker Build阶段go mod init冗余         🆕 新发现  可COPY go.mod替代
N-4   运维脚本grep全量日志存在内存隐患         🆕 新发现  大日志文件会OOM
─────────────────────────────────────────────────────────────────────────
```

---

## ❌ P0 阻塞级（1项）

### P0-1. CSV尾部换行符导致 SHA256 对账永远失败

> **位置：** `formatToCSV()` 第467行 vs `Reconcile()` SQL 第315-318行
> **状态：** ❌ **未修复**

**问题复现：**

```
Go侧 formatToCSV() 输出:
  "p,role_admin,/sys_user,GET\np,role_admin,/sys_role,GET\n"
                                              ↑ 尾部多一个\n

PG侧 string_agg() 输出:
  "p,role_admin,/sys_user,GET\np,role_admin,/sys_role,GET"
                                              ↑ 无尾部换行
```

**后果量化：**
- 策略量 50,000 行时，APISIX存储的CSV约含尾部`\n`，DB哈希不含
- 每10分钟对账必然误判不一致，触发不必要全量 Sync
- 浪费：5MB序列化 + etcd网络传输 + etcd写入压力

**修复方案A（推荐，改1行）：**

```go
// 在第469行 return 之前追加 TrimSuffix
func (s *Syncer) formatToCSV(rows []PolicyRow) string {
    var builder strings.Builder
    for _, r := range rows {
        // ... 原有逻辑 ...
        builder.WriteString(strings.Join(parts, ","))
        builder.WriteString("\n")
    }
    // ← 修复：去掉尾部换行，与 SQL string_agg 行为一致
    return strings.TrimSuffix(builder.String(), "\n")
}
```

**修复方案B（重构为 []string，更优雅）：**

```go
func (s *Syncer) formatToCSV(rows []PolicyRow) string {
    lines := make([]string, 0, len(rows))
    for _, r := range rows {
        parts := []string{r.Ptype}
        cols := []*sql.NullString{&r.V0, &r.V1, &r.V2, &r.V3, &r.V4, &r.V5}
        lastValidIdx := -1
        for i := len(cols) - 1; i >= 0; i-- {
            if cols[i].Valid {
                lastValidIdx = i
                break
            }
        }
        for i := 0; i <= lastValidIdx; i++ {
            if cols[i].Valid {
                parts = append(parts, cols[i].String)
            }
        }
        lines = append(lines, strings.Join(parts, ","))
    }
    return strings.Join(lines, "\n")  // Join 不会在末尾添加\n
}
```

---

## 🟡 P1 重要级（5项）

### P1-1. 无 `/healthz` 端点 — 容器编排无法做存活/就绪探针

> **位置：** `main()` 无HTTP监听代码
> **状态：** ❌ **未修复**

**影响：**
- Docker Compose 无法配置 `healthcheck`
- Kubernetes 无法配置 liveness/readiness probe
- 运维脚本只能检查容器 running 状态，无法确认进程是否正常处理事件

**修复方案：**

在 `main()` 中、`listener.Listen` 之前添加：

```go
http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
    if err := db.Ping(); err != nil {
        w.WriteHeader(http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
})
go http.ListenAndServe(":8080", nil)
log.Println("✅ /healthz 健康检查端点已启动 (port 8080)")
```

---

### P1-2. Advisory Lock 断连后失效 — 多实例可能并发写入 APISIX

> **位置：** 第169-185行，`tx` 保持打开但无心跳验证
> **状态：** ❌ **未修复**

**根因：** Advisory Lock 绑定在 `tx` 的连接上，而 Listener 使用独立连接。Listener 重连成功 ≠ Advisory Lock 仍持有。

**修复方案：**

在 `StartEventLoop` 的 select 中添加定时心跳验证：

```go
lockTicker := time.NewTicker(1 * time.Minute)
defer lockTicker.Stop()

// ... 在 for 循环中添加：
case <-lockTicker.C:
    var stillLeader bool
    err := s.db.QueryRowContext(ctx, "SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&stillLeader)
| !stillLeader {
        log.Println("⚠️  Advisory Lock 已丢失！安全退出...")
        cancel()
    }
```

---

### P1-3. 事件循环潜在竞态条件

> **位置：** `StartEventLoop()` 第251-288行
> **状态：** ❌ **未修复**

**修复方案：**

```go
var syncing int32 // 在 StartEventLoop 函数开头声明

// 在 case <-debounceChan: 中：
case <-debounceChan:
    if atomic.CompareAndSwapInt32(&syncing, 0, 1) {
        go func() {
            defer atomic.StoreInt32(&syncing, 0)
            log.Println("⏰ 防抖定时器触发，执行同步...")
            if err := s.Sync(); err != nil {
                log.Printf("❌ 同步失败: %v", err)
            } else {
                log.Println("✅ 同步完成")
            }
        }()
    } else {
        log.Println("⏰ 防抖触发，但同步已在进行中，跳过")
    }
debounceTimer = nil
debounceChan = nil
```

---

### P1-4. DSN 密码未 URL 编码 — 特殊字符导致连接失败

> **位置：** 第152-153行
> **状态：** ❌ **未修复**

**修复方案：**

```go
import "net/url"

// 在 main() 中替换 DSN 构建行：
password := url.QueryEscape(DBPassword)
dsn := fmt.Sprintf("postgres://%s:***@%s:%s/%s?sslmode=%s",
    url.QueryEscape(DBUser), password, DBHost, DBPort, DBName, SSLMode)
```

---

### P1-5. Reconcile 错误降级为 Sync — 网络抖动触发全量同步

> **位置：** 第326-329行
> **状态：** ❌ **未修复**

**修复方案：**

```go
apisixPolicy, err := s.fetchActivePolicyFromApisix()
if err != nil {
    // 区分网络错误与APISIX未初始化
    errStr := err.Error()
|
|
       strings.Contains(errStr, "no such host") {
        log.Printf("⚠️  APISIX 暂时不可用（网络抖动），跳过本次对账: %v", err)
        return nil  // 下次对账再试
    }
    return fmt.Errorf("无法从 APISIX 读取策略: %w", err)
}
```

---

## 🟢 P2 增强级（4项）

### P2-1. 缺少 Prometheus Metrics 端点

> **状态：** ❌ **未修复**

**建议指标：**
```go
// 建议在 /healthz 旁同端口暴露 /metrics
var (
    syncTotal = prometheus.NewCounterVec(...)
    syncDuration = prometheus.NewHistogram(...)
    reconcileTotal = prometheus.NewCounterVec(...)
)
```

### P2-2. 缺少单元测试

> **状态：** ❌ **未修复**

**关键测试点：**
- `formatToCSV` 输出与 SQL `string_agg` 完全一致（含 NULL 处理）
- 空策略表时返回空串
- 单行策略无尾部换行

### P2-3. 冷启动优化未集成

> **位置：** 文档§9.1 第819-823行有代码但 `Sync()` 未包含
> **状态：** ❌ **未修复**

**修复方案（在 Sync() 开头添加）：**

```go
func (s *Syncer) Sync() error {
    rows, err := s.fetchPoliciesFromDB()
    if err != nil {
        return fmt.Errorf("从 DB 读取策略失败: %w", err)
    }
    // 冷启动优化：策略表为空则跳过
    if len(rows) == 0 {
        log.Println("ℹ️  策略表为空，跳过全量同步")
        return nil
    }
    // ... 原有逻辑 ...
}
```

### P2-4. 优雅关闭超时硬编码

> **位置：** 第214行 `time.Sleep(1 * time.Second)`
> **状态：** ❌ **未修复**

**修复方案：**

```go
// 使用 WaitGroup 等待进行中的 Sync 完成
var wg sync.WaitGroup
var syncingP bool  // 是否有同步正在进行

// 在 goroutine 中替换 time.Sleep：
go func() {
    <-sigCh
    log.Println("\n🛑 收到终止信号，正在优雅关闭...")
    cancel()
    // 等待最多 15 秒让进行中的同步完成
    done := make(chan struct{})
    go func() { wgWait(); close(done) }()
    select {
    case <-done:
        log.Println("✅ 同步已完成，关闭中...")
    case <-time.After(15 * time.Second):
        log.Println("⚠️  等待同步超时，强制关闭")
    }
    tx.Rollback()
    db.Close()
    os.Exit(0)
}()
```

---

## 🆕 新发现的问题（4项）

### N-1. Reconcile SQL 缺少 `ptype='p'` 过滤条件

> **位置：** Reconcile 查询第315-318行
> **风险：** 若 `casbin_rule` 未来演进包含非策略行（如调试/审计），对账哈希将包含非策略数据

**修复方案：**

```sql
-- 在 Reconcile 查询末尾添加 WHERE 条件：
SELECT encode(digest(COALESCE(string_agg(
    concat_ws(',', ptype, v0, v1, v2, v3, v4, v5), E'\n'
    ORDER BY ptype, v0, v1, v2, v3, v4, v5
), ''), 'sha256'), 'hex') FROM casbin_rule WHERE ptype = 'p';
```

### N-2. `digest()` 函数依赖 `pgcrypto` 扩展，启动时未确认安装

> **风险：** 若 PG 容器未在 init 脚本中安装 pgcrypto，Reconcile 会无限报错触发全量同步

**修复方案（在 main() db.Ping() 之后）：**

```go
// 确保 pgcrypto 扩展存在（digest函数依赖）
if _, err := db.Exec("CREATE EXTENSION IF NOT EXISTS pgcrypto;"); err != nil {
    log.Fatalf("pgcrypto 扩展不可用（digest()函数需要）: %v", err)
}
log.Println("✅ pgcrypto 扩展确认就绪")
```

### N-3. Docker Build 阶段 `go mod init` 冗余

> **位置：** Dockerfile 第540行
> **建议：** 将 `go.mod` 复制进镜像后直接 `go build`，避免重复初始化模块

### N-4. 运维脚本 grep 关键字不匹配 + 全量日志内存隐患

> **位置：**
> - §6.1 PowerShell 第664行：匹配 `"Successfully listening"`，实际输出 `"✅ 正在监听 PostgreSQL casbin_channel..."`
> - §6.2 bash 第718行：同上
> - §7.3 PowerShell 第774行：`Select-String` 在 Git Bash 中不可用（应为 grep）

**修复方案（脚本）：**

```bash
# bash脚本修正：拉取最近100行而非全量
logs=$(docker logs --tail=100 policy-syncer 2>/dev/null)
 grep -q "正在监听 PostgreSQL"; then
    echo "  ✅ PostgreSQL 监听已建立"
fi
 grep -q "Advisory Lock"; then
    echo "  ✅ 已成为 leader"
fi
```

---

## 文档质量审查

 问题 | 位置 | 修正 |
:---|:---|:---|
 预期输出为英文，代码输出为中文 | §7.1 第739行 vs main第148行 | §7.1 改为 "Policy Syncer — 初始化中…" |
 运维脚本 grep 关键字与代码日志不匹配 | §6.1/§6.2 多处 | 匹配 "正在监听"、"Advisory Lock"、"已获取" |
 §8 故障排查表 "pg_net 扩展未启用" | 第808行 | 改为 "检查 PostgreSQL 连接是否正常"（LISTEN/NOTIFY 是 PG 原生功能） |
 §7.3 `Select-String` 在 bash 中不可用 | 第774行 | 明确标注为 PowerShell 命令，bash 用 `grep` |

---

## 一致性检查

 检查项 | 结果 | 说明 |
:---|:---|:---|
 与 00 总纲一致性 | ✅ 匹配 | Role-in-JWT、无g规则、端口9180、通道名casbin_channel |
 与 02 casbin_rule视图列 | ✅ 匹配 | PolicyRow 含 ptype,v0-v5 共7列 |
 与 04 authz-casbin模型 | ✅ 匹配 | CasbinModelConf 与 04 model.conf 完全一致 |
 与 04 APISIX URL路径 | ✅ 匹配 | `/apisix/admin/plugin_metadata/authz-casbin` |
 与 04.5 Casdoor RS256 | ✅ 兼容 | Syncer不直接验签 |
 内部语言一致性 | ❌ 不匹配 | 中英文混用 |
 运维脚本关键字一致性 | ❌ 不匹配 | 脚本关键字与代码日志不匹配 |
 §8故障排查准确性 | ⚠️ 过时 | pg_net不是LISTEN/NOTIFY依赖 |

---

## 修复优先级建议

### 🔴 立即修复（阻塞部署）

 # | 问题 | 改动文件 | 改动量 |
:---|:---|:---|:---|
 1 | P0-1 尾部换行符 | main.go 第467-469行 | 改1行 |
 2 | P1-1 healthz端点 | main.go ~20行 | 增15行 |
 3 | P1-4 URL编码 | main.go 第152-153行 | 改2行 |
 4 | N-2 pgcrypto扩展 | main.go ~5行 | 增4行 |

### 🟡 尽快修复（提升可靠性）

 # | 问题 | 改动文件 | 改动量 |
:---|:---|:---|:---|
 5 | P1-2 Advisory Lock心跳 | main.go ~15行 | 增12行 |
 6 | P1-5 错误类型区分 | Reconcile() ~8行 | 改5行 |
 7 | P2-3 冷启动优化 | Sync() ~5行 | 增4行 |
 8 | N-1 ptype过滤条件 | Reconcile SQL | 加3字符 |

### 🟢 建议修复（锦上添花）

 # | 问题 | 改动文件 | 改动量 |
:---|:---|:---|:---|
 9 | P1-3 竞态条件 | StartEventLoop ~10行 | 增8行 |
 10 | P2-4 优雅关闭 | main.go signal handler ~8行 | 改5行 |
 11 | 运维脚本关键字 | scripts/*.ps1, *.sh | 改6处 |
 12 | 文档§7.1/§8过时 | 06文档本身 | 改4处 |

---

## 修复后预期效果

```diff
+ P0-1修复后：SHA256对账 100% 匹配，不再触发不必要的全量同步
+ P1-1修复后：可配置 K8s liveness/readiness probe，生产可靠性提升
+ P1-4修复后：特殊密码（含@、/、%、:、#、?）不再导致连接失败
+ N-2修复后：PG容器启动时自动确保pgcrypto可用，避免隐蔽的扩展依赖错误
```

---

## 结论

$$\boxed{\textbf{❌ 不通过 — 需修复后重新审查}}$$

原始审查报告中 **10 个问题均未修复**（P0×1、P1×5、P2×4）。
最小修复集（P0-1 + P1-1 + P1-4 + N-2）约 **1小时工作量** 即可消除阻塞级问题。

**建议：** 先修复 P0-1 + P1-4 + N-2（共约15行改动），重新验证对账功能通过后再进入下一文档审查。