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
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lib/pq"
)

// ==============================================================================
// 配置参数（通过环境变量读取）
// ==============================================================================

var (
	DBHost     = getEnv("DB_HOST", "localhost")
	DBPort     = getEnv("DB_PORT", "5432")
	DBUser     = getEnv("DB_USER", "app_owner")
	DBPassword = getEnv("DB_PASSWORD", "dev_password_change_me")
	DBName     = getEnv("DB_NAME", "app_db")
	SSLMode    = getEnv("SSL_MODE", "disable")
)

var (
	ApisixAdminURL = getEnv("APISIX_ADMIN_URL", "http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin")
	ApisixAdminKey = getEnv("APISIX_ADMIN_KEY", "edd1c9f034335f136f87ad84b625c8f1")
)

// Casbin 模型配置（必须与 etcd 中的 model.conf 一致）
const CasbinModelConf = `[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = g(r.sub, p.sub) && keyMatch2(r.obj, p.obj) && r.act == p.act`

const DebounceDuration = 1 * time.Second

const ReconcileInterval = 10 * time.Minute

const AdvisoryLockKey = 12345

// ==============================================================================
// 状态指标（Prometheus 风格，文本输出）
// ==============================================================================

var (
	syncTotal      int64
	syncFailTotal  int64
	reconcileTotal int64
	reconcileMatch int64
	dbConnected    int32
	isLeader       int32
)

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

// APISIXClient 定义 APISIX 交互接口（便于测试 Mock）
type APISIXClient interface {
	GetPolicy() (string, error)
	PutPolicy(model, policy string) error
}

type httpApisixClient struct {
	url    string
	key    string
	client *http.Client
}

func newHTTPApisixClient(apiURL, apiKey string) *httpApisixClient {
	return &httpApisixClient{
		url:    apiURL,
		key:    apiKey,
		client: &http.Client{Timeout: 10 * time.Second},
	}
}

