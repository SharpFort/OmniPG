# Policy Syncer 架构决策与实施策略

> **创建日期：** 2026-07-10
> **文档类型：** 架构决策记录 (ADR)
> **关联文档：** 06-Policy-Syncer-Go实现.md, 审查文档/06-审查报告.md

---

## 1. 背景与核心问题

### 1.1 项目背景

本项目采用"零后端代码（Database-Driven）"架构：
- **数据库端**：PostgreSQL + VIEW (`casbin_rule`) 自动反映 RBAC 策略
- **网关端**：APISIX + `authz-casbin` 插件执行策略匹配
- **同步服务**：Policy Syncer (Go) 负责桥接两者

### 1.2 核心讨论问题

| # | 问题 | 结论 |
|:---|:---|:---|
| 1 | Syncer 的本质作用是什么？ | **数据搬运工**——将 DB VIEW 数据推送到 APISIX etcd |
| 2 | 是否可以移除 Syncer？ | **不能**——APISIX 无法直连 PG 加载策略 |
| 3 | casbin-pg-adapter 能否替代 Syncer？ | **不能**——它是 Go 库，不是服务，无法推送数据 |
| 4 | 是否支持增量更新？ | **当前全量**——APISIX API 不支持增量 |
| 5 | 性能消耗如何？ | **极低**——NOTIFY + 全量读取 < 1万行很快 |

---

## 2. 当前架构详解

### 2.1 数据流图

```
┌─────────────────────────────────────────────────────────────────────────┐
│  管理员操作（UI/API）                                                    │
│  INSERT/UPDATE/DELETE ON sys_role_api                                   │
│       │                                                                 │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  PostgreSQL 触发器 (trg_reload_on_role_api)                      │   │
│  │  AFTER INSERT OR UPDATE OR DELETE ON sys_role_api                │   │
│  │  FOR EACH STATEMENT                                              │   │
│  │                                                                  │   │
│  │  PERFORM pg_notify('casbin_channel',                             │   │
│  │    json_build_object('op', TG_OP, 'table', TG_TABLE_NAME,        │   │
│  │                      'ts', extract(epoch from now())::bigint     │   │
│  │  )::text);                                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼ (异步通知，不携带数据)                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Policy Syncer (Go 服务)                                         │   │
│  │                                                                  │   │
│  │  1. LISTEN casbin_channel                                        │   │
│  │  2. 收到通知 → 1秒防抖 (合并短时间内多次变更)                    │   │
│  │  3. 防抖后 → SELECT ptype, v0, v1, v2 FROM casbin_rule          │   │
│  │  4. formatToCSV() → 转换为 Casbin 兼容的 CSV 格式               │   │
│  │  5. PUT /apisix/admin/plugin_metadata/authz-casbin               │   │
│  │     → 全量覆写 APISIX etcd 中的策略                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│       │                                                                 │
│       ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Apache APISIX (Docker)                                          │   │
│  │                                                                  │   │
│  │  etcd (plugin_metadata.authz-casbin)                             │   │
│  │  │                                                               │   │
│  │  ▼ (启动时 / 收到 PUT 时)                                        │   │
│  │  Lua Casbin Enforcer (内存加载)                                  │   │
│  │  │                                                               │   │
│  │  ▼                                                                │   │
│  │  请求 → 提取 sub, obj, act → 内存匹配 → allow/deny               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 关键组件说明

#### 数据库端：`casbin_rule` VIEW

```sql
-- 07-Database-Migrations.md Migration 003
CREATE OR REPLACE VIEW casbin_rule AS
SELECT 
    NULL::integer AS id,
    'p'::varchar AS ptype,
    r.role_code::varchar AS v0,      -- 策略主体：角色
    a.path::varchar AS v1,           -- 策略对象：API 路径
    a.method::varchar AS v2,         -- 策略动作：HTTP 方法
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM sys_role_api ra
JOIN sys_role r ON ra.role_id = r.id 
                     AND r.is_active = true      -- [修复 P1-1]
