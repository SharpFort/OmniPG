# 关键数据流

> 本章描述五条核心链路：登录与 token 生命周期、webhook 同步、权限判定、审计日志、cron 与 webhook 重放。所有函数/表名以 db/ 下实际 SQL 为准。

## 数据流 1：用户登录与 token 生命周期

```text
用户          前端 App           Logto               APISIX/PostgREST        PostgreSQL
 │  1.点击登录    │                │                       │                     │
 ├──────────────▶│  2.重定向 OIDC  │                       │                     │
 │               ├───────────────▶│  3.认证（密码/验证码/微信）│                     │
 │               │◀───────────────┤  4.code → access+refresh│                     │
 │               ├─ 5.getAccessToken(resource, orgId) ────▶│                     │
 │               │                │  6.执行 claims 脚本     │                     │
 │               │◀─ 7.组织 token ─┤  (roles/global_roles/  │                     │
 │               │                │   org_roles/pg_role)    │                     │
 │               ├─ 8.登录回调调 ensure_user（JIT 建档） ──────────────────────────▶│
 │               │◀─ 9.claims 快照对齐 user_role 镜像 ──────┤                     │
 │ 10.业务请求    │                │                       │                     │
 ├──────────────▶├─ 11.Bearer JWT ───────────────────────▶│ 12.jwt-auth 验签      │
 │               │                │                       │ 13.PostgREST 验签+    │
 │               │                │                       │    注入 claims       │
 │               │                │                       ├─ 14.RLS/has_permission▶│
 │               │◀─ 15.安全数据 ──────────────────────────┤                     │
```

token 生命周期要点：

| 项 | 说明 |
| --- | --- |
| access token | Logto 签发（建议 15 分钟）；过期后 SDK 用 refresh token 自动刷新，角色变更在刷新时生效（D11） |
| refresh token | Logto 原生管理（轮换）；撤销端点 `POST /oidc/token/revocation` 即时失效；并发设备上限可选 maxAllowedGrants |
| 组织 token | 必须经 refresh token flow 换取（带 resource + organization_id），内置 organization_id claim |
| 吊销语义 | 用户禁用/删除 → 下次刷新被拒；会话即时吊销 → 调 Logto 撤销 refresh token → 前端 401 → 重登；access token 残留 ≤ 寿命 |
| JIT 建档 | 登录回调调 `POST /rpc/ensure_user`（目标路由 init-apisix-routes.sh：jwt-auth key_claim_name=sub）→ `api_v1_public.ensure_user()`：users/user_profile 仅缺失补建（N7 不覆盖 webhook 权威值）；user_role 按 global_roles / org_roles 分段精确对齐（049 D5/D6） |
| 登录日志 | Logto PostSignIn webhook 事件异步写 `login_log`（sync_login_log_write），与业务请求并行，失败不阻断 |

## 数据流 2：Logto webhook 事件 → rpc_webhook_logto → sync_*

```text
Logto（事件源）              APISIX               PostgREST                PostgreSQL
  │ User.Created / User.Data.Updated / User.Deleted
  │ Organization.* / Membership.Updated / OrganizationRole.*
  │ Role.* / PostSignIn
  ├── POST /rpc/webhook_logto ──▶ HMAC 验签（目标路由） ──▶ api_v1_public.webhook_logto(payload)
  │                                                   │ 1. INSERT webhook_event_log (received)
  │                                                   │ 2. CASE event 分发
  │                                                   ├─▶ sync_user_upsert / sync_user_delete / sync_user_suspension
  │                                                   ├─▶ sync_tenant_upsert / sync_tenant_delete
  │                                                   ├─▶ sync_membership_delta（addedUserIds/removedUserIds）
  │                                                   ├─▶ sync_organization_role_upsert / _delete
  │                                                   ├─▶ sync_role_upsert / sync_role_delete
  │                                                   └─▶ sync_login_log_write（PostSignIn）
  │                                                   │ 3. UPDATE webhook_event_log → success/error/ignored
  ◀── 返回 {ok: true|false} ───────────────────────────┘
```

可靠性设计（代码 + 05 号文档 F3/F15/N6/N18）：