func (c *httpApisixClient) GetPolicy() (string, error) {
	req, err := http.NewRequest("GET", c.url, nil)
	if err != nil {
		return "", fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", c.key)

	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("HTTP 请求失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
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

func (c *httpApisixClient) PutPolicy(model, policy string) error {
	metadata := ApisixMetadata{
		Model:  model,
		Policy: policy,
	}
	payload, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("序列化 JSON 失败: %w", err)
	}

	req, err := http.NewRequest(http.MethodPut, c.url, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", c.key)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
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

// Syncer 定义同步器
type Syncer struct {
	db             *sql.DB
	client         APISIXClient
	shutdownWg     sync.WaitGroup
	syncInProgress int32 // 原子标志，防止并发同步
}

// 构造函数（便于测试注入）
func NewSyncer(db *sql.DB, client APISIXClient) *Syncer {
	return &Syncer{
		db:     db,
		client: client,
	}
}

// ==============================================================================
// 主函数
// ==============================================================================

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
	log.Println("========================================")
	log.Println("  Policy Syncer — 初始化中...")
	log.Println("========================================")

	// 1. 构建数据库连接
	// 修复 P1-4: DSN 密码需要进行 URL 编码，避免特殊字符解析错误
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		url.QueryEscape(DBUser), url.QueryEscape(DBPassword), DBHost, DBPort, DBName, SSLMode)
	maskedDSN := fmt.Sprintf("postgres://%s:***@%s:%s/%s?sslmode=%s",
		url.QueryEscape(DBUser), DBHost, DBPort, DBName, SSLMode)

	log.Printf("连接数据库: %s:%s/%s", DBHost, DBPort, DBName)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("数据库连接失败: %v", err)
	}
	defer db.Close()

	// 设置连接池参数
	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		log.Fatalf("数据库 ping 失败: %v", err)
	}
	log.Println("✅ 数据库连接成功")
	atomic.StoreInt32(&dbConnected, 1)

	// 修复 N-2: 确保 pgcrypto 扩展存在（digest() 函数依赖）
	if _, err := db.Exec("CREATE EXTENSION IF NOT EXISTS pgcrypto;"); err != nil {
		log.Fatalf("pgcrypto 扩展不可用（digest() 函数需要）: %v", err)
	}
	log.Println("✅ pgcrypto 扩展确认就绪")

	// 2. Advisory Lock 选主（多实例部署时只有一个 leader）
	tx, err := db.Begin()
	if err != nil {
		log.Fatalf("开启事务失败: %v", err)
	}

	var acquired bool
	if err := tx.QueryRow("SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&acquired); err != nil {
		tx.Rollback()
		log.Fatalf("获取 Advisory Lock 失败: %v", err)
	}
	if !acquired {
		tx.Rollback()
		log.Println("⚠️  另一个实例正在运行作为 leader，当前实例将退出")
		return
	}
	log.Println("✅ 已获取 Advisory Lock，当前实例为 leader")
	atomic.StoreInt32(&isLeader, 1)

	// 修复 P1-2: 启动心跳协程，定期验证 Advisory Lock 是否仍被持有
	lockCtx, lockCancel := context.WithCancel(context.Background())
	defer lockCancel()

	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-lockCtx.Done():
				return
			case <-ticker.C:
				var stillLeader bool
				err := db.QueryRowContext(lockCtx, "SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&stillLeader)
				if err != nil || !stillLeader {
					log.Println("⚠️  Advisory Lock 已丢失！安全退出...")
					atomic.StoreInt32(&isLeader, 0)
					lockCancel()
					return
				}
			}
		}
	}()

	// 3. 构建 Syncer 实例
	apisixClient := newHTTPApisixClient(ApisixAdminURL, ApisixAdminKey)
	syncer := NewSyncer(db, apisixClient)

	// 4. 初始全量同步（冷启动）
	log.Println("🔄 执行初始全量同步...")
	if err := syncer.Sync(); err != nil {
		log.Printf("⚠️  初始同步失败（可能是 APISIX 未就绪）: %v", err)
		log.Println("将在事件循环重试...")
	} else {
		log.Println("✅ 初始同步完成")
	}

	// 5. 启动 HTTP 健康检查端点（修复 P1-1: /healthz）
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			atomic.StoreInt32(&dbConnected, 0)
			w.WriteHeader(http.StatusServiceUnavailable)
			log.Printf("/healthz 失败: %v", err)
			return
		}
		atomic.StoreInt32(&dbConnected, 1)
		w.WriteHeader(http.StatusOK)
	})

	// 修复 P2-1: Prometheus /metrics 端点
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		fmt.Fprintf(w, "# HELP syncer_sync_total Total number of policy syncs\n")
		fmt.Fprintf(w, "# TYPE syncer_sync_total counter\n")
		fmt.Fprintf(w, "syncer_sync_total{status=\"success\"} %d\n", atomic.LoadInt64(&syncTotal))
		fmt.Fprintf(w, "syncer_sync_total{status=\"failure\"} %d\n", atomic.LoadInt64(&syncFailTotal))
		fmt.Fprintf(w, "# HELP syncer_reconcile_total Total number of reconcile runs\n")
		fmt.Fprintf(w, "# TYPE syncer_reconcile_total counter\n")
		fmt.Fprintf(w, "syncer_reconcile_total{status=\"match\"} %d\n", atomic.LoadInt64(&reconcileMatch))
		fmt.Fprintf(w, "syncer_reconcile_total{status=\"mismatch\"} %d\n", atomic.LoadInt64(&reconcileTotal)-atomic.LoadInt64(&reconcileMatch))
		fmt.Fprintf(w, "# HELP syncer_db_connected Database connection status\n")
		fmt.Fprintf(w, "# TYPE syncer_db_connected gauge\n")
		fmt.Fprintf(w, "syncer_db_connected %d\n", atomic.LoadInt32(&dbConnected))
		fmt.Fprintf(w, "# HELP syncer_is_leader Whether this instance is the leader\n")
		fmt.Fprintf(w, "# TYPE syncer_is_leader gauge\n")
		fmt.Fprintf(w, "syncer_is_leader %d\n", atomic.LoadInt32(&isLeader))
	})

	go func() {
		log.Println("✅ /healthz (8080) 和 /metrics 端点已启动")
		if err := http.ListenAndServe(":8080", nil); err != nil {
			log.Printf("HTTP 服务器错误: %v", err)
		}
	}()

	// 6. 启动事件循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 信号监听（优雅关闭）
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// 修复 P2-4: 优雅关闭超时时间可配置
	shutdownTimeout := getShutdownTimeout()

	go func() {
		<-sigCh
		log.Println("\n🛑 收到终止信号，正在优雅关闭...")
		cancel()
		lockCancel()

		// 等待进行中的同步完成（最多等待 shutdownTimeout）
		done := make(chan struct{})
		go func() {
			syncer.shutdownWg.Wait()
			close(done)
		}()

		select {
		case <-done:
			log.Println("✅ 所有同步已完成，关闭中...")
		case <-time.After(shutdownTimeout):
			log.Printf("⚠️  等待同步超时（%s），强制关闭", shutdownTimeout)
		}
		tx.Rollback()
		db.Close()
		os.Exit(0)
	}()

	// 7. 启动 PostgreSQL LISTENER（使用独立连接字符串，自定义 ReportProblem）
	listener := pq.NewListener(dsn, 10*time.Second, 10*time.Minute, func(event pq.ListenerEventType, err error) {
		if err != nil {
			log.Printf("PostgreSQL Listener 事件: %v, 错误: %v", event, err)
		}
	})
	defer listener.Close()

	if err := listener.Listen("casbin_channel"); err != nil {
		log.Fatalf("监听 casbin_channel 失败: %v", err)
	}
	log.Println("✅ 正在监听 PostgreSQL casbin_channel...")

	// 8. 进入事件循环
	log.Println("📡 事件循环已启动，实时同步就绪。")
	syncer.StartEventLoop(ctx, listener.Notify, cancel)
}

