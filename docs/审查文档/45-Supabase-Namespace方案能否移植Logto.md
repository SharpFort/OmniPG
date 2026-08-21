# 45 Supabase Auth 的 Namespace 模板方案能否移植给 Logto？

> **状态**：✅ 核查完成（2026-08-21）。基于 supabase/auth master 分支源码逐文件核实
> **回答**：你看到的 `CREATE TABLE IF NOT EXISTS {{ index .Options "Namespace" }}.users` **是正确方向，本质就是我 44 号文档说的"参数化"方案**——但 Supabase 做到的是"全量显式 schema 前缀"，而 Logto 当前是"混合策略"（大部分靠 search_path、少数硬编码 public）。这套方案**可以也应当提供给 Logto**，但有一个 Supabase 根本不存在的复杂度需要额外补上：**租户角色（tenant role）的两层连接授权**。

---

## 1. Supabase Auth 到底做了什么（源码事实）

### 1.1 机制：运行时模板渲染 schema 名

- 配置项：`internal/conf/configuration.go` → `DBConfiguration.Namespace`，env `DB_NAMESPACE`，**默认 `auth`**。
- 迁移执行：`cmd/migrate_cmd.go` 把这值塞进 pop 库的连接 Options：
  ```go
  deets.Options = map[string]string{ "migration_table_name": "schema_migrations", "Namespace": config.DB.Namespace }
  ```
- 每个迁移 SQL 把 schema 名用 Go 模板占位：`{{ index .Options "Namespace" }}`，运行时由 pop 模板引擎替换成真实的 namespace。

### 1.2 覆盖面：全量显式前缀（这是与 Logto 的核心差异）

`migrations/00_init_auth_schema.up.sql` 里**每一条**建表/建索引/建函数都带前缀：

```sql
CREATE TABLE IF NOT EXISTS {{ index .Options "Namespace" }}.users (...)
CREATE INDEX IF NOT EXISTS users_instance_id_idx ON {{ index .Options "Namespace" }}.users ...
create or replace function {{ index .Options "Namespace" }}.uid() returns uuid ...
```

连**授权/RLS**也全带前缀（`20240612123726_enable_rls_update_grants.up.sql`）：

```sql
alter table {{ index .Options "Namespace" }}.users enable row level security;
grant select on {{ index .Options "Namespace" }}.users to postgres with grant option;
```

**结论**：Supabase Auth 的 schema 是**一等公民、贯穿从建表到授权的每一个对象名**，没有任何一处依赖 search_path 或硬编码 public。这就是它"优雅"的真正来源——不是某一句语法，而是**全链路参数化**。

---

## 2. 对比 Logto 当前实现（为何不能只抄那一句）

| 维度 | Supabase Auth | Logto v1.42.0 | 差异 |
|---|---|---|---|
| schema 名来源 | `DB_NAMESPACE` env，默认 auth | 无配置，多数隐式走 search_path | Supabase 显式化 |
| 建表前缀 | 每条语句显式 `{{ namespace }}.` | 大部分**无前缀**（靠 search_path），少数硬编码 public | 关键差异 |
| 授权 | `grant select on {{ namespace }}.users to postgres` | `_after_all.sql` 硬编码 `in schema public` | 关键差异 |
| 函数 search_path | 无此概念（全部显式） | 两个函数 `set search_path = public`（PR #6101 加固） | Logto 独有 |
| 函数内表引用 | `{{ namespace }}.users` 显式 | `public.check_role_type` / `public.roles` | Logto 独有 |
| **租户角色两层连接** | **不存在**（单连接直连） | **存在**：`tenants.db_user` → `logto_tenant_<db>_default/_admin` 重连 | **Logto 独有，最难** |

---

## 3. 答案：能否提供给 Logto？

### 3.1 能，而且是正确方向

Supabase 的"全量显式 schema 前缀 + 运行时变量渲染"**正是 Logto 应该走的方向**，它天然解决了我 44 号文档里 6 处硬编码中的 5 处：

