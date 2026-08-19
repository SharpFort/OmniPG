# 新增一个 API 的完整流程

> 定位：从迁移到 RPC/视图 → 权限 → 暴露 → 测试的端到端清单。适用于在 api_v1_public 中新增一个对外视图或 RPC（含底层表、函数、RLS、权限点）。
>
> 📌 若要**新建一个业务域模块**（新开目录 + 配置声明），请先看 [新建业务模块完整指南](adding-module.md)。

OmniPG 是「数据库即后端」架构：**API = `api_v1_public` 中的视图/RPC + PostgREST 自动暴露 + APISIX 路由/鉴权**。新增 API 没有代码层，只有 SQL。整个流程受 **17 号铁律（代码型对象归位）** 约束：表结构与数据变更进 `db/migrations/`，函数/视图/触发器/枚举/RLS 一律以幂等源文件归位 `db/src/` 或 `db/api_v1/`。

```
迁移(表结构/数据) → src/public(底层函数/触发器/RLS/枚举) → api_v1(视图/RPC)
  → 权限(GRANT + RLS + has_permission + 权限点) → PostgREST 暴露 → APISIX 路由 → 测试 → 更新文档
```

## Step 0：先按 17 号铁律判定对象归属

| 对象类型 | 归属目录 |
| --- | --- |
| 表/列/约束/索引、数据变更（seed/回填） | `db/migrations/public/`（新编号文件，从 067 起） |
| 枚举类型 | `db/src/public/types/<name>.sql`（bootstrap 前置） |
| 底层函数（public 无前缀） | `db/src/public/functions/<name>.sql` |
| 触发器 / 审计模板 | `db/src/public/triggers/`、`templates/` |
| RLS 策略 | `db/src/public/privileges/rls_policies.sql`（集中清单） |
| 对外视图 / RPC（api_v1_public.*） | `db/api_v1/public/views/`、`db/api_v1/public/rpc/` |
| GRANT | `db/api_v1/public/privileges/zz_grant_all.sql`（集中管理） |

规则速记：**迁移只承载表结构与数据；代码型对象一文件一对象；GRANT/RLS 用集中清单；新迁移禁止引用 src 函数/视图**（详见 [migrations.md](migrations.md) 与 [coding-standards.md](coding-standards.md)）。

## Step 1：迁移新增表/字段（表结构或数据变更）

在 `db/migrations/public/` 新建迁移文件。仓库惯例为 3 位序号（当前基线 `064/065/066`，squash 后新文件从 `067` 开始）：

```bash
cd db
# dbmate new 会生成 <时间戳>_<名称>.sql（可改名为 067_<名称>.sql，文件名单调递增即可）
dbmate new create_xxx_table
```

迁移文件必须带 `-- migrate:up` / `-- migrate:down` 标记，且遵循「幂等三件套」（`IF NOT EXISTS` / `DO` 块守卫 / `ON CONFLICT`）：

```sql
-- 067_create_xxx_table.sql
-- 用途: 新建 xxx 表（仅表结构与数据；代码对象一律归 src/api_v1，17 号铁律）
-- migrate:up
CREATE TABLE IF NOT EXISTS public.xxx (
    id         uuid DEFAULT uuidv7() PRIMARY KEY,
    tenant_id  text NOT NULL,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_xxx_tenant ON public.xxx USING btree (tenant_id);

-- migrate:down
-- 回滚说明（基线类迁移可仅写注释；可回滚的迁移在此写 DROP TABLE）
```

应用迁移：

```bash
make migrate            # 或 make migrate-status 先看状态
# 或按环境: bash scripts/migrate.sh up development
```

> ⚠️ 全新环境禁止裸跑 `dbmate up`：扩展/枚举/schema/角色由 bootstrap（`deploy-db.sh` 第一步）前置，冷启动依赖倒置会炸（见 [migrations.md](migrations.md)）。

## Step 2：在 src/public 编写函数/触发器/RLS（如需）

底层逻辑（被 RPC 调用的 public 函数、触发器、RLS、枚举）全部放 `db/src/public/`，一文件一对象：

