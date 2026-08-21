# 39 Logto 同库 Schema 方案复审（数据不重要 / 可重建版）——"只改参数"可行性判定与最小落地路径

> **状态**：✅ 核查完成（2026-08-21），对 38 号文档的深化与两处修正
> **适用前提（用户拍板）**：**存量 logto 数据不需要保留**——只解决"把 Logto 从独立库变为 `app_db.logto` schema"这一件事；方案可按"重新 seed + 落位"设计，无需承担 38 号 §3.3/§3.4 的存量迁移负担
> **审查问题**：① 方案可行性；② 有无技术难点；③ 是否"改几个参数即可达成"；④ 是否稳定无隐患
> **一句话结论**：**不可"只改参数"**。改 `DB_URL`（端口/库名 + `?options=-c search_path=...`）只是必要条件之一；"在 app_db 里直接 `db seed` 落 logto schema"存在**四道无法用参数绕过的墙**（§3，含一道 PG18 源码级死链）。但数据不重要反而让方案变简单：**在一次性 staging 库里按官方行为重新 seed → 库内重排到 logto schema → dump → 恢复进 app_db → 7 条幂等补丁 → 升级回归门**，全程无需 fork Logto、无需改镜像，可脚本化一键执行。稳定性结论：运行期稳；"无隐患"的成立条件 = 升级回归门制度化（§6）。

---

## 1. 直接回答四个问题

| 问题 | 结论 |
|---|---|
| 可行性 | ✅ 可行，走 §4 的 staging 重建流水线；**不可**走"直接改参数 + 在 app_db 里 seed"（§3 证明） |
| 技术难点 | 有 7 个，全部已定位、可脚本化解决（§5），无未知难点；最难的不是 search_path，而是 **Logto SQL 里硬编码 `public` 的 5 处引用**与**seed 需要 CREATEROLE** |
| 改几个参数即可？ | ❌ **不是**。除 `DB_URL`/端口外，还必须：① `pigsty.yml` 给 `logto` 用户补 `privileges: CREATEROLE`（官方 compose 里该用户本就是 superuser，本项目是低权限——§2）；② staging 中转 + `ALTER ... SET SCHEMA` + `pg_dump -n logto`；③ 恢复前预建 1 个包装函数 + 恢复后 6 条补丁（§4.6）；④ 升级回归门（每次 `latest` 升级 diff + 重放） |
| 稳定无隐患 | ⚠️ 有条件成立：运行期稳定可保证（补丁幂等 + 断言门）；升级期风险靠回归门压制（D4 `latest` 漂移的代价）；若"零升级期风险"是硬要求，维持独立库（官方拓扑）才是零隐患答案（§7 方案 B） |

---

## 2. 前提校准：官方拓扑与本项目拓扑的一个关键差异（第 0 道墙）

Logto 官方 docker-compose：`POSTGRES_USER: logto`——postgres 官方镜像把初始用户建成 **superuser**。而 Logto 的 seed 里有两处 `create role`（`packages/schemas/tables/_before_all.sql` 建父角色 `logto_tenant_<db>`；`packages/cli/src/commands/database/seed/tenant.ts` 建 `logto_tenant_<db>_default/_admin`），官方靠 superuser 直接通过。

本项目现状（`infra/pigsty.yml` L59-63）：`logto` 用户**无任何 privileges**（普通登录角色）；`docs/开发实施方案/06-Logto迁移-开发路线与验收清单.md` T1 也写明"专用低权限"。即：**当前拓扑下 `db seed` 的 `create role` 在官方前提下能跑、在本项目前提下跑不了**（`ERROR: must be superuser or have CREATEROLE`）。

**对策（前置动作 1，非参数但一行配置）**：`infra/pigsty.yml` → `pg_users.logto.privileges: [CREATEROLE]`。安全面评估：CREATEROLE 只是"建/管自己创建的角色"，仍远小于官方 superuser；且只有 seed/升级演练时需要（运行时不建角色）。若想更严，可在 staging 阶段临时授权、完成后 `ALTER ROLE logto NOCREATEROLE`，但每次升级演练要再开——建议常驻，并写入审计说明。

---

## 3. 为什么"改参数"不可行：fresh seed 直落 app_db 的四道墙（其中第 3 道无解）

前提：`DB_URL` 已指向 `app_db` 且 `search_path=logto,public`（role 级或 options 参数），执行 `npm run cli db seed -- --swe`。按执行顺序，seed 会依次撞墙：