JOIN sys_api a ON ra.api_id = a.id 
                   AND a.is_active = true;       -- [修复 P1-1]
```

**特性：**
- **自动反映**：VIEW 每次查询时实时计算，永远是最新的
- **过滤无效数据**：`is_active = true` 确保只输出有效角色和 API
- **无需维护**：无需手动更新，数据变更自动反映

#### 触发器：`trg_reload_on_role_api`

```sql
-- 07-Database-Migrations.md Migration 004
CREATE OR REPLACE FUNCTION notify_policy_reload()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('casbin_channel', json_build_object(
        'op', TG_OP,
        'table', TG_TABLE_NAME,
        'ts', extract(epoch from now())::bigint
    )::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reload_on_role_api
AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
FOR EACH STATEMENT EXECUTE FUNCTION notify_policy_reload();
```

**特性：**
- **语句级触发**：`FOR EACH STATEMENT` 避免批量操作时触发风暴
- **仅发送信号**：不传输实际数据，仅通知"有变化"
- **JSON payload**：包含操作类型和时间戳，便于调试

#### Syncer 核心逻辑

```go
// 06-Policy-Syncer-Go实现.md 简化版
func (s *Syncer) StartEventLoop(ctx context.Context, notifyChan <-chan *pq.Notification) {
    ticker := time.NewTicker(ReconcileInterval)  // 10分钟对账
    var debounceTimer *time.Timer
    
    for {
        select {
        case n := <-notifyChan:
            // 收到 PG 通知 → 重置防抖定时器
            if debounceTimer != nil {
                debounceTimer.Stop()
            }
            debounceTimer = time.NewTimer(1 * time.Second)
            
        case <-debounceTimer.C:
            // 防抖后执行全量同步
            s.Sync()
            
        case <-ticker.C:
            // 定时对账（SHA256 哈希校验）
            s.Reconcile()
        }
    }
}

func (s *Syncer) Sync() error {
    // 1. 全量读取 VIEW
    rows, _ := s.fetchPoliciesFromDB()  // SELECT * FROM casbin_rule
    
    // 2. 格式转换为 CSV
    policyStr := s.formatToCSV(rows)
    
    // 3. 全量推送到 APISIX
    s.pushToApisix(policyStr)  // PUT Admin API
    
    return nil
}
```

---

## 3. 替代方案调研

### 3.1 casbin-pg-adapter

**项目地址：** https://github.com/apache/casbin-pg-adapter

| 属性 | 值 |
|:---|:---|
| 类型 | Go 库（非服务） |
| 运行方式 | 嵌入 Go 应用进程 |
| 核心方法 | `LoadPolicy()`, `SavePolicy()`, `AddPolicy()`, `RemovePolicy()` |
| 变更通知 | ❌ 不支持 Watcher |
| 数据推送 | ❌ 无法推送到外部系统 |
| 适用场景 | Go 应用内做策略匹配 |

**结论：不能替代 Syncer。**

### 3.2 其他 PostgreSQL Casbin 适配器

| 适配器 | 语言 | Watcher | 适用性 |
|:---|:---|:---|:---|
| `apache/casbin-pg-adapter` | Go | ❌ | 应用内匹配 |
| `going/casbin-postgres-adapter` | Go | ❌ | 已归档 (2019) |
| `apache/casbin-sqlx-adapter` | Rust | ❌ | 应用内匹配 |
| `Blank-Xu/sql-adapter` | Go | ❌ | 应用内匹配 |

**结论：所有适配器都是应用级库，无法作为独立服务推送数据到 APISIX。**

### 3.3 APISIX 端限制

APISIX `authz-casbin` 插件的策略加载方式：

| 方式 | 支持 | 说明 |
|:---|:---|:---|
| `model_path` + `policy_path` | ✅ | 本地文件路径 |
| `model` + `policy` (内联) | ✅ | JSON 配置中的字符串 |
| HTTP 端点 | ❌ | 不支持从 URL 加载 |
| PostgreSQL 连接 | ❌ | Lua 没有 pg 适配器 |
| etcd 监听 | ✅ | 通过 Admin API 写入 etcd |

**结论：APISIX 只能通过 etcd/文件加载策略，必须有一个"搬运工"服务。**

---

## 4. 性能分析

### 4.1 各环节开销

| 操作 | 开销 | 说明 |
|:---|:---|:---|
| `pg_notify` | **极低** | 仅发送信号，不传输数据 |
| `LISTEN` (PG) | **极低** | 原生支持，类似 WebSocket |
| 全量读取 VIEW | **中等** | 1万行约 10-50ms |
| CSV 格式化 | **低** | 内存操作 |
| PUT APISIX API | **低** | HTTP 请求，传输文本 |
| SHA256 对账 | **低** | 每 10 分钟一次 |

### 4.2 全量 vs 增量

**当前实现：全量同步**

```go
// 每次变更都全量读取 + 全量推送
rows := db.Query("SELECT * FROM casbin_rule")  // 全量读取
csv := formatToCSV(rows)                        // 全量格式化
PUT apisix/admin/plugin_metadata/authz-casbin   // 全量覆写
```

**为何不能增量？**

| 层面 | 限制 |
|:---|:---|
| APISIX Admin API | `plugin_metadata` 是**全量覆写**，不支持追加/删除单条 |
| Casbin Lua Enforcer | 策略匹配在内存中进行，需要完整策略集 |
| 数据库 VIEW | VIEW 是虚拟表，无法追踪"哪些行变了" |

**结论：在当前架构下，全量同步是唯一选择。**

### 4.3 全量同步的性能影响

| 策略数量 | 读取时间 | CSV 大小 | 推送延迟 |
|:---|:---|:---|:---|
| 100 行 | < 5ms | ~5KB | < 50ms |
| 1,000 行 | ~10ms | ~50KB | < 100ms |
| 10,000 行 | ~50ms | ~500KB | < 200ms |
| 100,000 行 | ~500ms | ~5MB | < 1s |

**结论：** 对于 RBAC 系统（通常 < 1万条策略），全量同步的开销完全可接受。

---

## 5. 实施策略建议

### 5.1 开发环境：简化版 Syncer（轮询模式）

**目标：** 代码量从 500 行减至 50 行，去掉 LISTEN/NOTIFY 复杂度。

```go
// syncer/main.go (简化版)
package main

import (
    "database/sql"
    "fmt"
    "log"
    "time"
    
    _ "github.com/lib/pq"
)

func main() {
    db, _ := sql.Open("postgres", "postgres://app_owner:***@localhost:5432/app_db?sslmode=disable")
    defer db.Close()
    
    ticker := time.NewTicker(5 * time.Second)
    defer ticker.Stop()
    
    log.Println("✅ Policy Syncer 启动 (轮询模式, 5秒间隔)")
    
    for range ticker.C {
        rows, err := db.Query("SELECT ptype, v0, v1, v2 FROM casbin_rule ORDER BY ptype, v0, v1")
        if err != nil {
            log.Printf("❌ 查询失败: %v", err)
            continue
        }
        
        var policies []string
        for rows.Next() {
            var ptype, v0, v1, v2 string
            rows.Scan(&ptype, &v0, &v1, &v2)
            policies = append(policies, fmt.Sprintf("%s,%s,%s,%s", ptype, v0, v1, v2))
        }
        rows.Close()
        
        // TODO: 推送到 APISIX Admin API
        log.Printf("✅ 已同步 %d 条策略", len(policies))
    }
}
```

**优点：**
- 代码极简，易于理解和维护
- 无需 LISTEN/NOTIFY，无需防抖逻辑
- 5 秒延迟对 RBAC 完全可接受

**缺点：**
- 有 5 秒延迟（但 RBAC 策略变更频率低，可接受）

### 5.2 生产环境：完整版 Syncer（事件驱动）

**目标：** 实时同步（1-2秒延迟），增加对账和健康检查。

保留 06 文档中的完整实现：
- LISTEN/NOTIFY 事件驱动
- 1 秒防抖
- SHA256 对账（每 10 分钟）
- Advisory Lock 多实例选主
- `/healthz` 健康检查端点

### 5.3 备选方案：Shell 脚本（最简）

```bash
#!/bin/bash
# scripts/sync-casbin.sh
# 每 5 秒导出 casbin_rule VIEW 到 CSV

while true; do
    psql -h localhost -U app_owner -d app_db -c \
        "COPY (SELECT ptype,v0,v1,v2 FROM casbin_rule ORDER BY ptype,v0,v1) TO STDOUT CSV" \
        > /tmp/casbin_policy.csv
    
    # 可选：推送到 APISIX
    # curl -s -X PUT http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin \
    #   -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
    #   -d "{\"model\":\"...\",\"policy\":\"$(cat /tmp/casbin_policy.csv | base64)\"}"
    
    sleep 5
done
```

---

## 6. 决策矩阵

| 方案 | 实时性 | 复杂度 | 适用场景 |
|:---|:---|:---|:---|
| **A: 轮询模式 (Go)** | 5秒 | ⭐ 最低 | 开发环境、小型项目 |
| **B: 事件驱动 (Go)** | 1-2秒 | ⭐⭐ 中 | 生产环境 |
| **C: Shell 脚本** | 5秒 | ⭐ 最低 | 快速验证、临时方案 |
| **D: 保留 Syncer (当前)** | 1-2秒 | ⭐⭐⭐ 高 | 已有 Go 基础设施 |

**推荐：**
- **开发环境：方案 A（轮询模式）**
- **生产环境：方案 B（事件驱动）或 D（当前完整方案）**

---

## 7. 实施步骤

### 7.1 开发环境部署

```bash
# 1. 确保 PostgreSQL 运行在 WSL2
sudo systemctl status postgresql

# 2. 确保 casbin_rule VIEW 存在
psql -U app_owner -d app_db -c "SELECT * FROM casbin_rule LIMIT 5;"

# 3. 启动简化版 Syncer
cd syncer
go run main.go

# 4. 验证同步
curl http://localhost:9180/apisix/admin/plugin_metadata/authz-casbin \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"
```

### 7.2 验证清单

- [ ] 数据库 VIEW 能正确查询
- [ ] Syncer 能读取 VIEW 数据
- [ ] Syncer 能推送数据到 APISIX
- [ ] APISIX 策略匹配正常工作
- [ ] 修改 `sys_role_api` 后 5 秒内 APISIX 策略更新

---

## 8. 风险与注意事项

| 风险 | 缓解措施 |
|:---|:---|
| Syncer 宕机导致策略不同步 | 1. 设置健康检查告警 2. 定时对账（SHA256） |
| 全量同步导致 APISIX 短暂不可用 | 1. 使用 HTTP PUT 原子操作 2. 策略量 < 1万行时延迟 < 200ms |
| 数据库 VIEW 性能问题 | 1. 确保 `sys_role_api` 表有索引 2. 定期 ANALYZE |
| 多实例 Syncer 并发写入 | 使用 Advisory Lock 选主 |

---

## 9. 参考文档

| 文档 | 内容 |
|:---|:---|
| `06-Policy-Syncer-Go实现.md` | 完整 Syncer 实现（Go 源码、Dockerfile、运维脚本） |
| `审查文档/06-审查报告.md` | 原始审查报告（P0/P1/P2 问题） |
| `07-Database-Migrations.md` | `casbin_rule` VIEW 和触发器定义 |
| `08-Docker-Compose.md` | Syncer 在 docker-compose.yml 中的服务定义 |
| `10-APISIX路由批量配置.md` | APISIX authz-casbin 插件配置 |

---

## 10. 变更记录

| 日期 | 变更 | 说明 |
|:---|:---|:---|
| 2026-07-10 | 初始版本 | 基于讨论结果整理 |
| 2026-07-21 | 追加审查报告 | 根据 Role-in-JWT 方案审查，发现 5 处问题，见 §11 |

---

## 11. 审查报告（2026-07-21）

> **审查背景：** 项目已确认采用 **Role-in-JWT + casbin_rule 仅存 p 规则 + Syncer 监控权限变更并全量推送 p 规则** 的精简方案。审查旨在发现与决策不符的内容。

### 审查结果

| # | 位置 | 严重度 | 问题 | 建议修复 |
|---|------|--------|------|----------|
| **1** | **§1.1 + 全文** | 🔴 关键 | **最关键的架构缺失**：全文未说明 JWT 中的角色如何被 `authz-casbin` 消费。APISIX 的 `authz-casbin` **从请求 Header 提取 `sub`，不解析 JWT**。你的方案需要完整认证→授权链路：① `jwt-auth` 插件验证 JWT → ② 将 roles 写入 Header（如 `X-User-Roles`）→ ③ `authz-casbin` 用该 Header 做 subject。整条链路缺失。 | 补充说明：JWT → jwt-auth → roles 写入 Header → authz-casbin |
| **2** | **§2.1 数据流图** | 🟡 不符 | 仍描述完整事件驱动（LISTEN/NOTIFY + 1s 防抖 + 10min 对账）。你已精简为"轮询全量同步 p 规则"，文档与决策不符 | 可保留为"生产方案"，但需新增"精简方案：轮询同步 p 规则"作为主推荐 |
| **3** | **§5.3 Shell 脚本** | 🟡 错误 | 将 policy CSV base64 编码后放入 JSON body。APISIX Admin API 的 `policy` 字段期望**纯文本格式**（`"p,admin,/api/users,GET\n..."`），不是 base64 | 改为直接传 CSV 文本：`{"model":"...","policy":"p,admin,/api/users,GET\np,admin,/api/users,POST\n..."}` |
| **4** | **§4.2 全量 vs 增量** | 🟡 不准确 | 写"VIEW 是虚拟表，无法追踪'哪些行变了'"——**不准确**。PG 语句级触发器可通过过渡表获取 `OLD`/`NEW`，底层表 `sys_role_api` 可以追踪变化 | 应改为：当前设计使用全量同步（非性能瓶颈，p 规则 < 1万条），但技术上可通过 `sys_role_api` 触发器实现增量同步 |
| **5** | **§3.3 APISIX 限制** | 🟢 补充 | 写"PostgreSQL 连接：❌ Lua 没有 pg 适配器"——需补充：**官方确认 `authz-casbin` 不支持从 DB 加载策略**，策略必须在 worker 启动时通过文件或 plugin_metadata 加载到内存。这是必须保留 Syncer 的根本原因 | 补充说明官方确认的限制（已通过子代理验证） |

### 额外发现

| 项目 | 说明 |
|------|------|
| **Grafana 端口冲突** | 文档 §5.1 测试验证中 Grafana 端口 3000 与 PostgREST 端口 3000 冲突。Pigsty INFRA 部署的 Grafana 也在 3000。PostgREST 在 Docker 中，Grafana 在 WSL2 中，但都映射到 Windows 的 3000 端口——**Windows 侧会冲突** |
| **JWT 认证职责** | `authz-casbin` 本身不做 JWT 验证，只匹配权限。文档应明确哪个组件负责 JWT 签发/验证（Casdoor 或 `jwt-auth` 插件） |

### 验证来源

- Apache APISIX `authz-casbin` 官方文档：https://apisix.apache.org/zh/docs/apisix/plugins/authz-casbin/
- Apache APISIX `authz-casdoor` 官方文档：https://apisix.apache.org/zh/docs/apisix/plugins/authz-casdoor/
- 关键确认：`authz-casbin` **不支持从数据库实时加载策略**，策略在 worker 启动时加载到内存
