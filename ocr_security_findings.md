# OmniPG 安全漏洞清单（Security Findings）

> ## 修复状态附录（2026-11-19 · 批次 2a 安全加固）
>
> - **已修复（代码已改，待阶段 3 联调回归）**：S-A2/S-A4（strict 变体 + INVOKER 化）、S-A5~S-A11、S-B1~B10/B16（视图谓词+收权；B11~B15 涉及 src 层 owner 链路属 2b/2c）、S-C4~C6、S-C7~C20、S-D2~D7/S-D12~D14、S-D1（经核实 0b47117 已修）、S-A1/S-C1~C3/S-D8 部分（经核实 0b47117 已修）、is_uuid_v7 C-4（同前）
> - **归入 2b（PL/pgSQL 正确性批）**：S-C 遗留 TOCTOU（delete_menu、set_role_menus 并发）、S-E1~E4（审计脱敏设计）
> - **归入 2c（075+ 修正迁移）**：S-A13（casbin 租户维度需配合种子/索引）、S-B17 role 视图补列
> - **归入 2d（网关与凭据批）**：S-C21/C22（webhook 鉴权 + SQLERRM）、S-F1~F8/F11~F14/G1~G3（凭据轮换、CORS、网络暴露、redis/userlist）
> - **设计取舍（已记录待 claims 注入后切换）**：strict 版租户函数当前"可用未接线"；compat 'default' 回退在 claims 注入完成前保持 dev 可用
> - 验收记录：`ocr_2a_acceptance_result.json`（40 条）→ `ocr_2a_acceptance2_result.json`（38 条，high 10→4）→ 第三轮人工修补 3 high + 6 medium

- **来源**：OpenCodeReview 11 个批次扫描结果（category=security，共 104 条）+ conf 人工复查补充 2 条 + 跨类引用 1 条
- **口径**：本清单只收安全类缺陷；功能性 bug、性能问题见《性能隐患清单》与 `ocr_review_summary.md`（总报告，含根因分析与 P0~P3 路线）
- **严重度分布**：critical 6（+2 补充）/ high 41 / medium 50 / low 7
- **每条含来源批次 JSON**（`ocr_*_result.json`），完整原文与 suggestion_code 见对应文件

> 修复路线：S-A~S-C 组对应总报告 **P0**；S-D~S-F 对应 P1~P3。关键前置事实：**Logto JWT 的 tenant_id claim 注入仍是 TODO**（见 `scripts/phase2/init-logto.py`），因此 fail-open 类缺陷在当前环境是常态而非边角。

---

## S-A 租户隔离 fail-open 链（P0，最高优先）

