# OmniPG OpenCodeReview 代码审查汇总报告

- **生成时间**：2026-11-19
- **审查工具**：`@alibaba-group/open-code-review` v1.13.12（`ocr scan` 全文件扫描 / workspace diff 模式）
- **LLM 配置**：
  - 批次 ①~③（2026-11-18，Antigravity 编排）：DeepSeek 官方 API `deepseek-flash`
  - 批次 ④~⑪（2026-11-19，OpenCode 编排）：**OpenCode Go `deepseek-v4.1-flash`**（DeepSeek V4.1 Flash 1017，`https://opencode.ai/zen/go/v1`）
- **总计**：11 个批次 + 9 个 conf 文件人工复查，覆盖 db/ 全部 SQL、gateway/、infra/、scripts/，**552 条评论**（critical 14 / high 134 / medium 276 / low 128）

---

## 1. 审查覆盖总览

| # | 结果文件 | 范围 | 文件数 | 评论 | 状态 | Tokens | 耗时 |
|---|---|---|---|---|---|---|---|
| ① | ocr_diff_review.json | workspace 未提交变更 | 23 | 42 | complete | 9.4M | 6m57s |
| ② | ocr_functions_result.json | db/src/platform/functions | 30 | 85 | success | 3.0M | 4m35s |
| ③ | ocr_rpc_result.json | db/api_v1/platform/rpc | 45 | 108 | completed_with_errors* | 7.5M | 8m4s |
| ④ | ocr_api_views_result.json | db/api_v1/platform/views | 31 | 40 | success | 7.4M | 12m35s |
| ⑤ | ocr_src_views_triggers_result.json | db/src/platform/views + triggers | 20 | 30 | success | 6.8M | 10m52s |
| ⑥ | ocr_types_privileges_result.json | types + templates + 两处 privileges | 9 | 30 | success | 1.6M | 8m13s |
| ⑦ | ocr_migrations_result.json | db/migrations/platform（含 066 种子） | 11 | 52 | success | 1.5M | 4m24s |
| ⑧ | ocr_tests_result.json | db/init + tests + test-data | 8 | 24 | success | 1.4M | 6m13s |
| ⑨ | ocr_gateway_infra_result.json | gateway + infra | 7 | 25 | success | 0.4M | 5m27s |
| ⑩ | ocr_scripts_result.json | scripts | 21 | 112 | success | 1.8M | 10m19s |
| ⑪ | ocr_rpc_delete_menu_reresult.json | rpc_delete_menu.sql 补漏 | 1 | 4 | success | 0.2M | 1m23s |

\* 批次 ③ 的一次 `code_comment` 调用解析失败丢失约 3 条评论，已由批次 ⑪ 重扫找回（见第 6 章 H 组）。

**目录热点**（crit/high/med/low）：

| 目录 | crit | high | med | low |
|---|---|---|---|---|
| db/api_v1/platform/rpc | 6 | 30 | 61 | 32 |
| db/src/platform/functions | 3 | 18 | 46 | 33 |
| db/migrations/platform（11 个迁移） | 0 | 18 | 25 | 10 |
| scripts | 3 | 33 | 46 | 24 |
| db/api_v1/platform/views | 0 | 9 | 22 | 9 |
| db/src/platform/views + triggers + types + templates | 1 | 12 | 24 | 8 |
| db/src/platform/privileges + db/api_v1/platform/privileges | 0 | 6 | 7 | 2 |
| infra + gateway | 0 | 9 | 12 | 3 |
| db/init + db/tests + db/test-data | 0 | 2 | 12 | 5 |

---

## 2. 严重度与类别分布

| Severity | 数量 | | Category | 数量 |
|---|---|---|---|---|
| 🔴 critical | 14 | | bug | 271 |
| 🟠 high | 134 | | security | 104 |
| 🟡 medium | 276 | | maintainability | 76 |
| ⚪ low | 128 | | performance | 49 |
| | | | test | 33 |
| | | | documentation | 19 |

---

## 3. 🔴 Critical（14 条，全文）

### 3.1 租户隔离与数据越权

**[C-1] `db/api_v1/platform/rpc/rpc_list_tenants.sql:16` [security]**（批次 ③）
Cross-tenant data exposure via the `'default'` bypass. `current_logto_tenant_id()` falls back to `'default'` whenever the JWT has no `tenant_id` claim. Combined with `platform.organizations` being a plain view over `public.organizations` (owner-privileged, so base-table RLS does not apply inside this SECURITY DEFINER function), any caller holding `platform:tenant:list` effectively sees **all organizations of all tenants** – tenant isolation is only nominal. The sibling RPC `rpc_list_tenant_members` uses `is_super_admin()` for the cross-tenant bypass instead of a magic `'default'` value; align with that pattern.

**[C-2] `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:23` [security]**（批次 ③）
`v_org IS NULL` 被同时用作"行不存在"与"行是全局字典"两种语义，且存在性探测不带租户过滤。**其他租户的行同样会得到 `v_org IS NULL` 而被误判为全局**，超管因此落入无租户过滤的 `DELETE FROM dict_data WHERE id = p_id`，删除他租户数据（SECURITY DEFINER 绕过 RLS）；非超管则收到误导性的 `global dict requires super admin`，泄漏外部 id 的存在性。应改用租户过滤探测 + 显式 `FOUND` 标志，DELETE 按租户/组织限定。