| 墙 | 触发点（v1.42.0 源码） | 现象 | 参数可否绕过 |
|---|---|---|---|
| 1 | `tables/_before_all.sql`：`create role logto_tenant_app_db ...` | `ERROR: permission denied to create role`（logto 无 CREATEROLE） | 不可——需 Pigsty 配置变更（§2） |
| 2 | `tables/roles.sql` L25：`create function public.check_role_type(...)`（**显式 public 限定**） | `ERROR: permission denied for schema public`（app_db 非 logto 所有，PG15+ 非库主无 public CREATE） | 不可——除非 `GRANT CREATE ON SCHEMA public TO logto`（把 DDL 面开进业务 schema，且第 3 道墙依旧在） |
| 3 | `tables/_after_all.sql` L6：`grant select, insert, update, delete on all tables in schema public to logto_tenant_app_db;` | **两种情况都不可接受**：① logto 对业务表无任何权限 → 按 PG18 `aclchk.c` 的 `restrict_and_check_grant()`（L305-330），`avail_goptions == ACL_NO_RIGHTS` 且 `pg_aclmask(...)=ACL_NO_RIGHTS` 时走 `aclcheck_error(ACLCHECK_NO_PRIV)` → **硬 ERROR，整个 seed 事务回滚**；② 若把 logto 升成 superuser（对齐官方）→ 不报错，但**把 app_db.public 全部业务表的增删改查授权给了 `logto_tenant_app_db` 租户角色——权限反向泄漏**。`in schema public` 是显式 schema 限定，与 `search_path` 完全无关，**没有任何参数能改它的作用域** | **不可，数学上无解**——这是"直接 seed 进 app_db"方案的死刑判据 |
| 4 | seed 数据插入触发 `users_roles/applications_roles/application_access_control_user_role_relations` 的 `CHECK (public.check_role_type(role_id, '...'))`，函数体 `select type from public.roles ...` | `ERROR: relation "public.roles" does not exist`（42P01）→ 事务回滚 | 不可——`public.roles` shim 必须依赖 `logto.roles` 存在，而表在 seed 事务内才创建（鸡生蛋）；event trigger 黑科技只能解这一道、解不了第 3 道（§7 方案 C） |

**结论**：`db seed` 一旦在 app_db 内执行，无论给什么参数，**必然失败或产生权限泄漏**；因此 seed 必须在**别的库**（staging）按官方行为完成，再把"成品"搬进 app_db。这同时是"数据不重要"时的最大简化——staging 里 seed 出的是全新官方数据，天然规避 38 号文档里的存量数据/角色名迁移复杂度（角色名在 P1 一步重命名对齐即可）。

---

## 4. 推荐方案：staging 重建 + 重排 + 落位（7 步，全脚本化）

### 4.1 总览

```
[前置] pigsty: logto 用户 + CREATEROLE；建 staging 库 logto_stage (owner=logto)
  ① 官方式 seed（DSN 不带 options，public 默认行为，零改造）
  ② 库内重排：create schema logto; 表/枚举/函数 全部 SET SCHEMA logto；清点 public 零残留
  ③ pg_dump -Fd -n logto
  ④ app_db 侧：临时 GRANT CREATE ON DATABASE；【先】预建 public.check_role_type(text) 包装函数
  ⑤ pg_restore 落位（以 logto 身份，对象 owner=logto）
  ⑥ 补丁 P1/P2/P4/P5/P6/P7 + 验收门 SQL
  ⑦ compose DB_URL → 5432/app_db + options；升级回归门入 runbook；drop staging
```

### 4.2 步骤 ①：staging 官方 seed（关键：**不要**带 options 参数）

```sh
# 一次性容器（或临时改 compose 起 logto 服务）：
docker run --rm --network host \
  -e DB_URL='postgres://logto:<pass>@127.0.0.1:5432/logto_stage?sslmode=disable' \
  ghcr.io/logto-io/logto:<tag> sh -c 'npm run cli db seed -- --swe'
```

- 保持 `public` 默认行为 → `_after_all` 的 grant 落在 staging 自己的表上、`public.check_role_type`/CHECK 全部按官方语义成立 → seed 一次成功。
- 产出：71 张表 + `logto_tenant_logto_stage[_default/_admin]` 角色 + `systems.alterationState=latest`（未来 `alteration deploy` 天然是 0 pending）。
- ⚠️ `<tag>` 与生产 compose 的 `latest` 保持一致（本次应为 1.42.x）。