**根因**：`current_logto_tenant_id()` 缺 claim 静默回落 `'default'`；多处写入侧不写 tenant_id（列 DEFAULT `'default'`）；读侧却按 claim 过滤。三者叠加 → 跨租户可见 + 非默认租户功能失效。

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-A1 | `db/api_v1/platform/rpc/rpc_list_tenants.sql:16` | 🔴 critical | `'default'` 旁路 + organizations 视图 owner 权限（DEFINER 内基表 RLS 不生效）→ 持 `platform:tenant:list` 者可见**全部租户组织**；同目录 rpc_list_tenant_members 用 is_super_admin 旁路，应与其对齐（ocr_rpc） |
| S-A2 | `db/src/platform/functions/current_logto_tenant_id.sql:9` | 🟠 high | RLS 租户谓词 fail-open 回落 'default'，全租户共占一个分区；建议区分"无 claim"与"字面 default 租户"（NULL 哨兵/strict 变体）并补三类场景测试（ocr_functions） |
| S-A3 | `db/src/platform/functions/current_logto_tenant_id.sql:10` | 🟡 medium | 新加 NULLIF 把 22P02 报错（fail-closed）变成静默回落 'default'（fail-open）——空 claims GUC 时更宽松（ocr_diff） |
| S-A4 | `db/src/platform/functions/current_logto_tenant_id.sql:13` | 🟡 medium | 纯读 GUC 的 helper 标 SECURITY DEFINER 无必要，徒增提权面并阻碍内联（ocr_functions） |
| S-A5 | `db/api_v1/platform/rpc/rpc_ensure_user.sql:23` | 🟠 high | JIT 建档 tenant_id 取列默认值 → 永远落 'default' 租户（ocr_rpc） |
| S-A6 | `db/api_v1/platform/rpc/rpc_ensure_user.sql:25` | 🟡 medium | organization_id claim 未验证用户真实归属即写入档案，伪造/mirror claim 可持久越权归属（ocr_rpc） |
| S-A7 | `db/src/platform/functions/sync_login_log_write.sql:35` | 🟠 high | Logto webhook 无 JWT claims，login_log 全部落 'default' 租户（ocr_functions） |
| S-A8 | `db/src/platform/functions/has_permission.sql:31/33` | 🟠 high | 角色名→ID 解析未按租户过滤（platform.role/tenant_role 是全租户投影），同名角色跨租户串权限；权威函数 resolve_role_ident 已示范正确写法（ocr_functions + ocr_diff 合并） |
| S-A9 | `db/src/platform/functions/get_user_menu.sql:42` | 🟡 medium | 同 S-A8：get_user_menu 内 `platform.role` 侧未限定租户（ocr_diff） |
| S-A10 | `db/src/platform/functions/current_data_scope.sql:32` | 🟡 medium | 角色解析同样无租户维度，且未遵循"全局优先、org-role 回退"规则（ocr_functions） |
| S-A11 | `db/src/platform/privileges/rls_policies.sql:18` | 🟠 high | user_profile `WITH CHECK` 只查 user_id → 用户可把自己的行写入任意 tenant_id/organization_id（ocr_types_privileges） |
| S-A12 | `db/migrations/platform/069_d27_tenant_org_columns.sql:97` | 🟡 medium | tenant_id 列保留 `DEFAULT 'default'` → 一切未来漏写 INSERT 静默归 default 租户；隔离关键列不应有透明默认（ocr_migrations） |
| S-A13 | `db/src/platform/views/zz_casbin_rule.sql:23` | 🟡 medium | casbin 策略无租户维度：两个 Logto 租户同名角色产出相同策略行（ocr_src_views_triggers） |

## S-B 视图层缺 `security_invoker` / 谓词缺失（P0，系统性）