| 子目录 | 内容 | 示例文件 |
| --- | --- | --- |
| `functions/` | 底层函数（无前缀 public schema） | `has_permission.sql`、`current_tenant_id.sql`、`update_updated_at.sql` |
| `triggers/` | `CREATE TRIGGER` | `trg_audit_iam_menu.sql`、`trg_updated_at.sql` |
| `views/` | 内部兼容视图 | `sys_user.sql`、`casbin_rule.sql`（兼容投影） |
| `types/` | 枚举（bootstrap 前置） | `scope_type.sql`、`menu_type.sql` |
| `templates/` | 审计字段模板参考 | `audit_fields.sql` |
| `privileges/` | RLS 策略集中清单 | `rls_policies.sql` |

**函数模板**（幂等、锁 search_path、DEFINER 必须自校验）：

```sql
-- db/src/public/functions/xxx_helper.sql
CREATE OR REPLACE FUNCTION xxx_helper(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- DEFINER 绕过 RLS：敏感逻辑必须显式校验
    IF NOT has_permission('public:xxx:read') THEN
        RETURN false;
    END IF;
    RETURN EXISTS (SELECT 1 FROM xxx WHERE id = p_id AND tenant_id = current_tenant_id());
END;
$$;
COMMENT ON FUNCTION xxx_helper(uuid) IS 'xxx 辅助函数（public:xxx:read）';
GRANT EXECUTE ON FUNCTION xxx_helper(uuid) TO authenticated;
```

**RLS 策略**写入集中清单 `db/src/public/privileges/rls_policies.sql`（DROP POLICY IF EXISTS + CREATE POLICY 幂等模板）：

```sql
ALTER TABLE xxx ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS xxx_tenant_isolation_policy ON xxx;
CREATE POLICY xxx_tenant_isolation_policy ON public.xxx
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());
```

**枚举**建在 `db/src/public/types/<name>.sql`（DO 块守卫 + 只增不删），由 bootstrap 阶段先于迁移应用。

## Step 3：在 api_v1 建对外视图或 RPC

**Schema 布局**（以 `db/init/02-schemas.sql` 为准）：`public`（核心业务 + 函数/触发器/RLS）、`api_v1_public`（对外暴露视图/RPC）、`api_v1_sys`（027 改名链兼容，新代码不用）、`net`（pg_net 宿主）；**不存在 extensions schema**。`db/api_v1/` 下按域分子目录（`_shared` / `inventory` / `public`，当前活跃模块 public，实际内容全部在此；`api_v1_sales` / `api_v1_inventory` 仅存在于参考配置与历史空目录）。**PostgREST 运行态以 compose 为权威：单 schema `api_v1_public`**。新增 API 默认落在 `db/api_v1/public/`：

- **视图**：`db/api_v1/public/views/<name>.sql` —— 视图名 = 底层表名（如 `users`、`iam_menu`）或 `v_*` 列表视图（如 `v_user_list`、`v_role_list`）；视图负责脱敏（例如 `users` 视图不暴露 password_hash）。
- **RPC**：`db/api_v1/public/rpc/rpc_<动词>_<名词>.sql` —— CRUD 类 RPC 统一 `rpc_` 前缀；历史函数（`get_user_menu`、`get_role_permissions`、`search_users`、`update_config`、`webhook_logto`、`ensure_user` 等）保留原名。新模块的视图/RPC 放对应域子目录（`db/api_v1/<域>/`），并同步声明到 `apply-src.sh` 的 `API_MODULES` 与 postgrest 的 `db-schemas`。

RPC 模板（写/管理类必须 `SECURITY DEFINER` + 权限门槛 + 审计）：

```sql
-- db/api_v1/public/rpc/rpc_create_xxx.sql
CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_xxx(p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
    -- 操作级权限（权限点门槛，见 Step 4）
    IF NOT has_permission('public:xxx:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    INSERT INTO xxx (tenant_id, name, created_by)
    VALUES (current_tenant_id(), p_name, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('xxx', 'create', 'xxx', v_id::text,
                        'success', jsonb_build_object('name', p_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_create_xxx(text) IS 'xxx 新增（public:xxx:create）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_xxx(text) TO authenticated;
```