**[C-3] `db/api_v1/platform/rpc/rpc_create_dict_data.sql:15` [security]**（批次 ③）
The scope-check block misuses a nullable data column as a found flag: `SELECT ... INTO v_global_ok` leaves it NULL when no `dict_type` matches, so `v_org IS NULL AND NOT v_global_ok` is NULL and the branch is skipped — **not-found 的 P0002 永远不会触发，is_super_admin() 也永远不被检查**。建议改为 `IF NOT FOUND THEN RAISE 'P0002'`，org 比较用 `IS DISTINCT FROM`，存在性探测带租户过滤。

### 3.2 高危路径的功能性破坏（bug）

**[C-4] `db/src/platform/functions/is_uuid_v7.sql:28` [bug]**（批次 ②）
`p_uuid` 是 `uuid` 类型，PostgreSQL 没有 uuid→text 隐式转换，`~` 操作符无法解析：**函数体在第一次执行时必然报 `operator does not exist: uuid ~ unknown`**（plpgsql 仅在运行期校验，CREATE 时静默通过）。该函数用于 CHECK 约束，所有引用表的 INSERT/UPDATE 都会失败。需显式 `::text`。

**[C-5] `db/api_v1/platform/rpc/rpc_assign_user_positions.sql:26` [bug]**（批次 ③）
当 `p_primary_position_id` 为 NULL（默认值，即每次不显式指定主职位的调用），`g = p_primary_position_id` 结果为 NULL 而非 false；`is_primary boolean DEFAULT false NOT NULL` 对显式 NULL 不生效，INSERT 报 23502，**整个岗位分配失败**。需 `COALESCE(..., false)`。

**[C-6] `db/api_v1/platform/rpc/rpc_update_user_profile.sql:57` [bug]**（批次 ③）
`FOUND` 并不是动态 `EXECUTE UPDATE` 的行数：`FOR ... IN <query>` 循环只要迭代过一次就覆盖 `FOUND=true`。结果只要 `p_updates` 含一个合法键，`NOT FOUND` 恒为 false，JIT 建档分支被跳过——**即使 UPDATE 一行未命中，调用方仍收到 `{"ok": true}`，数据被静默丢弃**；档案自动创建实际不可达。建议改用 `GET DIAGNOSTICS v_cnt = ROW_COUNT` 或 `INSERT ... ON CONFLICT DO NOTHING` 后统一 UPDATE。

**[C-7] `db/api_v1/platform/rpc/rpc_update_user_profile.sql:76` [bug]**（批次 ①）
本文件新增的 `REVOKE ... FROM PUBLIC` 与 `db/api_v1/platform/privileges/99_revoke_public.sql` 的集中授权逻辑冲突：99 号文件只对 ACL 为 NULL **或仍含 PUBLIC EXECUTE 条目**的函数把 PUBLIC 的执行权转授给登录角色（`role_guest/role_editor/role_admin/tenant_admin/super_admin`）；本文件在 99 之前运行时已剥离 PUBLIC，循环会跳过该函数——PostgREST 按 JWT 切到 `pg_role`（默认 `role_guest`）时普通用户得到 `permission denied`，**自助资料更新对全部非管理员失效**。应在文件内显式 GRANT 登录角色，或去掉逐文件 REVOKE、统一交给 99 号文件。

**[C-8] `db/src/platform/templates/audit_fields.sql:14` [bug]**（批次 ⑥）
模板中 `_by` 列声明为 UUID，而平台函数已 TEXT 化（`audit_user_fields.sql` 头注 "对齐 Logto 用户 id"，`users.id` 也是 text）。**按模板建表 + 绑定 audit 触发器将在运行期失败**（text→uuid 无隐式转换），且 `is_uuid_v7(created_by)` CHECK 在 text 列上根本无法创建。十个模板与头注需统一对齐 TEXT。

### 3.3 函数权限与导入通路

**[C-9] `db/src/platform/functions/import_geolite2_city.sql:13` [bug]**（批次 ①）
新增的 `is_super_admin()` 闸门破坏了唯一调用方：导入经 `scripts/import-geolite2.sh` 走普通 psql（无 `request.jwt.claims`），`current_user_roles()` 返回 `{}`，**函数恒抛 42501，GeoIP 导入彻底无法运行**。权限收口应交给 GRANT/REVOKE（文件底部已做），claims 检查只应在 JWT 会话存在时生效。

**[C-10] `db/src/platform/functions/import_geolite2_city.sql:25` [security]**（批次 ②）
SECURITY DEFINER 函数无 `REVOKE ... FROM PUBLIC`：PostgreSQL 默认 PUBLIC 可执行，该函数可 **TRUNCATE 整张 GeoIP 离线表**（数据丢失 + 登录路径 DoS）。按 `current_data_scope.sql` 的项目惯例显式收口。

### 3.4 脚本与凭据

**[C-11] `scripts/deploy-infra.sh:151` [bug]**（批次 ⑩）
`set -e` + `((ERRORS++))`：ERRORS 为 0 时该算术命令返回状态 1，**脚本在第一个失败处直接中止**，后续检查与汇总全部跳过。改用 `ERRORS=$((ERRORS+1))`。

**[C-12] `scripts/e2e-test.sh:18` [security]**（批次 ⑩）
脚本回退到仓库内默认密钥，包括 **APISIX 公开 admin key `edd1c9f0...` 与 e2e 管理员密码**。可静默通过仍使用默认值的部署，也可能掩盖密钥缺失。应强制 env 注入并轮换已泄漏的默认值。