**根因**：api_v1_platform 视图默认以 owner（多为 BYPASSRLS/高权）执行，基表 RLS 对视图不生效；叠加 zz_grant_all 宽授权。

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-B1 | `db/api_v1/platform/views/cron_job_log.sql:4` | 🟠 high | 无 security_invoker，owner 权限绕过基表 RLS（ocr_api_views） |
| S-B2 | `db/api_v1/platform/views/department.sql:6` | 🟠 high | 单表自动可更新视图 + role_admin 可写，owner 权限下可改任意租户行（ocr_api_views） |
| S-B3 | `db/api_v1/platform/views/organizations.sql:14` | 🟠 high | 跨租户聚合无租户谓词且授给 authenticated（ocr_api_views） |
| S-B4 | `db/api_v1/platform/views/v_audit_log_timeline.sql:5` | 🟠 high | 无 security_invoker → audit_log 的 RLS 以视图 owner 身份评估（ocr_api_views） |
| S-B5 | `db/api_v1/platform/views/app_config.sql:10` | 🟠 high | "公开配置"视图未过滤 is_public → authenticated 可读全部配置（ocr_api_views） |
| S-B6 | `db/api_v1/platform/views/config_admin.sql:4` | 🟠 high | "仅管理员"视图无任何限制且可更新（ocr_api_views） |
| S-B7 | `db/api_v1/platform/privileges/zz_grant_all.sql:21` | 🟠 high | config_admin 暴露 security.*/session.* 等非公开配置值（ocr_types_privileges） |
| S-B8 | `db/api_v1/platform/privileges/zz_grant_all.sql:18` | 🟠 high | audit_log 无过滤视图授给全部 authenticated（含租户受限用户）（ocr_types_privileges） |
| S-B9 | `db/api_v1/platform/privileges/zz_grant_all.sql:47` | 🟠 high | 与 034 设计矛盾：login_log/v_login_log/v_user_roles/v_role_users 被兜底 GRANT（ocr_types_privileges） |
| S-B10 | `db/api_v1/platform/privileges/zz_grant_all.sql:65` | 🟡 medium | app_config 视图可更新且授 role_admin → 直接写穿配置行（ocr_types_privileges） |
| S-B11 | `db/src/platform/views/zz_sys_user.sql:23` | 🟠 high | `users` 关系名未限定，与 platform.users 视图（owner=BYPASSRLS reader）解析歧义（ocr_src_views_triggers） |
| S-B12 | `db/src/platform/views/organizations.sql:16` | 🟡 medium | src 层多个视图（organizations/tenant_role/user_role/user_tenants/v_logto_login_events）owner 权限无租户谓词（ocr_src_views_triggers） |
| S-B13 | `db/src/platform/views/tenants.sql:12` | 🟡 medium | "仅运维排查"的 db_user 列授权给了应用角色并被 api 层再投影（ocr_src_views_triggers） |
| S-B14 | `db/src/platform/views/user_role.sql:26` | 🟡 medium | 依赖 BYPASSRLS reader 属主；DROP/CREATE 重放后属主复位，RLS 语义静默改变（ocr_src_views_triggers） |
| S-B15 | `db/src/platform/views/user_tenants.sql:6` | 🟡 medium | 自动可更新视图写穿 Logto 基表风险（ocr_src_views_triggers） |
| S-B16 | `db/api_v1/platform/views/users.sql:22` | 🟡 medium | API 投影暴露 password_hash 占位列，邀请未来事故（ocr_api_views） |
| S-B17 | `db/api_v1/platform/views/role.sql:13` | 🟡 medium | 未暴露 type/is_default 且硬编码 is_active=true → M2M 角色混入业务角色列表（ocr_api_views） |
| S-B18 | `db/api_v1/platform/views/dict_data.sql:8` | 🟡 medium | 基表未 schema 限定，依赖会话 search_path，可能解析到遗留同名关系（ocr_api_views） |

## S-C RPC 鉴权与越权（P0）

