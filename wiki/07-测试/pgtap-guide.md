# pgTAP 测试指南

pgTAP 是 PostgreSQL 的单元测试框架，负责验证数据库对象的存在性与基础行为。OmniPG 的全部数据库测试位于 `db/tests/`，通过 `make test-db`（内部调用 pg_prove）执行。

## pgTAP 安装与启用

pgTAP 由 **Pigsty 统一管理**（权威 = `infra/pigsty.yml`：`pg_extensions` 装包 + `pg_databases[].extensions` 库内启用；`db/init/01-extensions.sql` 已于 2026-08-19 移除）。本地验证环境如需手动补建：

```sql
CREATE EXTENSION IF NOT EXISTS "pgtap";
```

环境策略（见 [wiki/01-项目简介/extensions/pgtap.md](../01-项目简介/extensions/pgtap.md)）：

| 环境 | pgtap 安装 | 说明 |
| --- | --- | --- |
| 生产 | ❌ 不安装 | 避免测试框架引入安全风险 |
| 预发布 | ❌ 不安装 | 生产数据的副本 |
| 开发 | ✅ 安装 | 本地开发运行测试（Pigsty 随 PostgreSQL 18 预装） |
| CI | ✅ 安装 | CI 流水线运行测试 |

检查是否已安装：

```bash
psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'pgtap';"
```

## 测试目录与文件组织

- 测试目录：`db/tests/`（当前仅 `public/` 子目录，对应 public 业务域）。
- 命名规范：数字前缀控制执行顺序 + 描述性名称，例如 `01_schema_test.sql`、`02_function_test.sql`、`03_trigger_test.sql`、`05_rls_test.sql`；行为类测试用完整描述名（`test_casbin_view.sql`、`test_rls_isolation.sql`）。
- 收集方式：pg_prove 以 `--ext .sql` + `-r`（递归）扫描目录。

当前文件清单（计划断言合计 115 条）：

> 兼容视图说明：`public.sys_user` / `casbin_rule` 兼容视图已于 2026-08-20 移除；`01_schema_test.sql` 用 `hasnt_table('sys_user')`、`hasnt_view('sys_user')`、`hasnt_view('casbin_rule')` 断言其不存在。

| 文件 | 计划断言数 | 主题 |
| --- | ---: | --- |
| `01_schema_test.sql` | 63 | 表/列/索引/外键/视图存在性；`sys_*` 与 Casdoor 时代表已移除 |
| `02_function_test.sql` | 11 | 函数存在性与基础行为（sha256、JWT helper、RLS helper 等） |
| `03_trigger_test.sql` | 4 | 触发器存在与行为（审计、updated_at） |
| `05_rls_test.sql` | 12 | RLS 启用状态、055 单表化后的表删除断言 |
| `test_rls_isolation.sql` | 14 | 镜像表、RLS 策略、RLS helper 函数 |

## 文件结构与事务回滚

每个测试文件都是独立的 SQL 脚本，用事务包裹保证可重复执行：`BEGIN` → `plan(N)` → 断言 → `finish()` → `ROLLBACK`。测试内的任何写操作（如触发器的 UPDATE）都随回滚丢弃，多次运行结果一致。

```sql
BEGIN;
SELECT plan(2);
SELECT ok(true, '示例');
SELECT has_table('users');
SELECT * FROM finish();
ROLLBACK;
```

要点：

- `plan(N)` 声明用例数，实际执行数与声明不符时 pg_prove 会报告计划差异。
- 断言失败不会中断脚本，pgTAP 逐条记录结果，最后统一输出 TAP 摘要。
- 测试以 `app_owner` 身份直连执行，**不经过** PostgREST/APISIX，也不带 JWT——JWT 语义下的行为（如 `current_user_id()` 返回 NULL）只能验证“无 JWT 分支”。

## 常用断言

