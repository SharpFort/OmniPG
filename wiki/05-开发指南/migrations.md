# dbmate 数据表演进管理

> 定位：迁移规范——如何新增/修改/回滚数据库结构。核心约束是 **17 号铁律**：`db/migrations/` 只承载「表结构变更」与「数据变更」；函数/视图/触发器/枚举/RLS/GRANT 一律归 `db/src/` 或 `db/api_v1/` 幂等源文件。

## 概览

| 项 | 现状 |
| --- | --- |
| 工具 | dbmate（迁移表 `schema_migrations`） |
| 配置 | `db/dbmate.toml`（`migrations_dir = "./migrations/public"`） |
| 迁移目录 | `db/migrations/public/`（当前仅 3 个基线文件：064/065/066） |
| 主入口 | `make migrate` / `make migrate-rollback` / `make migrate-status`；或 `scripts/migrate.sh {up|down|status|create} <environment>` |
| 部署链 | bootstrap（init + src types）→ dbmate up → apply-src 全量幂等重放（`scripts/deploy-db.sh`） |

## dbmate 安装与配置

安装（Windows）：

```powershell
dbmate --version          # 检查
winget install dbmate     # 或 scoop install dbmate
```

配置 `db/dbmate.toml`：

```toml
database_url = "postgres://app_owner:dev_password_change_me@127.0.0.1:5432/app_db?sslmode=disable"
migrations_dir = "./migrations/public"
```

- 连接串以 `DATABASE_URL` 环境变量为准（Makefile 会从 `gateway/.env` 读取 `DB_PASSWORD` 拼装）；`dbmate.toml` 的 `database_url` 仅作本地兜底。
- CI 中 dbmate 的用法见 `.github/workflows/ci.yml`（`dbmate up --dry-run` 于 postgres:18 service）。

## 迁移目录与命名

- 目录：`db/migrations/public/`（公共/系统域）。历史 `inventory`/`sales` 子目录保留为空（测试模块已退役）。
- 文件命名：3 位序号 + 描述，如 `064_v010_mirror_tables.sql`、`065_v010_baseline.sql`、`066_v010_seed_data.sql`。dbmate 按文件名排序执行，`dbmate new` 默认生成时间戳前缀（`<时间戳>_<名称>.sql`），可改名为序号风格，只要保持单调递增。
- 每个文件必须带 `-- migrate:up` 与 `-- migrate:down` 标记（缺标记 dbmate 拒跑）；**标记前只允许注释**。
- 新迁移从 **067 起**继续编号（18 号文档约定）。

## 新增迁移的标准流程

```bash
cd db
dbmate new create_xxx_table        # 生成 <时间戳>_create_xxx_table.sql（含 up/down 标记）
# 编辑迁移文件（幂等三件套，见下）
cd .. && make migrate               # 应用；或 make migrate-status 先看 Applied/Pending
```

按环境执行：`bash scripts/migrate.sh up development`（支持 up/down/status/create）。

### 幂等三件套（apply-src 会全量重放迁移，必须两遍不炸）

```sql
-- 067_create_xxx_table.sql
-- migrate:up
CREATE TABLE IF NOT EXISTS public.xxx (
    id         uuid DEFAULT uuidv7() PRIMARY KEY,
    tenant_id  text NOT NULL,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 约束用 DO 块守卫（CREATE CONSTRAINT 无 IF NOT EXISTS）
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'xxx_name_not_null') THEN
        ALTER TABLE public.xxx ALTER COLUMN name SET NOT NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_xxx_tenant ON public.xxx USING btree (tenant_id);

-- migrate:down
-- 回滚说明（可回滚迁移在此写 DROP TABLE ...）
```

种子/数据变更用 `ON CONFLICT (id) DO NOTHING`（见 066 样板）。

## 可回滚性：up/down 成对

- dbmate 的 `rollback` 按 `schema_migrations` 逆序执行最近一个迁移的 down 段（`make migrate-rollback`）。
- 基线迁移（064/065/066）**无 down 语义**：down 段只写注释，回滚 = 从 git tag `v0.1.0` 取回历史 62 个迁移（当前目录下已 squash）。
- 新迁移要求 up/down 成对：结构性变更写真实 down（DROP TABLE / DROP COLUMN 等），纯数据变更写对应的 DELETE/UPDATE 或注释说明。

## 种子数据与基线迁移（064/065/066）

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `064_v010_mirror_tables.sql` | IdP 镜像/绑定表 6 张：`users`、`tenants`、`role`、`organization_role`、`user_tenants`、`user_role`（text id = Logto nanoid） | 业务表 FK 指向本文件表，必须先建 |
| `065_v010_baseline.sql` | 业务表 18 张 + 2 序列 + 30 索引 + 31 约束（department/position/user_profile/iam_menu/audit_log/login_log/app_config 等） | 幂等：CREATE IF NOT EXISTS / DO 守卫 / COMMENT 覆盖 |
| `066_v010_seed_data.sql` | 种子 80 行：app_config(14)、dict_type(2)、dict_data(9)、iam_menu(55) | 全部 ON CONFLICT (id) DO NOTHING；iam_menu 按 parent_id 拓扑序 |

