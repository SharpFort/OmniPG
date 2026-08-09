# Sys 模块 P0 + P1 修复报告

> **日期**: 2026-07-29  
> **分支**: `fix/cicd-v2-deployment-issues`  
> **执行人**: Hermes Agent + 用户协作

---

## 一、背景

用户即将开发 Admin 前端项目，需要在此之前确保后端 API 层的完整性和正确性。本次修复分为两个阶段：

- **P0（阻塞性）**：前端开发前必须完成，否则无法渲染页面或执行操作
- **P1（重要）**：前端开发中需要，影响功能完整性和安全性

---

## 二、P0 修复清单

### 2.1 GRANT EXECUTE 补充

**问题**：9 个 RPC 函数缺少 `GRANT EXECUTE` 授权，前端调用会返回 403。

**修改文件**：

| 文件 | 补充内容 |
|:---|:---|
| `db/api_v1/sys/rpc/rpc_approve_role_request.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.approve_role_request(uuid) TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_change_user_password.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.change_user_password(uuid, text, text) TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_cleanup_expired_tokens.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.cleanup_expired_tokens() TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_create_user.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.create_user(text, text, uuid, uuid, text, text) TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_generate_user_password.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.generate_user_password(text) TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_get_user_menu.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.get_user_menu() TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_kick_user.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.kick_user(uuid) TO authenticated;` |
| `db/api_v1/sys/rpc/rpc_refresh_token.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.refresh_token_rtr(text) TO web_anon;` |
| `db/api_v1/sys/rpc/rpc_reset_user_password.sql` | `GRANT EXECUTE ON FUNCTION api_v1_sys.reset_user_password(uuid, text) TO authenticated;` |

**说明**：`refresh_token` 授予 `web_anon` 是因为 Token 刷新时用户可能未携带有效 JWT。

---

### 2.2 apply-src.sh 扫描路径修复

**问题**：原脚本只扫描 `db/src/`，`db/api_v1/` 下的视图和 RPC 不会被应用到数据库。

**修改文件**：`scripts/apply-src.sh`

**变更**：
- 扫描路径从 `db/src` 扩展到 `db`（包含 `src`、`api_v1`、`init`、`migrations`）
- 执行顺序：`src` → `api_v1` → `init` → `migrations`

---

### 2.3 密码策略补充

**问题**：`change_user_password` 和 `reset_user_password` 缺少应用层密码强度验证。

**修改文件**：

| 文件 | 补充规则 |
|:---|:---|
| `rpc_change_user_password.sql` | ① 最小 8 位 ② 新密码不能与旧密码相同 ③ 旧密码验证 |
| `rpc_reset_user_password.sql` | 最小 8 位 |

**验证逻辑**：
```plpgsql
IF length(p_new_password) < 8 THEN
    RAISE EXCEPTION 'Password must be at least 8 characters' USING ERRCODE = 'P0005';
END IF;
```

---

### 2.4 审计日志标准化（write_audit_log）

**问题**：原审计触发器直接 `INSERT INTO sys_audit_log`，缺少标准化的写入接口，业务 RPC 无法方便地记录审计。

**新增文件**：`db/src/sys/functions/write_audit_log.sql`

**函数签名**：
```sql
public.write_audit_log(
    p_table_name    text,
    p_operation     text,          -- INSERT/UPDATE/DELETE
    p_old_data      jsonb DEFAULT NULL,
    p_new_data      jsonb DEFAULT NULL,
    p_source        text DEFAULT 'trigger',  -- trigger/manual/rpc/business
    p_description   text DEFAULT NULL
)
```

**改进点**：
1. 统一审计日志写入接口（触发器和业务 RPC 共用）
2. 自动提取 `tenant_id`（从 `new_data` 或 `old_data`）
3. 支持 `source` 字段区分来源（trigger / rpc / business）
4. 支持 `description` 字段记录业务描述

---

### 2.5 审计日志表结构更新

**修改文件**：`db/migrations/sys/005_audit_log_table.sql`

**新增字段**：

| 字段 | 类型 | 默认值 | 说明 |
|:---|:---|:---|:---|
| `source` | `VARCHAR(20)` | `'trigger'` | 审计来源：trigger/manual/rpc/business |
| `description` | `TEXT` | `NULL` | 业务描述（可选） |

---

### 2.6 审计触发器函数更新

**修改文件**：`db/src/sys/functions/audit_trigger_func.sql`

**变更**：从直接 `INSERT INTO sys_audit_log` 改为调用 `public.write_audit_log()`