视图模板：

```sql
-- db/api_v1/public/views/xxx.sql
CREATE OR REPLACE VIEW api_v1_public.xxx AS
SELECT id, tenant_id, name, created_at, updated_at
FROM public.xxx;
COMMENT ON VIEW api_v1_public.xxx IS 'xxx 对外视图';
```

## Step 4：配置权限（RLS 策略、角色授权、权限点）

三层正交（详见 [permission-development.md](permission-development.md)）：

1. **数据级（RLS）**：表 `ENABLE ROW LEVEL SECURITY` + 策略写入 `rls_policies.sql`（Step 2 模板）。
2. **操作级（has_permission）**：新写/管理 RPC 在函数内校验权限点；查询类 RPC 依赖 RLS 即可。
3. **表级 GRANT**：视图/RPC 的授权写入 `db/api_v1/public/privileges/zz_grant_all.sql`：

```sql
GRANT SELECT ON api_v1_public.xxx TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_xxx(text) TO authenticated; -- 一般随 RPC 文件尾部
```

**权限点注册**：权限点 = `iam_menu` 中 `menu_type='button'` 的行，`api_code` 为权限码（命名空间 `public:`），`api_url`/`api_method` 记录真实端点（055 单表化模型）：

```sql
-- 运行时经 rpc_create_menu 创建按钮行（menu_type='button' 必填 api_code；端点成对）
SELECT * FROM api_v1_public.rpc_create_menu(
    p_menu_name := 'xxx 新增', p_menu_type := 'button',
    p_api_code := 'public:xxx:create',
    p_api_url := '/rpc/rpc_create_xxx', p_api_method := 'POST');
```

> 权限点/种子类数据也可以按 17 号铁律放入迁移（数据变更归迁移），如 `066_v010_seed_data.sql` 中 55 行 iam_menu 种子。

角色绑定（授权 = 菜单树勾选，单表 `iam_role_menu`）：

```sql
SELECT * FROM api_v1_public.rpc_set_role_menus(
    p_role_code := 'tenant_admin',
    p_menu_ids := ARRAY['<menu_id>'::uuid]);
```

镜像表（`users`/`tenants`/`role`/`user_tenants`/`user_role`/`organization_role`）只读投影，写入只能走 webhook 同步函数（`sync_*`）——**不要给镜像表视图授写权限**（`zz_grant_all.sql` 中已有 `REVOKE INSERT, UPDATE ON api_v1_public.users/role FROM role_admin` 的先例）。

## Step 5：PostgREST 暴露检查

运行时配置来自 `gateway/docker-compose.yml`（postgrest 容器环境变量）：

| 配置项 | 当前值 | 说明 |
| --- | --- | --- |
| `PGRST_DB_SCHEMAS` | `api_v1_public`（单 schema，compose 运行态权威） | 暴露的 schema；postgrest.conf 参考文件已对齐（2026-08-19） |
| `PGRST_DB_EXTRA_SEARCH_PATH` | `api_v1_public,public` | 额外搜索路径（运行态） |
| `PGRST_DB_ANON_ROLE` | `web_anon` | 匿名角色（默认无表权限） |
| `PGRST_JWT_ROLE_CLAIM_KEY` | `.pg_role` | Logto customizer 注入的 PG 角色 claim |
| `PGRST_JWT_SECRET` | `${JWKS_JSON}` | Logto JWKS 验签 |
| `PGRST_DB_PRE_REQUEST` | 空（已退役） | 黑名单检查已移除 |
| `PGRST_MAX_ROWS` | `1000` | 单次最大返回行数 |
| 宿主端口 | `3100 → 容器 3000` | PostgREST 直连地址 |