**[C-13] `scripts/init-logto-reader.sh:38` [security]**（批次 ⑩）
把 **BYPASSRLS 角色 `omnipg_logto_reader` 直接授予业务角色 `app_owner`**，等于开了一条 `SET ROLE omnipg_logto_reader` 提权通道：任何 app_owner 会话（或注入点、SECURITY DEFINER 函数）可绕过所有 Logto 表 RLS 读全租户数据。业务侧只需视图 SELECT（脚本后段已 GRANT），无需角色成员身份。另：`app_owner` 不存在时 `ON_ERROR_STOP=1` 会中断脚本，建议前置存在性校验。

**[C-14] `scripts/verify-fresh-db.sh:22` [bug]**（批次 ⑩）
`DB_NAME` 取自 `$1` 未校验，直接拼进 **`DROP DATABASE ... WITH (FORCE)`** 与连接 URI：误传已有/受保护库名可摧毁生产，构造串可注入 SQL/破坏 URI。需标识符白名单校验、拒绝空/受保护名，SQL 与 URI 中正确引用。

---

## 4. 🟠 High（134 条，按根因主题分组）

> 每条格式：`path:line [类别] 摘要`；完整内容与建议代码见对应 `ocr_*_result.json`。

### 主题 A：租户 fail-open `'default'` 链与读写侧 tenant_id 不一致（9 条）

根因：`current_logto_tenant_id()` 缺 claim 时静默回落 `'default'`（见 [C-1]），同时多处写入侧不写 `tenant_id`（列 DEFAULT `'default'`），而读侧过滤 `rm.tenant_id = current_logto_tenant_id()`——**非默认租户的功能（菜单/权限/档案）会系统性失效或串租户**。

- `db/src/platform/functions/current_logto_tenant_id.sql:9` [security] RLS 租户谓词 fail-open 回落 'default'，全租户共享一个分区；建议区分"无 claim"与"字面 default 租户"（NULL 哨兵/strict 变体）并补测试
- `db/src/platform/functions/sync_login_log_write.sql:35` [security] Logto webhook 无 JWT claims，login_log 全部落 'default' 租户
- `db/api_v1/platform/rpc/rpc_ensure_user.sql:23` [security] JIT 建档 tenant_id 靠列默认值，永远落 'default'
- `db/api_v1/platform/rpc/rpc_set_role_menus.sql:25` [bug] INSERT/DELETE 均未写 tenant_id/organization_id，绑定全部落默认租户
- `db/migrations/platform/071_d27c_tenant_role_menu.sql:30` [bug] 未显式赋 tenant_id，绑定与 has_permission/get_user_menu 的租户过滤不匹配
- `db/migrations/platform/071_d27c_tenant_role_menu.sql:37` [bug] 同上；且 `ON CONFLICT DO NOTHING` 无法去重（唯一索引含 NULL 列失效，另见 068:168）
- `db/migrations/platform/071_d27c_tenant_role_menu.sql:23` [bug] 只绑定了叶子菜单，未绑父级目录行；get_user_menu 递归 CTE 自根向下每层都要求绑定存在 → **整棵菜单树对绑定角色不可见**
- `db/src/platform/functions/get_user_menu.sql:54` [bug] 读侧 `rm.tenant_id = current_logto_tenant_id()` 与写侧（默认 'default'）不一致 → 非默认租户用户菜单全空
- `db/src/platform/privileges/rls_policies.sql:18` [security] user_profile 的 `WITH CHECK` 只查 user_id，不拦 tenant_id/organization_id 写入 → 用户可把自己的行挂到别的租户/组织

### 主题 B：api_v1 视图层缺 `security_invoker` / 谓词缺失（系统性，11 条）

根因：api_v1_platform 的视图默认以 owner 权限执行，owner 多为 BYPASSRLS 或高权角色，**基表 RLS 对视图查询不生效**；叠加 `zz_grant_all.sql` 的宽授权。

- `db/api_v1/platform/views/cron_job_log.sql:4` [security] 无 `security_invoker`，owner 权限绕过 RLS
- `db/api_v1/platform/views/department.sql:6` [security] 单表投影自动可更新 + role_admin 可写，owner 权限下可改任意租户行
- `db/api_v1/platform/views/organizations.sql:14` [security] 跨租户聚合视图无租户谓词且授给 authenticated
- `db/api_v1/platform/views/v_audit_log_timeline.sql:5` [security] 无 security_invoker，audit_log 的 RLS 被 owner 绕过
- `db/api_v1/platform/views/app_config.sql:10` [security] "公开配置"视图未过滤 `is_public`，authenticated 可读全部配置
- `db/api_v1/platform/views/config_admin.sql:4` [security] "仅管理员"视图无任何访问限制（可更新视图）
- `db/api_v1/platform/privileges/zz_grant_all.sql:21` [security] config_admin 暴露 security.* 等非公开配置值
- `db/api_v1/platform/privileges/zz_grant_all.sql:18` [security] audit_log 无过滤视图授给所有 authenticated（含租户受限用户）
- `db/api_v1/platform/privileges/zz_grant_all.sql:47` [security] 与 034 设计矛盾：login_log/v_login_log/v_user_roles/v_role_users 被兜底 GRANT
- `db/api_v1/platform/privileges/99_revoke_public.sql:24` [security] 末尾 blanket GRANT 自相矛盾，推翻本文件最小权限设计
- `db/src/platform/views/zz_sys_user.sql:23` [security] `users` 未加 schema 限定，与 platform.users 视图同名冲突解析；owner 链路含 BYPASSRLS