**根因**：SECURITY DEFINER 绕过 RLS，但入参/父引用/范围校验缺失。

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-C1 | `db/api_v1/platform/rpc/rpc_create_dict_data.sql:15` | 🔴 critical | scope 检查用可空列当 found 标志：v_global_ok 为 NULL 时分支被跳过——**not-found 与超管检查双双失效**（ocr_rpc） |
| S-C2 | `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:23` | 🔴 critical | `v_org IS NULL` 双语义 + 存在性探测无租户过滤 → **他租户行被当全局删除**；非超管则泄漏外部 id 存在性（ocr_rpc） |
| S-C3 | `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:20` | 🟠 high | 无 organization claim 时 `v_org <> current_organization_id()` 为 NULL，鉴权分支整体跳过（ocr_rpc） |
| S-C4 | `db/api_v1/platform/rpc/rpc_update_dict_data.sql:17` | 🟡 medium | 回退 EXISTS 探测丢租户过滤 → 他租户行被当全局（与 S-C2 同型）（ocr_rpc） |
| S-C5 | `db/api_v1/platform/rpc/rpc_delete_dict_type.sql:26` | 🟡 medium | DELETE 只按 id（+tenant）不再验 organization，SELECT 与 DELETE 间 scope 可变；DEFINER 下可逃逸已验范围（ocr_diff + ocr_rpc 合并） |
| S-C6 | `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:35` | ⚪ low | org 校验只在 SELECT，DELETE 不复验 organization_id，并发事务可换 scope（ocr_diff） |
| S-C7 | `db/api_v1/platform/rpc/rpc_create_position.sql:17` | 🟠 high | parent_id 不验存在/组织/租户/软删 → DEFINER 下跨租户挂载、孤儿子树（ocr_rpc） |
| S-C8 | `db/api_v1/platform/rpc/rpc_create_position.sql:21` | 🟡 medium | create 侧补了校验但 `rpc_update_position` 同型缺口未补（ocr_diff） |
| S-C9 | `db/api_v1/platform/rpc/rpc_create_department.sql:20` | 🟡 medium | 同型：rpc_update_department 的 COALESCE 路径无父校验（ocr_diff） |
| S-C10 | `db/api_v1/platform/rpc/rpc_update_department.sql:18` | 🟠 high | 只拒自引用；新父存在性/同组织/非叶子/成环全不验（ocr_rpc） |
| S-C11 | `db/api_v1/platform/rpc/rpc_assign_user_positions.sql:21` | 🟠 high | id 数组不验行存在与组织归属（DEFINER 绕 RLS）→ 跨组织绑定（ocr_rpc） |
| S-C12 | `db/api_v1/platform/rpc/rpc_search_user_positions.sql:22` | 🟠 high | 权限层级与返回内容不匹配：仅 position:list 却返回 username/primary_email 等 PII（ocr_rpc） |
| S-C13 | `db/api_v1/platform/rpc/rpc_search_user_positions.sql:44` | 🟡 medium | 隔离仅靠 JOIN 树隐式成立，user_position 本身无 org/tenant 过滤（ocr_rpc） |
| S-C14 | `db/api_v1/platform/rpc/rpc_get_menu_tree_admin.sql:49` | 🟠 high | 管理菜单树读 RPC 无 has_permission 检查，任意 authenticated 可调用（ocr_rpc） |
| S-C15 | `db/api_v1/platform/rpc/rpc_get_all_public_configs.sql:14` | 🟠 high | DEFINER + web_anon 可调 + 069 后 app_config 带租户/组织列 → 匿名跨租户读配置（ocr_rpc） |
| S-C16 | `db/api_v1/platform/rpc/rpc_get_user_profile.sql:12` | 🟠 high | current_user_id() 为 NULL 时自查判断 fail-open（ocr_rpc） |
| S-C17 | `db/api_v1/platform/rpc/rpc_get_user_profile.sql:18` | 🟡 medium | SELECT * 序列化全部内部/审计/PII 列（ocr_rpc） |
| S-C18 | `db/api_v1/platform/rpc/rpc_get_dept_tree.sql:13` | 🟠 high | 计算了 v_org 却用裸 p_organization_id 过滤 → 越权取整树（ocr_rpc） |
| S-C19 | `db/api_v1/platform/rpc/rpc_delete_menu.sql:5` | 🟡 medium | DELETE 只按 id，无租户/组织限定（DEFINER 绕 RLS）（ocr_rpc_delete_menu_reresult） |
| S-C20 | `db/api_v1/platform/rpc/rpc_delete_menu.sql:9` | 🟡 medium | 全局表仅凭租户绑定的权限码守卫（ocr_rpc） |
| S-C21 | `db/api_v1/platform/rpc/rpc_webhook_logto.sql:68` | 🟠 high | DEFINER 无任何调用方/密钥校验却暴露给未认证流量（ocr_rpc） |
| S-C22 | `db/api_v1/platform/rpc/rpc_webhook_logto.sql:65` | 🟡 medium | SQLERRM 原样返回 web_anon，泄漏内部 schema 细节（ocr_rpc） |
| S-C23 | `db/api_v1/platform/rpc/rpc_list_cron_job_runs.sql:14` | 🟡 medium | 权限失败静默吞掉返回空集（200 无行），无法区分"无数据"与"拒绝"（ocr_rpc） |

## S-D EXECUTE/ACL 收口（P0）