> 注① schema：运行态以 `gateway/docker-compose.yml` 为权威（`PGRST_DB_SCHEMAS=api_v1_public` 单 schema）；`gateway/postgrest/postgrest.conf` 是**参考文件**（2026-08-19 已与运行态对齐：单 schema api_v1_public、.pg_role）。新增模块时同步 compose `PGRST_DB_SCHEMAS` + `apply-src.sh` 的 `API_MODULES`，改配置后需 `docker compose up -d postgrest` 重建。
> 注② JWT 算法：开发环境 HS256（`JWKS_JSON` 对称密钥）；staging/production 指向 Logto JWKS 公钥 RS256（05 文档与 init-apisix-routes.sh 口径；compose 注释与 .env.staging/.production 注释写 ES384——口径不一致，**需以 Logto 实际配置核实**）。

应用 SQL 后验证：

```bash
# 1) 全量幂等重放（含 §6.3 迁移扫描；新对象未归位会直接失败）
bash scripts/apply-src.sh "postgres://app_owner:...@127.0.0.1:5432/app_db?sslmode=disable"

# 2) OpenAPI 规格（含全部视图/RPC 端点）
curl -s -H "Accept: application/openapi+json" http://localhost:3100/ | head -50

# 3) 直接调 PostgREST（不经过 APISIX）
curl -s -X POST http://localhost:3100/rpc/rpc_get_position_tree \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'

# 视图查询（RLS 生效）
curl -s "http://localhost:3100/v_user_list?select=id,username,email&limit=5" \
  -H "Authorization: Bearer $TOKEN"
```

如果 OpenAPI 里看不到新端点，检查：对象是否建在暴露层 schema（默认 `api_v1_public`，新模块为对应域 schema，而非 public 或其他未声明 schema）；函数是否有 `GRANT EXECUTE`；RPC 参数是否为 JSON 友好的 `text`/`json`（枚举不进函数签名）。

## Step 6：APISIX 路由（如需对外暴露）

**目标路由集 = `scripts/init-apisix-routes.sh`（Logto 时代，7 条）**，通过 Admin API 写入 etcd（路由 id 即下表首列；priority 与脚本一致）：

| 路由 id | priority | 路径 | 行为 | 鉴权 |
| --- | --- | --- | --- | --- |
| `logto_jwks` | 100 | `/.well-known/jwks` | → Logto（`app-logto:3001`） | 公开 |
| `webhook_logto` | 95 | `POST /rpc/webhook_logto` | → PostgREST，`serverless-pre-function` HMAC-SHA256 验签（`logto-signature-sha-256`） | 无 jwt-auth（web_anon） |
| `ensure_user` | 80 | `POST /rpc/ensure_user` | → PostgREST | jwt-auth（`key_claim_name: sub`） |
| `logto_proxy` | 60 | `/logto/*` | → Logto 同源代理（去 `/logto` 前缀） | 公开 |
| `api_v1_public` | 50 | `/api/v1/sys/*` | → `/$1`（去前缀映射 api_v1_public） | jwt-auth |
| `rpc_all` | 40 | `/rpc/*` | → PostgREST `/rpc/*` | jwt-auth |
| `catch_all` | 10 | `/*` | 兜底 → PostgREST | jwt-auth |

> `api_v1_sales`/`api_v1_inventory` 路由已于 2026-08-15 退役（测试模块移除），不在目标路由集内。

一般新增 API **不需要改路由**（`/rpc/*` 与 `/api/v1/sys/*` 已通配）。只有需要独立路径/公开访问/特殊校验时才新增，例如：

```bash
curl -s -X PUT http://localhost:9180/apisix/admin/routes/xxx_route \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" -H "Content-Type: application/json" \
  -d '{"uri":"/rpc/xxx","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":45,"methods":["POST"],"plugins":{"jwt-auth":{}}}'
```

### 已知不一致 / 待收敛（路由脚本新旧并存）

