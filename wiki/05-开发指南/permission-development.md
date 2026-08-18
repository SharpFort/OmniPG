# 权限模型开发

> 定位：菜单、角色、数据范围 scope 与 RLS 的开发指南。事实以 `db/` 当前代码为准：角色/组织来自 Logto（webhook 同步镜像），权限点单表化（055），判定收敛为 has_permission 单通道 + RLS 数据级隔离。

## 权限模型总览（角色-菜单-数据范围）

三层正交模型（设计源于历史文档 05.4，已归档）：

| 层 | 机制 | 管什么 | 代码位置 |
| --- | --- | --- | --- |
| ① 操作级 | `has_permission(code)` / `require_permission` / `require_super_admin` | 有没有资格做（写/管理/敏感操作） | `db/src/public/functions/` |
| ② 数据级 | RLS 策略（20 条集中清单） | 能看到哪些行（租户/本人/部门范围） | `db/src/public/privileges/rls_policies.sql` |
| ③ 前端 UX | 菜单树 + 按钮显隐（get_user_menu / v-perm） | 看不看得到（可被篡改，非安全边界） | 前端仓库 |

数据流：**Logto（角色/组织权威）→ webhook → `sync_*` 函数 → 镜像表 → JWT claims（`roles` 字符串数组、`organization_id`）→ PostgREST 注入 `request.jwt.claims` → RLS / has_permission 消费**。

## 核心表

| 表 | 类型 | 作用 |
| --- | --- | --- |
| `role` | Logto 全局角色镜像（只读投影） | 角色目录；`role_code` 生成列 = name；与 JWT roles 对齐 |
| `organization_role` | Logto 组织角色镜像 | 组织级角色 |
| `user_role` | 用户-角色分配镜像（global 段 `organization_id=''` + 组织段） | JIT/对账维护，RLS = 超管 OR 本人 |
| `user_tenants` | Logto 组织成员关系镜像 | 租户成员判定 |
| `iam_menu` | 自主表（**单表承载导航 + 权限点 + 端点**） | `menu_type` 四值；button 行 = 权限点（api_code + api_url/api_method） |
| `iam_role_menu` | 角色-菜单绑定（授权唯一通道） | `role_code` + `menu_id`，唯一索引；RLS 全量可读 |
| `iam_role_data_scope` | 角色数据范围 | `scope_type`（枚举）+ `dept_id`（custom 时多行） |

> 055 单表化后 **`iam_api`/`iam_role_api` 已删除**，不存在 Casbin/Go syncer 运行时鉴权；`casbin_rule` 仅是 public 兼容视图（供测试留档），不是鉴权通道。

## 菜单（iam_menu）与按钮权限

`menu_type` 枚举（`db/src/public/types/menu_type.sql`）：`directory`（目录）/ `menu`（菜单）/ `button`（按钮=权限点）/ `link`（外链或 iframe）。

按钮行约束（基线 065 实测）：

- `menu_type='button'` → `api_code` 必填（权限码，命名空间 `public:`，如 `public:dept:create`）、`router`/`component` 必须 NULL（不污染 UI，CHECK `iam_menu_button_nav_null_check`）。
- `api_url`/`api_method` 成对：`api_url` 非空行 `api_method` 必填且值域 IN（GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*）；部分唯一索引 `idx_iam_menu_api_url_method WHERE api_url IS NOT NULL`。
- 一码多端点 = 多行同 `api_code` 的 button 行（`idx_iam_menu_api_code` 非唯一，055 D4）。

权限码命名空间：当前统一 `public:`（055 D11 收敛，前端 v-perm 已同步）。业务模块预留 `content:` / `ugc:` 等。

菜单/权限点写入路径：运行时 `api_v1_public.rpc_create_menu`（18 参，button 行校验 api_code/端点），或种子迁移（066 的 iam_menu 55 行先例）。

## 角色与数据范围 scope_type

`scope_type` 枚举（`db/src/public/types/scope_type.sql`，059 转原生 ENUM）：

| 值 | 含义 | 备注 |
| --- | --- | --- |
| `all` | 全部数据 | 超管短路返回此值 |
| `dept_and_child` | 本部门及以下 | 递归子树 |
| `self` | 仅本人 | 无角色/无绑定时默认 |
| `custom` | 自定义部门 | `iam_role_data_scope` 多行（dept_id） |

消费函数：

