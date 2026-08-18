# 生产问题排查

本文汇总 OmniPG 生产/联调环境的高频问题与排查路径。所有命令与事实以当前代码为准（master，2026-08-18 核对）。日志与指标的大前提：先确认影响面（网关/数据库/认证），再逐层下钻。

## 0. 日志位置速查

| 组件 | 日志/入口 | 查看方式 |
| --- | --- | --- |
| APISIX | 容器日志 + error.log | docker logs app-apisix --tail 200 |
| APISIX 状态 | Status API | curl http://localhost:7085/status |
| PostgREST | 容器日志（PGRST 错误码） | docker logs app-postgrest --tail 100 |
| Logto | 容器日志 | docker logs app-logto --tail 200 |
| PostgreSQL | /var/log/postgresql/（Pigsty 宿主） | tail -f /var/log/postgresql/*.log |
| pgBouncer | /var/log/postgresql/pgbouncer.log | tail -f /var/log/postgresql/pgbouncer.log |
| etcd | 容器日志 | docker logs app-etcd --tail 100 |
| Swagger | 浏览器 + PostgREST spec | http://localhost:8082/ |

## 1. 连接问题（pgbouncer / 连接数打满）

### 1.1 配置事实

- PostgreSQL：max_connections = 100（infra/postgresql.conf）。
- pgBouncer（infra/pgbouncer.ini）：listen 0.0.0.0:6432，pool_mode = session，max_client_conn = 100，default_pool_size = 20，reserve_pool_size = 5，reserve_pool_timeout = 3，server_idle_timeout = 600。
- PostgREST 经 host.docker.internal:6432 连接 app_db；容器 → 宿主网络依赖 Windows 11 mirrored 模式或 scripts/wsl-portproxy.ps1 端口转发（见 22 号实施记录）。

### 1.2 排查步骤

```bash
# ① 看 pgBouncer 池状态（admin console 库）
psql -h 127.0.0.1 -p 6432 -U app_owner -d pgbouncer -c 'SHOW POOLS;'
psql -h 127.0.0.1 -p 6432 -U app_owner -d pgbouncer -c 'SHOW STATS;'

# ② 看数据库侧活跃会话/连接数
psql -h 127.0.0.1 -U app_owner -d app_db -c \
  "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"

# ③ 容器 → 宿主连通性
docker exec app-postgrest sh -c 'nc -zv host.docker.internal 6432 2>&1'
```

### 1.3 常见根因与处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 连接全部超时/报 too many clients | max_client_conn(100) 或 default_pool_size(20) 打满 | 调大 pgbouncer 池参数并重启；排查长事务/空闲会话；应用侧做连接复用 |
| session 池被长事务占满 | pool_mode=session，事务外保持连接 | 评估切 transaction 模式或限制长事务（statement_timeout） |
| 容器连不上 6432 | WSL2 网络隔离 | Win11 mirrored 模式；或重跑 scripts/wsl-portproxy.ps1；pg_hba 放行 172.17/172.20 网段（已配置） |
| authenticator 认证失败 | userlist.txt 密码与 PG 角色密码不一致 | 同步 infra/pigsty.yml pg_users 与 infra/userlist.txt 后重载 pgbouncer |

### 1.4 已知配置偏差（待核实）

- Logto 业务库走宿主 **5433**（统一端口口径，compose 中 host.docker.internal:5433/logto）。Pigsty 侧当前**未声明 logto 角色/库**（pigsty.yml pg_users、pgbouncer.ini、userlist.txt 均无 logto 条目）—— **首次部署前需在 Pigsty 创建 logto 角色与 logto 库**（可 5432 直连或经 6432 池），此为待补齐项（TODO）。

## 2. 性能问题：慢查询定位

### 2.1 当前可用手段

- **pg_stat_activity**（实时活跃查询）；**pg_stat_statements** 当前**未启用**（shared_preload_libraries = 'pg_net,pg_cron'，infra/postgresql.conf）——如需慢 SQL 累积统计，需加到 preload 并重启（TODO）。
- **EXPLAIN ANALYZE** 手工定位（PostgREST 日志给出语句后复现）。
- **index_advisor 扩展**在 Pigsty 扩展列表中（P1 试点），可给出索引建议。
- auto_explain 未开启；log_min_duration_statement 默认 -1（不记录）。

### 2.2 定位命令

```sql
-- 当前活跃查询（含等待事件）
SELECT pid, state, wait_event_type, wait_event, now()-query_start AS dur,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND query <> ''
ORDER BY dur DESC;

-- 长事务/空闲事务
SELECT pid, state, now()-xact_start AS xact_age, now()-query_start AS q_age,
       left(query, 120)
FROM pg_stat_activity
WHERE state = 'idle in transaction' OR (state = 'active' AND now()-query_start > interval '5 seconds');
```

### 2.3 常见根因

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 单 RPC 慢 | 缺索引（ILIKE 前缀通配走全表） | 核对 065 基线索引；用 index_advisor；对高频过滤列加 btree/gin |
| 审计页慢 | audit_log 无分区且增长快 | 见 [审计与日志](audit-logging.md) 保留/归档建议 |
| 偶发尖峰 | 连接池排队（见 §1）或 checkpoint（max_wal_size=1GB） | 错峰任务、调 checkpoint 参数 |
| 聚合视图慢 | v_system_stats_realtime 等实时聚合 | EXPLAIN 后加物化/缓存策略（当前未实现，TODO） |

## 3. 认证异常（token 过期 / Logto 不可用 / 时钟漂移）

### 3.1 401 排查链（自上而下）

1. **APISIX 层**：请求是否命中路由？jwt-auth 是否挂上？
   - curl http://localhost:9180/apisix/admin/routes -H "X-API-KEY: ${APISIX_ADMIN_KEY}"
   - 检查 plugin_metadata/jwt-auth 的算法与 JWKS 是否最新（Logto 版脚本 init-apisix-routes.sh §2 每次实时拉取）。
2. **Logto 层**：token 是否有效/过期？
   - curl http://localhost:3001/oidc/.well-known/openid-configuration（issuer/jwks_uri）
   - Logto 容器日志看签发/吊销。
3. **PostgREST 层**：PGRST_JWT_SECRET=${JWKS_JSON} 是否与 Logto 一致；PGRST_JWT_ROLE_CLAIM_KEY=".pg_role" 是否有该 claim（init-logto.py CLAIMS_SCRIPT 注入）。
4. **数据库层**：切换后的角色是否存在（authenticator/web_anon/authenticated/super_admin/role_*，Pigsty pg_users 管理）；RLS/权限函数是否因 roles 缺失返回 42501。

### 3.2 常见根因与处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 全部请求 401 | jwt-auth 元数据缺失/过期（etcd 重建后路由/元数据丢失） | 重跑 bash scripts/init-apisix-routes.sh |
| 仅新 token 401 | Logto 轮换了 JWKS，APISIX 仍用旧公钥 | 重新拉取 JWKS 写 plugin_metadata；Logto 轮换支持多 key + kid |
| Logto 不可用 | 登录/OIDC discovery 失败 | 现有 token 仍可被 APISIX 验签（公钥在插件元数据内），新登录受影响；恢复 Logto 容器 |
| 偶发 401 时钟漂移 | 服务器时间偏差影响 token 有效期判断 | 部署 NTP/chrony（Pigsty 已含 chrony 模块，确认启用） |
| 42501 permission denied | token 无 roles 或 has_permission 不通过 | 检查 Logto 用户角色分配与组织 token（organization_id）；customizer 是否注入 roles/pg_role |
| RS256 vs ES384 口径 | 开发 HS256（JWKS_JSON 对称密钥）、生产 RS256（Logto JWKS，init-apisix-routes.sh）；compose/.env 注释写 ES384 | 以 init-apisix-routes.sh 与 Logto 实际 JWKS 为准，统一注释（TODO） |

## 4. 数据一致性问题（webhook 同步失败）

### 4.1 链路

Logto 事件 → APISIX /rpc/webhook_logto（HMAC 验签：logto-signature-sha-256）→ api_v1_public.webhook_logto(jsonb) → sync_* 函数 → 镜像表（users / tenants / role / organization_role / user_tenants / user_role）。

### 4.2 排查入口：webhook_event_log

| RPC | 用途 |
| --- | --- |
| api_v1_public.rpc_list_webhook_events(p_result, p_limit≤100, p_offset) | 查看 received/success/error/ignored 事件（仅超管） |
| api_v1_public.rpc_replay_webhook_event(p_event_id uuid) | 重放 error 事件（仅超管），并记 log_operate |

```bash
# 查最近 50 条事件
curl -s 'http://localhost:9080/api/v1/sys/rpc/rpc_list_webhook_events' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_limit":50}'

# 只看 error 事件
curl -s 'http://localhost:9080/api/v1/sys/rpc/rpc_list_webhook_events' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_result":"error","p_limit":50}'
```

### 4.3 常见根因与处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 401 / signature mismatch | LOGTO_WEBHOOK_SIGNING_KEY 与 Logto Console 配置不一致；rawBody 被插件改动 | 核对 gateway/.env 与 Logto webhook 签名密钥；勿叠加 request-validation |
| 事件 result=error | sync_* 函数抛错（如 payload 字段缺失、类型转换） | 查看 webhook_event_log.error 列（SQLERRM）→ 修复后 rpc_replay_webhook_event 重放 |
| 用户/角色缺失或滞后 | webhook 丢失/重试耗尽 | 运行对账脚本：python3 scripts/phase2/reconcile-logto.py --m2m-id ... --m2m-secret ... --pg-dsn ...（建议 crontab 每日 3:00，见脚本头注释） |
| 乱序覆盖 | Logto 事件乱序到达 | sync_*_upsert 内置 logto_updated_at 乱序守护（EXCLUDED.logto_updated_at >= 现值才更新）；核对水位 |
| PostSignIn 未写 login_log | sync_login_log_write 独立容错吞异常 | 该事件失败仅把 webhook_event_log 标 error；检查 payload 形状（userId 必须存在） |

## 5. 网关问题（APISIX 路由 / 限流误伤）

### 5.1 模式与配置

- APISIX 为 **traditional 模式**：路由/插件元数据存 compose 内 etcd（app-etcd:2379），Admin API 9180 + 内置 Dashboard（/ui），Status API 7085，Control API 9092。
- 路由初始化：**scripts/init-apisix-routes.sh（Logto 版，当前唯一有效）**；⚠️ scripts/setup_apisix.sh 与 gateway/apisix/apisix.yaml 为 Casdoor 时代遗留（HS256 / app-casdoor / user_login_sso），勿用于排查。
- 当前路由（7 条）：100 /.well-known/jwks（代理 Logto）· 95 POST /rpc/webhook_logto（HMAC 验签，无 jwt-auth）· 80 POST /rpc/ensure_user · 60 /logto/* · 50 /api/v1/sys/*（重写至 api_v1_public）· 40 /rpc/* · 10 /*。api_v1_sales / api_v1_inventory 路由 2026-08-15 已退役。
- 当前**未配置 limit-req 限流插件**（历史安全分析的建议尚未实施，TODO）；全局规则只有 CORS。

### 5.2 排查步骤

```bash
# ① APISIX 是否就绪
curl -sf http://localhost:7085/status

# ② 路由清单（Logto 版 7 条：100 /.well-known/jwks、95 POST /rpc/webhook_logto、80 POST /rpc/ensure_user、60 /logto/*、50 /api/v1/sys/*、40 /rpc/*、10 /*）
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: ${APISIX_ADMIN_KEY}"

# ③ 命中测试（带 token 与不带 token 对比）
curl -s -o /dev/null -w '%{http_code}' http://localhost:9080/api/v1/sys/role
curl -s -o /dev/null -w '%{http_code}' http://localhost:9080/api/v1/sys/role -H "Authorization: Bearer $TOKEN"
```

### 5.3 常见根因与处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 全部 404 | etcd 未启动或路由未初始化 | docker compose ps 检查 app-etcd；重跑 init-apisix-routes.sh |
| 受保护路由 401 | jwt-auth 元数据缺失/算法不符 | 见 §3.1；重新拉 Logto JWKS |
| 路径 404 但 /rpc/* 可用 | 路由优先级/rewrite 不对 | 检查 api_v1_public 路由 regex_uri（^/api/v1/sys/(.*) → /$1） |
| Dashboard 打不开 | enable_admin_ui / allow_admin / 9180 映射 | 核对 config.yaml；浏览器 http://localhost:9180/ui 输入 Admin Key |
| 怀疑限流误伤 | 当前无限流插件 | 若已加 limit-req，检查 rate/burst/全局规则；可临时移除验证 |

## 6. 回滚预案

### 6.1 数据库

- **迁移前备份是硬要求**（见 [备份与恢复](backup-restore.md)）；回滚首选从 pg_dump 快照恢复，而不是依赖 dbmate rollback。
- dbmate rollback：bash scripts/migrate.sh down development（仅对最近一次迁移有效；064/065/066 baseline 无 down 语义）。
- 代码对象（函数/视图/触发器/RLS）：apply-src 幂等重放，回滚 = git checkout 旧版本后重跑 scripts/apply-src.sh。

### 6.2 网关

- 路由/插件元数据在 etcd：回滚 = 重跑旧版 init-apisix-routes.sh 或从 etcd 快照恢复。
- 容器镜像：docker compose down && docker compose up -d（拉取旧 tag 或回滚 gateway/ 目录后 rebuild）。

### 6.3 快速恢复顺序

1. 停止写入（必要时暂停 APISIX 数据面）；
2. 恢复数据库（pg_restore 到临时库验证 → 切流量）；
3. 重跑部署链 deploy-db.sh + init-apisix-routes.sh；
4. e2e-test.sh + verify-fresh-db.sh 双验收。

## 7. 快速排查速查表

| 症状 | 第一步命令 | 指向章节 |
| --- | --- | --- |
| API 全部 401 | curl :9180/apisix/admin/routes + plugin_metadata | §3 / §5 |
| API 全部 404 | curl :7085/status；重跑 init-apisix-routes.sh | §5 |
| PostgREST 一行报错 | curl http://localhost:3100/ + docker logs app-postgrest | §1 / §3 |
| 数据库连不上 | psql -p 6432；nc -zv host.docker.internal 6432 | §1 |
| 页面/接口慢 | pg_stat_activity + EXPLAIN ANALYZE | §2 |
| 用户不同步 | rpc_list_webhook_events + reconcile-logto.py | §4 |
| 登录失败 | docker logs app-logto + Logto Console | §3 |
| 需要回滚 | 备份文件 + 恢复流程 | §6 |

> 参考：[部署指南总览](../03-部署指南/deployment-overview.md) · [数据流](../04-架构/data-flow.md) · [网关路由](../06-API参考/gateway-routing.md) · [Logto Webhook](../06-API参考/logto-webhook.md) · [备份与恢复](backup-restore.md) · [审计与日志](audit-logging.md)
