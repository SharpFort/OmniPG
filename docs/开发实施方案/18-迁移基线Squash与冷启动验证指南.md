# 18-迁移基线 Squash 与冷启动验证指南（v0.1 发布沉淀，2026-08-16）

> 本文沉淀 2026-08-16 完成的 **0.1 迁移基线 squash**（62 个历史迁移 → 064/065/066 三文件）
> 与**全新库冷启动部署链修复**（5 项）的工作成果与可复用经验。
> 方案分析原文见 `docs/审查文档/36-迁移基线合并方案分析与业界最佳实践.md`。

---

## 1. 现状：0.1 基线三文件

`db/migrations/public/` 仅含三个文件（dbmate 按文件名序 064→065→066 应用）：

| 文件 | 内容 | 关键约定 |
|:---|:---|:---|
| `064_v010_mirror_tables.sql` | IdP 镜像/绑定表结构 6 张：users、tenants、role、organization_role、user_tenants、user_role（text id，Logto nanoid） | 业务表 FK 指向本文件表，必须先建 |
| `065_v010_baseline.sql` | 业务表结构 18 张 + 2 序列 + 30 索引 + 31 约束 | 幂等：CREATE IF NOT EXISTS / 约束 DO 守卫 / COMMENT 覆盖 |
| `066_v010_seed_data.sql` | 种子数据 80 行：app_config(14)、dict_type(2)、dict_data(9)、iam_menu(55) | 全部 `ON CONFLICT (id) DO NOTHING`；iam_menu 按 parent_id 拓扑序（自引用 FK 安全） |

- 存量库账本：`schema_migrations` 清空后仅记 `064/065/066`（`dbmate status` = Applied 3 / Pending 0）。
- 历史 62 个迁移永久保存在 `git tag v0.1.0`（`git show v0.1.0 -- db/migrations/public/` 可取回）。
- 触发器（9 trg_audit_* + 7 trg_*_updated_at）、RLS 策略（20 条）、枚举（5 个）均为代码对象，
  归 `db/src/`，由 apply-src 部署——**迁移文件不含任何代码对象（17 号铁律）**。

---

## 2. 版本发布 SOP（何时再 squash）

- **节奏**：开发期按需新增迁移（067+）；发布新版本时 squash 一次，tag 留存。
- **流程**（本次实证，全命令可复用）：
  1. 反写：`pg_dump --schema-only --no-owner --no-privileges -t <白名单表>`（现库 = 审计追平终态，反写语义最真）。
  2. 种子：`--data-only --column-inserts`；自引用 FK 表（如 iam_menu）用递归 CTE 拓扑序导出（见下 §4.3）。
  3. 转换：剥离 pg_dump boilerplate（含 PG18 的 `\restrict`/`\unrestrict` meta 命令）；
     剔除触发器/RLS 策略（src 权威）；幂等化三件套（§4.2）。
  4. 必须带 `-- migrate:up` / `-- migrate:down` 标记（dbmate 无标记即 ErrParseMissingUp 拒跑），
     down 段只写注释（psql -f 会执行全文件）。
  5. `git rm` 旧迁移 + 存量库账本收敛（DELETE FROM schema_migrations + INSERT 新版本号）。
  6. 全新库冷启动验证（§5，`scripts/verify-fresh-db.sh`）+ `make test`。
  7. `git tag vX.Y.0` + 推送（tag 内保留被 squash 的迁移）。
- **多环境部署后**改用 Django 官方两阶段（squash 保留旧文件 → 发布 → 全部环境升级 → 删旧文件 → 二次发布）；
  单开发库一步到位 + tag 兜底即可。

---

## 3. 冷启动部署链（修复后终态）

```
[前提] Pigsty 已管理: 扩展 pg_cron/pg_graphql（pigsty.yml）、
       角色与成员关系（pg_users/pg_roles，见 db/init/02-schemas.sql 头注配置参考）
       ↓
bootstrap（deploy-db.sh [1/4]）: 01-extensions（幂等兜底 4 个）+ 02-schemas + src types
       ↓
dbmate up（[2/4]）: 064/065/066
       ↓
apply-src 全量（[3/4]）: §6.3 扫描 → src → api_v1 → init → migrations 重放
       （内置 3 遍收敛：失败文件进重试队列，3 遍仍失败才终止）
       ↓
dbmate status 验证（[4/4]）
```