### 主题 C：RPC 鉴权与越权（SECURITY DEFINER 绕过 RLS）（12 条）

- `db/api_v1/platform/rpc/rpc_create_position.sql:17` [security] parent_id 不验证存在性/组织/租户/软删 → 跨组织挂载、孤儿节点
- `db/api_v1/platform/rpc/rpc_assign_user_positions.sql:21` [security] id 数组不校验行存在与组织归属（DEFINER 绕 RLS）
- `db/api_v1/platform/rpc/rpc_search_user_positions.sql:22` [security] 权限层级与返回内容不匹配：仅 position:list 却返回 username/primary_email 等 PII
- `db/api_v1/platform/rpc/rpc_get_menu_tree_admin.sql:49` [security] 读 RPC 无 has_permission 检查（同组均有），任意 authenticated 可拉管理菜单树
- `db/api_v1/platform/rpc/rpc_get_all_public_configs.sql:14` [security] DEFINER + web_anon 可调 + 069 后 app_config 带 tenant/org 列 → 匿名跨租户读
- `db/api_v1/platform/rpc/rpc_get_user_profile.sql:12` [security] `current_user_id()` 为 NULL 时自查判断 fail-open
- `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:20` [security] 无 organization claim 时 `v_org <> current_organization_id()` 为 NULL，鉴权分支被跳过
- `db/api_v1/platform/rpc/rpc_webhook_logto.sql:68` [security] DEFINER 无任何调用方/密钥校验，却暴露给未认证流量
- `db/api_v1/platform/rpc/rpc_create_dict_type.sql:28` [security] DEFINER 默认 PUBLIC EXECUTE，anon/web_anon 可直接调用（授权收口见主题 D）
- `db/api_v1/platform/rpc/rpc_get_dept_tree.sql:13` [security] 计算 `v_org` 却从未使用，实际按裸参数过滤 → 越权取整树
- `db/api_v1/platform/rpc/rpc_get_position_tree.sql:17` [bug] 锚点/递归分支均缺 `deleted_at IS NULL` → 软删岗位入树
- `db/src/platform/functions/log_operate.sql:19` [security] DEFINER 直写 audit_log（业务角色无权限）但无 REVOKE PUBLIC → 任意会话可伪造审计

### 主题 D：ACL/GRANT 链回归（REVOKE PUBLIC × 99_revoke_public 顺序矛盾，5 条）

与 [C-7] 同根因的一批回归：

- `db/api_v1/platform/rpc/rpc_create_department.sql:36` [bug] 逐文件 REVOKE 后 99 号转授循环跳过 → 登录角色失权
- `db/api_v1/platform/rpc/rpc_create_position.sql:37` [bug] 同上
- `db/api_v1/platform/rpc/rpc_assign_user_positions.sql:51` [bug] 同上
- `db/api_v1/platform/rpc/rpc_list_tenants.sql:39` [bug] 同上
- `db/api_v1/platform/rpc/rpc_update_user_profile.sql:33` [bug] 无条件 upsert 改变已有行行为（BEFORE INSERT 触发器先于 ON CONFLICT 运行，excluded 已被改写）

### 主题 E：PL/pgSQL 语义正确性（FOUND/NULL/TOCTOU/递归/易变性，21 条）