| 机制 | 说明 |
| --- | --- |
| 事件落库 | 每次调用先 INSERT webhook_event_log（hook_id/event/logto_created/payload），result = received；处理完成后置 success / error / ignored（未知事件）；payload 含 PII，RLS 仅超管可读 |
| 幂等 | sync_* 全部 ON CONFLICT 幂等；Membership delta 空数组早退（N21） |
| 乱序守护 | 镜像表以 logto_updated_at 为水位，仅当新值 ≥ 现值才覆盖（N18）；sync_user_suspension 用 now() 比较 |
| 投递重试 | Logto 侧重试 3 次、超时 10s、fire-and-forget（F15，docs 05 号核实）；接收端必须幂等 |
| 5000 截断 | Membership.Updated 数组上限 5000 条、超限静默截断（F3）→ 恰好 5000 条时应调 GET /organizations/:id/users 全量对账 |
| 兜底对账 | scripts/phase2/reconcile-logto.py（每日 crontab）：Management API 拉全量 → sync_* diff upsert |
| 重放 | rpc_list_webhook_events（超管查询）+ rpc_replay_webhook_event（超管重放 payload，重新走 webhook_logto 分发） |

> ⚠️ 网关路由注意（目标 vs 现状）：目标路由集（scripts/init-apisix-routes.sh）为 webhook_logto 单独建公开路由（POST /rpc/webhook_logto，priority 95，无 jwt-auth，serverless-pre-function 用 LOGTO_WEBHOOK_SIGNING_KEY 对 rawBody 做 HMAC-SHA256 验签，缺 key fail-closed N15）；而部署链当前调用的 scripts/setup_apisix.sh 仍是 Casdoor 时代路由（/rpc/* 与 /* 全挂 jwt-auth、无 webhook 路由），init-apisix-routes.sh 尚未接入部署链（仅 e2e-test.sh 注释引用）——webhook 可送达的前提是部署侧已按目标路由配置，收敛待办（见 [架构概览](./architecture-overview.md) 的「已知不一致 / 待收敛」与 [Logto webhook](../06-API参考/logto-webhook.md)）。

## 数据流 3：菜单 / 角色 / 数据范围权限判定

```text
业务请求进入 PostgreSQL
  ├─ 查询类（视图/表）：RLS 强制行过滤
  │    current_user_id()/current_tenant_id()/current_user_roles()
  │    → users/tenants/audit_log/login_log 等按租户/本人隔离
  ├─ 写/管理类（DEFINER RPC）：
  │    require_permission('public:xxx') / has_permission('public:xxx')
  │    → claims roles ∩ iam_role_menu → iam_menu.api_code（button 行）
  ├─ 菜单树（get_user_menu）：
  │    claims roles → iam_role_menu → iam_menu 递归 CTE → json 树
  │    （directory/menu/link/button 按 menu_type 过滤；button 不生成路由）
  └─ 数据范围（部门维度）：
       current_data_scope() → {scope_type, dept_ids}
       current_visible_dept_ids() → 可见部门 id 集合
       （all / dept_and_child=递归子树 / custom=指定 / self）
```

关键函数（db/src/public/functions/）：

| 函数 | 链路 | 说明 |
| --- | --- | --- |
| get_user_menu() | 登录后拉取菜单树 | 递归 CTE + claims roles；输出 is_affix/is_cache 等导航元数据（055/057） |
| has_permission(p_code) | 写/管理 RPC 门槛 | 超管短路 → claims roles ∩ iam_role_menu → iam_menu.api_code（单通道） |
| current_data_scope() | RLS 部门维度判定源 | 多角色取最宽；超管返回 all |
| current_visible_dept_ids() | 部门范围展开 | all/custom/dept_and_child 三种 UNION |
| current_user_dept_id() | dept_and_child 递归锚点 | 查 user_profile.dept_id（DEFINER 防 RLS 递归） |

管理端授权写路径：`rpc_set_role_menus(p_role_code, p_menu_ids)`（权限点 public:role-menu:bind；全量覆盖 iam_role_menu + log_operate 审计）→ `rpc_set_role_data_scope(p_role_code, p_scope_type, p_dept_ids)`（public:data-scope:bind；custom 校验部门存在性）。

## 数据流 4：审计与操作日志

三条写入通道汇聚到 `audit_log` / `login_log`：

| 通道 | 触发方式 | 落点 | 说明 |
| --- | --- | --- | --- |
| 数据变更审计 | 表级触发器 trg_audit_* → audit_trigger_func() → write_audit_log() | audit_log（log_type=data_change） | old_data/new_data jsonb 差异；source='trigger' |
| 业务操作审计 | RPC 内 PERFORM log_operate(...) | audit_log（log_type=operate） | module/action/target_type/target_id/result/detail |
| 登录日志 | PostSignIn webhook → sync_login_log_write() | login_log | username/login_type/ip/user_agent/region/logto_event |

审计触发器挂载（db/src/public/triggers/trg_audit_*.sql，9 张业务表；镜像表不挂）：

`trg_audit_app_config`、`trg_audit_department`、`trg_audit_dict_data`、`trg_audit_dict_type`、`trg_audit_iam_menu`、`trg_audit_position`、`trg_audit_role_menu`、`trg_audit_user_position`、`trg_audit_user_profile`

辅助模板函数：`audit_created_at()`（created_at 防篡改）、`audit_user_fields()`（created_by/updated_by 自动填充，无 JWT 上下文为 NULL）、`audit_deletion_user()`（软删除时填充 deleted_by）、`update_updated_at()`（updated_at 自动维护，trg_updated_at 批量挂载）。

audit_log 关键列：`log_type`（data_change / operate / login / exception / event / open_api）、`operation/table_name/record_id`、`old_data/new_data`（jsonb）、`user_id/tenant_id`、`module/action/target_type/target_id/result`、`ip/region/duration_ms`、`source`（trigger/manual/rpc/business）。

读路径与隔离：

| 查询 | 入口 | 权限 |
| --- | --- | --- |
| 审计日志列表/搜索 | rpc search_audit_log（INVOKER，RLS 超管/本租户） | 无额外门槛 |
| 审计时间线 | get_audit_log_timeline → v_audit_log_timeline（按天聚合） | INVOKER + RLS |
| 审计详情视图 | api_v1_public.v_audit_log_detail / audit_log 视图 | authenticated SELECT + RLS |
| 登录日志搜索 | rpc_search_login_logs（has_permission('public:login-log:list') + 租户成员过滤） | 权限点 |
| 登录日志视图 | v_login_log（LATERAL geo_locate 实时地理 join） | authenticated SELECT + RLS（login_log_read_policy：超管/本租户/本人） |

IP 归属链路（db/src/public/functions/geo_locate.sql + ip2region.sql）：`sync_login_log_write` 落库时用 `ip2region(ip)`（ip_region_v4，仅 IPv4）写 region 快照；查询时 `geo_locate(ip)` 实时解析（ip2region 优先 → GeoLite2 ip_geolite2_city 兜底，含 IPv6/经纬度/时区）。

## 数据流 5：cron 任务与 webhook 事件重放

**pg_cron（Pigsty 集群级扩展，shared_preload_libraries 含 pg_net,pg_cron）**：

- 任务定义在 `cron.job`、运行历史在 `cron.job_run_details`（cron schema）。
- 管理端只读 RPC：`rpc_list_cron_jobs()` / `rpc_list_cron_job_runs(p_limit)`（SECURITY DEFINER + is_super_admin，非超管静默返回空）。
- 业务侧 `cron_job_log` 表记录任务执行日志（job_name/execution_time/result/duration_ms）；`v_system_stats_realtime.last_cleanup_time` 引用 job_name = 'cleanup-old-audit-logs'（审计日志 90 天清理任务，035 已删除已退役的 cleanup-expired-tokens 死链任务）。
- 不建 sys_job 表：任务定义以 pg_cron 为真相源（05.1 D-E）。

**webhook 事件重放（webhook_event_log 生命周期）**：

```text
Logto 投递 ──▶ INSERT webhook_event_log（result=received）
                 │ 处理中
                 ├─▶ 成功 → result=success
                 ├─▶ 同步失败 → result=error（error 字段记录 SQLERRM）
                 └─▶ 未知事件 → result=ignored（可观测）
                                  │
                                  ▼
             超管查询 rpc_list_webhook_events(result, limit, offset)
             超管重放 rpc_replay_webhook_event(p_event_id)
                 └─▶ 取 payload 重新调用 api_v1_public.webhook_logto
                     └─▶ log_operate('webhook','replay',...) 审计
```

- webhook_event_log 保留 90 天（065 迁移注释），清理任务归 pg_cron（P2）。
- 对账兜底：scripts/phase2/reconcile-logto.py 每日全量 diff（users/tenants/user_tenants/role/organization_role/user_role + profile/ssoIdentities 补拉）。

---

> 参考：登录与 token 生命周期详见 [认证与授权设计](./auth-design.md)；webhook 事件表与重放见 [Logto webhook](../06-API参考/logto-webhook.md)；RPC 签名见 [RPC 参考](../06-API参考/rpc-reference.md)；审计读写规范见 [审计日志](../08-运维/audit-logging.md)。
