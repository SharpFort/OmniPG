# 46 D26 实施记录：业务侧直接 FK 指向 Logto 基表 + 角色绑定 ID 化

> **状态**：✅ 实施完成（2026-08-23）；pgTAP 全绿（123 断言）
> **前置**：37/38/39/40/43 号文档（同库多 Schema 决策）、45 号（Supabase Namespace 参数化对照）、D25（六镜像表退役）
> **核心结论**：同库跨 schema 外键完全可行；**FK 指向 Logto 基表（public.*），只读投影视图继续作为读取面**；角色绑定一次性升级为 `role_id + org_role_id` 双列 FK。

---

## 1. 背景与目标

- 此前 D25 将六张 Logto 镜像表退役为 `platform.*` 只读投影视图，业务侧完整性改用 RPC + BEFORE 触发器 + pg_cron 孤儿清理（不跨 schema）。
- 本人在此前 AI 文档中未被提醒两点：
  1. **同库跨 schema 可以直接建外键**（真正不行的是“跨数据库”）；
  2. **RLS 需要的“视图层”与 FK 是两回事**：视图供安全读取，FK 应指向视图背后的基表。
- 本次目标：
  - `platform.user_profile / user_position` 直接 FK 到 `public.users / public.organizations`；
  - `iam_role_menu / iam_role_data_scope` 一次性升级为 `role_id + org_role_id` 两个可空列，分别 FK 到 `public.roles(id) / public.organization_roles(id)`，CHECK 恰好一个非空；
  - 六个只读投影视图（`users / tenants / role / tenant_role / user_tenants / user_role`）保持不变，继续承担前端读取/脱敏/租户过滤。

---

## 2. Logto 中 Organization vs Tenant（必须先搞清楚）

| 概念 | Logto 对象 | 本项目映射 | 说明 |
|---|---|---|---|
| **Logto 部署租户（Tenant）** | `public.tenants`（如 `db_user=logto_tenant_app_db_default`） | 不直接映射业务 | Logto 多租户 Cloud 概念；所有业务数据表的 `tenant_id` 列都指“部署租户”，本项目恒为 `'default'` |
| **Logto 组织（Organization）** | `public.organizations` | **业务“租户”** | 业务 RLS 的 `tenant_id` = Logto organization id；成员关系在 `public.organization_user_relations` |
| **全局角色（Role）** | `public.roles` | `platform.role`（`role_code=name`） | 如 `role_super_admin` |
| **组织角色（OrganizationRole）** | `public.organization_roles` | `platform.tenant_role` | 如 `tenant_admin / editor / viewer` |

一句话：**Logto 用 Organization 代替了“业务租户”**；Logto 自身的 Tenant 是部署实例容器，业务不需要直接使用。因此 `platform.tenants` 视图 = `public.organizations`，不是 `public.tenants`。

---

## 3. 目标拓扑

```
public.*（Logto 基表：users / organizations / roles / organization_roles …，权威源 + Logto RLS）
        ▲ FK（D26 新增）
platform.*（user_profile / user_position / iam_role_menu / iam_role_data_scope）
        ▲ 只读投影视图（D25 保留）
platform.users / tenants / role / tenant_role / user_tenants / user_role
        ▲
api_v1_platform.*（PostgREST 暴露层）
```

---

## 4. 实施内容

### 4.1 权限前置（superuser 一次性）

```sql
GRANT REFERENCES ON public.users, public.organizations, public.roles, public.organization_roles TO app_owner;
```

新增脚本 `scripts/init-logto-fk-references.sh`；`scripts/deploy-db.sh` 在 `dbmate up` 之前调用（[1.5/4]），否则 068 迁移会因缺 REFERENCES 权限失败。`scripts/init-logto-reader.sh` 也追加了同样授权，作为 apply-src 后兜底。

> ⚠️ `REFERENCES` 只是“建外键”权限，不是 DML；业务角色仍然拿不到 `public.*` 的读写。

### 4.2 迁移：`db/migrations/platform/068_d26_identity_fks.sql`

1. 退役 `d25-purge-identity-refs`（`cron.unschedule`）与 `platform.purge_orphan_identity_refs()`；
2. `platform.user_profile`：
   - `user_id → public.users(id) ON DELETE CASCADE`
   - `tenant_id → public.organizations(id) ON DELETE SET NULL`
3. `platform.user_position`：
   - `user_id → public.users(id) ON DELETE CASCADE`
   - `tenant_id → public.organizations(id) ON DELETE CASCADE`
4. `iam_role_menu`：
   - 新增 `role_id` / `org_role_id`，回填后 `CHECK (恰好一个非空)`；
   - 唯一索引 `(role_id, org_role_id, menu_id)`；
   - FK `role_id → public.roles(id)`、`org_role_id → public.organization_roles(id)`，均 ON DELETE CASCADE；
   - 删除 `role_code` 列。
5. `iam_role_data_scope`：
   - 同 4 的 ID 化 + 唯一索引 `(role_id, org_role_id, scope_type, dept_id)` + 双 FK。