- `db/api_v1/platform/rpc/rpc_assign_user_positions.sql:27` [bug] p_position_ids 重复 id 直接撞主键 23505，整调用失败
- `db/api_v1/platform/rpc/rpc_delete_dict_data.sql:16` [bug] 非 STRICT `SELECT INTO` 零行时把 v_found 从 false 覆写为 NULL，守卫失效（与 [C-2] 叠加）
- `db/api_v1/platform/rpc/rpc_delete_department.sql:8` [bug] 无 NULL id/组织上下文守卫，审计记录仍写入
- `db/api_v1/platform/rpc/rpc_delete_department.sql:21` [bug] 删除 0 行仍返回 ok:true 并写审计
- `db/api_v1/platform/rpc/rpc_create_dict_type.sql:21` [bug] 全局/组织字典重名未处理（唯一键 NULLS DISTINCT 失效，另见 068:168）
- `db/api_v1/platform/rpc/rpc_get_audit_log_timeline.sql:31` [bug] LIMIT 施加在无序子查询上，截断哪部分不确定
- `db/api_v1/platform/rpc/rpc_get_position_tree.sql:22` [bug] 递归 CTE 无环保护（A→B→C→A 时递归直至超时）
- `db/src/platform/functions/current_visible_dept_ids.sql:32` [bug] UNION ALL 无环/深度保护
- `db/src/platform/functions/ip2region.sql:6` [bug] 做表查询却标 IMMUTABLE，可被常量折叠/索引误用
- `db/src/platform/functions/logto_ts.sql:6` [bug] ISO 分支依赖会话 TimeZone/DateStyle，IMMUTABLE 不成立
- `db/src/platform/functions/sync_login_log_write.sql:37` [bug] 函数级 `EXCEPTION WHEN OTHERS THEN NULL` 吞掉一切错误（列改名、视图失效、类型错误全部静默）
- `db/src/platform/functions/write_audit_log.sql:46` [bug] p_operation 未判空、varchar 宽度未校验 → 22001/23502 裸错误
- `db/src/platform/functions/identity_refs_guard.sql:19` [bug] NOT EXISTS 检查无锁，并发删成员行 TOCTOU
- `db/src/platform/functions/audit_created_at.sql:19` [bug] INSERT 无条件覆盖 created_at：pg_dump/pg_restore/回填会静默改写历史时间戳，建议会话级 GUC 旁路
- `db/src/platform/functions/audit_user_fields.sql:21` [bug] UPDATE 不冻结 created_by → 审计可篡改；INSERT 不归一 updated_by
- `db/src/platform/functions/audit_user_fields.sql:26` [security] 未 pin `search_path`，`current_user_id()` 等按调用方 search_path 解析 → 审计 spoof/运行期失败（影响 audit_trigger_func/current_user_roles/derive_route_name/is_super_admin/sha256）
- `db/src/platform/functions/import_geolite2_city.sql:22` [bug] staging 为空仍 TRUNCATE+导入 → GeoIP 表被清空
- `db/api_v1/platform/rpc/rpc_replay_webhook_event.sql:23` [bug] 回放不检查 webhook_logto 的 ok/error 结果，失败也报成功
- `db/api_v1/platform/rpc/rpc_webhook_logto.sql:53` [bug] 异常处理器仍按 `result='received'` 定位旧行，v_log_id 语义过期
- `db/src/platform/triggers/trg_audit_dict_type.sql:9` [bug] `audit_trigger_func()` 声明无参但以 TG_ARGV 期望参数，DML 期才炸
- `db/src/platform/triggers/trg_updated_at.sql:19` [bug] 守卫查 `pg_trigger` 只按触发器名（集群目录、名字仅表内唯一）→ 任意表同名即误判
- `db/src/platform/triggers/trg_updated_at.sql:20` [bug] 触发器名用 `%s` 而非 `%I`：混合大小写表名被折叠、`IF NOT EXISTS` 形态不兼容 → 幂等重放破

### 主题 F：角色解析未按租户限定（has_permission/get_user_menu 链，2 条）

- `db/src/platform/functions/has_permission.sql:33` [security] 角色名→ID 解析无租户过滤，而权威函数 `resolve_role_ident()` 有 → 同名角色跨租户串权限
- `db/src/platform/functions/get_user_menu.sql:41` [bug] 同一问题：`platform.role`/`tenant_role` 是全租户投影视图，解析未加 `tenant_id = current_logto_tenant_id()`

### 主题 G：迁移链一致性（17 条）