历史 62 个迁移保存在 `git tag v0.1.0`（`git show v0.1.0 -- db/migrations/public/` 可取回）。squash 的完整 SOP 见历史文档（18-迁移基线 Squash 指南，已归档）。

## 迁移与 src（函数/触发器/RLS）的关系：apply-src.sh

**17 号铁律判定表**（建/改对象前必查）：

| 对象 | 归属 |
| --- | --- |
| 表/列/约束/索引结构变更、数据变更（无论幂等与否） | `db/migrations/<module>/` 新编号文件 |
| 枚举创建/加值 | `db/src/<schema>/types/<name>.sql`（bootstrap 前置） |
| 底层函数 / 触发器 / 视图 / RLS | `db/src/public/`（functions/triggers/views/privileges） |
| 对外视图 / RPC（api_v1_public.*） | `db/api_v1/<域>/`（views/rpc；目录按域组织 `_shared`/`inventory`/`public`，当前活跃模块 public；运行态仅暴露 api_v1_public——新模块须同步 `apply-src.sh` 的 `API_MODULES` 与 compose `PGRST_DB_SCHEMAS`，postgrest.conf 参考文件已对齐（2026-08-19）） |
| GRANT | `db/api_v1/public/privileges/zz_grant_all.sql` 集中管理 |

`scripts/apply-src.sh` 全量幂等重放顺序（**迁移最后执行**；模块清单 `MODULES="public"`、`API_MODULES="_shared public"`，新增域模块在此声明）：

```
src types → src 其余 → api_v1（rpc → views → 其余/privileges）→ init → migrations（最后）
```

- 执行前先做 **§6.3 迁移代码对象扫描**：`db/migrations/**/*.sql` 中出现 `CREATE ... FUNCTION|VIEW|TRIGGER|TYPE|DOMAIN|POLICY|RULE` 或对应 COMMENT 即 exit 1（新迁移零容忍）。
- 由于迁移最后重放，**迁移中残留同名函数/视图会覆盖 src 版本**——对象定义必须只存在于 src/api_v1，迁移只留结构+数据。
- 新建库必须走 `scripts/deploy-db.sh`（bootstrap → dbmate up → apply-src → 验证），**禁止裸跑 `dbmate up`**（枚举/schema/角色由 bootstrap 前置，否则冷启动 42704 炸）。

## 常见坑：已上线环境的破坏性变更

| 坑 | 说明与对策 |
| --- | --- |
| 迁移含代码对象 | apply-src 扫描直接失败；定义一律归 src/api_v1（17 号铁律） |
| 新迁移引用 src 函数/视图 | 冷启动时 dbmate 先于 apply-src，对象尚不存在；只允许引用更早迁移 + bootstrap 对象（schema/角色/枚举/扩展） |
| `ALTER TYPE ... ADD VALUE` 后同文件使用新值 | dbmate 每迁移文件包事务，事务内新值不可用（`unsafe use of new value`）；枚举加值一律走 src types（psql autocommit 安全） |
| 修改已应用的迁移文件 | dbmate **无 checksum**（只记版本号），改结构/数据段不会破坏 status，但存量库不重放 → 新老环境分叉；只允许「删除代码对象定义段」或「改注释」（17 号铁律 §7.4 编辑边界） |
| 幂等三件套缺失 | apply-src 二次重放必炸（`IF NOT EXISTS` / DO 守卫 / ON CONFLICT） |
| RENAME 只做单守卫 | `ALTER TABLE IF EXISTS ... RENAME TO` 重放二次会冲突；需「源存在 AND 目标不存在」双守卫 |
| 数据迁移引用已被删的源表 | 用 `IF to_regclass('...')` 包住（历史 011 实证） |
| 直接 rollback 基线 | 064/065/066 无 down 语义；回滚走 git tag 恢复 |

## 常用命令速查

| 命令 | 作用 |
| --- | --- |
| `make migrate` | 应用所有待执行迁移（`dbmate -d migrations/public up`） |
| `make migrate-rollback` | 回滚最近一次迁移 |
| `make migrate-status` | 查看 Applied / Pending |
| `bash scripts/migrate.sh create <name>` | 新建迁移 |
| `bash scripts/apply-src.sh <db_url>` | src + api_v1 + init + migrations 全量幂等重放 |
| `bash scripts/deploy-db.sh <env>` | 完整部署链（bootstrap → dbmate → apply-src → 验证） |
| `bash scripts/verify-fresh-db.sh` | 全新库冷启动验证（结构比对 + 幂等两遍 + pgTAP） |

---

> 参考：迁移文件的内容规范见 [coding-standards.md](coding-standards.md)，新增 API 流程见 [adding-api.md](adding-api.md)，目录职责见 [repo-layout.md](repo-layout.md)；部署链与冷启动细节见 [../03-部署指南/deployment-overview.md](../03-部署指南/deployment-overview.md) 与 [../03-部署指南/manual-deploy.md](../03-部署指南/manual-deploy.md)。