// ==============================================================================
// 事件循环
// ==============================================================================

func (s *Syncer) StartEventLoop(ctx context.Context, notifyChan <-chan *pq.Notification, cancel context.CancelFunc) {
	reconcileTicker := time.NewTicker(ReconcileInterval)
	defer reconcileTicker.Stop()

	lockTicker := time.NewTicker(1 * time.Minute)
	defer lockTicker.Stop()

	var debounceTimer *time.Timer
	var debounceChan <-chan time.Time

	for {
		select {
		case <-ctx.Done():
			log.Println("事件循环已停止。")
			return

		case n := <-notifyChan:
			if n == nil {
				log.Println("⚠️  PostgreSQL 连接可能断开，等待重连...")
				atomic.StoreInt32(&dbConnected, 0)
				continue
			}
			log.Printf("📨 收到 DB 通知 (channel: %s)，开始防抖...", n.Channel)
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			debounceTimer = time.NewTimer(DebounceDuration)
			debounceChan = debounceTimer.C

		case <-debounceChan:
			debounceTimer = nil
			debounceChan = nil
			// 修复 P1-3: 原子标志防止并发同步
			if atomic.CompareAndSwapInt32(&s.syncInProgress, 0, 1) {
				s.shutdownWg.Add(1)
				go func() {
					defer func() {
						atomic.StoreInt32(&s.syncInProgress, 0)
						s.shutdownWg.Done()
					}()
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

		case <-reconcileTicker.C:
			log.Println("🔍 定时对账触发...")
			if atomic.CompareAndSwapInt32(&s.syncInProgress, 0, 1) {
				s.shutdownWg.Add(1)
				go func() {
					defer func() {
						atomic.StoreInt32(&s.syncInProgress, 0)
						s.shutdownWg.Done()
					}()
					if err := s.Reconcile(); err != nil {
						log.Printf("⚠️  对账失败: %v", err)
					}
				}()
			} else {
				log.Println("🔍 对账触发，但同步已在进行中，跳过")
			}

		case <-lockTicker.C:
			var stillLeader bool
			err := s.db.QueryRowContext(ctx, "SELECT pg_try_advisory_lock($1)", AdvisoryLockKey).Scan(&stillLeader)
			if err != nil || !stillLeader {
				log.Println("⚠️  Advisory Lock 已丢失！安全退出...")
				atomic.StoreInt32(&isLeader, 0)
				cancel()
				return
			}
		}
	}
}

// ==============================================================================
// 同步方法
// ==============================================================================

func (s *Syncer) Sync() error {
	rows, err := s.fetchPoliciesFromDB()
	if err != nil {
		atomic.AddInt64(&syncFailTotal, 1)
		return fmt.Errorf("从 DB 读取策略失败: %w", err)
	}

	// 修复 P2-3: 冷启动优化，策略表为空则跳过同步
	if len(rows) == 0 {
		log.Println("ℹ️  策略表为空，跳过全量同步")
		return nil
	}

	policyStr := s.formatToCSV(rows)
	if err := s.client.PutPolicy(CasbinModelConf, policyStr); err != nil {
		atomic.AddInt64(&syncFailTotal, 1)
		return fmt.Errorf("推送到 APISIX 失败: %w", err)
	}

	atomic.AddInt64(&syncTotal, 1)
	log.Printf("✅ 已同步 %d 条策略到 APISIX", len(rows))
	return nil
}

func (s *Syncer) Reconcile() error {
	atomic.AddInt64(&reconcileTotal, 1)

	// 计算数据库侧 SHA256 指纹
	// 修复 N-1: 添加 WHERE ptype='p' 过滤
	var dbHash string
	query := `SELECT COALESCE(encode(digest(string_agg(
		concat_ws(',', ptype, v0, v1, v2, v3, v4, v5), E'\n'
		ORDER BY ptype, v0, v1, v2, v3, v4, v5
	), 'sha256'), 'hex'), '') FROM casbin_rule WHERE ptype = 'p';`

	err := s.db.QueryRow(query).Scan(&dbHash)
	if err != nil {
		return fmt.Errorf("计算 DB 策略哈希失败: %w", err)
	}

	apisixPolicy, err := s.client.GetPolicy()
	if err != nil {
		// 修复 P1-5: 区分网络错误与 APISIX 未初始化
		errStr := err.Error()
		if strings.Contains(errStr, "connection refused") ||
			strings.Contains(errStr, "timeout") ||
			strings.Contains(errStr, "no such host") ||
			strings.Contains(errStr, "context deadline exceeded") {
			log.Printf("⚠️  APISIX 暂时不可用（网络抖动），跳过本次对账: %v", err)
			return nil
		}
		log.Printf("❌ 读取 APISIX 策略失败: %v，触发全量同步", err)
		return s.Sync()
	}

	apisixHash := fmt.Sprintf("%x", sha256.Sum256([]byte(apisixPolicy)))

	log.Printf("🔍 对账: DB=%s APISIX=%s", truncate(dbHash, 16), truncate(apisixHash, 16))

	if dbHash != apisixHash {
		atomic.AddInt64(&syncFailTotal, 1)
		log.Println("⚠️  哈希不匹配！触发全量同步...")
		return s.Sync()
	}

	atomic.AddInt64(&reconcileMatch, 1)
	log.Println("✅ 哈希匹配，APISIX 与 DB 一致")
	return nil
}

// ==============================================================================
// 数据库操作
// ==============================================================================

func (s *Syncer) fetchPoliciesFromDB() ([]PolicyRow, error) {
	query := `SELECT ptype, v0, v1, v2, v3, v4, v5 FROM casbin_rule WHERE ptype = 'p' ORDER BY ptype, v0, v1, v2, v3, v4, v5;`
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
// 策略格式化（修复 P0-1: 去掉尾部换行）
// ==============================================================================

func (s *Syncer) formatToCSV(rows []PolicyRow) string {
	var lines []string
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
	// strings.Join 不会在末尾添加 \n，与 SQL string_agg 行为完全一致
	return strings.Join(lines, "\n")
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

func getShutdownTimeout() time.Duration {
	s := os.Getenv("SHUTDOWN_TIMEOUT")
	if s == "" {
		return 15 * time.Second
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		log.Printf("⚠️  SHUTDOWN_TIMEOUT 格式错误，使用默认值 15s: %v", err)
		return 15 * time.Second
	}
	return d
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