**回填关键点（本实施实测踩坑）**：`app_owner` 直读 `public.roles / public.organization_roles` 会被 Logto RLS 过滤为 0 行，因此回填**必须走 `platform.role / platform.tenant_role` 只读投影视图**（owner=BYPASSRLS）。且回填/视图 DROP 都要用 `information_schema.columns` 判断 `role_code` 列是否仍存在，保证 `apply-src` 幂等重放不丢视图、不重复迁移。

### 4.3 源码层（apply-src 归位）

- 新增 `db/src/platform/functions/resolve_role_ident.sql`：`p_role_code → (role_id, org_role_id)`（全局角色优先）。
- `db/src/platform/functions/get_user_menu.sql / has_permission.sql / current_data_scope.sql`：JWT 角色名先解析为 Logto 角色 ID，再匹配 `iam_role_menu / iam_role_data_scope`。
- `db/src/platform/views/zz_casbin_rule.sql`：由 `role_id/org_role_id` 回卷 `role_code` 作为 Casbin v0（文件名加 `zz_` 前缀保证在 `role.sql / tenant_role.sql` 之后重建）。
- `db/api_v1/platform/views/iam_role_menu.sql / v_role_list.sql / v_role_menu_detail.sql / v_role_users.sql / v_user_roles.sql`：改用 `role_id/org_role_id` 关联，同时继续输出 `role_code` 供前端兼容。
- `db/api_v1/platform/rpc/rpc_set_role_menus.sql / rpc_set_role_data_scope.sql / rpc_get_role_data_scope.sql / rpc_get_role_permissions.sql`：**入参不变**（仍为 `p_role_code`），内部解析为 ID 落库/查询。
- `db/src/platform/functions/identity_refs_guard.sql`：仅保留“用户必须是租户成员”校验（FK 无法表达成员关系）；角色校验与孤儿清理退役。

### 4.4 基线同步

`db/migrations/platform/065_v010_baseline.sql` 同步更新为最终 schema（`role_id/org_role_id` + 对应唯一索引），保证新库冷启动时迁移链一致；068 在既有库上承担转换。

---

## 5. 本机验证结果

- `pgTAP`：6 个测试文件、**123 断言全部通过**（01_schema / 02_function / 03_trigger / 05_rls / test_casbin / test_rls_isolation）。
- `platform.resolve_role_ident('role_super_admin')` → `ivxsh5bjftb18ng7drq6g`；`resolve_role_ident('tenant_admin')` → `pxi3ew0dl9hhcggsxdiki`。
- `api_v1_platform.get_role_permissions('role_super_admin')` 正常返回（含 apis/menus）。
- `user_profile.user_id` 插入不存在用户 → **23503 FK violation**（证明 FK 校验不受 Logto RLS 影响）。
- 迁移后 `iam_role_menu` 数据已按备份语义恢复（55 条全局 + 52 条租户角色绑定）。

---

## 6. 已知注意/遗留

1. **部署时序**：新增脚本必须在 `dbmate up` 前执行（deploy-db 已加 [1.5/4]）；手工 `make migrate` 前请先跑 `scripts/init-logto-fk-references.sh`。
2. **apply-src 后必须重跑 `init-logto-reader.sh`**：投影视图重建后 owner 会回到 `app_owner`，丢失 BYPASSRLS 导致视图空读（D25 既有流程，D26 沿用）。
3. **`db/schema.sql` 快照**：仍为旧镜像时代快照，待按最终 schema 重建（D25 遗留）。
4. **Logto 升级耦合**：FK 使 Logto 侧 DDL（DROP/TRUNCATE/ALTER TYPE）受平台依赖约束；升级回归门继续保留。
5. **历史日志不设 FK**：`audit_log / login_log` 的 user_id 仍保留历史字符串，不指向 Logto 用户（避免删用户导致日志丢失）。

---

## 7. 涉及文件

- 迁移：`db/migrations/platform/068_d26_identity_fks.sql`；`065_v010_baseline.sql`（基线同步）
- 脚本：`scripts/init-logto-fk-references.sh`（新增）、`scripts/init-logto-reader.sh`、`scripts/deploy-db.sh`
- 平台函数/视图：`resolve_role_ident.sql`、`identity_refs_guard.sql`、`get_user_menu.sql`、`has_permission.sql`、`current_data_scope.sql`、`zz_casbin_rule.sql`
- API 视图/RPC：`iam_role_menu.sql`、`v_role_list.sql`、`v_role_menu_detail.sql`、`v_role_users.sql`、`v_user_roles.sql`、`rpc_set_role_menus.sql`、`rpc_set_role_data_scope.sql`、`rpc_get_role_data_scope.sql`、`rpc_get_role_permissions.sql`
- 测试：`db/tests/platform/01_schema_test.sql`、`db/tests/platform/test_rls_isolation.sql`
- 文档：本文件、`wiki/04-架构/认证授权设计.md`