### 4.3 步骤 ②：库内重排（SET SCHEMA 三类对象 + 零残留校验）

```sql
create schema logto;

-- 1) 表（含分区表、序列；索引/约束/触发器/ACL 随表走）
do $$ declare r record; begin
  for r in select c.oid from pg_class c join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relkind in ('r','p','S') and c.relowner = (select oid from pg_roles where rolname='logto')
  loop
    execute 'alter table ' || r.oid::regclass || ' set schema logto';
  end loop;
end $$;

-- 2) 枚举类型（列类型引用 OID，必须同迁，否则 dump 出 public.xxx 引用）
do $$ declare r record; begin
  for r in select t.oid from pg_type t join pg_namespace n on n.oid=t.typnamespace
           where n.nspname='public' and t.typtype='e'
  loop
    execute 'alter type ' || r.oid::regtype::text || ' set schema logto';
  end loop;
end $$;

-- 3) 函数（含 set_tenant_id / set_updated_at / check_* 等）
do $$ declare r record; begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public'
  loop
    execute 'alter function ' || r.oid::regprocedure::text || ' set schema logto';
  end loop;
end $$;

-- 4) 零残留校验（public 只剩 pg_catalog 自带对象；public.check_role_type 允许遗留——它不进 dump，由 P3 在目标库预建）
select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relowner=(select oid from pg_roles where rolname='logto');
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public';
```

### 4.4 步骤 ③/④⑤：导出与落位（注意 P3 的预建时机与签名技巧）

```sh
pg_dump -Fd -j4 -n logto -f /backup/logto_schema logto_stage

# app_db 侧（管理账号）：
GRANT CONNECT, CREATE ON DATABASE app_db TO logto;   -- 恢复期临时

# ★ 必须在 pg_restore 之前预建（否则恢复建表时 CHECK 解析 public.check_role_type 失败）。
# 签名用 text 而非 logto.role_type 枚举——恢复时枚举类型尚未创建，text 参数规避时序依赖，
# CHECK 里的 'User'/'MachineToMachine' 是 unknown 字面量，隐式 cast 到 text，解析成立。
CREATE OR REPLACE FUNCTION public.check_role_type(role_id varchar(21), target_type text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  RETURN (SELECT type::text FROM logto.roles WHERE id = role_id) = target_type;
END $$;
REVOKE ALL ON FUNCTION public.check_role_type(varchar(21), text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_role_type(varchar(21), text) TO logto, logto_tenant_app_db;

pg_restore -h 127.0.0.1 -p 5432 -U logto -d app_db -Fd /backup/logto_schema   # 以 logto 身份：对象 owner=logto（P7 自动满足）

REVOKE CREATE ON DATABASE app_db FROM logto;         -- 收口
```

### 4.5 步骤 ⑥：补丁（承接 38 号 P1–P7，此处按新时序重新排序）

| 补丁 | 内容 |
|---|---|
| P3（已预建，见 4.4） | `public.check_role_type(varchar(21), text)` → 体指向 `logto.roles`，解除 T2 |
| P1 | 角色对齐：`ALTER ROLE logto_tenant_logto_stage RENAME TO logto_tenant_app_db;`（父）＋ `..._default/_admin` 同规则；`UPDATE logto.tenants SET db_user='logto_tenant_app_db_default' WHERE id='default';`（admin 同理）——不重命名则下次升级的 `grant ... to logto_tenant_app_db` 找不到角色必挂 |
| P2 | search_path：`ALTER ROLE logto IN DATABASE app_db SET search_path TO logto, public;` + 对每个租户角色同款；或 compose `DB_URL` 用 `?options=-c search_path=logto%2Cpublic`（38 号 §2.5 实测端到端可用，且自动覆盖租户重连——二选一，推荐 options） |
| P4 | `ALTER FUNCTION logto.check_application_type(...) SET search_path = logto, public;`、`logto.check_organization_role_type(...)` 同款（解除 T3/T4） |
| P5 | `GRANT USAGE ON SCHEMA logto TO logto_tenant_app_db, app_owner;`（表级 ACL 已随 dump 带过来）；app_owner 按 37 号 §4.2 步骤 3 仅授安全视图所需列；`ALTER DEFAULT PRIVILEGES FOR ROLE logto IN SCHEMA logto GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO logto_tenant_app_db;` 兜底未来新表 |
| P6 | 权限防泄漏断言：`has_table_privilege('logto_tenant_app_db','public.users','SELECT')` 必须为 f（staging 方案下天然成立——seed 的 `_after_all` 只作用于 staging；此处仅断言兜底） |
| P7 | 属主校验：logto schema 全部对象 owner=logto（以 logto 身份恢复自动满足；sharedPool 以 owner 读 `tenants` 才能绕开 RLS） |

