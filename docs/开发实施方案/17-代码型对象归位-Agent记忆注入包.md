# 17 号铁律 — Agent 记忆注入包（P0-2 交付物）

> **用途**：将「代码型对象归位铁律」的核心规则注入另一台电脑的 agent（Hermes 记忆 / skill / 参考文档均可）。
> **来源**：`docs/开发实施方案/17-代码型对象归位-迁移仅表结构与数据-铁律-v1.1-修订稿.md`（v1.2 已确认执行，2026-08-14）。
> **适用范围**：OmniPG 项目（D:\WeChat Files\OmniPG，PG18 + Pigsty + PostgREST，db/ 目录 SQL 仓库）。
> **注入方式建议**：① 整篇作为记忆条目（紧凑版见文末「记忆压缩版」）；② 或存为 skill/参考文档，需要时读取。

---

## 0. 铁律主文（一句话）

**`db/migrations/` 只允许承载「表结构变更」与「数据变更」；函数（RPC/底层）、视图、触发器、类型（含枚举）等「代码型对象」一律以幂等源文件形式归位于 `db/src/` 或 `db/api_v1/`，禁止在迁移文件中创建或修改代码型对象。**

六条硬性约束：
1. **判定先行**：建/改 SQL 对象前先按 §4 判定表归类，不允许"顺手写进迁移"。
2. **禁止双份定义**：同一对象全库只允许一处定义；迁移删定义与源文件建文件**必须同一提交同步完成**；双轨冲突按 §6 仲裁（人工裁决强制）。
3. **GRANT 集中**：`db/api_v1/public/privileges/grant_all.sql` 为 GRANT 唯一集中地。
4. **Bootstrap 前置**：部署链固定为 **bootstrap（init + `src/*/types/`）→ dbmate up → apply-src.sh 全量重放**；新建库禁止裸跑 `dbmate up`。
5. **删定义机制**：从迁移中移除对象 = **编辑既有迁移文件删除该对象 DDL 段**；禁止新增 DROP 迁移来归位。
6. **一文件一对象**：每个代码型对象独立 `<name>.sql`；触发器函数归 `functions/`、`CREATE TRIGGER` 归 `triggers/`（两文件同一提交）；GRANT/RLS 用集中清单文件（grant_all.sql / rls_policies.sql）。

---

## 1. B' 判定表（对象归属，创建/修改前必查）

| 对象类型 | 判定特征 | 归属目录 |
|---|---|---|
| 表/列/约束/索引结构变更 | DDL，需版本演进 | `db/migrations/<module>/`（新编号文件） |
| 数据变更（seed/权限点映射/回填/字典数据） | INSERT/UPDATE/DELETE，**无论幂等与否** | `db/migrations/<module>/` |
| **枚举类型创建 / 加值（ADD VALUE）** | 代码型对象（B' 拍板） | `db/src/<schema>/types/<name>.sql`（§5 模板） |
| 枚举 → CHECK/字典 转换 | 列结构 + 数据变更 | `db/migrations/`（新编号，§6 流程） |
| PostgREST RPC | `api_v1_public.*` 前缀（如 rpc_create_department） | `db/api_v1/public/rpc/<name>.sql` |
| 对外视图（PostgREST 暴露） | `api_v1_public.*`（如 v_user_list） | `db/api_v1/public/views/<name>.sql` |
| 底层函数（被 RPC 调用） | public schema 无前缀（如 current_tenant_id、has_permission） | `db/src/public/functions/<name>.sql` |
| 触发器 / 审计模板 / 其他类型（domain/复合） | public.* | `db/src/public/triggers/`、`templates/`、`types/` |
| GRANT | — | `db/api_v1/public/privileges/grant_all.sql`（集中管理） |