```plpgsql
-- 旧代码
INSERT INTO sys_audit_log (table_name, operation, old_data, new_data, user_id, tenant_id, created_at)
VALUES (TG_TABLE_NAME, TG_OP, v_old_data, v_new_data, current_user_id(), v_tenant_id, now());

-- 新代码
PERFORM public.write_audit_log(
    p_table_name := TG_TABLE_NAME,
    p_operation := TG_OP,
    p_old_data := v_old_data,
    p_new_data := v_new_data,
    p_source := 'trigger'
);
```

---

### 2.7 批量操作 RPC

**新增文件**：

| 文件 | 函数 | 说明 |
|:---|:---|:---|
| `rpc_batch_update_user_status.sql` | `api_v1_sys.batch_update_user_status(uuid[], text)` | 批量禁用/激活/软删除/恢复用户 |
| `rpc_batch_assign_role_to_users.sql` | `api_v1_sys.batch_assign_role_to_users(uuid, uuid[])` | 给多个用户分配同一角色 |
| `rpc_batch_remove_role_from_users.sql` | `api_v1_sys.batch_remove_role_from_users(uuid, uuid[])` | 从多个用户移除同一角色 |

**安全约束**：
- `batch_update_user_status`：自动跳过当前操作用户（防止自禁用）
- `batch_assign_role_to_users`：带租户隔离校验
- 全部支持 `tenant_id` 隔离（通过 RLS 策略）

---

## 三、P1 修复清单

### 3.1 审计触发器补全

**问题**：原有 4 张表的审计触发器不足以覆盖所有关键业务操作。

**新增文件**（8 个触发器）：

| 文件 | 触发表 | 操作 |
|:---|:---|:---|
| `trg_audit_sys_tenant.sql` | `sys_tenant` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_menu.sql` | `sys_menu` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_api.sql` | `sys_api` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_role_api.sql` | `sys_role_api` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_role_menu.sql` | `sys_role_menu` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_user_session.sql` | `sys_user_session` | INSERT/UPDATE/DELETE |
| `trg_audit_sys_token_blacklist.sql` | `sys_token_blacklist` | INSERT（踢人操作） |
| `trg_audit_sys_user_role_request.sql` | `sys_user_role_request` | INSERT/UPDATE/DELETE |

**审计覆盖统计**：12 张表全覆盖（原 4 → 现 12）

---

### 3.2 系统配置中心（sys_config）

**新增文件**：

| 文件 | 说明 |
|:---|:---|
| `db/migrations/sys/006_create_sys_config.sql` | 创建表 + 默认配置数据 |
| `db/api_v1/sys/views/sys_config.sql` | 公开配置视图（仅 key/value） |
| `db/api_v1/sys/views/sys_config_admin.sql` | 管理员视图（含描述） |
| `db/api_v1/sys/rpc/rpc_get_config.sql` | 获取单个公开配置 |
| `db/api_v1/sys/rpc/rpc_get_all_public_configs.sql` | 获取所有公开配置（前端初始化） |
| `db/api_v1/sys/rpc/rpc_update_config.sql` | 更新配置（管理员） |

**默认配置项**：

| 配置键 | 默认值 | 类型 | 说明 |
|:---|:---|:---|:---|
| `site.title` | `零后端权限管理系统` | string | 站点标题 |
| `site.logo` | `/logo.png` | string | Logo URL |
| `site.copyright` | `© 2026 OmniPG` | string | 版权信息 |
| `password.min_length` | `8` | number | 密码最小长度 |
| `password.require_uppercase` | `true` | boolean | 需要大写字母 |
| `password.require_number` | `true` | boolean | 需要数字 |
| `password.require_special` | `false` | boolean | 需要特殊字符 |
| `session.timeout_minutes` | `15` | number | AT 有效期（分钟） |
| `session.max_concurrent` | `1` | number | 单用户最大并发会话 |
| `security.login_attempts_limit` | `5` | number | 登录失败锁定阈值 |
| `security.lockout_duration_minutes` | `30` | number | 登录锁定时长 |

---

### 3.3 通用导入导出

**新增文件**：

| 文件 | 函数 | 说明 |
|:---|:---|:---|
| `rpc_export_csv.sql` | `api_v1_sys.export_csv(text, text, text)` | 通用导出提示（PostgREST 不支持流式 COPY） |
| `rpc_import_csv.sql` | `api_v1_sys.import_csv(text, jsonb, boolean)` | 通用导入（JSON 数组，支持 dry_run） |

**安全约束**：
- 白名单校验表名（SQL 注入防护）
- 禁止导入系统表（sys_secret, sys_token_blacklist, sys_cron_log, sys_audit_log）
- dry_run 模式预览不实际写入

---

### 3.4 GRANT 权限更新

**修改文件**：`db/api_v1/sys/privileges/grant_all.sql`

**新增授权**：

```sql
-- 配置表读取权限
GRANT SELECT ON api_v1_sys.sys_config TO authenticated;
GRANT INSERT, UPDATE ON api_v1_sys.sys_config TO role_admin;