**根因**：PL/pgSQL 新函数默认 PUBLIC EXECUTE；逐文件 REVOKE 与 99 号转授循环互斥；DEFINER 函数 search_path 未 pin。

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-D1 | `db/api_v1/platform/rpc/rpc_update_user_profile.sql:76` | 🔴 critical* | 逐文件 REVOKE 先于 99 执行 → 转授循环跳过，role_guest 等登录角色失权，**自助更新全断**（ocr_diff；*bug 类跨引，ACL 安全链缺陷） |
| S-D2 | 同型（5 处） | 🟠 high | `rpc_create_department:36` / `rpc_create_position:37` / `rpc_assign_user_positions:51` / `rpc_list_tenants:39` 等：同一 REVOKE×99 矛盾（ocr_diff） |
| S-D3 | `db/api_v1/platform/rpc/rpc_create_dict_type.sql:28` | 🟠 high | DEFINER 默认 PUBLIC EXECUTE，anon/web_anon 可直接调用（ocr_rpc） |
| S-D4 | `db/src/platform/functions/log_operate.sql:19` | 🟠 high | DEFINER 直写 audit_log 无收口；platform schema 函数无统一 PUBLIC 回收 → 任意会话可伪造审计（ocr_functions） |
| S-D5 | `db/src/platform/functions/write_audit_log.sql:23` | 🟠 high | DEFINER + 无 REVOKE PUBLIC；tenant/org 取自调用方 JSON 优先 → 可伪造审计归属（ocr_functions） |
| S-D6 | `db/src/platform/functions/import_geolite2_city.sql:25` | 🔴 critical | DEFINER 无 REVOKE PUBLIC → 任意角色可 TRUNCATE GeoIP 表（ocr_functions） |
| S-D7 | `db/src/platform/functions/import_geolite2_city.sql:30` | 🟡 medium | GRANT 目标与运行时角色模型不匹配（.pg_role → role_*，登录角色不继承 authenticated）（ocr_diff） |
| S-D8 | `db/api_v1/platform/privileges/99_revoke_public.sql:24` | 🟠 high | 末尾 blanket GRANT 推翻本文件最小权限设计（ocr_types_privileges） |
| S-D9 | `db/api_v1/platform/privileges/99_revoke_public.sql:27` | 🟡 medium | PUBLIC 加固只对 app_owner 创建的函数生效，超管/其他角色建的函数不受控（ocr_types_privileges） |
| S-D10 | `db/api_v1/platform/privileges/99_revoke_public.sql:30` | 🟡 medium | 新函数默认 EXECUTE 给 role_guest = fail-open 默认（ocr_types_privileges） |
| S-D11 | `db/api_v1/platform/privileges/99_revoke_public.sql:36` | ⚪ low | ensure_user/get_current_user 授给 web_anon 但其永不携带 JWT → 死授权（ocr_types_privileges） |
| S-D12 | `db/src/platform/functions/audit_user_fields.sql:26` | 🟠 high | 未 pin search_path，current_user_id() 等按调用方解析 → 审计 spoof/运行期失败（影响 audit_trigger_func/current_user_roles/derive_route_name/is_super_admin/sha256）（ocr_functions） |
| S-D13 | `db/api_v1/platform/rpc/rpc_update_menu.sql:15` | 🟡 medium | search_path 中 `ext` 在 pg_temp 前：可建 ext 同名函数者可劫持调用链（ocr_rpc） |
| S-D14 | `db/src/platform/functions/is_uuid_v7.sql:27/30` | 🟡 medium | IMMUTABLE 函数内 `~` 操作符经 search_path 解析 → 可被用户自定义操作符重定向（ocr_diff + ocr_functions 合并） |
| S-D15 | `db/src/platform/functions/audit_created_at.sql:25` | ⚪ low | PUBLIC 默认 EXECUTE 未回收（ocr_functions） |
| S-D16 | `db/src/platform/functions/audit_trigger_func.sql:38` | ⚪ low | 触发器函数保留 PUBLIC EXECUTE，防御纵深缺口（ocr_functions + ocr_diff 合并） |
| S-D17 | `db/src/platform/functions/write_audit_log.sql:16` | ⚪ low | DEFINER 的 search_path 含 pg_temp（会话可写 schema）（ocr_functions） |
| S-D18 | `db/init/02-schemas.sql:70` | 🟡 medium | `REVOKE ... FROM authenticated` 只移除直接授权，PUBLIC 默认 EXECUTE 仍开放（ocr_tests） |
| S-D19 | `db/src/platform/functions/audit_user_fields.sql:22` | 🟡 medium | 防篡改修复只做一半且静默：合法回填也被无提示吞掉（ocr_diff） |