**关键注记**：
- 新迁移**不得引用 src 函数/视图**（dbmate 先于 apply-src，全新库上 src 对象尚不存在）；引用 bootstrap 对象（schema/角色/枚举/扩展）合法。
- **枚举不进入函数签名**（参数/返回值用 text + 函数体内部显式 cast）。
- 数据变更"幂等写法（ON CONFLICT）"是防重放手段，**不是归位判据**——src 目录永不写数据。
- COMMENT 随定义走：迁移内 `COMMENT ON FUNCTION/VIEW/TRIGGER/TYPE` 属违规残留。

---

## 2. Bootstrap 部署链（部署顺序固定）

```
deploy-db.sh:
  ① bootstrap   —— init/*.sql（扩展/schema/角色）+ src/<module>/types/*.sql（枚举）
                   psql 逐语句 autocommit（apply-src.sh --bootstrap 子集）
  ② dbmate up   —— 迁移按编号顺序执行，每个迁移文件默认包在一个事务里
  ③ apply-src.sh—— 全量幂等重放（含 §6.3 迁移扫描零容忍 + 迁移幂等重放）
  ④ dbmate status 验证
```

apply-src.sh 全量重放顺序（显式化）：
**src types → src 其余（functions/triggers/views/privileges）→ api_v1（rpc → views → 其余/privileges）→ init → migrations（最后）**

**三大陷阱**：
1. **迁移最后重放覆盖源文件**：迁移残留同名定义 → 全量重放后迁移版本胜出（后执行者胜）——源文件修改永不生效（静默回归）。推论：搬迁 = 迁移删定义 + 源文件建文件一步到位。
2. **dbmate 事务包裹**：每个迁移文件原子执行；`ALTER TYPE ADD VALUE` 后同文件使用新值在事务内必炸（`unsafe use of new value of enum type`）。B' 方案下枚举 ADD VALUE 一律在 src（psql autocommit 安全）。
3. **冷启动依赖倒置**：dbmate 先于 apply-src 时，迁移引用的 schema/角色/枚举（bootstrap 对象）不存在 → 必炸。**bootstrap 前置是必须的修复；新建库必须走 deploy-db.sh，禁止裸跑 dbmate up。**

---

## 3. 双份定义仲裁五步（人工裁决强制）

**原则：src 源文件 = 唯一权威版本。迁移中的定义一律视为"待清除的历史遗留"，不参与版本竞选。机器只负责发现与拦截，裁决必须人工执行——禁止任何自动删除/自动覆盖。**

1. **定位**：发现同名对象双轨（新双份由 §6.3 机器扫描拦截；历史双份走清单）。
2. **取证**：按回放终态提取"迁移链终态" T_m，与 src 版本 T_s 做归一化 diff。
3. **人工分情形裁决**（强制人工环节）：
   - **情形 a**：T_s 与 T_m 等价或更新 → 迁移删定义，src 定稿；
   - **情形 b**：T_m 含有 T_s 缺失的逻辑 → 人工确认是**有意修复**（合并进 src）还是**过时残留**（丢弃），再迁移删定义；
   - **情形 c**：双向分叉 → 逐段人工仲裁合并进 src，**禁止"两处都留"**。
4. **落点**：无论哪种情形 = 迁移删定义 + src 定稿**同一提交**；COMMENT 随定义迁走；GRANT 原地保留。
5. **记录**：每次仲裁在迁移文件头注释登记，并在 §6.2 仲裁记录表追加一行。

**机器防线（§6.3）**：`apply-src.sh` 内嵌扫描（每次执行前，命中即 exit 1）——`CREATE (OR REPLACE)? (FUNCTION|VIEW|MATERIALIZED VIEW|TRIGGER|TYPE|DOMAIN|POLICY|RULE)` 或 `COMMENT ON (FUNCTION|VIEW|TRIGGER|TYPE|DOMAIN)`；归位已清零 → **新迁移零容忍**（无白名单）。

---

## 4. 回放终态（最新版定义）

**对象的最新版 = 全部迁移按编号顺序重放后的数据库终态（"最后生效的定义"）。不以文件修改时间、注释自称、作者意图为准。**