- `current_data_scope()`（`db/src/public/functions/current_data_scope.sql`）：返回 `{scope_type, dept_ids}`；**多角色取最宽**：`all > dept_and_child > custom > self`。
- `current_visible_dept_ids()`（SETOF uuid）：把 scope 展开为部门 id 集合（all=全表、custom=指定集合、dept_and_child=递归子树）。
- `current_user_dept_id()`：当前用户部门（查 user_profile）。
- 查询 RPC：`rpc_get_role_data_scope(p_role_code)`；写 RPC：`rpc_set_role_data_scope(p_role_code, p_scope_type, p_dept_ids)`（全量覆盖，custom 必须给 dept_ids，非 custom 不允许带 dept_ids）。

## has_permission 的用法

`has_permission(p_code)`（`db/src/public/functions/has_permission.sql`）判定逻辑：

1. 空码 → false；
2. **超管短路**：`is_super_admin()`（roles 含 `role_super_admin`）→ true；
3. 从 `request.jwt.claims->roles` 提取角色（零查询）；
4. **单通道**：`iam_role_menu → iam_menu`，`role_code = ANY(roles) AND m.api_code = p_code AND m.is_active`。

统一入口：

```sql
-- 权限点档（写/管理 RPC 内一行调用）
PERFORM require_permission('public:dept:create');   -- 不通过即 42501

-- 超管档（平台级 RPC：pg_cron 任务查看等）
PERFORM require_super_admin();

-- 或手写
IF NOT has_permission('public:dept:create') THEN
    RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
END IF;
```

**选择矩阵**：普通查询 → RLS 即可（不逐 RPC 校验）；写/管理/敏感数据源 → has_permission；SECURITY DEFINER 函数 → 必须函数内自校验（DEFINER 绕过 RLS）；自查接口（get_current_user/get_user_menu）→ 无需门槛。

## RLS 策略编写规范

集中清单：`db/src/public/privileges/rls_policies.sql`（20 条策略，全部 `DROP POLICY IF EXISTS` + `CREATE POLICY` 幂等模板，挂最终表名）。常见模式：

| 模式 | 模板 | 例子 |
| --- | --- | --- |
| 租户隔离（RESTRICTIVE） | `USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id())` | department、position、user_position |
| 超管 + 本人 + 同租户 | `is_super_admin() OR user_id = current_user_id() OR ...` | users、user_profile（写 = 超管 OR 本人） |
| 镜像表全局只读 | `FOR SELECT USING (true)` | role、organization_role、iam_role_menu、iam_role_data_scope |
| 全局 + 租户字典 | `is_super_admin() OR tenant_id IS NULL OR tenant_id = current_tenant_id()` | dict_data、dict_type |
| 审计/登录日志 | `is_super_admin() OR tenant_id = current_tenant_id()`（login_log 加 `OR user_id = current_user_id()`） | audit_log、login_log |
| 系统级共享读 | `FOR SELECT USING (is_active = TRUE)` | iam_menu |

编写要求：

1. 新表必须 `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` + 策略（不要漏）。
2. 策略引用 `current_tenant_id()`/`current_user_id()` 等 claims 消费函数（SECURITY DEFINER 防 RLS 递归）。
3. 表级 GRANT 与策略配合：`authenticated` 默认 SELECT（`zz_grant_all.sql`），写权限只授 role_admin/super_admin；**镜像表视图不授写**（N4：REVOKE INSERT/UPDATE FROM role_admin）。
4. 审计/日志表 append-only：UPDATE/DELETE 不授业务角色，写入走 SECURITY DEFINER（write_audit_log / log_operate / sync_*）。

## 授权相关 RPC 清单

以 `db/api_v1/public/rpc/` 实际文件为准（44 个）：