- `_after_all.sql` 的 `in schema public` → `in schema {{ namespace }}`；
- `roles.sql` 的 `public.check_role_type` / `public.roles` → `{{ namespace }}.check_role_type` / `{{ namespace }}.roles`；
- `applications.sql` / `organization_roles.sql` 的 `set search_path = public` → `set search_path = {{ namespace }}`；
- `models/tenants.ts` 的 `'public'` → 动态传入 schema 变量。

Logto 的 SQL 已经是 JS 模板字符串（`sql...` + `sql.raw`/占位符），实现"变量渲染 schema 名"比 Supabase 的 Go 模板还更直接——只需在 seed/alteration 入口注入一个 schema 变量。

### 3.2 但不能只抄那一句，要补三个 Supabase 没有的东西

1. **租户角色授权要跟着变**：Logto 的 `_after_all.sql` 不只是授权，它后面还有针对 `tenants` 表的列级 grant + revoke + RLS 策略（`using (db_user = current_user)`）。改成 `{{ namespace }}` 后，**这些授权/revoke/策略的对象名也要全部跟着 namespace 走**，否则租户角色对自定义 schema 下的 tenants 表拿不到所需列权限，运行时 `select id from tenants` 失败。Supabase 无租户角色，没有这一段。
2. **租户角色的 search_path 仍要设置**：即使所有 SQL 都显式带 schema 前缀，运行时 Logto 以 `logto_tenant_<db>_default` 重连后，**代码里仍有 unqualified 查询**（如 Issue #8607 暴露的 `logto_configs` 读取、以及 `getTenantDatabaseDsn` 里的 `select db_user from tenants`）。这些不写 schema 的读，仍依赖该租户角色的 search_path。所以"全量前缀化"之外，**仍需给两级租户角色设 search_path**——这正是 44 号/39 号反复强调的"两层连接"尾巴。
3. **存量库迁移 alteration**：Supabase 是 pop + `schema_migrations` 版本表，Logto 是 `systems.alterationState` + alterations 目录，机制不同但道理一样——只改源码对存量库无效，必须新增一条带 down 的 alteration 做 `ALTER ... SET SCHEMA` + 租户角色授权迁移。

---

## 4. 给 Logto 的最终建议（合并 Supabase 方案 + 我们的 44 号结论）

正确、完整、无副作用的改法是：

1. **引入 schema 变量**（env/config，如 `DATABASE_SCHEMA`），默认 `public` 向后兼容；
2. **把 6 处硬编码全部替换为变量**（采用 Supabase 式的"显式前缀"，而非删掉）；
3. **`_after_all.sql` 及相关 tenants 授权/revoke/RLS 同步跟着变量走**；
4. **seed 建两级租户角色后**：grant `USAGE` + 设 `search_path` + grant DML（把现在只对 public 做的，改成对 namespace）；
5. **附带一条带 down 的 migration alteration** 处理存量库（`ALTER ... SET SCHEMA` + 租户角色 search_path 迁移）；
6. **验收**：fresh seed 落自定义 schema + Console 登录 + 角色/应用/组织角色三类 CHECK e2e + alteration 对存量库报 0 pending。

——这与我 44 号文档的结论完全一致，Supabase Auth 是它的一个**成功参照实现**：它证明"全量显式 schema 前缀 + 变量"在同类认证服务上落地是成熟可行的；同时它没有 Logto 的租户角色负担，所以 Logto 要多做第 3、4 步。

---

## 5. 证据索引

- supabase/auth master：`cmd/migrate_cmd.go`（pop Options 注入 Namespace）、`internal/conf/configuration.go` L121（`DB_NAMESPACE` 默认 auth）、`migrations/00_init_auth_schema.up.sql`（全量 `{{ index .Options "Namespace" }}`）、`migrations/20240612123726_enable_rls_update_grants.up.sql`（授权/RLS 也全前缀）
- logto v1.42.0：`packages/schemas/tables/{_after_all,roles,applications,organization_roles}.sql`、`packages/schemas/src/models/tenants.ts`、`packages/core/src/tenants/utils.ts`（getTenantDatabaseDsn 两层连接）、allegations 1.9.0/PR #6101
- 本仓库：44 号（移除 public 可行性）、39 号（四道墙 + P1–P7）、GitHub Issue 草稿（§3 Suggested implementation approach）