| 脚本/文件 | 现状 | 说明 |
| --- | --- | --- |
| ~~`scripts/setup_apisix.sh`~~ | **Casdoor 时代残留** | 2026-08-19 已删除（部署链统一 init-apisix-routes.sh） |
| `scripts/init-apisix-routes.sh` | **唯一路由初始化脚本（Logto 版）** | 本页路由集的事实来源；2026-08-19 起为部署链唯一入口（Makefile dev / deploy-all / deploy-gateway.yml） |
| ~~`gateway/apisix/apisix.yaml`~~ | **过时残留** | 2026-08-19 已删除 |
| `scripts/verify-stack.sh` | 预期 **7 条路由**（logto_jwks/logto_proxy/webhook_logto/ensure_user/api_v1_public/rpc_all/catch_all） | ✅ 2026-08-19 已同步 Logto 路由集 |

**现状（2026-08-19）**：部署链已统一 `init-apisix-routes.sh`，以其路由集为事实标准（7 条）。

## Step 7：pgTAP 测试 + 手动 curl 验证

**pgTAP**（详见 [../07-测试/pgtap-guide.md](../07-测试/pgtap-guide.md)）：在 `db/tests/public/` 新增/更新测试文件（如 `06_xxx_test.sql`），事务包裹 + 断言：

```sql
-- db/tests/public/06_xxx_test.sql
BEGIN;
SELECT plan(3);
SELECT has_table('xxx');
SELECT has_function('api_v1_public.rpc_create_xxx', ARRAY['text']);
SELECT lives_ok($$ SELECT api_v1_public.rpc_create_xxx('demo') $$, 'rpc_create_xxx 可调用');
SELECT * FROM finish();
ROLLBACK;
```

运行：

```bash
make test-db      # pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r tests/
make test-e2e     # scripts/e2e-test.sh（Logto 登录 → APISIX 全链路）
bash scripts/verify-fresh-db.sh   # 全新库冷启动验证（结构比对 + 幂等两遍 + pgTAP）
```

**手动冒烟**（走完整链路）：

```bash
# 经 APISIX（jwt-auth 前置）
curl -s -X POST http://localhost:9080/rpc/rpc_get_position_tree \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```

## Step 8：更新本 wiki 的 rpc-reference.md

在 [../06-API参考/rpc-reference.md](../06-API参考/rpc-reference.md) 登记新 RPC：签名、参数、返回、权限码、示例。若新增视图，同步检查 [../06-API参考/postgrest.md](../06-API参考/postgrest.md) 中的端点示例。

## 端到端检查清单

| # | 核对项 | 通过标准 |
| --- | --- | --- |
| 1 | 对象归属判定 | 表结构/数据 → 迁移；代码对象 → src/api_v1（17 号铁律） |
| 2 | 迁移文件 | `-- migrate:up`/`-- migrate:down` 标记、幂等三件套、编号 067+ |
| 3 | src/api_v1 文件 | 一文件一对象、CREATE OR REPLACE / DROP IF EXISTS、`SET search_path = public, pg_temp` |
| 4 | RLS 策略 | 写入 `rls_policies.sql`，表已 ENABLE ROW LEVEL SECURITY |
| 5 | GRANT | 视图/RPC 已授 authenticated（zz_grant_all.sql 或文件尾部 GRANT） |
| 6 | 权限点 | 写/管理 RPC 有 `has_permission`/`require_permission` 门槛；button 行已注册 `public:` 权限码并绑定角色 |
| 7 | PostgREST | OpenAPI 可见新端点；curl 直连 3100 可调（RLS 生效） |
| 8 | APISIX | 按 init-apisix-routes.sh 路由集核对（logto_jwks/logto_proxy/webhook_logto/ensure_user/api_v1_public/rpc_all/catch_all，共 7 条） |
| 9 | 测试 | `make test-db` 通过；`make test-e2e` 通过（如涉及全链路） |
| 10 | 文档 | rpc-reference.md 已更新 |

---

> 参考：本页与 [migrations.md](migrations.md)、[coding-standards.md](coding-standards.md)、[permission-development.md](permission-development.md) 配套阅读；PostgREST 用法见 [../06-API参考/postgrest.md](../06-API参考/postgrest.md)，网关路由见 [../06-API参考/gateway-routing.md](../06-API参考/gateway-routing.md)，目录职责见 [repo-layout.md](repo-layout.md)。