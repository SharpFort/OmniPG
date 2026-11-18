# 40 反向方案评审：Logto 留 public、业务迁出（对 37 号 D1 的修正建议）

> **2026-08-21 定名修订（执行落地）**：D17 最终决策——业务 schema 定名 **platform**（弃用建议名 omnipg，避免与项目名 OmniPG 混淆、体现平台业务属性）；API 暴露层 api_v1_public → api_v1_platform；权限码命名空间 public: → platform:；URL /api/v1/public/* → /api/v1/platform/*；扩展宿主 ext 已建（pgcrypto/pgtap 迁出 public）。本文件其余 omnipg 字样为方案评审期建议名，以本条修订为准。
> [*][*]状态[*][*]：✅ 核查完成（2026-08-21），回答三个问题：① 7 个难点是否"一个脚本全解决"；② 关键矛盾是否"public 被业务占用"；③ 业务迁出、public 让给 Logto 是否可行
> **一句话结论**：**对，关键矛盾就是 public 的归属**——Logto 在 SQL 里硬编码 `public`（5 处，且随版本升级漂移），业务侧则是自己仓库里的白盒代码。**让硬编码方留在原地（public 给 Logto）、让可控方迁走（业务 → `omnipg`/admin schema），是最优解**：Logto 侧完全回到官方拓扑（38/39 号的 7 个难点和补丁层 P1–P7 全部消失），全部成本转移为"业务侧一次性机械迁移"——自己的代码、可测试、可回滚。**可行，且比 38/39 两个方案都更稳。**

---

## 1. 三个问题的直接回答

| 问题 | 回答 |
|---|---|
| ① 7 个技术难点，"一个脚本文件"就能全部无隐患解决，对吧？ | **不完全对**。38/39 的 7 难点针对"Logto 迁入 logto schema"方向：脚本能把执行复杂度收敛为一条流水线，但"无隐患"靠的是**升级回归门制度化**（每次 `latest` 升级 diff + 补丁重放），不是脚本本身。**但按你本轮的思路反向设计后，Logto 侧连这 7 个难点都没有了**（§3），只剩业务侧一次性迁移脚本——这才是真正接近"一个脚本解决"的形态 |
| ② "Logto 在独立库时数据在 public，现在要进业务库的 logto schema，而业务库 public 被占用"——这才是问题关键，对吧？ | **对，一针见血**。Logto v1.42.0 有 5 处硬编码 `public`（38 号 §2.3：`grant ... in schema public`、`public.check_role_type`/`public.roles`、两个函数体 `set search_path = public`）+ 升级中历史上 54 处 `public.` 引用、4 处 `set search_path=public`（master 还有 7 个新表文件在漂移）。把 Logto 赶出 public = 跟一个会随版本漂移的黑盒对抗；**把业务请出 public = 一次白盒重构**。成本应落在可控侧 |
| ③ 清空业务 public → admin schema，public 让给 Logto，能否解决？ | ✅ **能，而且是最优解**。Logto 侧 = 官方 compose 拓扑（仅两处配置差异，§3）；seed 可直接在 app_db 里跑（不需要 staging 中转、不需要 38/39 的 P1–P7 补丁、不需要 DB_URL options 魔法、不需要升级回归门）；业务侧迁移是一次性机械重构（§4，清单已量化） |

---

## 2. 核心洞察：谁迁走，谁背债

| | Logto 迁出 public（38/39 方向） | 业务迁出 public（本方案，建议） |
|---|---|---|
| 迁移动机方 | 黑盒（官方镜像，SQL 硬编码 `public`） | 白盒（本仓库 db/ 全部 SQL） |
| 一次性成本 | staging 流水线 + 7 条补丁 | 业务对象 `SET SCHEMA` + 引用重写（已量化：约 1000+ 处，§4.1） |
| 持续性成本 | **每次 Logto 升级：diff + 补丁重放 + 断言门**（D4 `latest` 漂移的代价） | **零**（Logto 按官方 runbook 升级：`db alteration deploy latest` + 重启） |
| 隐患面 | 升级期持续暴露 | 一次性迁移窗口，之后 Logto 侧 = 官方支持拓扑 |
| 37 号 D1 的关系 | D1 拍板"业务留 public、Logto 迁 schema" | **建议修订 D1：业务迁 `omnipg`，Logto 留 public** |

37 号当时选"业务不动"是因为估算"业务侧 111 个 `public.` 限定 SQL / 59 处 `SET search_path` 改动大"；38/39 的核查证明这个节省买来的是**黑盒补丁 + 永续升级回归门**。权衡应反过来。

---

## 3. 新方案下 Logto 侧 = 官方拓扑（四道墙逐一消失）

对照 39 号 §3 的"四道墙"，业务迁出后：

| 原死墙 | 新方案下 | 说明 |
|---|---|---|
| ① seed 的 `create role` 需要 CREATEROLE | 仍需一项配置 | `pigsty.yml` → `pg_users.logto.privileges: [CREATEROLE]`（官方 compose 的 `POSTGRES_USER=logto` 是 superuser，本项仍比官方收敛） |
| ② `create function public.check_role_type` 需要 public CREATE | **消失** | 把 public schema owner 转给 logto（`ALTER SCHEMA public OWNER TO logto`），Logto 在自己的 schema 里建函数 = 官方行为 |
| ③ `_after_all` 的 `grant ... in schema public` 撞业务表（ERROR/泄漏） | **消失** | public 已清空给 Logto，grant 只作用于 Logto 自己的 71 张表 |
| ④ CHECK 引用 `public.roles` 不存在（42P01） | **消失** | Logto 表就在 public，`public.roles` 天然存在 |

**Logto 侧最终形态**：
- `gateway/docker-compose.yml`：`DB_URL = postgres://logto:***@host.docker.internal:5432/app_db?sslmode=disable`（只改库名和端口 5433→5432，**无需 options 参数**）；
- 容器 entrypoint 保持 `npm run cli db seed -- --swe && npm start`——首次启动直接在 app_db.public **原生 seed 成功**（数据不重要时连迁移都不用）；
- 租户角色自动命名为 `logto_tenant_app_db[_default/_admin]`——**无 38/39 的角色名对齐问题（P1 消失）**；
- 升级 = 官方 runbook：`npm run cli db alteration deploy latest` → 重启（无补丁重放、无 diff 门）；
- **38/39 的 P1–P7 全部作废**（仅保留业务侧 P5 等价物：app_owner 不再碰 public、无需任何跨 schema 授权）。

---

## 4. 业务侧一次性迁移清单（成本所在，全部可脚本化）

### 4.1 工作量实测（本仓库现状）

| 位置 | `public.` 引用数 | 处理方式 |
|---|---|---|
| `db/api_v1/public/`（29 视图 + 44 RPC + 权限） | 458 | 机械重写 `public.` → `omnipg.` + `SET search_path` 收敛 |
| `db/migrations/public/064/065/066` | 342 | squash baseline 直接改写（36 号已授权"基线可重写"） |
| `db/src/public/`（函数/RLS/触发器） | 147 | 同上 + `SET search_path` 改写 |
| `db/src/public/` 的 `SET search_path = public...` | 118（59+36+23） | 统一改 `SET search_path = omnipg, ext, pg_temp`（§4.3） |
| `db/tests/public/` | 22 | 同步改写 |
| `db/init/02-schemas.sql` | 9 | 新增 `omnipg`/ext schema 与 usage 授权 |
| `scripts/` + `gateway/`（reconcile SQL、conf、compose） | 53 | 同步改写 |
| `db/schema.sql`（dbmate 快照） | 1240 | **不手改**：迁移完成后 dbmate `--dump-schema` 重新生成 |
| `backups/`（历史 iam_menu 快照） | 若干 | 历史存档，不参与部署，不动 |

### 4.2 对象搬迁（数据保留场景；若业务数据也可重建则直接改 baseline 重建）

```sql
create schema omnipg authorization app_owner;

-- 1) 表/序列（索引、约束、触发器、RLS、ACL 随表走）
do $$ declare r record; begin
  for r in
    select c.oid from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p','S')
      and c.relowner=(select oid from pg_roles where rolname='app_owner')
  loop
    execute 'alter table ' || r.oid::regclass || ' set schema omnipg';
  end loop;
end $$;

-- 2) 业务枚举/复合类型
do $$ declare r record; begin
  for r in
    select t.oid from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typtype in ('e','c')
      and t.typowner=(select oid from pg_roles where rolname='app_owner')
  loop
    execute 'alter type ' || r.oid::regtype::text || ' set schema omnipg';
  end loop;
end $$;

-- 3) 业务函数
do $$ declare r record; begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proowner=(select oid from pg_roles where rolname='app_owner')
  loop
    execute 'alter function ' || r.oid::regprocedure::text || ' set schema omnipg';
  end loop;
end $$;

-- 4) 扩展迁出 public（pgcrypto/pgtap 等默认落 public 的扩展；以 \dx + \dn 实查为准）
create schema ext;
alter extension pgcrypto set schema ext;   -- 其余占用 public 的可迁移扩展同款
```

随后：改写仓库 SQL（§4.1）→ `apply-src` 幂等重放（视图/函数在 omnipg/api_v1_public 重建）→ 更新 PostgREST 配置（§4.3）→ 校验 public 零业务残留 → e2e 全绿。

### 4.3 search_path 收敛规则（防"业务误命中 Logto 表"——本方案最大的安全要点）

public 现在装着 Logto 的 `users/tenants/roles/organizations/users_roles...`，与业务镜像表**同名**。业务侧任何 unqualified 引用一旦落到 public 就会静默读 Logto 数据。规则：

- 业务角色/函数 search_path **不含 public**：`omnipg, ext, pg_temp`；
- PostgREST：`PGRST_DB_EXTRA_SEARCH_PATH = "api_v1_public, omnipg, ext"`（当前是 `api_v1_public,public`，必改）；
- 118 处 `SET search_path = public, pg_temp`（DEFINER 函数）→ 全部改写为 `omnipg, ext, pg_temp`；
- `authenticator`/pgBouncer 侧默认 search_path 同步检查（PostgREST 每请求 SET，改 extra 即生效）；
- 扩展函数（`gen_random_uuid` 等）经 `ext` 解析；不再依赖 public。

### 4.4 实施顺序（铁律：先迁业务，后 seed Logto）

```
冻结窗口 → 建 omnipg/ext → 搬迁对象+重写 SQL → apply-src 重放 → PostgREST 配置更新
→ 校验 public 零业务残留（pg_class/pg_proc/pg_type 按 owner=app_owner 清点 + e2e 全绿）
→ ALTER SCHEMA public OWNER TO logto + pigsty logto 加 CREATEROLE
→ compose DB_URL 改 5432/app_db → 容器启动自动 seed（--swe）→ Logto 原生落 public
→ 验收：Console 登录 / OIDC discovery / seed 幂等 / 业务 API 回归 / 官方升级演练
```

回滚：`SET SCHEMA` 可反向；Logto seed 之后若要回滚业务，须先清掉 Logto 的 public 对象（数据不重要 → 直接 drop + 重 seed）。

---

## 5. 风险与残余项（一次性，无升级期债务）

| # | 风险 | 缓解 |
|---|---|---|
| R1 | 业务 unqualified 引用误命中 public 的 Logto 表（同名 users/tenants） | §4.3 search_path 全面收敛 + 迁移后 `\dn`/`search_path` 审计 + 对拍期视图只读 |
| R2 | 扩展遗留 public（pgcrypto/pgtap 等），业务解析不到或 Logto `_after_all` 波及 | `ALTER EXTENSION ... SET SCHEMA ext`；`_after_all` 只 grant 表，扩展函数不受影响 |
| R3 | 迁移窗口业务中断 | SET SCHEMA 逐表快、视图/函数重建走 `apply-src` 幂等重放；测试环境全量演练后再上生产 |
| R4 | 镜像表 6 张与 Logto 同名 → 顺序错误即撞车 | 铁律"先迁后 seed"（§4.4）；seed 前校验 public 中无 app_owner 对象 |
| R5 | 备份/监控脚本引用 `public.` | scripts/gateway 53 处同步改写；`db/schema.sql` 快照重生成；`backups/` 历史存档不动 |
| R6 | 同库故障域（Logto 锁/长事务影响业务） | 沿用 37 号风险册：低峰窗口、直连 5432 与 pgbouncer 分离保持 |

---

## 6. 与 37/38/39 号文档的关系

- **37 号 D1 建议修订**："业务表留在 public，仅新增 logto schema" → **"业务表迁 `omnipg`（或 admin），public 整体让给 Logto"**。D2–D4 不变。
- **38 号**：S1–S5 事实核查仍然有效（硬编码 5 处、租户两层连接、71 表清单、options 透传实验），但落地建议降级为**备选方案 B**。
- **39 号**：四道墙、CREATEROLE 前提仍然有效，但其 staging 流水线与 P1–P7 补丁层**不再需要**；仅保留"CREATEROLE"一项作为本方案配置。
- **升级回归门**：从"diff Logto SQL + 补丁重放"简化为官方 runbook（`alteration deploy latest` + seed 幂等 + e2e）。

---

## 7. 需要拍板的点

| # | 决策点 | 建议 |
|---|---|---|
| D1（修订） | 谁迁出 public | **业务迁 `omnipg`，Logto 留 public**（本文件结论） |
| D17 | 业务 schema 命名 | 建议 `omnipg`（37 号规格书原名，语义清晰）；用户提议的 `admin` 也可，但与"管理员角色"语义易混，建议避免 |
| D18 | public owner 转移 | `ALTER SCHEMA public OWNER TO logto`（管理账号执行；业务侧对 public 零权限） |
| D19 | 扩展隔离 | 建 `ext` schema，pgcrypto/pgtap 等迁出 public（以 `\dx` 实查清单为准） |
| D20 | 业务数据是否也允许重建 | 若允许（与 Logto 同等口径），可直接重写 064/065/066 baseline 全新建库，省去 SET SCHEMA 步骤；否则走 §4.2 搬迁 |

---

## 8. 证据索引

- Logto v1.42.0：`packages/schemas/tables/{_before_all,_after_all,roles,applications,organization_roles,users_roles,applications_roles,application_access_control_user_role_relations}.sql`、`packages/cli/src/commands/database/seed/tenant.ts`、官方 `docker-compose.yml`（`POSTGRES_USER: logto` = superuser）
- 本仓库实测：`db/` 内 `public.` 引用分布（api_v1 458 / migrations 342 / src 147 / tests 22 / init 9）、`SET search_path` 118 处、`db/schema.sql` 为 dbmate 快照（1240 处，重生成）、scripts+gateway 53 处、`infra/pigsty.yml` L59-63（logto 无 privileges）、`gateway/docker-compose.yml` L83/L135/L143
- 37 号 §1 D1、38 号 §2.3/§3.7、39 号 §3/§5（本文件对三者的承接与修订）
