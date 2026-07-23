package syncer

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lib/pq"
	"policy-syncer/internal/apisix"
	"policy-syncer/internal/database"
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

// 状态指标（Prometheus 风格，文本输出）
// 导出供 main 包访问
var (
	SyncTotal      int64
	SyncFailTotal  int64
	ReconcileTotal int64
	ReconcileMatch int64
	DbConnected    int32
	IsLeader       int32
)

// Syncer 定义同步器
type Syncer struct {
	db             *sql.DB
	store          database.DBPolicyStore
	client         apisix.APISIXClient
	shutdownWg     sync.WaitGroup
	syncInProgress int32 // 原子标志，防止并发同步
}

// NewSyncer 构造函数（便于测试注入）
func NewSyncer(db *sql.DB, store database.DBPolicyStore, client apisix.APISIXClient) *Syncer {
	return &Syncer{
		db:     db,
		store:  store,
		client: client,
	}
}

// Wait 等待所有进行中的同步完成
func (s *Syncer) Wait() {
	s.shutdownWg.Wait()
}

// StartEventLoop 事件循环
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
				atomic.StoreInt32(&DbConnected, 0)
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
				atomic.StoreInt32(&IsLeader, 0)
				cancel()
				return
			}
		}
	}
}

// Sync 同步方法
func (s *Syncer) Sync() error {
	rows, err := s.store.FetchPolicies()
	if err != nil {
		atomic.AddInt64(&SyncFailTotal, 1)
		return fmt.Errorf("从 DB 读取策略失败: %w", err)
	}

	// 修复 P2-3: 冷启动优化，策略表为空则跳过同步
	if len(rows) == 0 {
		log.Println("ℹ️  策略表为空，跳过全量同步")
		return nil
	}

	policyStr := formatToCSV(rows)
	if err := s.client.PutPolicy(CasbinModelConf, policyStr); err != nil {
		atomic.AddInt64(&SyncFailTotal, 1)
		return fmt.Errorf("推送到 APISIX 失败: %w", err)
	}

	atomic.AddInt64(&SyncTotal, 1)
	log.Printf("✅ 已同步 %d 条策略到 APISIX", len(rows))
	return nil
}

// Reconcile 定时对账
func (s *Syncer) Reconcile() error {
	atomic.AddInt64(&ReconcileTotal, 1)

	dbHash, err := s.store.CalcPolicyHash()
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
		atomic.AddInt64(&SyncFailTotal, 1)
		log.Println("⚠️  哈希不匹配！触发全量同步...")
		return s.Sync()
	}

	atomic.AddInt64(&ReconcileMatch, 1)
	log.Println("✅ 哈希匹配，APISIX 与 DB 一致")
	return nil
}

// formatToCSV 策略格式化（修复 P0-1: 去掉尾部换行）
func formatToCSV(rows []database.PolicyRow) string {
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
	return strings.Join(lines, "\n")
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