提取规程（禁止肉眼串读迁移链）：
1. **首选**：从已回放到最新的库导出——`pg_get_functiondef('schema.fn'::regproc)` / `pg_get_viewdef('schema.v'::regclass)` / `obj_description`，落为 src 文件。
2. **无可用库**：PGlite 验证链按 bootstrap → src → api_v1 → init → migrations 顺序全量回放 → 从 PGlite 实例导出终态。
3. **人工质检**：导出结果与迁移史关键节点 diff 审阅；仅当"最后生效版本疑似回退/半成品"时提交用户裁决。

**迁移文件编辑边界（§7.4 安全契约）**：
- ✅ 允许：删除代码型对象定义段；修正注释/登记仲裁记录（无执行语义）。
- ❌ 禁止：修改/删除表结构、列、约束、索引段；修改/删除数据段（老环境 dbmate 不重放已应用文件 → 新老结构分叉，无兜底）。
- dbmate 无 checksum（只记版本号），编辑已应用迁移不破坏 `dbmate status`。

---

## 5. 枚举专项（B' 方案，2026-08-14 用户拍板）

- **开发期（上线前）：所有枚举一律用原生 ENUM，统一归 `db/src/public/types/`**（当前全库枚举均属 public schema）；目录即注册表，一个文件一个枚举。
- 存量 TEXT+CHECK 形态同样转原生 ENUM（P0-8 已完成：scope_type 已转）。
- 测试期若值频繁变更/需删值，再按 §6 流程转 TEXT+CHECK（优先字典表）。

**源文件模板（新建枚举必须遵守）**：
```sql
-- db/src/<schema>/types/<name>.sql
-- 语义: ...          使用位置: <表>.<列>
-- 演进史: v1 三值 → v2 加 'x'（日期，经办人）
-- 废弃值: z_deprecated_*（RENAME VALUE 标记，永不删除）

-- ① 当前态全量值（只追加、不重排、不删除）
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = '<name>' AND n.nspname = '<schema>'
    ) THEN
        CREATE TYPE <schema>.<name> AS ENUM ('a', 'b', 'c');
    END IF;
END $$;

-- ② 每个"首次发布后追加"的值一个守卫块（新库跳过、存量库追平）
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = '<name>' AND n.nspname = '<schema>' AND e.enumlabel = 'b'
    ) THEN
        ALTER TYPE <schema>.<name> ADD VALUE 'b';
    END IF;
END $$;

COMMENT ON TYPE <schema>.<name> IS '...';
```

**硬性约束**：值只增不删（无 DROP VALUE）、不重排（排序语义分叉）；守卫必须 schema 限定（typname + typnamespace 双条件）；禁止 src 文件内显式 BEGIN/COMMIT（psql autocommit 天然安全）；COMMENT 只在源文件一处；枚举不进函数签名。
**可发现性**：`information_schema` 查不到枚举值（必须走 pg_catalog）——全库枚举清单：
```sql
SELECT n.nspname, t.typname, e.enumsortorder, e.enumlabel
FROM pg_type t JOIN pg_enum e ON e.enumtypid=t.oid JOIN pg_namespace n ON n.oid=t.typnamespace
WHERE t.typtype='e' ORDER BY 1,2,3;
```

---

## 6. 幂等写法模板（源文件必须遵守）

| 对象 | 常规变更 | 结构变更（签名/列集变化） |
|---|---|---|
| 函数 | `CREATE OR REPLACE FUNCTION` | 同文件 `DROP FUNCTION IF EXISTS`（无参名形式）+ 重建；**禁止重载（一名一签名）** |
| 触发器函数 | `CREATE OR REPLACE FUNCTION` | 被触发器依赖 → 函数文件 DROP+重建、触发器文件 `DROP TRIGGER IF EXISTS`+重建，**两文件同一提交** |
| 视图 | `CREATE OR REPLACE VIEW`（仅末尾加列） | 删列/改名 → 同文件 `DROP VIEW IF EXISTS` + `CREATE VIEW`；依赖视图同批修改 |
| 触发器 | PG18 可用 `CREATE OR REPLACE TRIGGER` | 或 DROP IF EXISTS + CREATE |
| RLS 策略 | — | `DROP POLICY IF EXISTS` + `CREATE POLICY` |
| 枚举/类型 | — | §5 模板 |