## S-E 审计/敏感数据落盘与暴露（P1~P2）

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-E1 | `db/src/platform/functions/audit_trigger_func.sql:11` | 🟡 medium | to_jsonb(OLD/NEW) 整行入审计表 → 密钥/PII 长期明文留存（app_config.config_value 等）（ocr_functions） |
| S-E2 | `db/src/platform/triggers/trg_audit_app_config.sql:8` | 🟡 medium | app_config 整行（含 config_value）进 audit_log（ocr_src_views_triggers） |
| S-E3 | `db/src/platform/functions/write_audit_log.sql:38` | 🟡 medium | old_data/new_data 原样持久化敏感字段，且经视图暴露给 authenticated（ocr_functions） |
| S-E4 | `db/api_v1/platform/views/cron_job_log.sql:5` | 🟡 medium | cron_job_log.result、audit_log.old/new_data、login-log IP/UA/geo、tenants.db_user 等敏感载荷宽授权可见（ocr_api_views） |
| S-E5 | `scripts/init-logto-reader.sh:60` | 🟠 high | reader（BYPASSRLS）直授 `payload` 原始日志列 → 全租户敏感载荷（密码哈希/token）暴露给视图 owner 链路（ocr_scripts） |

## S-F 凭据、网络与脚本入口（P0 凭据轮换；其余 P3）

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-F1 | `scripts/e2e-test.sh:18` | 🔴 critical | 回退仓库内默认密钥：**APISIX 公开 admin key `edd1c9f0...`**、e2e 管理员密码；需强制 env 注入 + 轮换（ocr_scripts） |
| S-F2 | `scripts/init-logto-reader.sh:38` | 🔴 critical | **BYPASSRLS 角色授予 app_owner** → SET ROLE 即绕过全部 Logto RLS；视图 owner 无需角色成员身份（ocr_scripts） |
| S-F3 | `scripts/deploy-db.sh:40` | 🟠 high | DB 密码缺失回退仓库凭据 `app_owner/admin@password`（deploy-infra.sh、start.sh 同型）（ocr_scripts） |
| S-F4 | `scripts/e2e-test.sh:193` | 🟠 high | 命令内硬编码 DB 凭据 + 2>/dev/null 吞连接错误（ocr_scripts） |
| S-F5 | `scripts/migrate.sh:21` | 🟠 high | 硬编码凭据且不读 .env 契约变量（ocr_scripts） |
| S-F6 | `scripts/import-geolite2.sh:21` | 🟠 high | MaxMind license key 拼进 URL 并回显 → 终端/CI 日志泄漏（ocr_scripts） |
| S-F7 | `scripts/init-apisix-routes.sh:59` | 🟠 high | `allow_origins:"*"` + `allow_credentials:true` 违反 CORS 规范（ocr_scripts） |
| S-F8 | `scripts/wsl-portproxy.ps1:41` | 🟠 high | portproxy 0.0.0.0 + 防火墙规则无 RemoteAddress/Profile → 5432/6432 全网可达（ocr_scripts） |
| S-F9 | `infra/pgbouncer.ini:6` | 🟠 high | 连接池与管理台监听 0.0.0.0（postgresql.conf 刻意只听 localhost）（ocr_gateway_infra） |
| S-F10 | `infra/pgbouncer.ini:21` | 🟠 high | 业务账号 app_owner 兼任 pgbouncer admin/stats（ocr_gateway_infra） |
| S-F11 | `infra/pigsty.yml:117` | 🟠 high | 10.0.0.0/8 任意角色（含 postgres 超管）仅密码可连任意库，无截止时间（ocr_gateway_infra） |
| S-F12 | `infra/pigsty.yml:148` | 🟠 high | Redis 公网防火墙区开放且未设 redis_password（ocr_gateway_infra） |
| S-F13 | `infra/pigsty.yml:51` | 🟡 medium | 明文可猜凭据 `admin@password` 入库且为渲染源（ocr_gateway_infra） |
| S-F14 | `infra/pigsty.yml:200` | 🟡 medium | Grafana/HAProxy 使用文档化默认口令（ocr_gateway_infra） |
| S-F15 | `scripts/deploy-db.sh:21` | 🟡 medium | ENV 无白名单校验直接拼路径/source（ocr_scripts） |
| S-F16 | `scripts/deploy-db.sh:45` | 🟡 medium | 含密 DSN 走命令行参数 → 进程列表/日志可见（ocr_scripts） |
| S-F17 | `scripts/deploy-gateway.sh:26` | 🟡 medium | 渲染出的 .env/pigsty.yml/userlist.txt 以默认 umask 落盘（ocr_scripts） |
| S-F18 | `scripts/deploy-infra.sh:59` | 🟡 medium | `curl pigsty.cc/get | bash` 远端代码直灌 root（ocr_scripts） |
| S-F19 | `scripts/import-ip2region.sh:51` | 🟡 medium | 路径单引号内插值 → `'` 产生畸形 \COPY 命令（ocr_scripts） |
| S-F20 | `scripts/start.sh:135` | 🟡 medium | `curl -k` 关证书校验探测 etcd（ocr_scripts） |
| S-F21 | `scripts/apply-src.sh:67` | 🟡 medium | §6.3 零容忍门未覆盖 PROCEDURE/AGGREGATE/OPERATOR/CAST 与动态 SQL 产出对象（ocr_scripts） |