| RPC | 权限码 | 作用 |
| --- | --- | --- |
| `rpc_set_role_menus(p_role_code, p_menu_ids uuid[])` | `public:role-menu:bind` | 全量覆盖角色菜单绑定（授权=菜单树勾选） |
| `rpc_set_role_data_scope(p_role_code, p_scope_type, p_dept_ids)` | `public:data-scope:bind` | 全量覆盖角色数据范围（custom 校验部门存在） |
| `rpc_get_role_data_scope(p_role_code)` | `public:data-scope:bind` | 查询角色数据范围（默认 self） |
| `get_role_permissions(p_role_code)` | —（查询，RLS） | 角色权限明细：apis 段 = button 行 api_url/api_method 非空；menus 段 = 绑定菜单 |
| `get_user_menu()` / `rpc_get_user_menu()` | —（自查） | 当前用户菜单树（roles → iam_role_menu → iam_menu 递归） |
| `rpc_create_menu` / `rpc_update_menu` / `rpc_delete_menu` | `public:menu:create/update/delete` | 菜单/按钮行 CRUD（button 行校验 api_code/端点/导航置空） |
| `rpc_get_menu_tree_admin()` | — | 管理端菜单树 |
| `rpc_create_department` 等 CRUD | `public:dept:create/update/delete`、`public:position:*`、`public:dict:*` 等 | 各管理域写路径 |
| `rpc_search_users` / `rpc_list_tenant_members` | `public:tenant-member:list`（部分） | 用户/成员查询 |
| `rpc_search_login_logs` | `public:login-log:list` | 登录日志查询 |
| `rpc_import_csv` | `public:import` | 通用导入（6 表白名单） |
| `update_config` | `public:config:write` | 配置更新 |
| `webhook_logto(jsonb)` | —（web_anon 可调） | Logto webhook 入口 |

> 权限码全集以 `db/api_v1/public/rpc/` 与 `db/src/public/functions/` 中实际出现的 `public:*` 字符串为准（当前 20+ 个码，grep 可复核）。新码先在 iam_menu 注册 button 行再使用。

## 示例：给角色挂菜单

```sql
-- 1) 拿到按钮/菜单 id（菜单树勾选结果）
SELECT id, menu_name, menu_type, api_code FROM api_v1_public.iam_menu WHERE is_active;

-- 2) 全量覆盖绑定（先删后插，单事务）
SELECT * FROM api_v1_public.rpc_set_role_menus(
    p_role_code := 'tenant_admin',
    p_menu_ids := ARRAY['<menu_id_1>'::uuid, '<menu_id_2>'::uuid]
);
```

## 新增一种数据范围的完整例子

假设新增 `dept_only`（仅本部门，不含子级）：

1. **枚举加值**（值只增不删，改 `db/src/public/types/scope_type.sql`，按 §8.3 模板追加守卫块）：
   ```sql
   DO $$
   BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                      JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.typname = 'scope_type' AND n.nspname = 'public'
                        AND e.enumlabel = 'dept_only') THEN
           ALTER TYPE public.scope_type ADD VALUE 'dept_only';
       END IF;
   END $$;
   ```
2. **`current_data_scope()` 最宽序 CASE 扩展**（`all > dept_and_child > dept_only > custom > self`）。
3. **`current_visible_dept_ids()` 增加 UNION 分支**（`scope_type='dept_only' → id = current_user_dept_id()`）。
4. **`rpc_set_role_data_scope` 的 IN 校验列表**加入 `'dept_only'`（非 custom 不允许 dept_ids）。
5. **RLS 消费**：需要行级过滤的策略改为 `id IN (SELECT current_visible_dept_ids())`（视业务语义选择）。
6. **测试**：`db/tests/public/` 增加 scope 分支断言；`make test-db` 通过。
7. 同步更新 [rpc-reference.md](../06-API参考/rpc-reference.md) 中 `rpc_get_role_data_scope`/`rpc_set_role_data_scope` 的取值说明。

> 注意：scope_type 是封闭枚举（只增不删），废弃值用 `z_deprecated_` 前缀 RENAME；改枚举不进函数签名（RPC 参数保持 text）。

## 开发检查清单

- [ ] 新写/管理 RPC：SECURITY DEFINER + `require_permission('public:xxx:yyy')` + `SET search_path = public, pg_temp`？
- [ ] 权限码已在 iam_menu 注册 button 行（api_code + 端点成对）并绑定角色？
- [ ] 新表 ENABLE RLS + 策略写入 rls_policies.sql + GRANT 写入 zz_grant_all.sql？
- [ ] 查询类接口依赖 RLS，未重复堆 has_permission？
- [ ] 镜像表未授写权限？
- [ ] 数据范围改动：枚举、current_data_scope、current_visible_dept_ids、rpc_set_role_data_scope 四处同步？

---

> 参考：认证授权整体设计见 [../04-架构/auth-design.md](../04-架构/auth-design.md)，新增 API 流程见 [adding-api.md](adding-api.md)，编码规范见 [coding-standards.md](coding-standards.md)，RPC 参数明细见 [../06-API参考/rpc-reference.md](../06-API参考/rpc-reference.md)。