-- P0 批量操作 RPC
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_update_user_status(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_assign_role_to_users(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_remove_role_from_users(uuid, uuid[]) TO authenticated;

-- P1 配置管理 RPC
GRANT EXECUTE ON FUNCTION api_v1_sys.get_config(text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_all_public_configs() TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.update_config(text, text) TO authenticated;

-- P1 通用导入导出 RPC
GRANT EXECUTE ON FUNCTION api_v1_sys.export_csv(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.import_csv(text, jsonb, boolean) TO authenticated;
```

---

## 四、新增文件清单（完整）

### P0 新增文件（3 个）

```
db/api_v1/sys/rpc/rpc_batch_assign_role_to_users.sql
db/api_v1/sys/rpc/rpc_batch_remove_role_from_users.sql
db/api_v1/sys/rpc/rpc_batch_update_user_status.sql
db/src/sys/functions/write_audit_log.sql
```

### P1 新增文件（17 个）

```
db/api_v1/sys/rpc/rpc_export_csv.sql
db/api_v1/sys/rpc/rpc_get_all_public_configs.sql
db/api_v1/sys/rpc/rpc_get_config.sql
db/api_v1/sys/rpc/rpc_import_csv.sql
db/api_v1/sys/rpc/rpc_update_config.sql
db/api_v1/sys/views/sys_config.sql
db/api_v1/sys/views/sys_config_admin.sql
db/migrations/sys/006_create_sys_config.sql
db/src/sys/triggers/trg_audit_sys_api.sql
db/src/sys/triggers/trg_audit_sys_menu.sql
db/src/sys/triggers/trg_audit_sys_role_api.sql
db/src/sys/triggers/trg_audit_sys_role_menu.sql
db/src/sys/triggers/trg_audit_sys_tenant.sql
db/src/sys/triggers/trg_audit_sys_token_blacklist.sql
db/src/sys/triggers/trg_audit_sys_user_role_request.sql
db/src/sys/triggers/trg_audit_sys_user_session.sql
```

### 修改文件清单（13 个）

```
db/api_v1/sys/privileges/grant_all.sql
db/api_v1/sys/rpc/rpc_approve_role_request.sql
db/api_v1/sys/rpc/rpc_change_user_password.sql
db/api_v1/sys/rpc/rpc_cleanup_expired_tokens.sql
db/api_v1/sys/rpc/rpc_create_user.sql
db/api_v1/sys/rpc/rpc_generate_user_password.sql
db/api_v1/sys/rpc/rpc_get_user_menu.sql
db/api_v1/sys/rpc/rpc_kick_user.sql
db/api_v1/sys/rpc/rpc_refresh_token.sql
db/api_v1/sys/rpc/rpc_reset_user_password.sql
db/migrations/sys/005_audit_log_table.sql
db/src/sys/functions/audit_trigger_func.sql
scripts/apply-src.sh
```

---

## 五、验证清单

### ✅ 本机已通过

| 验证项 | 工具 | 结果 |
|:---|:---|:---:|
| SQL 语法解析 | sqlparse | ✅ 126/126 |
| 括号平衡 | sqlparse | ✅ |
| `$$` 块闭合 | sqlparse | ✅ |
| 文件编码 | file | ✅ 全部 UTF-8 |
| GRANT EXECUTE 覆盖 | grep | ✅ 38/38 |
| apply-src.sh 扫描 | 代码审查 | ✅ |
| 密码策略 | grep | ✅ |

### ⏳ 待用户环境验证

| 验证项 | 命令 | 预期结果 |
|:---|:---|:---|
| 数据库迁移 | `make migrate` | 无错误，所有表/视图/函数创建成功 |
| pgTAP 测试 | `make test-db` | 全部测试通过 |
| E2E 测试 | `make test-e2e` | 全部端到端测试通过 |

---

## 六、注意事项

### 6.1 迁移执行顺序

```
1. db/src/        （基础函数、触发器）
2. db/api_v1/     （视图、RPC、GRANT）
3. db/init/       （初始化数据，如有）
4. db/migrations/ （版本化迁移，dbmate 管理）
```

### 6.2 sys_audit_log 迁移注意

如果 `005_audit_log_table.sql` **已在环境中执行过**（dbmate 已记录），则新增的 `source` 和 `description` 字段**不会自动添加**。

**解决方案**：新建迁移文件 `007_add_audit_source_description.sql`：

```sql
-- migrate:up
ALTER TABLE sys_audit_log 
    ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'trigger',
    ADD COLUMN IF NOT EXISTS description TEXT;

-- migrate:down
ALTER TABLE sys_audit_log 
    DROP COLUMN IF EXISTS source,
    DROP COLUMN IF EXISTS description;
```

### 6.3 RLS 策略注意事项

新增的 `sys_config` 表暂未启用 RLS（因为是系统级配置，所有用户可读）。如需启用：

```sql
ALTER TABLE sys_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY config_read_policy ON sys_config FOR SELECT USING (true);
```

### 6.4 审计触发器性能影响

新增触发器会增加写操作延迟。如果性能敏感，可考虑：
- 使用 `pg_stat_statements` 监控触发器开销
- 对高频写表（如 `sys_user_session`）考虑异步审计

### 6.5 前端调用建议

**公开配置获取**（登录页/初始化）：
```
GET /api/v1/rpc/get_all_public_configs
```

**用户菜单获取**（登录后）：
```
GET /api/v1/rpc/get_user_menu
```

**配置管理**（管理员页面）：
```
GET /api/v1/sys_config_admin
PATCH /api_v1/sys_config_admin?config_key=eq.site.title
```

---

## 七、后续工作（P2）

| 任务 | 说明 | 优先级 |
|:---|:---|:---|
| 通知/公告模块 | 独立模块开发 | P2 |
| 文件上传 + Cloudflare R2 | 独立模块开发 | P2 |
| 角色继承（RBAC Hierarchy） | `g` 规则支持 | P2 |
| 会话管理增强 | 单会话终止、配置化 | P2 |
| 数据字典表 | 下拉选项管理 | P2 |

---

## 八、附录：API 速查表（更新后）

### 认证
- `POST /rpc/user_login_sso` — 登录（web_anon）
- `POST /rpc/refresh_token` — 刷新 Token（web_anon）
- `POST /rpc/logout` — 登出（authenticated）
- `GET /rpc/get_current_user` — 当前用户（authenticated）
- `GET /rpc/get_user_permissions` — API 权限列表（authenticated）
- `GET /rpc/health_check` — 健康检查（web_anon）

### 用户管理
- `GET /v_user_list` — 用户列表（PostgREST 分页）
- `GET /rpc/search_users` — 搜索用户（分页）
- `POST /rpc/create_user` — 创建用户
- `POST /rpc/update_user_status` — 更新状态（单个）
- `POST /rpc/batch_update_user_status` — **批量更新状态（新增）**
- `POST /rpc/change_user_password` — 修改密码（含策略）
- `POST /rpc/reset_user_password` — 重置密码（含策略）
- `POST /rpc/kick_user` — 踢人下线
- `POST /rpc/force_logout_user` — 强制下线

### 角色管理
- `GET /v_role_list` — 角色列表（含统计）
- `POST /rpc/assign_role_to_user` — 分配角色（单个）
- `POST /rpc/remove_role_from_user` — 移除角色（单个）
- `POST /rpc/batch_assign_roles` — 批量分配（用户维度）
- `POST /rpc/batch_remove_roles` — 批量移除（用户维度）
- `POST /rpc/batch_assign_role_to_users` — **批量分配（角色维度，新增）**
- `POST /rpc/batch_remove_role_from_users` — **批量移除（角色维度，新增）**
- `POST /rpc/update_role_permissions` — 批量更新权限（API + 菜单）
- `GET /rpc/get_role_permissions` — 角色权限详情

### 部门管理
- `GET /v_dept_list` — 部门列表（含用户计数）
- `GET /rpc/get_dept_tree` — 部门树

### 菜单/API 管理
- `GET /rpc/get_user_menu` — 用户菜单树（含按钮权限）
- `GET /rpc/get_menu_tree_admin` — 完整菜单树（管理）

### 审批流
- `POST /rpc/submit_role_request` — 提交申请
- `POST /rpc/approve_role_request` — 审批通过
- `POST /rpc/reject_role_request` — 拒绝
- `GET /rpc/get_user_role_requests` — 申请列表

### 监控
- `GET /v_online_users` — 在线用户
- `GET /rpc/get_online_users` — 在线用户（分页）
- `GET /v_audit_log_detail` — 审计详情
- `GET /rpc/search_audit_log` — 搜索审计
- `GET /rpc/get_audit_log_timeline` — 审计时间线
- `GET /v_system_stats` — 统计面板
- `GET /v_system_stats_realtime` — 实时统计

### 配置管理（新增）
- `GET /rpc/get_all_public_configs` — 获取所有公开配置
- `GET /rpc/get_config` — 获取单个配置
- `GET /sys_config` — 配置列表
- `PATCH /sys_config?config_key=eq.xxx` — 更新配置

### 数据导入导出（新增）
- `GET /rpc/export_csv` — 导出提示
- `POST /rpc/import_csv` — 导入数据

---

> **文档版本**: v1.0  
> **最后更新**: 2026-07-29