### 4.6 步骤 ⑦：运行时与升级门

- `gateway/docker-compose.yml` L143：`DB_URL → postgres://logto:***@host.docker.internal:5432/app_db?sslmode=disable&options=-c%20search_path%3Dlogto%2Cpublic`（5433→5432 一并收敛）。
- 升级 runbook（每次 `latest` 变更强制执行）：`npm run cli db alteration deploy latest`（entrypoint 不自动跑，38 号 §2.1.3）→ diff 新版本 `tables/*.sql`、`alterations/*` 中新增 `public.`/`search_path` 引用 → 重放 P3/P4/P5 补丁 → 跑 38 号 §3.7 验收门 SQL + Console 登录 + 角色分配/应用/组织角色 e2e。

---

## 5. 技术难点清单（全部已定位，无未知项）

| # | 难点 | 严重度 | 解法 | 是否可脚本化 |
|---|---|---|---|---|
| D1 | logto 用户无 CREATEROLE，seed 的 `create role` 必挂 | 前置阻断 | Pigsty `privileges: [CREATEROLE]`（仍小于官方 superuser） | 配置一行 |
| D2 | fresh seed 直落 app_db 四道墙（§3） | 方案级阻断 | seed 移到 staging，成品搬进 app_db | 全流程脚本 |
| D3 | `SET SCHEMA` 对象全覆盖（表/枚举/函数，遗漏= dump 引用 public 失败） | 中 | §4.3 三类循环 + 零残留校验；触发器/索引/约束/ACL 随表走 | ✅ |
| D4 | `public.check_role_type` 不在 `-n logto` dump 内，CHECK 恢复时缺函数 | 中 | 恢复**前**预建 P3；参数用 text 规避枚举时序 | ✅ |
| D5 | 租户角色名与库名绑定（staging 名 ≠ app_db） | 中 | P1 重命名 + `tenants.db_user` 同步（RLS/触发器按字符串比对） | ✅ |
| D6 | search_path 只覆盖主连接不够，租户重连漏掉 | 中 | DB_URL `options` 自动随租户 DSN 传播（38 号 §2.5 实测），或 role 级逐租户角色 ALTER | ✅ |
| D7 | `latest` 升级漂移：未来版本新增硬编码 `public` 引用 | 持续性 | 升级回归门（diff + 补丁重放 + 断言）；master 已见 7 个新表文件为活样本 | 制度 + 脚本 |

---

## 6. 稳定性评估（"稳定无隐患"的成立条件）

| 维度 | 评估 | 依据 |
|---|---|---|
| 运行期稳定 | **高** | 连接三层（主池/租户池/CLI）行为已源码级验证；`--swe` 幂等判断尊重 search_path；补丁全部幂等（`CREATE OR REPLACE`/断言式）；RLS、触发器、ACL 随 dump 落位 |
| 升级期稳定 | **中 → 高（取决于回归门是否制度化）** | 风险源只有一个：新版本 SQL 新增 `public.`/`search_path` 硬编码。历史 54 处 `public.`、4 处 `set search_path=public` 均在"已应用批次"中，未来批次必须 diff。回归门跑一次 <10 分钟 |
| 隔离与安全 | **高（staging 方案天然规避 T1 泄漏）** | app_db 侧 logto **不需要** CREATE on public（P3 由管理账号预建）；租户角色对业务 public 表零权限（P6 断言） |
| 故障域 | 与 37 号 §7 一致 | 同库后 Logto 长事务/锁与业务共享实例——低峰窗口 + 演练（沿用 37 号风险册） |

**结论**：运行期可做到"无隐患"；整体"无隐患"成立的条件是 **D7 回归门制度化**（每次升级：alteration deploy → 新 SQL diff → 补丁重放 → 断言门全绿，任一失败禁止推进）。这是 D4 选择 `latest` 的固有代价，本方案把它显式化。若不愿承担任何升级期检查成本，见 §7 方案 B。

---

## 7. 三方案对比与建议