## S-G 人工复查补充（OCR 扩展名过滤排除的文件）

| # | 位置 | 严重度 | 问题 |
|---|---|---|---|
| S-G1 | `infra/redis.conf:1` | 🔴 critical（人工） | `bind 0.0.0.0` 且**无 requirepass**——与 S-F12 互证：网络上任何人可读写/FLUSHALL；加密码 + 绑定内网，同步修 pigsty.yml.tpl |
| S-G2 | `infra/userlist.txt` / `userlist.txt.tpl` | 🟠 high（人工） | pgbouncer 凭据**明文入库**（app_owner/authenticator/logto/casdoor）；改 SCRAM 条目 + 部署期生成 |
| S-G3 | `infra/pg_hba.conf:24-27` | 🟡 medium（人工） | Docker 桥网段对 `all/all` 开放，任意容器可尝试任意角色；建议收窄用户列 |
| — | `scripts/verify-fresh-db.sh:22` | 🔴 critical*（跨类引用） | DB_NAME 未校验直接拼入 `DROP DATABASE WITH (FORCE)` 与 URI（bug 类但属注入/破坏性安全缺陷，详见总报告 C-14） |

---

## 修复路线摘要（与总报告 P0~P3 对齐）

1. **P0-租户链**：S-A1~S-A11（strict 租户语义、写侧补 tenant、has_permission/get_user_menu 租户限定、rls WITH CHECK）
2. **P0-EXECUTE 收口**：S-D 全组（统一 DEFINER 函数 ACL 策略 + search_path pin `pg_catalog, platform, ext, pg_temp`）
3. **P0-视图层**：S-B 组 security_invoker（**涉及运行时权限链，必须配合阶段 3 联调验证**）
4. **P0-RPC 越权**：S-C1~S-C12（FOUND 语义、租户过滤探测、parent 校验、webhook 鉴权）
5. **P0-凭据轮换**：S-F1/S-F3/S-F5/S-F6 + S-G1/S-G2（轮换动作由运维执行，我方出配置与脚本改动）

*清单完 — 生成于 2026-11-19，依据 OpenCodeReview 11 批次结果 + 人工复查；条目编号可作为修复工单引用。*