### 2026-08-16 修复的 5 项冷启动问题（与决策对照）

| # | 问题 | 修复 | 落点 |
|:--|:---|:---|:---|
| 1 | 01-extensions 含 pgaudit/pgsodium：pgaudit 无 shared_preload_libraries 必炸；pgsodium 零使用且其事件触发器在 dbmate 会话读 GUC 无 missing_ok 炸 42704 | 两行移除；扩展权威管理归 Pigsty（头注写明启用路径 = pg_libs） | `db/init/01-extensions.sql` |
| 2 | apply-src 单遍 `find\|sort` 不保证依赖序；LANGUAGE sql 函数体 CREATE 时即解析（plpgsql 才惰性）→ 全新库 current_user_dept_id/current_visible_dept_ids 必炸 | ① 两函数转 plpgsql（根因消除）② apply-src 加 3 遍收敛重放（通用兜底） | `db/src/public/functions/*.sql`、`scripts/apply-src.sh` |
| 3 | net.request_status（pg_net 扩展成员对象，不可 DROP）+ public.request_status（零引用死枚举）+ db/src 残留 inventory/sales 空目录 | net 模块退役（src 删除、MODULES=public；类型由扩展自动带出）；public.request_status 退役（src 删除 + 现库 DROP）；空目录 rmdir | `db/src/`、`scripts/apply-src.sh` |
| 4 | 02-schemas：角色成员 GRANT 需 ADMIN OPTION（app_owner 无）必炸；死 schema api_v1 行；pg_net 函数授 EXECUTE 给 authenticated = SSRF 后门 | 角色与成员关系移交 Pigsty（含 pg_users 配置参考）；api_v1_public USAGE 显式授予；net 授权改 REVOKE 固化 | `db/init/02-schemas.sql` |
| 5 | （验证中发现）net 属主坑、pgsodium 事件触发器坑为 scratch 环境伪影；app_db 现库本就无 pgsodium/pgaudit | 随 #1 一并清理 | — |

---

## 4. 后续迁移编写约定（067 起）

1. **dbmate 标记必须**：`-- migrate:up` + `-- migrate:down` 缺一不可；标记前只允许注释；down 段只写注释。
2. **幂等三件套**：CREATE TABLE/SEQUENCE/INDEX → `IF NOT EXISTS`；ADD CONSTRAINT →
   `DO $$ IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='...') THEN ... END IF; END $$`；
   种子 → `ON CONFLICT (id) DO NOTHING`。
3. **17 号铁律不变**：迁移只承载表结构+数据；函数/视图/触发器/枚举/RLS/GRANT 一律归 src/api_v1。
4. **新函数默认 plpgsql**：SQL 语言函数体在 CREATE 时解析引用，文件序不保证依赖；确有跨函数引用
   且必须用 SQL 语言时，在 apply-src 收敛循环能力内验证（全新库冷启动是硬门槛）。
5. **枚举**：值只增不删不重排；归 `db/src/public/types/`；不进函数签名。
6. **审计**：业务表配 trg_audit_*（tenant_aware 语义）+ `_by` TEXT 列（Logto 用户 id）；
   镜像表不套审计模板（仅 created_at + logto_updated_at）。
7. **种子 vs 运行时数据**：镜像表（webhook 同步）与业务流水/绑定数据（iam_role_menu 等）不入种子。

### 4.3 自引用 FK 种子导出配方（拓扑序）