| 方案 | 说明 | 稳定性 | 成本 | 判定 |
|---|---|---|---|---|
| A. staging 重建 + 落位（§4，推荐） | 数据不重要 → 全新 seed 到 staging → 重排 → 恢复进 app_db.logto | 运行期高、升级期靠回归门 | 一次性脚本 ~10 条命令 + 回归门 runbook | ✅ 符合 D1 决策，本评审推荐 |
| B. 维持独立 logto 库 | 官方拓扑、零补丁、零回归门 | **全程零隐患** | 放弃"单库单 schema"目标（37 号降级路径） | 若"无隐患"权重最高，选 B |
| C. event trigger 自动建 `public.roles` shim 直 seed | 想省 staging 的黑科技 | 低（DDL 钩子副作用） | 开发+验证成本 | ❌ 否决：只能解 §3 第 4 道墙，第 3 道墙（grant 业务表 ERROR/泄漏）无解 |

**建议**：按方案 A 落地；把"升级回归门"作为与 067/068 迁移同级的交付物。若评审后认为升级期检查成本不可接受，立即退回方案 B（独立库），不要进入"参数级半成品"状态。

---

## 8. 需要拍板的点（在 38 号 D9–D12 基础上）

| # | 决策点 | 建议 |
|---|---|---|
| D13 | `logto` 用户授权口径 | Pigsty `privileges: [CREATEROLE]` 常驻（官方为 superuser，本项目收敛一档）；或 staging 期临时授权 + 升级演练前重开 |
| D14 | search_path 机制 | DB_URL `options` 单点（推荐，38 号 §2.5 实测）；role 级 `IN DATABASE` 双保险可选（勿混设冲突值） |
| D15 | staging 库生命周期 | 用后即弃（drop）；角色保留并已由 P1 重命名 |
| D16 | 升级回归门载体 | 独立 runbook 章节 + CI 步骤（diff 脚本 + 补丁重放 + 断言门），禁止手工跳步 |

---

## 9. 对 38 号文档的两处修正（以本文为准）

1. **fresh seed 死链从 2 道墙补全为 4 道**：38 号 §1/§3.6 只列了"public CREATE 权限（T5）"与"CHECK 42P01（T2）"，实测遗漏了 ① `_before_all` 的 `create role` 需要 CREATEROLE（§2，本项目 Pigsty 低权限与官方 superuser 前提的偏差）；② `_after_all` 的 `grant ... in schema public` 对业务表**硬 ERROR**（PG18 `aclchk.c` `restrict_and_check_grant` L305-330）或 superuser 下**权限反向泄漏**——这道墙数学上无解，是"禁止在 app_db 直接 seed"的最强依据。
2. **P3 补丁的时序与签名**：38 号写"恢复后执行补丁层 P1–P7"，其中 P3 必须**提前到 pg_restore 之前**预建（否则恢复建表时 CHECK 解析 `public.check_role_type` 失败）；且预建函数签名用 `(varchar(21), text)` 而非 `logto.role_type`（恢复时枚举类型尚未创建，text 规避时序依赖，CHECK 的 `'User'` unknown 字面量隐式 cast 到 text，解析成立）。

---

## 10. 证据索引

- Logto v1.42.0：`packages/schemas/tables/{_before_all,_after_all,roles,users_roles,applications_roles,application_access_control_user_role_relations,applications,organization_roles}.sql`、`packages/cli/src/commands/database/seed/{tables,tenant}.ts`、`packages/toolkit/core-kit/src/models/tenant.ts`、`packages/cli/src/queries/{logto-config,system}.ts`、`Dockerfile`、官方 `docker-compose.yml`（`POSTGRES_USER: logto` = superuser）
- PostgreSQL 18：`src/backend/catalog/aclchk.c` `ExecGrant_Relation` L1794+、`restrict_and_check_grant` L241-330（无 grant option 且无对象权限 → `aclcheck_error` 硬 ERROR；有权限 → WARNING 跳过）；`src/backend/utils/init/postinit.c` L1251/1377（role 级 GUC 只取会话用户自身设置）
- 本仓库：`infra/pigsty.yml` L59-63（logto 无 privileges）、`infra/pigsty.yml.tpl` L53（对照 app_owner 的 CREATEDB 写法）、`gateway/docker-compose.yml` L135/L143、`docs/开发实施方案/06-Logto迁移-开发路线与验收清单.md` T1（"专用低权限"）
- 38 号文档 §2.5（slonik/pg options 透传实验）、§3.7（验收门 SQL，本方案直接复用）
