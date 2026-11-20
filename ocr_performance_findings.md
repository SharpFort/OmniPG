# OmniPG 性能隐患清单（Performance Findings）

- **来源**：OpenCodeReview 11 个批次扫描结果（category=performance，共 49 条）
- **口径**：本清单只收性能类缺陷；安全漏洞见 `ocr_security_findings.md`，功能性 bug 与完整根因分析见 `ocr_review_summary.md`
- **严重度分布**：high 5 / medium 29 / low 15
- **每条含来源批次 JSON**（`ocr_*_result.json`），完整原文与 suggestion_code 见对应文件

> 修复路线：P-1 索引组对应总报告 **P1**（并入 075+ 修正迁移）；P-2/P-3 组对应 P2；其余 P3。**建议在阶段 3（WSL3 联调）后、阶段 4（压测）前完成**，以便用 EXPLAIN ANALYZE 与 QPS 基线验证收益。

---

## P-1 索引与迁移（并入 075+ 修正迁移）

**背景**：074_perf_fix_missing_indexes.sql 即"补 FK 索引 + tenant/org 复合索引"专项，审查发现其本身存在缺陷，需在 075+ 一次性修正。

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| P-1a | `db/migrations/platform/074_perf_fix_missing_indexes.sql:7` | 🟠 high | 21 个索引在单事务内 `CREATE INDEX`：SHARE 锁阻塞全部写入直至提交；生产表应 `CREATE INDEX CONCURRENTLY`（dbmate 需 `-- migrate:up transaction:false`）+ lock_timeout/statement_timeout（ocr_migrations） |
| P-1b | `074:12` | 🟡 medium | 冗余索引：`idx_user_profile_user_id` 重复 PK；`idx_user_position_user_id` 为 PK 左前缀（ocr_diff） |
| P-1c | `074:16` | 🟡 medium | `idx_iam_menu_parent_id` 与 065 的 `idx_iam_menu_parent` 同列不同名 → 真正建成并双份维护（ocr_diff）；另 `app_config` 两索引对小表无收益（ocr_migrations） |
| P-1d | `074:22/24/25` | 🟡 medium | `idx_dict_data_tenant_id`/`idx_dict_type_tenant_id`/`idx_login_log_tenant_id`/`idx_login_log_user_id` 均为既有（或本文件后段）复合索引的严格左前缀，纯写放大（ocr_diff） |
| P-1e | `074:39` | 🟡 medium | iam_role_menu（has_permission 最热表）迁移后同时维护 **6 个重叠索引**（unique + 065 两个 + 074 三个），写路径代价显著（ocr_migrations） |
| P-1f | `074:49` | 🟡 medium | `idx_iam_role_menu_lookup (tenant_id, menu_id)` 与 has_permission/get_user_menu 实际谓词（role_id/org_role_id = ANY + tenant）不匹配，规划器不会使用；应建 `(tenant_id, role_id)`/`(tenant_id, org_role_id)` 或修正注释（ocr_diff） |
| P-1g | `074:51` | ⚪ low | `is_active` 进索引键冗余（部分索引谓词已固定为 true），且无法服务 is_active 谓词查询（ocr_diff） |
| P-1h | `db/migrations/platform/069_d27_tenant_org_columns.sql:159` | 🟡 medium | 新增 FK 子列只有部分建了索引（department/position/user_position 有，其余缺失）→ 父表 DELETE/UPDATE 时子表顺序扫描（ocr_migrations） |
| P-1i | `db/migrations/platform/065_v010_baseline.sql:430` | ⚪ low | 基线中与 UNIQUE 约束背书索引重复的冗余索引（写放大无读收益）（ocr_migrations） |
| P-1j | `db/migrations/platform/070_d27b_cleanup_stale_tenant_fks.sql:17` | ⚪ low | `DROP CONSTRAINT` 取 ACCESS EXCLUSIVE 锁，恰逢 ensure_user 热路径故障期，长事务会放大阻塞（ocr_migrations） |