- `db/migrations/platform/074_perf_fix_missing_indexes.sql:7` [performance] 21 个索引在单事务内 `CREATE INDEX`，SHARE 锁阻塞写入直至提交；生产表建议 `CREATE INDEX CONCURRENTLY`（dbmate 需 transaction:false）+ lock_timeout
- `db/migrations/platform/074_perf_fix_missing_indexes.sql:19` [bug] 两个索引与 065/068 重复（IF NOT EXISTS 静默跳过，但 down 会误删存量索引 → 权限检查回归）
- `db/migrations/platform/069_d27_tenant_org_columns.sql:151` [bug] 四个 CREATE INDEX IF NOT EXISTS 与基线索引同名冲突，实际未建
- `db/migrations/platform/069_d27_tenant_org_columns.sql:166` [bug] RENAME CONSTRAINT 只改名不改指向表；预 D26 库上 FK 仍指 public.tenants
- `db/migrations/platform/068_d26_identity_fks.sql:116` [bug] `UPDATE ... FROM` 命中 tenant_role 多行时静默取任意一行 → 绑定到"某个"组织的角色（非确定性越权）
- `db/migrations/platform/068_d26_identity_fks.sql:123` [bug] 对不可解析的绑定行**无条件物理删除**，且无回滚；Logto 同步滞后即清空角色-菜单绑定
- `db/migrations/platform/068_d26_identity_fks.sql:168` [bug] 唯一索引双列恰好一空（CHECK num_nonnulls），默认 NULLS DISTINCT → `('r1',NULL,'m1')` 可无限重复，唯一性完全失效（直接影响 rpc ON CONFLICT）
- `db/migrations/platform/065_v010_baseline.sql:124` [bug] 依赖 apply-src 拥有的类型对象（types/*.sql、uuidv7()），冷启动顺序敏感
- `db/migrations/platform/065_v010_baseline.sql:336` [bug] 约束守卫只查 conname，不查 relation/schema → 同名约束误判
- `db/migrations/platform/065_v010_baseline.sql:334` [bug] 序列 START WITH 1 仅挂默认值，无 setval → 重放基线后 ID 冲突
- `db/migrations/platform/065_v010_baseline.sql:353` [bug] iam_role_menu 缺 `CHECK (num_nonnulls(role_id, org_role_id)=1)`，"恰好一非空"不变式无约束
- `db/migrations/platform/065_v010_baseline.sql:346` [bug] iam_role_data_scope 同一不变式缺口，org_role_id/dept_id 可全空
- `db/migrations/platform/066_v010_seed_data.sql:22` [bug] 含生产运行态水位行（特定 org `ohidlhkvs07x`），不属于种子数据
- `db/migrations/platform/067_d25_retire_mirrors.sql:29` [bug] 删除 sync_* 函数但保留的 webhook_logto 函数体仍 PERFORM 调用它们 → PostSignIn 分支运行期必炸
- `db/src/platform/types/menu_type.sql:12` [bug] duplicate_object 跳过路径不能保证"双应用顺序收敛一致"的头注承诺
- `db/src/platform/types/scope_type.sql:11` [bug] "只追加"守卫只处理 create 场景，已存在时移除/重排成员不拦
- `db/src/platform/types/audit_operation.sql:6` [bug] 枚举孤儿化且与 065 的 varchar(50) 列定义重复

### 主题 H：视图投影与模板正确性（9 条）

- `db/api_v1/platform/views/v_dept_list.sql:19` [bug] user_count 的 `deleted_at IS NULL` 恒真（视图已硬编码 NULL），未排除停用用户
- `db/api_v1/platform/views/v_login_log.sql:11` [bug] JSON→float8 强转未防护，geo 数据异常即视图不可用
- `db/api_v1/platform/views/v_login_log.sql:16` [performance] geo_locate 未 schema 限定 + 无 GiST 索引支撑
- `db/src/platform/views/v_logto_login_events.sql:15` [bug] PostSignIn 载荷是扁平结构，`payload->'application'->>'id'` 恒 NULL → 视图关键列全空
- `db/src/platform/views/zz_casbin_rule.sql:40` [bug] 按钮菜单 NULL router 可产出非法 casbin 策略行
- `db/src/platform/views/zz_sys_user.sql:5` [bug] D27 加列后 `CREATE OR REPLACE VIEW` 无法重放（42P16 列名/顺序变更不支持）
- `db/src/platform/templates/audit_fields.sql:179` [bug] 模板只给 happy-path CREATE TRIGGER，未说明非幂等与行为约束
- `db/init/02-schemas.sql:7` [bug] schema 属主不统一：api_v1_platform 无 AUTHORIZATION，bootstrap 超管执行后 app_owner 无法建对象
- `db/test-data/001_dept_position_test_data.sql:22` [bug] 单事务包裹与文档"按角色分两段执行"互斥 → 必然中途权限失败整段回滚

### 主题 I：运维脚本与凭据（含 infra/gateway，31 条）

**凭据安全**：
- `scripts/deploy-db.sh:40` [security] DB 密码缺失时回退到仓库内 `app_owner/admin@password`（deploy-infra.sh、start.sh 同款）
- `scripts/e2e-test.sh:193` [security] 硬编码 DB 凭据 + `2>/dev/null` 吞连接错误
- `scripts/migrate.sh:21` [security] 硬编码凭据且不读 .env 契约变量
- `scripts/import-geolite2.sh:21` [security] MaxMind license key 拼在 URL 并回显 → 终端/CI 日志泄漏
- `scripts/init-logto-reader.sh:60` [security] reader（BYPASSRLS）直授 `payload` 原始日志列 → 全租户敏感载荷暴露
- `scripts/init-apisix-routes.sh:59` [security] `allow_origins:"*"` + `allow_credentials:true` 违反 CORS 规范，带凭请求被浏览器拒绝
- `scripts/wsl-portproxy.ps1:41` [security] portproxy 监听 0.0.0.0，防火墙规则无 RemoteAddress/Profile → 5432/6432 全网可达

**脚本健壮性**：
- `scripts/deploy-infra.sh:148` [bug] 第 5 步无视 $MODE 无条件验证 PG/pgBouncer/Redis
- `scripts/deploy-all.sh:54` [bug] `export $(grep -v '^#' .env | xargs)` 不安全：空格/JSON 断裂、set -e 下可能中止
- `scripts/deploy-gateway.sh:40` [bug] 声称为 init-apisix-routes.sh 加载变量但从不调用它
- `scripts/deploy-db.sh:47` [bug] bootstrap 用 DB_URI、dbmate 用 DATABASE_URL，两套目标可能指向不同库
- `scripts/apply-src.sh:113` [bug] db/init/02-schemas.sql 排在全部 src/api_v1 之后 → 冷库必失败
- `scripts/apply-src.sh:90` [performance] 不分失败原因整批盲目重试 3 次（迁移部分应用后重放极危险）
- `scripts/check-extensions.sh:60` [bug] 只盯单一清单文件，与 pigsty.yml.tpl 的副本漂移无校验
- `scripts/import-geolite2.sh:30` [bug] psql 无 `-v ON_ERROR_STOP=1`，失败仍报成功；TRUNCATE+COPY 未包事务
- `scripts/import-geolite2.sh:42` [bug] staging 空也不校验行数即导入
- `scripts/import-ip2region.sh:50` [bug] \COPY 7 列无法吞 10 字段商业文件，头注承诺错误
- `scripts/migrate.sh:31` [bug] up/rollback 缺 `--no-dump-schema`，dbmate dump 会破坏 db/schema.sql（deploy-db.sh 已注明）
- `scripts/start.sh:45` [bug] pgbouncer 后台启动无成功检查即打印"已启动"
- `scripts/start.sh:54` [bug] systemctl start/stop 失败未处理，stop 失败仍记成功
- `scripts/stop.sh:33` [bug] `pkill pgbouncer` 模式匹配会杀掉宿主上所有 pgbouncer 实例
- `scripts/wsl-portproxy.ps1:13` [bug] 无提权检查，`$ErrorActionPreference` 策略与 netsh 失败处理矛盾
- `scripts/wsl-portproxy.ps1:19` [bug] `wsl hostname -I` 为空时 .Trim() 抛空引用
- `scripts/e2e-test.sh:28` [bug] `eval "$cmd"` 把插值变成代码（引号/`$()` 注入）
- `scripts/e2e-test.sh:106` [bug] 登录失败打印空串时断言恒 PASS
- `scripts/e2e-test.sh:114` [test] `jq -e 'length >= 0'` 恒真断言（多处同款）
- `scripts/e2e-test.sh:124` [bug] HTTP 断言接受任意 4xx/5xx，网关错误混过
- `scripts/phase2/init-logto.py:100` [bug] endpoint 默认值在 import 时绑定，--endpoint 实际不生效
- `scripts/phase2/init-logto.py:43` [bug] M2M app id 常量与 CLI 默认值不一致
- `scripts/phase2/init-logto.py:406` [bug] 全部步骤返回值被丢弃，失败仍打印"全部完成 ✅"
- `scripts/phase2/init-logto.py:297` [bug] signing key 写两个 .env 但只读一个 → 永久假性漂移

**infra / gateway 配置**：
- `infra/pgbouncer.ini:6` [security] listen 0.0.0.0 暴露连接池与管理台（对比 postgresql.conf 刻意只听 localhost）
- `infra/pgbouncer.ini:21` [security] 业务账号 app_owner 被授予 pgbouncer admin/stats
- `infra/pgbouncer.ini:17` [performance] session 池模式 + client_idle_timeout=0 → 少量泄漏连接即耗尽后端
- `infra/pigsty.yml:88` [bug] 禁用全部内置 HBA 且自定义规则全为 host → 无任何 local 规则
- `infra/pigsty.yml:117` [security] 10.0.0.0/8 全角色（含 postgres 超管）仅密码即可达，注释标"Phase 2 过渡"但无截止
- `infra/pigsty.yml:148` [security] Redis 6379 开公网防火墙区但未声明 redis_password
- `gateway/logto-patch/logto-csp-patch.js:30` [bug] origins 未校验/转义直接内插进生成的 JS；空列表产出非法 CSP
- `gateway/swagger/swagger-initializer.js:62` [bug] 写操作需 Content-Profile 而 try-it-out 未注入 → 跨模块写必 404

### 主题 J：测试有效性（4 条）

- `db/tests/platform/test_rls_isolation.sql:3` [test] 文件名叫 RLS isolation，11 条断言却全是对象存在性检查，**没有一条真正的隔离断言**（未 set_config JWT claims 模拟租户）
- `scripts/e2e-test.sh:114` [test] 见主题 I（恒真断言群）
- `db/tests/platform/01_schema_test.sql`、`02_function_test.sql`、`03_trigger_test.sql`、`05_rls_test.sql` [test/medium] 覆盖度与断言强度不足（详见 ocr_tests_result.json）

---

## 5. 补充人工审查（OCR 扩展名过滤器排除的 9 个文件）

以下文件因 `.conf/.txt/.tpl` 后缀被 OCR 跳过，已人工复查：

| 文件 | 结论 |
|---|---|
| `infra/redis.conf` | 🔴 **`bind 0.0.0.0` 且无 `requirepass`**——与 pigsty.yml:148 的发现互相印证：网络上任何人可读写/FLUSHALL。需加密码 + 绑定内网或保留 localhost（与 pigsty.yml.tpl 同步修） |
| `infra/userlist.txt` / `userlist.txt.tpl` | 🟠 pgbouncer 凭据**明文入库**（app_owner/authenticator/logto/casdoor）。建议改 SCRAM 条目格式并从 env/部署期生成，配合主题 I 的凭据轮换 |
| `infra/pg_hba.conf` | 🟡 结构良好（scram-sha-256 + localhost peer）。但 `172.17.0.0/16`/`172.20.0.0/16` 对 `all/all` 开放——Docker 桥上任意容器可尝试任意角色；建议按 compose 服务拆分规则或收窄用户列 |
| `infra/postgresql.conf` | 🟡 基本为 PG18 默认模板，仅 6 处定制（listen localhost ✅、autovacuum_worker_slots=16、pg_net+pg_cron、timezone 等）。建议：为配合 074 的性能专项，开启 `log_min_duration_statement`/`log_lock_waits` 采集慢 SQL 与锁等待证据 |
| `gateway/postgrest.conf` | ✅ 无实质问题。文件自我声明"仅为参考，不挂载进容器"（密码已打码）；注意保持与 compose PGRST_* 同步（头注已有此约定） |
| `gateway/swagger/default.conf` | ✅ 标准 swagger-ui nginx 模式 + /pgrst-spec 代理（Accept-Profile 注入）；写操作 Content-Profile 缺口已在主题 I（swagger-initializer.js:62）覆盖 |
| `infra/pigsty.yml.tpl` | 🟡 与 pigsty.yml 的同步漂移问题已被 OCR 发现（check-extensions.sh:60）；请将 redis 密码等修正同步到模板 |
| `gateway/.env.example` | ✅ 示例文件，无真实密钥（`gateway/.env` 被 gitignore，未参与审查） |

---

## 6. 批次 ③ 遗失评论的补漏（批次 ⑪ 重扫结果）

`rpc_delete_menu.sql` 在批次 ③ 因 `code_comment` 参数解析错误丢失约 3 条评论，重扫找回 4 条：

1. [high/bug] `p_id` 无存在性/NULL 校验——不存在的 id 也返回 `{"ok": true}` 并写审计
2. [medium/bug] 子节点检查与 DELETE 之间 TOCTOU：FK 为 `ON DELETE SET NULL`，并发插入的子节点被静默 re-parent 成根节点，破坏"有子节点禁删"不变式 → 建议 `FOR UPDATE` 锁父行或改 `ON DELETE RESTRICT`
3. [medium/security] 删除仅按 `id` 过滤，无租户/组织限定（DEFINER 绕 RLS）
4. [low/maintainability] 手动清理 `iam_role_menu` 冗余——该表已有 `ON DELETE CASCADE` FK

---

## 7. 未覆盖范围说明

- `wiki/`（54 文件）、`docs/`（75 文件）、`backups/`、`.github/`：文档与备份，未纳入代码审查
- `gateway/.env`：被 gitignore（含真实密钥），刻意不送审
- `db/syncer/`：目录为空（REFACTOR_PROGRESS 记录的 syncer 迁移未落地）
- 运行期行为（真实查询计划、APISIX 路由实测、Logto claims 实际注入效果）不在静态审查范围——尤其注意本报告多处"fail-open"结论依赖"claims 尚未注入"的现状描述，init-logto 补全后请重估主题 A

## 8. 运行成本统计

| 阶段 | 模型 | Tokens | 缓存读 | 输出 | 耗时 |
|---|---|---|---|---|---|
| 批次①~③（11-18） | deepseek-flash（官方） | 19.96M | 8.59M | 0.87M | 19m36s |
| 批次④~⑪（11-19） | deepseek-v4.1-flash（OpenCode Go） | 21.29M | 12.24M | 1.08M | 59m26s |
| **合计** | | **41.25M** | | | **78m62s** |

新批次按 OpenAI Go 牌价折算理论成本 ≈ **$1,850**（非缓存输入 7.76M × $0.15 + 缓存读 12.24M × $0.003 + 输出 1.08M × $0.6），缓存命中 61%；实际以 Go 控制台账单为准（订阅可能含额度）。注：实际消耗高于计划期粗估，主因是视图/脚本批次的工具检索轮次多于预期、输出 token 占比更高。

## 9. 建议修复优先级

**P0 —— 安全闭环（建议先于任何功能迭代）**
1. 租户 fail-open 链（主题 A + [C-1..C-3]）：`current_logto_tenant_id()` 区分"无 claim"与 default 租户（strict 变体/NULL 哨兵），`rpc_list_tenants` 改用 `is_super_admin()` 旁路；写侧补 tenant_id 赋值（rpc_set_role_menus / rpc_ensure_user / 071 回填）；`rls_policies` 补 WITH CHECK
2. EXECUTE 收口（[C-7]/[C-10]/主题 C、D）：统一在 99_revoke_public 收口或逐文件 REVOKE+显式 GRANT 登录角色，消除"逐文件 REVOKE × 99 号转授循环"的顺序矛盾；DEFINER 函数全部 pin `search_path`
3. 视图层（主题 B）：api_v1_platform 视图统一 `WITH (security_invoker = true)`，逐视图补租户/公开性谓词；audit_log/login_log/config_admin 收权
4. 凭据轮换（主题 I + §5）：APISIX admin key、DB 密码、MaxMind key、redis requirepass、pgbouncer userlist SCRAM 化；脚本改强制 env 注入
5. 功能性 critical（[C-4]~[C-6]、[C-8]、[C-11]、[C-14]）：is_uuid_v7 cast、is_primary COALESCE、update_user_profile ROW_COUNT、audit 模板 TEXT 化、deploy-infra 算术、verify-fresh-db 白名单

**P1 —— 数据与迁移一致性（主题 G）**：074 索引去重 + CONCURRENTLY；069 索引名冲突与 RENAME CONSTRAINT；068 唯一索引 `NULLS NOT DISTINCT` + 不可解析行禁止物理删除 + num_nonnulls CHECK；071 父级菜单绑定与 tenant 回填

**P2 —— 函数/触发器健壮性（主题 E、F）**：FOUND/NULL 语义重构、递归 CYCLE 保护、IMMUTABLE 降级、trigger 守卫 %I + schema 过滤、角色解析按租户限定

**P3 —— 脚本加固与测试有效性（主题 I、J）**：ON_ERROR_STOP、恒真断言、eval 移除、CORS 组合、wsl-portproxy 收窄；为 RLS 真隔离写断言型测试（set_config claims 模拟跨租户）

---

### 附录：各批次结果文件

均位于项目根目录：`ocr_diff_review.json`、`ocr_functions_result.json`、`ocr_rpc_result.json`、`ocr_api_views_result.json`、`ocr_src_views_triggers_result.json`、`ocr_types_privileges_result.json`、`ocr_migrations_result.json`、`ocr_tests_result.json`、`ocr_gateway_infra_result.json`、`ocr_scripts_result.json`、`ocr_rpc_delete_menu_reresult.json`。每条评论含 `path/start_line/end_line/category/severity/content/existing_code/suggestion_code/thinking`，可用 OCR Session Viewer（`ocr session list`）回放审查过程。

*报告完 — 由 OpenCode（GLM-5.3）编排，OpenCodeReview 1.13.12 + OpenCode Go DeepSeek V4.1 Flash 1017 生成。*