```sql
-- 递归 CTE 按深度排序（父先于子），format(%L, to_jsonb) 生成 INSERT 流
-- psql -tA 输出纯语句流（无表头/行数尾）
WITH RECURSIVE tree AS (
    SELECT m.*, 0 AS depth FROM public.iam_menu m WHERE parent_id IS NULL
    UNION ALL
    SELECT m.*, t.depth + 1 FROM public.iam_menu m JOIN tree t ON m.parent_id = t.id
)
SELECT 'INSERT INTO public.iam_menu (' || x.cols || ') VALUES (' || x.vals || ') ON CONFLICT (id) DO NOTHING;'
FROM tree t JOIN LATERAL (
    SELECT string_agg(c.col, ', ' ORDER BY c.ord) AS cols,
           string_agg(format('%L', to_jsonb(t.*)->>c.col), ', ' ORDER BY c.ord) AS vals
    FROM (SELECT column_name AS col, ordinal_position AS ord
          FROM information_schema.columns
          WHERE table_schema='public' AND table_name='iam_menu') c
) x ON true ORDER BY t.depth;
```

---

## 5. scratch 验证库（保留复用）

- **`app_db_verify` 保留**（不复用即浪费）：每次冷启动验证 `DROP ... WITH (FORCE)` 重建。
- **一键验证**：`bash scripts/verify-fresh-db.sh [dbname]`（WSL 内执行；默认 app_db_verify，
  参照库 app_db）。8 步：重建库 → superuser 扩展 → 02-schemas+types → dbmate up → apply-src
  ×2 → 结构比对（表/列/约束/种子/函数/视图/触发器/策略/索引，pg_cron 对象已排除）→ pgTAP。
- **何时跑**：新迁移合入后、发布前、部署链任何脚本变更后。
- 生产 Pigsty 无 sudo 时用 `PG_SUPER_CMD` 覆盖超级用户执行方式。

---

## 6. 本次执行验证记录（2026-08-16）

| 验证 | 结果 |
|:---|:---|
| 临时库 dbmate up（064/065/066） | ✅ 98ms/287ms/59ms 全应用 |
| 临时库 apply-src 二遍幂等 | ✅ 迁移三文件重放 0 ERROR |
| 临时库 vs 现库结构比对 | ✅ 表/列/约束/种子/函数/视图/触发器/索引全等；仅 pg_cron 扩展策略差（排除项） |
| 现库 apply-src 全量重放（修复后首跑） | ✅ EXIT=0、0 ERROR（此前必在 pgaudit 行中断） |
| make test | ✅ pgTAP 115/115 + e2e 33/33 |
| 提交/发布 | ✅ `e15a812` + tag `v0.1.0` 推送（feature/logto-authn） |

---

## 7. 沉淀的开发经验清单（防再踩）

1. **dbmate 只扫文件系统判定 Applied**：schema_migrations 多余记录无害；删旧迁移对存量库零风险。
2. **dbmate 2.34.1 不读配置文件**：URL 用 `DATABASE_URL` 环境变量；`dump` 输出路径随 cwd
   （`./db/schema.sql`），注意在仓库根执行。
3. **pg_dump -t 不导出依赖枚举**：列引用枚举时依赖 bootstrap 的 src types 前置（本链已保证）。
4. **pg_dump 自引用 FK 表有 circular FK warning**：结构无碍，数据文件需拓扑序。
5. **psql -tA 出纯数据流**：不带表头与 `(N rows)` 尾；`\o` 输出会带这些噪音。
6. **CRLF 仓库脚本在 WSL 直接跑必炸**（`$'\r': command not found`）：`tr -d '\r' < x.sh > /tmp/x.sh`；
   verify-fresh-db.sh 已用 LF 写入，勿改行尾。
7. **字节级编辑保留行尾**：对 CRLF 文件用 Python `data.replace(old,new)` 逐对断言唯一性后
   `open(path,'wb')` 写回；避免 patch 工具整文件行尾翻转造成 diff 噪音。
8. **扩展/角色 = 集群级资源**：属 Pigsty；库脚本只做幂等兜底与对象授权。GRANT 角色成员需
   ADMIN OPTION，app_owner 永远没有——不要再放进 init SQL。
9. **安全基线**：pg_net 函数授权 = SSRF 风险面，一律 SECURITY DEFINER 封装 + REVOKE 固化。
10. **冷启动验证是发布硬门槛**：任何迁移/部署链变更后跑 `verify-fresh-db.sh` + `make test` 双闸。
