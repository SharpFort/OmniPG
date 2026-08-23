# 47 D27 实施记录：Logto Tenant / Organization 双语义落地

> **状态**：✅ 实施完成（2026-08-23）；pgTAP 全绿（152 断言）
> **前置**：44/45/46 号文档、D25（镜像退役）、D26（基表 FK + 角色 ID 化）
> **目标**：业务侧同时建模 Logto Tenant（部署租户）与 Organization（业务组织），
>         修复“platform.tenants 曾经映射 organizations”的错误，实现两边一一对应。

---

## 1. 结论：FK 完全正常，业务无需直读 Logto public 表

- **同库跨 schema FK 正常**：platform 业务表已直接 FK 到
  `public.tenants(id)` / `public.organizations(id)` / `public.users(id)` /
  `public.roles(id)` / `public.organization_roles(id)`。
- **实测**：插入不存在的 organization_id 触发 23503；FK 校验与 Logto RLS 无关。
- **业务只需要 FK，不需要直读**：读取统一走 `platform.*` 只读投影视图
  （owner = omnipg_logto_reader，BYPASSRLS + 列级 SELECT）。

---

## 2. Logto 概念映射（D27 定稿）

| 概念 | Logto 对象 | 业务侧 | 说明 |
|---|---|---|---|
| **Logto Tenant** | `public.tenants`（default/admin） | `platform.tenants` 视图；业务表 `tenant_id` 列 | 部署租户/容器，Organization 位于其下 |
| **Logto Organization** | `public.organizations` | `platform.organizations` 视图；业务表 `organization_id` 列 | 业务“租户/组织”，RLS 主维度 |
| 全局角色 | `public.roles` | `platform.role` | role_code=name，含 tenant_id |
| 组织角色 | `public.organization_roles` | `platform.tenant_role` | tenant_id + name |

当前 Logto 实例有 `default` 与 `admin` 两个 Tenant；D27 视图已不再硬过滤 `'default'`，
业务表 `tenant_id` 默认填 `'default'`，后续可由 Logto Custom Claims 注入 `tenant_id` 后全量路由。

---

## 3. 实施内容

### 3.1 迁移 `db/migrations/platform/069_d27_tenant_org_columns.sql`

1. **列改名**：8 张原“组织语义”的 `tenant_id` 列改名为 `organization_id`
   （audit_log / department / dict_data / dict_type / login_log / position / user_position / user_profile）；
2. **全部平台业务表增加双列**：
   - `tenant_id text NOT NULL DEFAULT 'default'`（Logto Tenant）
   - `organization_id text`（Logto Organization；全局表为 NULL）
3. **FK**：
   - 所有表 `tenant_id → public.tenants(id) ON DELETE RESTRICT`
   - `department / position / user_position`：`organization_id → public.organizations(id) ON DELETE CASCADE`
   - 其余：`organization_id → public.organizations(id) ON DELETE SET NULL`（保留历史/全局数据）
4. 旧 FK 约束名 `user_profile_tenant_id_fkey / user_position_tenant_id_fkey`
   重命名为 `*_organization_id_fkey`（语义随之纠正）。
5. 关键索引补建。

### 3.2 只读投影视图（src）

- `platform.tenants` = `public.tenants`（Logto Tenant，含 tenant_id 别名）
- `platform.organizations` = `public.organizations`（Logto Organization，含 organization_id/tenant_id 别名）
- `platform.users / role / tenant_role / user_tenants / user_role / v_logto_login_events`
  全部改为含 `tenant_id`（Logto 租户）与 `organization_id`（组织）双列，取消硬过滤 default。

### 3.3 运行时 helper

- `current_organization_id()`：JWT `organization_id` claim（业务组织）
- `current_tenant_id()`：保留为 `current_organization_id()` 的兼容别名
- `current_logto_tenant_id()`：JWT `tenant_id` claim（未注入时回退 `'default'`，TODO：init-logto 注入）

### 3.4 RLS

所有业务表策略改为 `tenant_id = current_logto_tenant_id()` + `organization_id = current_organization_id()`
（全局表 organization_id IS NULL 放行；超管豁免保留）。

### 3.5 API / RPC

- 新增 `api_v1_platform.tenants / organizations` 视图；
- 用户/部门/岗位/字典/组织/成员/角色/日志等 API 视图输出 **双列**；
- RPC 参数语义更新：`p_organization_id`（组织）、`tenant_id`（Logto 租户）；
- `rpc_list_tenants` 现在列出的是 **Logto Organizations**（业务租户），并带 Logto Tenant 名。

---

## 4. 验证结果

- pgTAP：**152 断言全部通过**（01_schema / 02_function / 03_trigger / 05_rls / test_casbin / test_rls_isolation）；
- `platform.tenants`：2 行（default/admin）
- `platform.organizations`：3 行（含 admin 租户下的 t-admin/t-default）
- `platform.users`：1 行；`platform.user_tenants`：1 行
- FK 实测：插入不存在 organization_id → `department_organization_id_fk` 23503
- apply-src 幂等重放通过（All SQL files applied successfully）

---

## 5. 遗留/注意

1. **Logto 实例侧**：重跑 `init-logto.py` 前如需双租户运行时路由，需在 Custom Claims 注入 `tenant_id`；
   否则 `current_logto_tenant_id()` 恒为 `default`（当前业务约定）。
2. **db/schema.sql**：仍为 D25 前快照，待重建。
3. **前端**：RPC 参数从 `p_tenant_id` 改为 `p_organization_id`，字段新增 `tenant_id/organization_id`，
   需按“API 全面双列”契约同步前端。
4. **部署顺序**：`init-logto-fk-references.sh`（新增 public.tenants REFERENCES）→ dbmate 069 → apply-src → init-logto-reader.sh。

---

## 6. 涉及文件（D27 主要）

- 迁移：`db/migrations/platform/069_d27_tenant_org_columns.sql`
- 脚本：`scripts/init-logto-fk-references.sh`、`scripts/init-logto-reader.sh`、`scripts/deploy-db.sh`
- 视图：`db/src/platform/views/{tenants,organizations,users,role,tenant_role,user_tenants,user_role,v_logto_login_events,zz_sys_user,zz_casbin_rule}.sql`
- 函数：`current_organization_id.sql`、`current_logto_tenant_id.sql`、`current_tenant_id.sql`、`identity_refs_guard.sql`、`write_audit_log.sql`、`log_operate.sql`、`sync_login_log_write.sql`、`has_permission.sql`、`get_user_menu.sql`、`current_data_scope.sql`、`resolve_role_ident.sql`
- API：`api_v1/platform/views/**`、`api_v1/platform/rpc/**`
- 测试：`db/tests/platform/01_schema_test.sql`、`test_rls_isolation.sql`
- 文档：本文件
