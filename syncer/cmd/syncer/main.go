package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lib/pq"
	"policy-syncer/internal/apisix"
	"policy-syncer/internal/database"
	"policy-syncer/internal/syncer"
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
	dsn := fmt.Sprintf("postgres://%s:***@%s:%s/%s?sslmode=%s",
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
	atomic.StoreInt32(&syncer.DbConnected, 1)

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
	if err := tx.QueryRow("SELECT pg_try_advisory_lock($1)", syncer.AdvisoryLockKey).Scan(&acquired); err != nil {
		tx.Rollback()
		log.Fatalf("获取 Advisory Lock 失败: %v", err)
	}
	if !acquired {
		tx.Rollback()
		log.Println("⚠️  另一个实例正在运行作为 leader，当前实例将退出")
		return
	}
	log.Println("✅ 已获取 Advisory Lock，当前实例为 leader")
	atomic.StoreInt32(&syncer.IsLeader, 1)

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
				err := db.QueryRowContext(lockCtx, "SELECT pg_try_advisory_lock($1)", syncer.AdvisoryLockKey).Scan(&stillLeader)
				if err != nil || !stillLeader {
					log.Println("⚠️  Advisory Lock 已丢失！安全退出...")
					atomic.StoreInt32(&syncer.IsLeader, 0)
					lockCancel()
					return
				}
			}
		}
	}()

	// 3. 构建 Syncer 实例
	store := database.NewPostgresStore(db)
	apisixClient := apisix.NewHTTPClient(ApisixAdminURL, ApisixAdminKey)
	s := syncer.NewSyncer(db, store, apisixClient)

	// 4. 初始全量同步（冷启动）
	log.Println("🔄 执行初始全量同步...")
	if err := s.Sync(); err != nil {
		log.Printf("⚠️  初始同步失败（可能是 APISIX 未就绪）: %v", err)
		log.Println("将在事件循环重试...")
	} else {
		log.Println("✅ 初始同步完成")
	}

	// 5. 启动 HTTP 健康检查端点（修复 P1-1: /healthz）
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			atomic.StoreInt32(&syncer.DbConnected, 0)
			w.WriteHeader(http.StatusServiceUnavailable)
			log.Printf("/healthz 失败: %v", err)
			return
		}
		atomic.StoreInt32(&syncer.DbConnected, 1)
		w.WriteHeader(http.StatusOK)
	})

	// 修复 P2-1: Prometheus /metrics 端点
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		fmt.Fprintf(w, "# HELP syncer_sync_total Total number of policy syncs\n")
		fmt.Fprintf(w, "# TYPE syncer_sync_total counter\n")
		fmt.Fprintf(w, "syncer_sync_total{status=\"success\"} %d\n", atomic.LoadInt64(&syncer.SyncTotal))
		fmt.Fprintf(w, "syncer_sync_total{status=\"failure\"} %d\n", atomic.LoadInt64(&syncer.SyncFailTotal))
		fmt.Fprintf(w, "# HELP syncer_reconcile_total Total number of reconcile runs\n")
		fmt.Fprintf(w, "# TYPE syncer_reconcile_total counter\n")
		fmt.Fprintf(w, "syncer_reconcile_total{status=\"match\"} %d\n", atomic.LoadInt64(&syncer.ReconcileMatch))
		fmt.Fprintf(w, "syncer_reconcile_total{status=\"mismatch\"} %d\n", atomic.LoadInt64(&syncer.ReconcileTotal)-atomic.LoadInt64(&syncer.ReconcileMatch))
		fmt.Fprintf(w, "# HELP syncer_db_connected Database connection status\n")
		fmt.Fprintf(w, "# TYPE syncer_db_connected gauge\n")
		fmt.Fprintf(w, "syncer_db_connected %d\n", atomic.LoadInt32(&syncer.DbConnected))
		fmt.Fprintf(w, "# HELP syncer_is_leader Whether this instance is the leader\n")
		fmt.Fprintf(w, "# TYPE syncer_is_leader gauge\n")
		fmt.Fprintf(w, "syncer_is_leader %d\n", atomic.LoadInt32(&syncer.IsLeader))
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
			s.Wait()
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
	s.StartEventLoop(ctx, listener.Notify, cancel)
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