**全对象禁令**：禁止 CASCADE（除迁移结构清理外）；禁止源文件内显式 BEGIN/COMMIT；禁止 GRANT 散落（归 grant_all.sql）；禁止同名重载；禁止一文件多对象。

---

## 7. 铁律检查清单（每次建/改 SQL 文件前逐条执行）

1. **判类型**：结构/数据 → 迁移新编号；代码型 → 源文件。查 §1 表。
2. **定归属**：`api_v1_public.*` → api_v1；public 无前缀 → src；枚举 → `src/<schema>/types/`。
3. **查双份**：grep 迁移目录确认无同名定义；有 → §3 仲裁（人工裁决），本提交同步删迁移定义，禁止过渡期双份。
4. **幂等写法**：§6 模板（CREATE OR REPLACE / IF NOT EXISTS / DO 块守卫 / DROP IF EXISTS + CREATE），重放两遍不炸；枚举按 §5。
5. **GRANT 归位**：权限授予写 grant_all.sql，不散落。
6. **新迁移依赖**：只允许引用更早迁移 + bootstrap 对象（schema/角色/枚举/扩展），禁止引用 src 函数/视图。
7. **验证**：PGlite 验证链通过 + 迁移扫描无违禁定义 + 空库冷启动冒烟（结构性变更时）。

---

## 8. 执行经验与新增约束（2026-08-14 全链重放实证，追加到检查清单）

**重放幂等三定律**（任何"改表结构+数据"的迁移都必须满足，否则 apply-src 二次重放必炸）：
1. **建表/建索引必须 IF NOT EXISTS**；`ALTER TABLE IF EXISTS ... RENAME TO` 只防源缺失——**RENAME 必须双守卫**（源存在 AND 目标不存在）。
2. **列改名（RENAME COLUMN）后旧列名引用失效**（011/033/038 的 path vs 044 改名 router）——引用列的 DML 需**列存在守卫**（`IF EXISTS information_schema.columns`）或动态列名。
3. **数据迁移必须包源表存在守卫**（`IF to_regclass(...)`）——重放时源表可能已被后续迁移删除（011 从 sys_api/sys_menu 迁移实证）。

**其他约束/建议**：
- **数据修正段必须考虑重放时序**：修正 UPDATE 按**列存在分叉 + 业务条件**限定（040 修正段曾误杀 055 端点行——perms 恒 NULL 但 api_code 有值）。
- **验证块环境自适应是必选模式**：引用已迁 src/已退役对象的断言包 `IF to_regprocedure(...)` / `IF to_regclass(...)` 守卫——dbmate 阶段跳过、apply-src 阶段生效。
- **退役对象源文件用 `.deprecated` 后缀**（保留登记，验证链跳过）。
- **终态提取必须模拟 DROP TABLE 的 CASCADE 连带**（055 删表连带策略/触发器 3 处漏判实证）。
- **PGlite 验证链坑**：db.exec 超长多语句静默失败→语句级分割器；`-- migrate:down` 段必须截断（dbmate 只执行 up）；`CREATE TRIGGER IF NOT EXISTS` 是非法语法（DO 块 pg_trigger 守卫）；触发器函数不能声明参数（参数走 TG_ARGV）；`ALTER COLUMN TYPE ... CASCADE` PGlite 解析失败（真实 PG 合法）；pgcrypto/pg_pwhash 等扩展需桩。
- **grant_all 排序**：`privileges/` 目录必须后于 views 执行（GRANT 引用视图）——apply-src 已按 rpc→views→其余分类排序；文件命名 zz_ 前缀兜底。

---