| 断言 | 作用 | 仓库内示例 |
| --- | --- | --- |
| `plan(N)` | 声明用例数 | `SELECT plan(63);`（01_schema_test.sql） |
| `ok(expr, desc)` | 布尔断言 | `ok((SELECT count(*) >= 1 FROM pg_indexes ...), 'users.username 有索引')` |
| `is(actual, expected, desc)` | 等值断言 | `is(current_user_id(), NULL, '无 JWT 时 user_id 为 NULL')` |
| `results_eq(sql, ARRAY[...], desc)` | SQL 结果与期望数组比较 | `results_eq($$ SELECT DISTINCT api_method FROM iam_menu WHERE api_method IS NOT NULL $$, ARRAY['GET'::varchar], ...)` |
| `lives_ok(sql, desc)` | 断言语句不抛异常 | `lives_ok('SELECT current_user_id()', 'current_user_id 不抛异常')` |
| `has_table / hasnt_table` | 表存在/不存在 | `has_table('users')`、`hasnt_table('iam_api')` |
| `has_column` | 列存在 | `has_column('users', 'username')` |
| `has_view / columns_are` | 视图存在/列集合 | `has_view('v_role_list')`、`columns_are('v_role_list', ARRAY['id',...])` |
| `has_function` | 函数存在 | `has_function('update_updated_at')`、`has_function('current_user_id', ARRAY[]::text[])` |
| `has_trigger` | 触发器存在 | `has_trigger('department', 'trg_audit_department')` |
| `fk_ok(table, col, ref_table, ref_col)` | 外键存在 | `fk_ok('user_tenants', 'user_id', 'users', 'id')` |
| `function_lang_is` | 函数语言 | `function_lang_is('is_super_admin', 'sql')` |

## 测试数据准备与清理

- 测试**不建立独立 fixture**：断言基于迁移种子数据（`app_config`/`dict_type`/`dict_data`/`iam_menu`、`role_super_admin` 等）与只读查询。
- 清理依赖事务回滚：`03_trigger_test.sql` 中对 `department` 的 UPDATE 只影响事务内数据。
- **已知预期差异**：`test_casbin_view.sql` 有 3 条用例依赖 `iam_role_menu` 的运行时绑定数据（种子不含），全新库上必然失败 → `verify-fresh-db.sh` 以“112/115 通过 + casbin 3 条预期差异”作为通过标准；管理员在 UI 配置绑定后自愈。

## 运行：make test-db 与 pg_prove

### make test-db（推荐）

```bash
make test-db
```

等价于（Makefile）：

```bash
cd db && pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r tests/ || true
```

### 直接使用 pg_prove

```bash
# 全量（从仓库根目录）
cd db && pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r tests/

# 单个文件
pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql db/tests/public/02_function_test.sql

# 全新库验证（verify-fresh-db.sh 内部自动执行 pg_prove，并处理 casbin 预期差异）
bash scripts/verify-fresh-db.sh
```

pg_prove 常用参数：

| 参数 | 含义 |
| --- | --- |
| `-h <host>` | 数据库主机（本地开发为 127.0.0.1） |
| `-U <user>` | 连接用户（`app_owner`） |
| `-d <dbname>` | 目标数据库（`app_db`） |
| `--ext .sql` | 只收集 .sql 后缀的测试文件 |
| `-r` / `--recurse` | 递归扫描目录 |

> 历史命令（`db/extensions/pgtap.md`，Docker 时代）：`docker compose exec app-postgres pg_prove -U app_owner -d app_db --ext .sql db/tests/`。当前栈由 Pigsty 管理 PostgreSQL，测试在宿主直接连接执行（见 `verify-fresh-db.sh`）。

## 新增测试的检查清单

- [ ] 文件放入 `db/tests/public/`，命名遵循数字前缀或描述性名称；
- [ ] `BEGIN` + `plan(N)` + `finish()` + `ROLLBACK` 四件套齐全；
- [ ] 断言只读、幂等、可重复执行；
- [ ] 涉及种子外数据时注明依赖（如 casbin 运行时绑定）；
- [ ] 本地 `make test-db` 全绿后，再跑 `make test-e2e` 验证请求级行为。

---

> 参考：[测试体系总览](testing-overview.md) · [E2E 集成测试](e2e-tests.md) · [冒烟验证脚本](verify-scripts.md) · [数据库迁移](../05-开发指南/migrations.md) · [认证与授权设计](../04-架构/auth-design.md)