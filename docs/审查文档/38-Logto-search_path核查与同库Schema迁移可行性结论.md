# 38 Logto search_path 源码级核查与"同库多 Schema 迁移"可行性结论（37 号文档 Spike 立项评审）

> **状态**：✅ 核查完成（2026-08-21），作为 37 号文档 §4.1 阶段 0（S1–S5）的结论文档
> **审查对象**：`docs/审查文档/37-Logto与OmniPG融合-同PG实例多Schema方案.md` 的 §4.1 Spike 项 + 另一 AI 出具的《search_path 核查报告》
> **核查方法**：
> 1. Logto 官方仓库 **v1.42.0 标签源码**（当前 `latest` 镜像对应的最新 release tag）逐文件核查：`packages/core`、`packages/cli`、`packages/schemas`（tables + alterations）、`packages/shared`、`packages/toolkit/core-kit`（sparse clone，比对 master 差异）
> 2. GitHub Issue [#8607](https://github.com/logto-io/logto/issues/8607) 官方成员两次回复原文、PR [#6101](https://github.com/logto-io/logto/pull/6101) 完整 diff
> 3. 本仓库本地配置核对（`gateway/docker-compose.yml` / `infra/pigsty.yml` / `infra/pgbouncer.ini` / `infra/postgresql.conf`）
> 4. 本地 node 实验（`@silverhand/slonik@31.0.0-beta.3` DSN 解析回环、`pg@8.23` startup 报文透传）
> 5. PostgreSQL 18 源码 `postinit.c`（role 级 GUC 生效范围）与 ALTER ROLE 官方文档
>
> **一句话结论**：**"把 logto 库的数据迁进 `app_db.logto` schema"本身可以成功；但"仅靠 role 级 `search_path` 让 Logto 直接可用"不成立**——Logto v1.42.0 的 SQL 并非"全部无 schema 前缀"，存在 5 处硬编码 `public` 依赖，且运行时是**两层连接**（`DB_URL` 主角色 + `tenants.db_user` 租户角色），另一 AI 的方案漏掉了租户角色与迁移后角色名对齐，照搬会失败。必须配套一个**持久的 schema 补丁层（P1–P7）**并在每次升级后重放验证。

---

## 1. 对"0 Spike 立项"核心问题的直接回答

| 问题 | 结论 |
|---|---|
| 直接把 logto 库迁入 `app_db.logto` schema，**数据搬迁**能成功吗？ | ✅ 能。但**不要**用"文本 sed 改 dump"（会损坏数据）或"先恢复到 app_db.public 再搬"（与业务镜像表 `public.users/tenants/role` 同名冲突，必然失败）。推荐 §3.4 的 **staging 中转库 + `ALTER ... SET SCHEMA` + 二次 dump（`-n logto`）** 方式。 |
| 仅靠 **role 级 `search_path`**（另一 AI 的路径 1）能直接跑起来吗？ | ❌ 不能。① 5 处硬编码 `public`（§2.3）；② 运行时以 `tenants.db_user` 租户角色重连（§2.1.2），role 级设置必须**逐个租户角色**设置且只能 post-seed 执行；③ 存量库的租户角色名带旧库名 `logto_tenant_logto_*`，与未来 alteration 生成的 `logto_tenant_app_db` 不一致（§3.3），不重命名则**下次升级必挂**。 |
| 全新环境直接在 app_db 里 `db seed` 落 logto schema（另一 AI 的 checklist 第 1 条）能成功吗？ | ❌ 不能一步到位。完整死链共**四道墙**（39 号文档 §3 有逐条源码依据）：① `_before_all` 的 `create role` 需要 CREATEROLE（本项目 Pigsty `logto` 为低权限，官方 compose 的 `POSTGRES_USER=logto` 是 superuser）；② `create function public.check_role_type` 需要 public CREATE（PG15+ 非库主无）；③ `_after_all` 的 `grant ... in schema public` 对业务表**硬 ERROR**（PG18 aclchk.c）或 superuser 下**权限反向泄漏**——数学上无解；④ seed 数据插入触发 CHECK → `public.roles` 不存在 → 42P01 → 事务回滚。新环境必须走 staging 流水线（§3.6）。 |
| 加上补丁层后，方案整体可行吗？ | ✅ 可行。补丁层 = §3.5 P1–P7，并纳入 37 号文档的"升级回归门"强制重放（与 D4 `latest` 漂移缓解正好闭环）。 |

---

## 2. S1/S2 源码级事实核查（37 号文档 §4.1 的答案）

### 2.1 Logto 的连接模型是"两层"，这是所有结论的根

#### 2.1.1 主连接（sharedPool）

`packages/core/src/env-set/create-pool.ts`（v1.42.0）：

```ts
// createPoolByEnv(databaseDsn, ...)
const poolOptions = {
  interceptors: createInterceptorsPreset(),
  maximumPoolSize: poolSize,
  connectionTimeout,
  ...conditional(statementTimeout !== undefined && { statementTimeout }),
};
return createPoolWithRetry(async () => createPool(databaseDsn, poolOptions));
```

**核查结论**：JS/TS 层对 `databaseDsn` 零加工，无 `SET search_path`、无 `set_config`。对 `packages/core/src`（888 个文件）、`packages/cli/src`、`packages/shared/src`、`packages/toolkit/core-kit/src` 全树 grep `search_path|SET ROLE|set_config` **0 命中**（v1.42.0）。

#### 2.1.2 租户重连（核心盲点，另一 AI 完全遗漏）

`packages/core/src/tenants/utils.ts` `getTenantDatabaseDsn()`：

```ts
// 从 tenants 表读 db_user / db_user_password，用 DB_URL 的其余参数重建 DSN
const { rows } = await pool.query(sql`
  select db_user, db_user_password from tenants where id = ${tenantId}
`);
return stringifyDsn({ ...parseDsn(dbUrl), username: dbUser, password: dbUserPassword });
```

而 seed 时（`packages/cli/src/commands/database/seed/tenant.ts` + `packages/toolkit/core-kit/src/models/tenant.ts`）：

```ts
const parentRole = `logto_tenant_${databaseName}`;
const role = `logto_tenant_${databaseName}_${tenantId}`;   // logto_tenant_logto_default / _admin
```

**即：运行时实际读写数据的连接身份不是 `DB_URL` 里的 `logto` 用户，而是 `tenants.db_user`（如 `logto_tenant_logto_default`）**。官方成员在 Issue [#8607](https://github.com/logto-io/logto/issues/8607#issuecomment-4202354551) 的第二次回复也明确写了这一点（"runtime tenant DB user … reconnects as the tenant-specific DB user, for example `logto_tenant_<database>_default`"）。

**推论**：
- `ALTER ROLE logto SET search_path` **只覆盖主连接，不覆盖租户连接**；
- 租户角色由 seed 动态创建 → role 级设置只能 post-seed 执行（不能预建，`create role` 无 IF NOT EXISTS）；
- PostgreSQL 的 role 级 GUC **不随成员关系继承**：`postinit.c` 中 `process_settings(MyDatabaseId, GetSessionUserId())` 只取"会话用户自身"的设置（PG18 源码 1251/1377 行），所以给父角色 `logto_tenant_<db>` 设置 search_path 对租户角色**无效**，必须逐个 `ALTER ROLE`。

#### 2.1.3 seed 幂等与 alteration 追踪

- `db seed -- --swe` 的跳过判断：`packages/cli/src/queries/logto-config.ts` 里 `select to_regclass('logto_configs')`——**无 schema 前缀，尊重 search_path**。所以在 role/DSN 把 search_path 指向 `logto` 后，`--swe` 幂等语义保持正确（这是好消息）。
- 升级追踪**不在**独立 migrator 表，而在 `systems` 表的一行数据：`packages/cli/src/queries/system.ts`（key=`alterationState`，value 含 timestamp）。**这是后文反驳"路径 3 破坏版本追踪表"的依据**。
- ⚠️ **发现一个 37 号文档未列出的缺口**：官方镜像 `Dockerfile` 的 `ENTRYPOINT ["npm","run"] CMD ["start"]`，官方 compose 入口是 `sh -c "npm run cli db seed -- --swe && npm start"`——**均不执行 `db alteration deploy latest`**。升级时必须在容器内显式执行 `npm run cli db alteration deploy latest`（CLI 会经 `dotenv` 自动读 `DB_URL`，无需 `--db-url`）。本仓库 `gateway/docker-compose.yml` L135 的 entrypoint 同样只有 seed+start。**阶段 1 的"升级回归门"必须把这一步补进去**，否则 D4 的 `latest` 漂移会在"迁移没跑"上直接翻车。

### 2.2 S1 结论：Logto 是否显式管理 search_path

**分两层回答，两层答案相反**：

| 层 | 是否显式 SET | 证据 |
|---|---|---|
| JS/TS 运行时（pool/驱动） | **否** | `create-pool.ts` 全树 grep 0 命中（§2.1.1） |
| SQL DDL（tables/*.sql + alterations） | **是，且硬编码 `public`** | 见 §2.3 清单；PR #6101 正是为此加的 |

**对 PR #6101 的正确解读**（37 号文档把它当作"Logto 有显式 search_path 改动"的佐证，方向对但需修正）：该 PR 的真实内容是给两个校验函数加 `set search_path = public`：

```sql
-- applications.sql / organization_roles.sql
end; $$ language plpgsql set search_path = public;
```

其背景注释原话："In Logto Cloud, we have multiple schemas and the default search behavior will be problematic."——**这是为 Logto Cloud 多 schema 环境做的确定性收敛，不是"支持自定义 schema"的开关**。在我们的"表放 `logto` schema"场景下，这两行恰好变成障碍（§2.3 T3/T4）。

### 2.3 5 处硬编码 `public` 依赖（S1 的完整答案，另一 AI 说"SQL 均未显式限定 Schema"是错的）

以下均出自 v1.42.0 `packages/schemas/tables/`，master 分支完全一致：

| # | 位置 | 内容 | 放到 logto schema 后的后果 |
|---|---|---|---|
| T1 | `_after_all.sql` L6 | `grant select, insert, update, delete on all tables in schema public to logto_tenant_${database};` | 租户角色拿不到 logto schema 任何表的 DML → 运行时 42501 permission denied。**若在 app_db 直接 fresh seed，这条还会把租户角色的 DML 授给业务 public 表——权限反向泄漏，必须补 revoke** |
| T2 | `roles.sql` L25/L27 | `create function public.check_role_type(...)`，函数体 `select type from public.roles where id = role_id` | `users_roles` / `applications_roles` / `application_access_control_user_role_relations` 三张表的 CHECK 全部引用 `public.check_role_type(...)`（L15/L15/L13）。`public.roles` 不存在 → 任何角色分配 INSERT 42P01 → **seed 的数据插入阶段即事务回滚** |
| T3 | `applications.sql` L49 | `check_application_type(...) ... set search_path = public` | 函数体 `select type from applications` 恒解析到 public → 应用类型校验 42P01 |
| T4 | `organization_roles.sql` L29 | `check_organization_role_type(...) ... set search_path = public` | 组织角色校验 42P01 |
| T5 | 隐式 | `create function public.check_role_type` 是**显式 public 限定**的 DDL | 在合并后的 app_db，`logto` 不再是库主，PG15+ 对 public schema 无 CREATE → **seed 直接 permission denied**（这是"fresh seed 直建"路径的第一道墙；存量 restore 路径不受此条影响） |

另注意 `packages/schemas/alterations/` 中还有 54 处 `public.` 引用与 4 处 `set search_path = public`（如 `1.19.0-multiple-app-secrets`、`1.22.0-add-saml-application-type`）——历史批次对"存量已打满 alteration"的库不再执行，但**未来版本的 alteration 可能再次引入**，这正是升级回归门必须逐版本 grep 新 SQL 的原因。

### 2.4 S2 结论：seed / alteration 与运行时是否同配置

- **同一 `DB_URL` 环境变量贯穿 CLI（seed / alteration，`packages/cli/src/index.ts` 经 dotenv 读入）与 core 运行时** → 是，同配置。
- 但 alteration **不在容器启动路径上**（§2.1.3 缺口），需 runbook 显式执行。
- `db seed -- --swe` 幂等判断无 schema 前缀 → search_path 指向 logto 后语义正确。

### 2.5 S4 结论：DB_URL `options` 参数（另一 AI 的路径 2）**实测可行，其"转义大坑"担忧不成立**

本地实验记录（2026-08-21）：

1. `@silverhand/slonik@31.0.0-beta.3`（Logto v1.42 实际栈，Issue 8607 堆栈中为 beta.2）：
   - `parseDsn('postgres://logto:p@127.0.0.1:5433/app_db?sslmode=disable&options=-c%20search_path%3Dlogto%2Cpublic')` → `options: "-c search_path=logto,public"` ✅
   - `stringifyDsn` 回环无损，且 `stringifyDsn({...options, username:'logto_tenant_app_db_default', password:'x'})` **自动把 options 带进租户 DSN**（与 §2.1.2 源码 `{...options, username, password}` 互相印证）✅
2. `pg@8.23.0`：`pg-connection-string` `parse()` 正确解码 `options`；`pg/lib/client.js` L567-568 将 `options` 写入 startup 报文 ✅
3. `createPoolConfiguration`（slonik）把 `connectionOptions.options` 直传 `pg.Pool` 配置 ✅

**结论**：`DB_URL=.../app_db?sslmode=disable&options=-c%20search_path%3Dlogto%2Cpublic` 在 Logto 自身栈里端到端可用，**且天然覆盖租户重连**（这是它相对 role 级方案的最大优点——不用 post-seed 逐角色 ALTER）。docker-compose 环境变量是纯字符串（引号包裹即可），无 shell 重解析；slonik 负责编解码。另一 AI 对路径 2 的否决理由不成立，但它与 role 级设置二者**选一**即可（role 级 PGC_S_DATABASE_USER 优先级高于 options 的 PGC_S_CLIENT，同设以 role 级为准）。

**推荐（本评审）**：运行时机制**首选 DB_URL `options` 参数**（一处配置、自动覆盖租户重连、seed/alteration/runtime 三处同源）；`ALTER ROLE ... IN DATABASE app_db SET search_path TO logto, public` 作为显式审计兜底同样可行，但必须写清"含 tenants.db_user 枚举出的所有租户角色、post-seed 执行"。**禁止 `ALTER DATABASE app_db SET search_path`**（会污染 app_owner/authenticator/PostgREST 的未限定查询，属数据安全级风险）。

### 2.6 S3 结论（表清单基线，可直接作为视图映射基线）

- **v1.42.0 共 71 张表**（`packages/schemas/tables/` 75 个 SQL 文件 − 4 个生命周期文件 `_before_all/_after_each/_after_all/_functions`）。另一 AI 说"30+ 张"明显低估。
- 与 master 差异 7 个文件（master 新增 `cimd_*` 6 张 + `trusted_devices`）——**这就是 D4 `latest` 漂移的活样本**，阶段 1 升级回归门应 diff "新 tag 的 tables 目录 + alterations 目录"。
- 关键语义（供视图映射/`api_v1_public` 换源使用）：
  - `users.id varchar(12)`（**064 镜像注释写"21 位 nanoid"对 users 不准确**，其余多数表 id 才是 varchar(21)）；
  - 所有业务表带 `tenant_id varchar(21) FK → tenants`，由触发器 `set_tenant_id()` 按 `tenants.db_user = current_user` 自动落值；
  - `users_roles` 唯一键 `(tenant_id, user_id, role_id)`；`organization_user_relations` / `organization_role_user_relations` 有 `(tenant_id, user_id)/(tenant_id, organization_id, user_id)` 复合 FK——安全视图过滤 tenant_id 时要按这些复合键 join，不能只按 id；
  - 敏感列：`users.password_encrypted / password_encryption_method / mfa_verifications / identities` 等，37 号文档 §7 的列级隔离要求继续成立。
- 镜像表与 Logto 权威表的形状差异（tenant_id 缺失、`role` 单复数命名等）在"双轨对拍"设计里要显式列映射（见 §4 修订建议）。

### 2.7 S5 结论：扩展依赖

v1.42.0 `tables/` 与 `core/src` 中**无** `create extension`、无 `citext`、无 `uuid-ossp/gen_random_uuid` 运行依赖；`pgcrypto` 只出现在历史 alteration `1.0.0_rc.0`（`CREATE EXTENSION IF NOT EXISTS pgcrypto`）。app_db 已装 pgcrypto（`infra/pigsty.yml` L68-69）→ **S5 通过**。

---

## 3. "直接迁移到 schema"这一步的完整可行性分析

### 3.1 三种路径的最终判定（对另一 AI"三路径"的修正版）

| 路径 | 另一 AI 结论 | 本评审结论 | 差异根因 |
|---|---|---|---|
| 1. Role 级 search_path | "完美/最严谨/零代码侵入" | **必要但不充分**。必须叠加 P1–P7 补丁层 | 漏了租户角色（§2.1.2）、5 处硬编码（§2.3）、角色名对齐（§3.3） |
| 2. DB_URL `options` 参数 | "有风险，不推荐" | **实测可用，且是 Logto 栈里最省事的机制**（自动覆盖租户重连） | "转义大坑"未经验证，与 slonik/pg 实测不符（§2.5） |
| 3. 迁移后 `ALTER ... SET SCHEMA` | "禁止，破坏版本追踪" | **禁止结论不成立；推荐用作一次性搬迁的 staging 中转技术**（§3.4），但不是"运行期维护模式" | 版本追踪在 `systems` 表**数据行**，`SET SCHEMA` 不碰数据；真正的风险是对象种类遗漏与 public 残留 |

### 3.2 为什么"直接恢复进 app_db.public 再搬"必死（设计约束）

app_db.public 已存在业务镜像表 `users / tenants / role / organization_role / user_tenants / user_role`（064 迁移）。Logto 表名 `users / tenants / roles / organizations / organization_roles ...` 与其**同名冲突**，`pg_restore` 到 public 会报已存在或（配 `--clean` 时）灾难性误删业务表。因此任何"先落 public 再搬"的路线在 app_db 上不可行；也正因如此，"文本 sed 全量改 public→logto" 也不可取（COPY 数据里可能含 `public.` 字面量，会损坏数据）。

### 3.3 存量库专属坑：租户角色名与库名绑定（另一 AI 与 37 号文档都未覆盖）

- 现有 `logto` 库 seed 时生成的父角色/租户角色名为 `logto_tenant_logto` / `logto_tenant_logto_default` / `logto_tenant_logto_admin`，`tenants.db_user` 存的就是这些名字。
- 合并后 `current_database() = app_db`，**未来任何新 alteration** 按 `alterations/utils/1704934999-tables.ts` 会生成 `logto_tenant_app_db` 并 `grant ... to logto_tenant_app_db`（§2.3 T1 的同款逻辑在新表上每张都会跑）→ 角色不存在 → **升级当场报错**。
- **必须在搬迁时做角色对齐（P1）**：`ALTER ROLE logto_tenant_logto RENAME TO logto_tenant_app_db`（及两个子角色同名规则重命名），并 `UPDATE logto.tenants SET db_user = 新名字`（RLS 策略 `db_user = current_user` 与触发器 `set_tenant_id()` 都按字符串比对，必须同步）。角色重命名按 OID 保留全部已授 ACL，安全；需要 CREATEROLE/超级用户执行（Pigsty 侧用管理账号）。

### 3.4 推荐的搬迁流水线（staging 中转，避免 public 冲突与数据损坏）

```
旧库 logto (public, 71表, 存量数据)
   │  ① pg_dump -Fp -n public  （或 -Fc；含 ACL，勿 -x）
   ▼
中转库 tmp_logto（新建、一次性，同实例）
   │  ② 原样恢复（同名同结构，无冲突）
   │  ③ CREATE SCHEMA logto; 逐类搬迁：ALTER TABLE / TYPE / FUNCTION / VIEW ... SET SCHEMA logto
   │     （触发器/索引/约束随表走；ACL 随对象走；CHECK 的 deparse 仍是 public.check_role_type → 由 P3 在目标库补函数）
   │  ④ 检查 public 零 Logto 残留（pg_class/pg_proc/pg_type 按 nspname 清点）
   ▼
  ⑤ pg_dump -n logto → 恢复进 app_db（以 logto 身份恢复：临时 GRANT CREATE ON DATABASE app_db TO logto，完成后 REVOKE；
     dump 的 ALTER SCHEMA public OWNER 语句已在 -n logto dump 中消失，不会再动 app_db.public 的属主）
   ▼
app_db.logto schema
   │  ⑥ 执行补丁层 P1–P7（§3.5）
   ▼
验收门（§3.7）
```

关键点：中转库把"对象搬迁"与"目标库落位"解耦，全程无文本替换、无数据损坏风险、不触碰 app_db.public 的任何对象。

### 3.5 补丁层清单（P1–P7，需落成幂等脚本/迁移，随每次升级重放）

| # | 补丁 | 内容与注意 |
|---|---|---|
| P1 | 角色名对齐（存量库路径专属） | 按 §3.3 重命名父子三角色 + `UPDATE tenants SET db_user`；新环境（staging seed 在 app_db 命名后）无此步 |
| P2 | search_path 收敛 | 首选 DB_URL `?options=-c search_path=logto,public`；或 `ALTER ROLE logto IN DATABASE app_db SET search_path TO logto, public` + 对 `SELECT db_user FROM logto.tenants` 枚举的每个租户角色逐个同款 ALTER（post-seed/重命名后执行）。禁止 `ALTER DATABASE` |
| P3 | 重建 `public.check_role_type` 包装函数 | `CREATE FUNCTION public.check_role_type(role_id varchar(21), target_type role_type) ... RETURN (SELECT type FROM logto.roles WHERE id=role_id) = target_type;`（与三张表 CHECK 的 deparse `public.check_role_type(...)` 对齐；函数以调用者权限跑，租户角色已有 logto.roles 的 DML）。替代方案：`public.roles` shim 视图 + 原函数体，但函数重写更干净、不在 public 留视图 |
| P4 | 修正两个函数 | `ALTER FUNCTION logto.check_application_type(...) SET search_path = logto, public;` 与 `check_organization_role_type` 同款（消除 T3/T4） |
| P5 | schema 级授权 | `GRANT USAGE ON SCHEMA logto TO logto_tenant_app_db, app_owner;`（表级 ACL 已随 dump/alteration 携带，schema USAGE 不会）；`app_owner` 侧按 37 号文档 §4.2 步骤 3 只授安全视图所需列；补 `ALTER DEFAULT PRIVILEGES FOR ROLE logto IN SCHEMA logto GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO logto_tenant_app_db;` 兜底未来新表 |
| P6 | 权限防泄漏 | fresh-seed 路径专属：`REVOKE ALL ON ALL TABLES IN SCHEMA public FROM logto_tenant_app_db;`（对冲 `_after_all` 的 `in schema public` 硬编码，§2.3 T1）；restore 路径无此问题（dump 只带 per-object ACL）但仍做断言：`has_table_privilege('logto_tenant_app_db', 'public.users','SELECT')` 必须为 f |
| P7 | 属主校验 | logto schema 全部对象 owner = `logto`（sharedPool 以 owner 身份读 `tenants` 才绕开 RLS，否则 `getTenantDatabaseDsn` 会读不到租户行 → TenantNotFoundError）；`public` 中除 P3 包装函数外无 Logto 残留对象 |

### 3.6 全新环境 bootstrap（D12）：禁止在 app_db 裸 seed

fresh seed 直建的完整死链是**四道墙**（39 号文档 §3 逐条源码依据）：① `_before_all` 的 `create role` 需要 CREATEROLE（官方 compose 的 `POSTGRES_USER=logto` 是 superuser，本项目 Pigsty `logto` 是低权限——前提偏差）；② `create function public.check_role_type` 需要 public CREATE（T5）；③ `_after_all` 的 `grant ... in schema public` 对业务表**硬 ERROR**（PG18 `aclchk.c` `restrict_and_check_grant` L305-330）或 superuser 下**权限反向泄漏**——无参数可绕；④ seed 数据插入触发 CHECK → `public.roles` 不存在 → 42P01 回滚（T2，shim 与表的鸡生蛋）。**新环境一律走 §3.4 流水线**：staging 库 `db seed`（保持官方行为，DSN 不带 options）→ SET SCHEMA → dump `-n logto` → 恢复进 app_db → P1–P7。这套流程同时天然支持"重建 staging/演练环境"。**时序修正**：P3 包装函数必须在 `pg_restore` **之前**预建（否则恢复建表时 CHECK 解析 `public.check_role_type` 失败），且签名用 `(varchar(21), text)` 规避枚举类型尚未恢复的时序依赖（详见 39 号文档 §4.4）。

### 3.7 验收门 SQL（并入 37 号文档阶段 1 回归门）

```sql
-- 以 DB_URL 主角色、各租户角色分别执行：
select current_user, current_database(), current_setting('search_path');          -- 期望含 logto
select to_regclass('logto_configs'), to_regclass('logto.logto_configs');          -- 均非空
select to_regclass('users'), to_regclass('logto.users');                          -- 均指向 logto.users

-- 以 logto 主角色执行（owner 绕过 RLS 读 tenants）：
select id, db_user from logto.tenants;                                            -- db_user 已对齐新角色名

-- 租户角色权限断言：
select has_schema_privilege(current_user, 'logto', 'USAGE'),
       has_table_privilege(current_user, 'logto.users', 'SELECT,INSERT,UPDATE,DELETE'),
       has_table_privilege(current_user, 'public.users', 'SELECT');               -- 后者必须 false

-- 硬编码点回归（T2/T3/T4）：
insert into logto.users_roles (tenant_id, id, user_id, role_id)
  select tenant_id, 't-'||gen_random_uuid(), id, (select id from logto.roles where type='User' limit 1)
  from logto.users limit 1;                                                       -- CHECK 走 public.check_role_type → logto.roles
select logto.check_application_type((select id from logto.applications limit 1), 'Protected'); -- 不再 42P01
select logto.check_organization_role_type((select id from logto.organization_roles limit 1), 'User');
```

```sh
# 升级追踪（容器内执行，CLI 自动读 DB_URL）：
npm run cli db alteration deploy latest   # 期望 "Found 0 alteration to deploy"
npm run cli db seed -- --swe              # 期望 "Seeding skipped"（幂等）
```

---

## 4. 对 37 号文档的修订建议

### 4.1 §4.1 Spike 状态更新

| 项 | 状态 | 结论摘要 |
|---|---|---|
| S1 | ✅ 关闭 | JS 层不显式 SET（§2.1.1）；SQL DDL 层硬编码 5 处（§2.3）；机制选 DB_URL options 为主、role 级兜底（§2.5） |
| S2 | ✅ 关闭 | seed/alteration/runtime 同 DB_URL；**新增缺口：alteration deploy 不在启动路径，升级回归门必须显式执行**（§2.1.3） |
| S3 | ✅ 基线产出 | 71 表清单（v1.42.0）+ id 长度/tenant_id/复合 FK 语义 + master 7 文件漂移样本（§2.6） |
| S4 | ✅ 关闭 | slonik 31 beta + pg 8.23 实测 options 参数端到端透传，含租户 DSN 继承（§2.5） |
| S5 | ✅ 关闭 | 无运行期扩展依赖；pgcrypto 仅历史 alteration，app_db 已装（§2.7） |

### 4.2 §4.2 表格修正

- 步骤 2（DB_URL 指向主实例）：`⚠️ 依赖 S1/S2` → `✅ 可行，前提 = 补丁层 P1–P7（§3.5）`。
- 步骤 3（GRANT SELECT）：补充"授 `app_owner` 仅安全视图所需列"之外，**必须**补 §3.5 P5 的租户角色 schema USAGE 与 P6 防泄漏断言。

### 4.3 §5.2 改造清单修正

- 新增两个文件级产物：
  - `db/migrations/public/067_logto_schema_merge.sql`：logto schema 落位（staging 流水线产物恢复）+ P1 角色对齐 + P2 search_path + P5/P6 授权；
  - `db/migrations/public/068_logto_schema_shims.sql` 或 `scripts/phase2/patch-logto-schema.sql`：P3 包装函数 + P4 两个 ALTER FUNCTION + P7 属主校验 + §3.7 断言（**幂等，每次 Logto 升级后重放**）。
- §5.1 `gateway/docker-compose.yml`：DB_URL 改 `5432/app_db` + options 参数；**升级 runbook 增加 `npm run cli db alteration deploy latest` 步骤**（entrypoint 可不动，但文档必须写）。

### 4.4 §6 分阶段路线修正

- 阶段 0（Spike）：可判定完成，产出即本文件；剩余收尾 = 双轨对拍脚本设计（§8 第二项）。
- 阶段 1 验收门**增补**：§3.7 全部断言 + `alteration deploy latest` 输出 0 + Console 登录 + 角色分配/应用类型/组织角色三项 e2e（正好覆盖 T2/T3/T4 回归）+ 补丁层重放演练（模拟升级一次）。

### 4.5 §7 风险登记册修订

| 原风险 | 修订 |
|---|---|
| "Logto search_path 不支持（S1 不通过）" P0 | 改写为："search_path 机制支持，但存在 5 处硬编码 + 租户两层连接 + 角色名对齐，已由 38 号文档定位；**补丁层随 latest 漂移**为新 P0：每次升级 diff 新增 tables/alterations 的 `public`/`search_path` 引用并重放 068 补丁" |
| 新增 | "新环境裸 seed 不可用"（§3.6）：staging 流水线是唯一 bootstrap 路径，写进运维 runbook |
| 新增 | "租户角色权限反向泄漏"（T1 在 fresh-seed 场景授权 business public 表）：P6 revoke + 断言兜底 |
| 敏感列暴露 / tenant_id 过滤 | 保留，并补充 §2.6 的复合 FK 映射注意点 |

### 4.6 §8 待办

- [x] 阶段 0 Spike 立项（S1–S5）→ 由本文档关闭
- [ ] 双轨对拍脚本设计（按 §2.6 权威表清单列显式映射）
- [ ] 补丁层 067/068 实现 + §3.7 断言集成进 e2e
- [ ] 升级 runbook：alteration deploy + 补丁重放 + 新版本 `public` 引用 diff

### 4.7 §9 新增决策点

| # | 决策点 | 建议 |
|---|---|---|
| D9 | search_path 机制二选一 | DB_URL `options` 参数为主（一处配置、自动覆盖租户重连），role 级 `ALTER ROLE ... IN DATABASE` 为辅（二选一，勿混设） |
| D10 | 是否允许 `logto` 角色 CREATE on public | restore 路径不需要；仅当将来决定在 app_db 裸 seed 时才需要（且仍受 T2 鸡生蛋限制）→ 不建议开放 |
| D11 | 角色重命名（P1）时机 | 搬迁窗口内与 tenants.db_user 更新同事务/同脚本执行，验收前不允许 Logto 容器启动 |
| D12 | 新环境 bootstrap | 一律 staging seed + SET SCHEMA + `-n logto` 二次 dump 流水线（§3.4/§3.6） |

---

## 5. 对另一 AI《核查报告》的逐条勘误

| # | 该报告的论断 | 判定 | 依据 |
|---|---|---|---|
| 1 | "SQL 语句均未显式限定 Schema" | ❌ 不成立 | §2.3 T1–T5 共 5 处硬编码 `public`；alterations 另有 54 处 `public.` |
| 2 | "Logto 不会强制 SET search_path 重置" | ⚠️ 仅 JS 层成立 | SQL DDL 层有两个函数 `set search_path = public`（PR #6101 正是其来源）；断言不能跨层推广 |
| 3 | "路径 1 role 级绑定 = 最严谨、零代码侵入" | ❌ 结论过强 | 漏租户角色（§2.1.2）、漏 5 处硬编码（§2.3）、漏角色名对齐（§3.3）；正确表述是"必要不充分，需 P1–P7" |
| 4 | "不要给 logto_user 对 public 的 CREATE" | ⚠️ 在其"独立库"语境下成立，合并语境下恰好相反 | 合并后 logto 非库主，fresh seed 会死在 `public.check_role_type`（T5）；restore 路径则不需要 |
| 5 | "路径 3 彻底破坏版本追踪表" | ❌ 机制性错误 | 追踪在 `systems` 表数据行（§2.1.3），`SET SCHEMA` 不动数据；路径 3 的真实风险是对象种类遗漏/public 残留，且它恰恰是本评审推荐的一次性搬迁技术（§3.4） |
| 6 | "路径 2 options 易被 URL Decode/转义破坏" | ❌ 实测不成立 | §2.5 实验：slonik 解析回环无损、pg startup 透传、且自动覆盖租户 DSN；docker-compose 纯字符串无 shell 风险 |
| 7 | "Logto 初始化 30+ 张系统表" | ❌ 低估 | v1.42.0 为 71 张表（§2.6） |
| 8 | "种子数据必须用绑了 search_path 的 logto_user" | ⚠️ 方向对、落地错 | 在合并后的 app_db 裸 seed 会先后死于 T5/T2（§3.6）；本项目存量迁移走 restore 流水线，不适用其 seed 配方 |
| 9 | Issue #8607 官方引文 | ✅ 基本准确 | 原文见 charIeszhao 2026-04-07/2026-05-07 两条评论；其第二次回复关于 tenant db user 的内容恰好佐证本评审 §2.1.2 |

---

## 6. 证据索引

- Logto v1.42.0：`packages/core/src/env-set/create-pool.ts`（L87-111）、`packages/core/src/tenants/utils.ts`（getTenantDatabaseDsn）、`packages/cli/src/commands/database/seed/{index,tables,tenant}.ts`、`packages/toolkit/core-kit/src/models/tenant.ts`、`packages/cli/src/queries/{logto-config,system}.ts`、`packages/schemas/tables/{_after_all,applications,organization_roles,roles,users_roles,applications_roles,application_access_control_user_role_relations}.sql`、`packages/schemas/alterations/utils/1704934999-tables.ts`、`Dockerfile`、`docker-compose.yml`
- GitHub：[PR #6101](https://github.com/logto-io/logto/pull/6101)、[Issue #8607](https://github.com/logto-io/logto/issues/8607)（评论 4167118754 / 4176149109 / 4199402122 / 4202354551）、[Database alteration 文档](https://docs.logto.io/logto-oss/using-cli/database-alteration)
- PostgreSQL：[ALTER ROLE 文档](https://www.postgresql.org/docs/current/sql-alterrole.html)（"Role-specific variable settings take effect only at login"）、PG18 `src/backend/utils/init/postinit.c`（`process_settings(MyDatabaseId, GetSessionUserId())`）
- 本仓库：`gateway/docker-compose.yml`（L83/L135/L143）、`infra/pigsty.yml`（L49-86）、`infra/pgbouncer.ini`、`infra/postgresql.conf`（L64）、`db/migrations/public/064_v010_mirror_tables.sql`
- 本地实验：`@silverhand/slonik@31.0.0-beta.3`（parseDsn/stringifyDsn 回环）、`pg@8.23.0`（`pg/lib/client.js` L567-568 startup options）
