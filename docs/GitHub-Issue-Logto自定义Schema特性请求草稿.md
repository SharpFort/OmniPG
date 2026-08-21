# GitHub Issue 草稿：Logto 支持将表安装到非 public 的自定义 Schema（Feature Request）

> 用途：用户复制到 GitHub 提交。对照话题：[#3795 feature request: Custom schema](https://github.com/logto-io/logto/issues/3795)
> 定性结论：**这是 Feature request，不是 bug**（官方已在 #3795 确认 "this is valid, but we don't have resource for now"）。
> 本草案在原 #3795 的基础上，补充了官方 team 未覆盖的**三处新的硬编码证据**（v1.42.0 源码核查），使诉求更完整、可复现。

---

## 1. What problem did you meet?

I want to deploy Logto against an existing PostgreSQL instance where multiple applications share one database, each isolated in its own schema. My business tables live in `public` (or I intend to move them out and dedicate `public` to something else), and I need Logto's tables to live in a **custom schema** such as `logto` / `auth` — not `public`.

Today Logto **cannot be installed into a non-public schema out of the box**. The schema is hard-coded to `public` in several places, so:

- Running `npm run cli db seed` (or `db alteration deploy`) against a database whose `search_path` points at a custom schema either **fails** (`relation "public.roles" does not exist`, or `permission denied for schema public`) or **silently grants the tenant role DML on the wrong schema**.
- The workaround suggested in [#3795](https://github.com/logto-io/logto/issues/3795#issuecomment-1530604780) (`ALTER ROLE ... SET search_path`) is **not sufficient** because at runtime Logto reconnects as per-tenant database users (`logto_tenant_<database>_default` / `_admin` read from `tenants.db_user`), and those roles also need the schema grant + `search_path` set individually. There is currently no supported way to do this cleanly.

The result: running Logto side-by-side with other apps in one PostgreSQL instance requires either (a) a dedicated database (losing single-database PITR/backup atomicity across auth + business data), or (b) fragile post-seed SQL patching that must be re-applied after every Logto upgrade (and can break silently when new alterations hard-code `public` again).

## 2. Describe what you'd like Logto to have

An officially supported, first-class way to run Logto in a **configurable schema** (e.g. `DB_URL=.../app_db?schema=logto` or an equivalent `SCHEMA` / `search_path` config), such that:

1. `db seed` and `db alteration deploy` create **all** objects (tables, enums, functions, triggers, indexes, grants) in the configured schema — no hard-coded `public`.
2. The **per-tenant database roles** (`logto_tenant_<database>` parent, and the per-tenant child roles `..._default` / `..._admin`) automatically receive `USAGE` on the configured schema, `search_path` = that schema, and DML on its tables — so the two-tier connection model (management pool + tenant reconnect via `tenants.db_user`) works without manual `ALTER ROLE`.
3. The `CREATE SCHEMA` / `GRANT` steps are performed by upgrade/seed (or documented as a one-time prerequisite), with the schema assumed not to pre-exist for upgrade safety.

### Concrete places that hard-code `public` today (v1.42.0, please treat these as the fix targets)

To make it concrete and actionable, here are the exact locations I found by reading the source (verified against the v1.42.0 tag):

| # | File | What hard-codes `public` |
|---|---|---|
| 1 | `packages/schemas/tables/_after_all.sql` (line 6) | `grant select, insert, update, delete on all tables **in schema public** to logto_tenant_${database};` |
| 2 | `packages/schemas/tables/roles.sql` (lines 25-27) | `create function **public**.check_role_type(...)` whose body is `select type from **public**.roles ...` |
| 3 | `packages/schemas/tables/applications.sql` (line 49) | `... language plpgsql **set search_path = public**;` (function `check_application_type`) |
| 4 | `packages/schemas/tables/organization_roles.sql` (line 29) | `... language plpgsql **set search_path = public**;` (function `check_organization_role_type`) |
| 5 | `packages/schemas/src/models/tenants.ts` (line ~24) | `createModel(...(sql..., 'public'))` — the `tenants` model declares the literal schema `'public'` |
| 6 | CHECK constraints referencing #2 | `users_roles.sql`, `applications_roles.sql`, `application_access_control_user_role_relations.sql` all use `check (public.check_role_type(role_id, ...))` |

(References 1-4 were first reported in #3795 by Destreyf; 5-6 are additional hard-codings I confirmed. Historical alterations under `packages/schemas/alterations/` also contain ~54 `public.` references and 4 `set search_path = public` that take the same shape in future upgrades.)

### Why the current "set search_path for the role" workaround is not enough

- Logto has a **two-tier connection model**: the management pool (role from `DB_URL`) plus a per-tenant reconnect using `tenants.db_user` (`packages/core/src/tenants/utils.ts` → `getTenantDatabaseDsn`). Setting `search_path` only on the `DB_URL` role leaves the tenant roles pointing at the wrong schema.
- `CREATE ROLE` for the tenant roles happens *inside* seed (`packages/cli/src/commands/database/seed/tenant.ts`), so the per-tenant `ALTER ROLE ... SET search_path` + `GRANT USAGE ON SCHEMA` must run **after** every seed — not declarable up front.
- A fresh seed with a non-public `search_path` fails at `create function public.check_role_type` (permission denied for schema public) and/or at `select ... from public.roles` (relation does not exist) via the CHECK constraints.

This issue would make Logto usable in the common "shared single PostgreSQL instance, schema-per-app" topology, which is a standard pattern for self-hosted setups (and already how Logto Cloud itself runs multiple schemas internally — see PR #6101's stated motivation).

---

## 3. Suggested implementation approach

> This section goes beyond a plain feature request and proposes the *concrete* change shape, because a naive "just delete the `public` qualifiers" is **not** correct — some of these `public` references are deliberate hardening (not leftovers), and deleting them would regress behavior. The correct shape is **"parameterize the schema, defaulting to `public`, plus a one-time migration alteration"**.

### 3.1 Why "just remove `public`" is not the right fix

Not all six hard-codings are the same kind, and removing them has different (some harmful) effects:

| Ref | Kind | Removing `public` breaks |
|---|---|---|
| #1 `_after_all.sql` grant | authorization boilerplate | Tenant roles lose DML on all tables → runtime `42501 permission denied`. This must be **parameterized**, never deleted. Note it is an explicit `in schema public` qualifier — unrelated to `search_path`.
| #2/#6 `check_role_type` + CHECKs | deliberate hardening (see #3795/#8607) | Since 1.9.0 the function was *hardened back to explicit `public`* precisely because an unqualified function could not be found under multi-schema (cloud) search paths. Removing it re-introduces that regression.
| #3/#4 `set search_path = public` | deliberate hardening (PR #6101) | PR #6101 added these for deterministic resolution in Logto Cloud's multi-schema deployment. Removing them makes the functions follow the caller's `search_path` and can resolve against the wrong schema.
| #5 `tenants.ts` `'public'` | model schema declaration | Removing it only affects fresh `db seed`; existing databases are never re-created on upgrade (upgrades run `alterations/` only), so a **separate migration alteration** is mandatory for existing DBs.

### 3.2 Recommended fix shape

1. **Introduce a schema variable** (env/config, e.g. `DATABASE_SCHEMA` or `DB_URL ?schema=`), **defaulting to `public`** for full backward compatibility. Replace the six hard-codings in §2 with this variable:
   - `_after_all.sql`: `grant ... on all tables in schema ${schema} to logto_tenant_${database};`
   - `roles.sql`: `create function ${schema}.check_role_type(...) ... select type from ${schema}.roles ...`
   - `applications.sql` / `organization_roles.sql`: `... language plpgsql set search_path = ${schema};`
   - `models/tenants.ts`: pass the configured schema instead of the `'public'` literal.
2. **Propagate the schema to the tenant roles**: after seed creates `logto_tenant_<database>[_default/_admin]`, grant them `USAGE ON SCHEMA ${schema}`, set their `search_path = ${schema}`, and grant DML on that schema's tables — mirroring what `_after_all.sql` currently does for `public`. This closes the two-tier connection gap described in §2.
3. **Ship a migration `alteration` (with a `down`)** for existing databases: move the `tenants` table (and any other schema-resident object) into the configured schema, and update the per-tenant roles' `search_path`. This is what makes the feature usable for existing installs, not just fresh seeds.
4. **Make `db seed --swe` and `authority schema detection` schema-aware**: the skip-if-exists check (`select to_regclass('logto_configs')`) already respects `search_path`, which is good; ensure any new schema-detection logic reads the same configured variable for seed, alteration, and runtime.

### 3.3 Acceptance criteria

- Fresh `db seed` into a custom schema (e.g. `logto`) produces all 71 tables/enums/functions there, with the two tenant roles fully functional (`USAGE` + `search_path` + DML);
- `db alteration deploy` on an existing database migrated via the new alteration reports 0 pending and does not re-target `public`;
- Console login, role assignment (`users_roles` CHECK), application-type and organization-role-type checks all pass end-to-end;
- Reverting the new alteration (`down`) moves the schema back to `public` without data loss.

---

_Related: #3795 (feature request: Custom schema), #8607 (runtime hard-codes unqualified `logto_configs` reads), PR #6101 (schema search-path fix for cloud multi-schema)._