## P-2 核心查询路径（has_permission / get_user_menu / RLS 内联）

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| P-2a | `db/src/platform/functions/geo_locate.sql:33` | 🟠 high | `g.network >>= v_cidr` inet 包含操作无法用 btree PK 服务，全库无 GiST 索引 → **每次 geo 定位全表扫描**；需 `CREATE INDEX ... USING gist (network)`（ocr_functions） |
| P-2b | `db/src/platform/functions/geo_locate.sql:26` | 🟡 medium | BEGIN/EXCEPTION 块为死代码但保留（plpgsql 子事务开销），且函数未 STABLE 标注（ocr_functions） |
| P-2c | `db/src/platform/functions/ip2region.sql:14` | 🟡 medium | 命中走 `idx_ip_region_start` 反向扫描便宜；**未命中**（范围外/脏数据）则退化为全表扫描，建议末尾哨兵行（ocr_functions） |
| P-2d | `db/src/platform/functions/has_permission.sql:25/39` | ⚪ low | 每次 3 条独立语句、2 次展开 claims、RLS per-row 场景下重复解析 JWT；is_super_admin 内部又重复一次（ocr_diff + ocr_functions） |
| P-2e | `db/src/platform/functions/get_user_menu.sql:34` | ⚪ low | v_roles 用 jsonb_array_elements_text 展开 3 次、函数 VOLATILE；入口一次转 text[] 后用 `= ANY(...)`（ocr_functions） |
| P-2f | `db/src/platform/functions/resolve_role_ident.sql:14` | ⚪ low | 全局角色探测在 role_id 查询与 NOT EXISTS 子查询里各执行一次（ocr_functions） |
| P-2g | `db/src/platform/functions/current_user_roles.sql:12` | ⚪ low | 缺 PARALLEL SAFE（纯 claims 解析），RLS 谓词内会禁用并行计划（ocr_functions） |
| P-2h | `db/src/platform/functions/current_user_dept_id.sql:10` | 🟡 medium | 单 SELECT 的 plpgsql 包装阻碍内联；被 RLS 谓词与 current_visible_dept_ids 引用 3 次 → per-row 调用放大（ocr_functions） |
| P-2i | `db/src/platform/functions/current_visible_dept_ids.sql:20` | 🟡 medium | 三分支全部执行后 UNION 去重，但 scope_type 单值至多一支命中 → 至多 3 次全扫；先分支再查询（ocr_functions） |
| P-2j | `db/src/platform/functions/is_uuid_v7.sql:26` | 🟡 medium | 单表达式 plpgsql 不能内联；改 `LANGUAGE sql` 后规划器可在计划期常量折叠（ocr_functions） |
| P-2k | `db/src/platform/functions/import_geolite2_city.sql:13` | 🟡 medium | TRUNCATE 持 ACCESS EXCLUSIVE 锁直至整段重灌完成 → 导入期间全部 geo 查询（登录路径）阻塞（ocr_functions） |

## P-3 RPC / 视图查询

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| P-3a | `db/api_v1/platform/rpc/rpc_list_webhook_events.sql:24` | 🟡 medium | `p_result IS NULL OR result = p_result` 两分支皆非 sargable → 每次调用全表扫 90 天留存的 webhook_event_log（ocr_rpc） |
| P-3b | `db/api_v1/platform/rpc/rpc_search_login_logs.sql:41` | 🟡 medium | is_super_admin() 非 constant-fold，被扫描行逐行调用且页查询再来一轮，每次重解析 claims（ocr_rpc） |
| P-3c | `db/api_v1/platform/rpc/rpc_search_user_positions.sql:26` | 🟡 medium | 三个谓词均 `%...%` 前导通配 ILIKE，btree 失效；count+page 双扫描 → 每次 2 次全扫（ocr_rpc） |
| P-3d | `db/api_v1/platform/rpc/rpc_list_tenants.sql:24` | ⚪ low | member_count 相关标量子查询逐行执行（≤100 次/请求）且条件冗余（ocr_rpc） |
| P-3e | `db/api_v1/platform/rpc/rpc_list_tenants.sql:28` | 🟡 medium | ILIKE 拼接未转义 `%`/`_` → 调用方可强制全表扫描（DoS 面）（ocr_rpc） |
| P-3f | `db/api_v1/platform/rpc/rpc_update_user_profile.sql:53` | 🟡 medium | 每列一条 EXECUTE UPDATE：N 字段 = N 份行版本/WAL/触发 + N 次动态解析；应拼单条（ocr_rpc） |
| P-3g | `db/api_v1/platform/rpc/rpc_get_all_public_configs.sql:6` | 🟡 medium | 只读函数 VOLATILE → 不可优化/内联，PostgREST 视为潜在写者；标 STABLE（ocr_rpc） |
| P-3h | `db/api_v1/platform/rpc/rpc_get_role_data_scope.sql:40` | ⚪ low | 同谓词对 iam_role_data_scope 两次扫描；`IS NOT DISTINCT FROM` 本身非 sargable（ocr_rpc） |
| P-3i | `db/api_v1/platform/rpc/rpc_get_user_roles.sql:32` | ⚪ low | 同关系仅 organization 谓词不同扫描两次（视图两次展开+聚合）（ocr_rpc） |
| P-3j | `db/api_v1/platform/rpc/rpc_list_webhook_events.sql:30` | ⚪ low | 列表行携带完整 payload jsonb（可含大 PII），≤100 行/页放大响应与聚合成本（ocr_rpc） |
| P-3k | `db/api_v1/platform/views/v_audit_log_timeline.sql:13` | 🟡 medium | 视图内嵌 ORDER BY 不保证传导到外层查询，消费方再排序 = 双重排序成本（ocr_api_views） |
| P-3l | `db/api_v1/platform/views/v_dict_list.sql:12` | 🟡 medium | 相关 json_agg 子查询逐行求值；rpc_search_users 对 v_user_list COUNT(*) 再强制全聚合 → 预聚合 + LEFT JOIN（ocr_api_views） |
| P-3m | `db/api_v1/platform/views/v_system_stats.sql:9` | 🟡 medium | users/iam_menu 各扫两遍共 4 次顺序扫描/请求，且该视图被轮询（ocr_api_views） |
| P-3n | `db/api_v1/platform/views/v_login_log.sql:16` | 🟠 high | geo_locate 未 schema 限定（解析依赖调用方 search_path，兼安全问题）；视图行级调用函数放大成本（ocr_api_views） |
| P-3o | `db/src/platform/views/zz_casbin_rule.sql:25` | 🟡 medium | UNION ALL 保留重复策略（api_url/api_method 无唯一性）→ casbin 加载重复行（ocr_src_views_triggers） |