## 9. 关键文件与命令

- 部署链：`scripts/deploy-db.sh`（四步）→ `scripts/apply-src.sh`（`--bootstrap` 子集 / 全量含扫描）
- 铁律权威文档：`docs/开发实施方案/17-代码型对象归位-迁移仅表结构与数据-铁律-v1.1-修订稿.md`
- 枚举注册表：`db/src/public/types/`（audit_operation / iam_gender / menu_type / request_status / scope_type）
- GRANT 集中地：`db/api_v1/public/privileges/zz_grant_all.sql`
- RLS 集中清单：`db/src/public/privileges/rls_policies.sql`（DROP POLICY IF EXISTS + CREATE 幂等模板，挂最终表名）
- PGlite 验证链：`~/.hermes_tmp/pglite-verify/verify-full-replay.js`（bootstrap→迁移→src→api_v1→两遍幂等；基线：迁移 59/59 + 幂等 59/59 + src 50/50 + api_v1 74/74 + §6.3 零残留 + 终态齐备：函数 87 / 视图 31 / 触发器 24 / RLS 20 / 枚举 5）

---

## 10. 记忆压缩版（直接注入 Hermes memory 的紧凑条目）

> 零后端项目（D:\WeChat Files\OmniPG）：PG18 + Pigsty；db/ 为 SQL 仓库（migrations/src/api_v1/init）。
> **17 号铁律（2026-08-14 已执行）**：migrations 只承载表结构+数据；函数/视图/触发器/枚举等代码型对象归 src/ 或 api_v1/（api_v1_public.*→db/api_v1/public/{rpc,views}/、public 无前缀→db/src/public/{functions,triggers,views}/、枚举→db/src/public/types/、GRANT→zz_grant_all.sql、RLS→rls_policies.sql）；一文件一对象；迁移删定义与 src 建文件必须同一提交；禁新增 DROP 迁移归位。
> **部署链**：bootstrap（init+src types）→ dbmate up → apply-src 全量（src types→src→api_v1 rpc→views→privileges→init→migrations）；禁裸跑 dbmate up（冷启动依赖倒置）。
> **仲裁五步**：定位→取证（回放终态 T_m vs src T_s diff）→人工分情形（a src 等价/更新→src 定稿；b T_m 有 src 缺失→人工确认合并或丢弃；c 双向分叉→逐段合并进 src，禁两处都留）→迁移删定义+src 定稿同一提交→文件头+记录表登记。
> **回放终态**：最新版=全部迁移按编号重放后的库终态；提取用 pg_get_functiondef/pg_get_viewdef 或 PGlite 回放；迁移文件编辑边界：可删代码对象定义段/改注释，禁改表结构/数据段（新老环境分叉）。
> **枚举**：开发期一律原生 ENUM 归 src/public/types（值只增不删不重排、守卫 schema 限定、禁 src 内 BEGIN/COMMIT、枚举不进函数签名）。
> **幂等**：CREATE OR REPLACE/DROP IF EXISTS+CREATE/DO 块守卫；禁 CASCADE/禁重载/禁一文件多对象；RENAME 双守卫（源存在+目标不存在）；引用旧列名 DML 需列存在守卫；数据迁移包 to_regclass 守卫；验证块环境自适应（to_regprocedure/to_regclass）。
> **检查清单**：判类型→定归属→查双份（grep）→幂等写法→GRANT 归位→新迁移禁引用 src 函数/视图→PGlite 验证链通过+扫描零容忍。
> **PGlite 坑**：db.exec 多语句静默失败（语句级分割）；截断 migrate:down；CREATE TRIGGER IF NOT EXISTS 非法；触发器函数禁参数（TG_ARGV）；ALTER TYPE CASCADE 解析失败；扩展需桩。
> 验证基线：迁移 59/59 + 幂等 59/59 + src 50/50 + api_v1 74/74 + 扫描零残留 + 终态（函数 87/视图 31/触发器 24/RLS 20/枚举 5）。