## P-4 触发器与模板

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| P-4a | `db/src/platform/templates/audit_fields.sql:106` | 🟡 medium | 软删模板无 `deleted_at IS NULL` 部分索引指引 → 消费表全表扫（ocr_types_privileges） |
| P-4b | `db/src/platform/triggers/trg_audit_iam_menu.sql:8` | ⚪ low | FOR EACH ROW 无 WHEN 守卫：无操作 UPDATE 与批量重建也整行入审计（ocr_src_views_triggers） |
| P-4c | `db/src/platform/triggers/trg_updated_at.sql:10` | ⚪ low | information_schema 按当前角色权限过滤 → 无权限的平台表被静默跳过（无触发器、无告警）（ocr_src_views_triggers） |

## P-5 基础设施与脚本

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| P-5a | `infra/pgbouncer.ini:17` | 🟠 high | session 池模式 + client_idle_timeout=0 → 少量泄漏连接即耗尽后端，PostgREST 无会话状态却钉死连接（ocr_gateway_infra） |
| P-5b | `infra/pgbouncer.ini:10/12` | 🟡 medium | pool_mode=session 不适配无状态 HTTP 消费方；default_pool_size=20 按 (db,user) 对分池 → 理论 8 池扇出（ocr_gateway_infra） |
| P-5c | `scripts/apply-src.sh:90` | 🟠 high | 不分失败原因整批盲目重试 3 次（迁移部分应用后重放极危险，兼正确性问题）（ocr_scripts） |
| P-5d | `scripts/apply-src.sh:95` | ⚪ low | 每文件一个 psql 进程/连接（约 120+ 文件）→ 连接建立开销主导运行时；考虑单连接 -f 串（ocr_scripts） |

---

## 修复路线摘要（并入总报告 P1~P3）

1. **P1 · 075+ 修正迁移**（一次解决 P-1 全组）：剔除 074 冗余/重复索引、按真实访问路径补 `(tenant_id, role_id)`/`(tenant_id, org_role_id)`、GiST(network)（或并入 GeoIP 维护迁移）、补齐 069 缺失 FK 子列索引、保留索引一律 `CONCURRENTLY` + `transaction:false`
2. **P2 · 函数内联与单次解析**（P-2 组）：has_permission/get_user_menu 单次展开 claims、STABLE/PARALLEL SAFE 标注、plpgsql→sql 内联、导入改分批/锁窗口
3. **P2 · 查询形态**（P-3 组）：sargable 化、ILIKE 转义、单条 UPDATE、视图预聚合
4. **P3 · 基建与脚本**（P-4/P-5 组）：pgbouncer 事务池改造（配合 PostgREST 验证）、审计 WHEN 守卫、apply-src 重试策略

*清单完 — 生成于 2026-11-19，依据 OpenCodeReview 11 批次结果；条目编号可作为修复工单引用。*
