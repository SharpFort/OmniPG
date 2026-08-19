# 新建业务模块完整指南（目录与配置变更清单）

> 定位：**为未来开发提供"新建一个业务域模块"的完整操作清单**——从新建目录、文件骨架，到需要在哪些配置中声明新模块，一次列全。区别于 [新增一个 API 的完整流程](adding-api.md)（在现有模块内加一个视图/RPC），本文档回答的是**"新开一个业务域"**（如 billing、hr、crm）时所有需要触碰的位置。
>
> 现状基准：v0.1.0 基线（迁移 064/065/066）、Logto 认证、Pigsty 单文件配置、APISIX traditional 模式（2026-08-19 收敛后）。

---

## 0. 模块划分：推荐形态 B（独立 schema），形态 A 谨慎使用

| 形态 | 说明 | 适用场景 | 现状示例 |
| --- | --- | --- | --- |
| **B. 独立 schema（推荐，新建模块默认选择）** | 模块拥有独立 schema（内部表/函数 + 对外 `api_v1_<module>`），模块之间通过 API（视图/RPC）交互 | **新建业务模块**；需要强隔离、独立权限模型、可独立演进的业务域 | sales/inventory 曾采用（已退役，按需重建即用此形态） |
| **A. 并入单 schema（谨慎使用）** | 业务对象并入 `public` / `api_v1_public`，按域分子目录组织 | 仅适合**极小型模块**或与现有 public 强耦合的工具性功能 | 当前 `public` 模块（权限管理） |

> ⚠️ **结论（2026-08-19 拍板）**：新建模块默认走**形态 B（独立 schema）**。`public` 模块定位为**权限管理/系统基础**专用，不再承载新业务域；复杂项目应拆分为多个 schema 模块。

### 0.1 为什么推荐形态 B（DDD 限界上下文 + 微服务式演进）

- **DDD 限界上下文（Bounded Context）→ 独立 schema**：每个业务域 = 一个限界上下文 = 一个独立 schema 模块，上下文之间通过 API 契约（视图/RPC）交互，不共享内部表——这是 DDD 的上下文映射在零后端架构里的落点（详见 [05.5-DDD 心智模型映射](../../docs/开发实施方案/05.5-DDD心智模型到零后端架构映射-视图与DTO的定位.md) 的映射表，本文档补充其未覆盖的"模块划分"部分）；
- **微服务式演进**：多 schema 模块天然隔离，未来可按模块拆分到独立数据库/服务器（PostgREST 多 schema 或独立部署），类似微服务拆分——先模块化，再决定是否物理拆分；
- **独立权限模型**：每个模块的 RLS 策略、GRANT、权限点（`<module>:` 前缀）独立管理，互不干扰；
- **依赖显式化**：模块依赖方向在 `apply-src.sh` 声明（后置可依赖前置），跨模块访问只能走对方 API（防腐层），防止"大泥球"式相互引用。

### 0.2 DDD 模块划分参考（借鉴 05.5，补充限界上下文维度）

| DDD 概念 | 模块化落点 | 说明 |
| --- | --- | --- |
| **限界上下文** | **schema 模块**（`billing`、`crm`、`hr`…） | 每个业务域一个模块；模块 = 内部表 + src 层 + 对外 `api_v1_<module>` |
| **聚合根 / Entity** | 模块内**表**（+ RLS 定义聚合边界） | 参照 05.5：Entity → 表；聚合内的表归同一模块 |
| **Value Object** | PG 类型 / CHECK / jsonb 子结构 | 模块内枚举（`types/`） |
| **防腐层（ACL）** | 跨模块访问 = 调用对方 `api_v1_<module>` 的视图/RPC | 禁止直连对方内部表；契约变更走对方模块 |
| **依赖方向** | `apply-src.sh` 的 `MODULES` 顺序 | 后置模块可依赖前置模块，反之不可；无环 |
| **模块演进** | 独立 schema → 未来可独立扩展/拆分部署 | 模块内部变化不影响其他模块（契约稳定即可） |
| **DTO / Read Model** | 模块内 `views/`、`rpc/` | 沿用 05.5：单表视图=DTO 形状，多表视图=Read Model |

> 📚 模块划分经验：① 模块命名 = 业务域（billing/crm/hr…），不要用技术名；② 模块内聚合自洽（表+函数+视图+RLS 一起）；③ 跨模块只读查询优先走对方视图，写操作走对方 RPC；④ 通用/共享能力（权限、审计、通知）放 `public` 模块。

---

## 1. 需要新建的目录与子文件夹（形态 B，以新业务域 `<module>` 为例）

```text
db/
├── migrations/
│   └── <module>/                       # ① 本模块迁移目录（独立于 public，见 §3.3 dbmate 方案）
│       └── <timestamp>_<module>_baseline.sql
├── src/
│   └── <module>/                       # ② 本模块底层源码（schema: <module>，一文件一对象）
│       ├── types/                      #    枚举（bootstrap 前置，只增不删）
│       │   └── <module>_status.sql
│       ├── functions/                  #    模块内部函数（schema <module>）
│       ├── triggers/                   #    CREATE TRIGGER
│       ├── views/                      #    内部视图（非对外）
│       ├── templates/                  #    审计字段模板参考（按需）
│       └── privileges/                 #    RLS 策略集中清单
│           └── rls_policies.sql
├── api_v1/
│   └── <module>/                       # ③ 对外暴露层（schema: api_v1_<module>）
│       ├── views/                      #    对外视图（视图名 = 底层表名或 v_*）
│       ├── rpc/                        #    对外 RPC（rpc_<动词>_<名词>.sql）
│       └── privileges/
│           └── zz_grant_all.sql        #    本模块 GRANT 集中清单
└── tests/
    └── <module>/                       # ④ pgTAP 测试（make test-db 自动递归覆盖）
        ├── 01_schema_test.sql
        └── ...
```

> 📌 形态 A（谨慎使用）时：目录同上但无独立迁移目录（并入 `migrations/public/`），对象进 `public` / `api_v1_public`，仅在 `db/src/`、`db/api_v1/` 下按域分子目录。

---

## 2. 需要修改/新增的配置文件清单（⚠️ 容易漏，逐项核对）

| # | 文件 | 改什么 | 形态 B（推荐） | 形态 A |
| --- | --- | --- | --- | --- |
| 1 | `scripts/apply-src.sh` | `MODULES` 追加 `<module>`；`API_MODULES` 追加 `<module>`（顺序 = 依赖方向，后置可依赖前置） | ✅ 必改 | ✅ 必改 |
| 2 | `db/init/02-schemas.sql` | `CREATE SCHEMA IF NOT EXISTS <module>` + `CREATE SCHEMA IF NOT EXISTS api_v1_<module>` + USAGE/授权 | ✅ 必改 | ❌ 不需要 |
| 3 | `gateway/docker-compose.yml` | postgrest 服务 `PGRST_DB_SCHEMAS` 追加 `api_v1_<module>`；`PGRST_DB_EXTRA_SEARCH_PATH` 追加 `<module>, api_v1_<module>` | ✅ 必改 | ❌ 不需要 |
| 4 | `gateway/postgrest/postgrest.conf` | 参考文件同步 `db-schemas` / `db-extra-search-path`（保持与 compose 对齐，2026-08-19 约定） | ✅ 必改 | ❌ 不需要 |
| 5 | `scripts/init-apisix-routes.sh` | 新增 `/api/v1/<module>/*` 路由（jwt-auth + proxy-rewrite） | ✅ 必改（见 §3.7） | ❌ 不需要 |
| 6 | `db/src/<module>/privileges/rls_policies.sql` | 新表 RLS 策略（集中清单，逐表追加） | ✅ 必改 | ✅ 必改 |
| 7 | `db/api_v1/<module>/privileges/zz_grant_all.sql` | 新视图/RPC 的 GRANT（按角色分层） | ✅ 必改 | ✅ 必改 |
| 8 | 权限点 | `has_permission` 权限码注册（`iam_menu` button 行 + `<module>:` 前缀） | ✅ 必改（管理类 RPC） | ✅ 必改 |
| 9 | `db/migrations/<module>/` | 模块独立迁移目录（见 §3.3 dbmate 方案）；`deploy-db.sh` 需支持多目录循环 | ✅ 必改 | ❌（并入 `migrations/public/`） |
| 10 | `db/tests/<module>/` | 新模块 pgTAP 测试 | ✅ 必改 | ✅ 必改 |
| 11 | CI（`.github/workflows/ci.yml`） | 无需修改（`db/migrations/**`、`db/src/**`、`db/api_v1/**`、`db/init/**`、`db/tests/**` 已覆盖新模块路径） | — | — |
| 12 | 文档 | 本页模块清单 + `repo-layout.md` 目录说明 + `architecture-overview.md` 模块划分表 | ✅ | ✅ |

---

## 3. 逐步操作

### Step 1：声明模块（apply-src.sh，最先做）

`scripts/apply-src.sh` 中两处清单**顺序即依赖方向**（后置模块可依赖前置，反之不可）：

```bash
MODULES="public <module>"              # src 模块：public（权限/基础）在前，新模块在后
API_MODULES="_shared public <module>" # API 模块：_shared（跨模块共享）置首
```

> 说明：`_shared` 是跨模块共享 API 的占位目录（当前为空）；`public` 是权限/系统管理域。新增模块追加在最后。

### Step 2：建目录骨架 + schema + 枚举

按 §1 建目录；在 `db/init/02-schemas.sql` 追加 schema 声明（形态 B）：

```sql
CREATE SCHEMA IF NOT EXISTS <module>;            -- 模块内部 schema（表/函数/RLS）
CREATE SCHEMA IF NOT EXISTS api_v1_<module>;     -- 对外暴露 schema（视图/RPC）
COMMENT ON SCHEMA <module> IS '<module> 业务域（DDD 限界上下文）';
COMMENT ON SCHEMA api_v1_<module> IS '<module> 对外 API 暴露层';
GRANT USAGE ON SCHEMA <module> TO app_owner;
GRANT USAGE ON SCHEMA api_v1_<module> TO authenticated;  -- 授权按实际角色模型
```

枚举写 `db/src/<module>/types/<name>.sql`（DO 块守卫、只增不删），因为 **bootstrap 阶段先应用 `src/*/types`**（`deploy-db.sh` 第一步），迁移依赖枚举必须先存在（依赖倒置陷阱，见 [migrations.md](migrations.md)）。

### Step 3：迁移表结构（形态 B：模块独立迁移目录）

**dbmate 多迁移目录结论（官方核实）**：dbmate **一次只支持一个 `--migrations-dir`**（配置项 `migrations_dir` 为单值；官方 [Discussion #424](https://github.com/amacneil/dbmate/discussions/424) 的"多目录合并"功能请求未实现）。多 schema 模块的可行方案：

1. **每模块独立目录 + 循环执行**：
```bash
cd db
dbmate new <module>_baseline -d migrations/<module>   # 在模块目录生成迁移
# 应用全部模块迁移（schema_migrations 表全局共享，文件名必须全局唯一）
for d in migrations/*/; do dbmate -d "$d" up; done
```
2. **文件名全局唯一**：`dbmate new` 默认生成 `<时间戳>_<名称>.sql`，天然全局唯一，跨目录不会冲突（`schema_migrations` 表按文件名记录）；**不要**用 3 位序号命名（会跨目录撞号）。
3. **部署链同步**：`scripts/deploy-db.sh` 与 `Makefile migrate` 目前是单目录（`dbmate -d migrations/public up`），形态 B 落地时需改为上面的循环（这是形态 B 唯一需要改动的部署脚本）。

写表结构 + 数据（仅表/列/约束/索引/种子；**禁止**在迁移里写函数/视图/触发器/策略——17 号铁律，`apply-src.sh` 的 §6.3 扫描会拦截）。幂等三件套：`IF NOT EXISTS` / `DO` 块守卫 / `ON CONFLICT`。

> 💡 形态 A（谨慎）时：并入 `migrations/public/`，用 3 位序号（当前 064/065/066，新文件从 067 起），无需改部署脚本。

### Step 4：写底层源码（db/src/<module>/）

- 函数：`db/src/<module>/functions/<name>.sql`，schema 为 `<module>`，幂等 `CREATE OR REPLACE`，SECURITY DEFINER 必须自校验 + `SET search_path = <module>, public, pg_temp`（模板见 [adding-api.md](adding-api.md) Step 2）；
- 触发器：`triggers/`（审计模板参考 `templates/audit_fields.sql`）；
- RLS：追加到 `db/src/<module>/privileges/rls_policies.sql`（`DROP POLICY IF EXISTS` + `CREATE POLICY` 幂等模板，`tenant_id = current_tenant_id()` 租户隔离）。

### Step 5：写对外视图/RPC（db/api_v1/<module>/）

- 视图：`views/<name>.sql`，schema `api_v1_<module>`，视图名 = 底层表名（脱敏投影）或 `v_*` 列表视图；
- RPC：`rpc/rpc_<动词>_<名词>.sql`（管理类必须 `SECURITY DEFINER` + `has_permission` 门槛）；
- 权限点：管理类 RPC 注册 `<module>:<资源>:<动作>` 权限码（`iam_menu` button 行），`has_permission` 校验。

### Step 6：GRANT（zz_grant_all.sql 集中清单）

新建 `db/api_v1/<module>/privileges/zz_grant_all.sql`，按角色分层授予（参照 `db/api_v1/public/privileges/zz_grant_all.sql` 的写法）：

```sql
-- db/api_v1/<module>/privileges/zz_grant_all.sql
GRANT SELECT ON api_v1_<module>.<view> TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_<module>.rpc_xxx(...) TO authenticated;
-- web_anon 默认无任何权限（安全第一）；需要公开的端点单独 GRANT 并注明理由
```

> ⚠️ `apply-src.sh` 的 API 模块文件排序：rpc → views → 其余（privileges 排最后），因为 `zz_grant_all.sql` 引用视图/RPC，必须先建对象再授权——脚本已显式排序（2026-08-14 实测修复），**你无需处理，但不要把 GRANT 写进 rpc/views 文件里**。

### Step 7：APISIX 路由（形态 B 必做）

在 `scripts/init-apisix-routes.sh` 第 4 段新增路由（参照现有 `api_v1_public` 写法；优先级低于 `/rpc/webhook_logto` 的 95、高于 catch_all 的 10；proxy-rewrite 把 URL 前缀映射到 PostgREST schema）：

```json
put api_v1_<module> '{"uri":"/api/v1/<module>/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":50,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/<module>/(.*)","/api_v1_<module>/$1"]},"jwt-auth":{"key_claim_name":"sub"}}}'
```

> ⚠️ 多 schema 时 PostgREST 路径带 schema 前缀（`/api_v1_<module>/...`），**rewrite 目标与单 schema 的 `/$1` 不同**——以实际 PostgREST 配置（compose `PGRST_DB_SCHEMAS` 顺序）为准。

### Step 8：测试与验证

- `db/tests/<module>/` 建 pgTAP（`make test-db` 的 `pg_prove -r tests/` 自动递归覆盖新目录，无需改 Makefile）；
- 部署链验证：`bash scripts/verify-fresh-db.sh`（全新库冷启动，apply-src 两遍幂等 + 结构比对 + pgTAP 硬门槛）；
- E2E：涉及全链路的接口追加到 `scripts/e2e-test.sh`（Logto 登录 → APISIX → PostgREST → RLS）。

---

## 4. 最小示例（新业务域 `billing`，形态 B 独立 schema）

```text
db/
├── migrations/billing/20260819xxxxxx_billing_baseline.sql   # billing schema: invoices 表
├── src/billing/
│   ├── types/billing_status.sql                            # 枚举 billing_status
│   ├── functions/billing_calc_total.sql                    # 模块函数 billing.billing_calc_total()
│   ├── privileges/rls_policies.sql                         # invoices RLS（tenant 隔离）
├── api_v1/billing/
│   ├── views/invoice.sql                                   # api_v1_billing.invoice（脱敏视图）
│   ├── rpc/rpc_create_invoice.sql                          # api_v1_billing.rpc_create_invoice
│   └── privileges/zz_grant_all.sql                         # GRANT SELECT/EXECUTE TO authenticated
└── tests/billing/01_schema_test.sql                        # pgTAP
```

配置改动（形态 B 共 8 处）：apply-src 两行 + 02-schemas 两个 schema + compose/conf 两处 + APISIX 路由一条 + rls/zz_grant_all + 权限点 + deploy-db.sh 多目录循环。

---

## 5. 交付前检查清单

- [ ] `apply-src.sh` 的 `MODULES` / `API_MODULES` 已声明（顺序 = 依赖方向）
- [ ] `02-schemas.sql` 已建 `<module>` 与 `api_v1_<module>` 两个 schema + USAGE 授权
- [ ] 枚举在 `types/`（bootstrap 前置），迁移未引用未创建对象
- [ ] 迁移目录无代码对象（§6.3 扫描通过）；文件名全局唯一（时间戳）
- [ ] `deploy-db.sh` / `Makefile migrate` 已支持多目录循环（形态 B）
- [ ] compose `PGRST_DB_SCHEMAS` / `PGRST_DB_EXTRA_SEARCH_PATH` 与 postgrest.conf 已同步
- [ ] `init-apisix-routes.sh` 已加 `/api/v1/<module>/*` 路由（rewrite 到 `/api_v1_<module>/$1`）
- [ ] RLS 已加到集中清单并 `ENABLE ROW LEVEL SECURITY`
- [ ] `zz_grant_all.sql` 已 GRANT（authenticated；web_anon 默认无权限）
- [ ] 管理类 RPC 有 `has_permission` 门槛 + 权限点已注册（`<module>:` 前缀）
- [ ] `bash scripts/apply-src.sh <url>` 全量两遍不炸
- [ ] `bash scripts/verify-fresh-db.sh` 通过（冷启动硬门槛）
- [ ] `make test-db` 通过（新模块 pgTAP 覆盖）
- [ ] 文档同步：本页模块清单、`repo-layout.md`、`architecture-overview.md` 模块划分表

---

## 6. 相关文档

- [新增一个 API 的完整流程](adding-api.md) —— 在现有模块内加视图/RPC 的逐步清单
- [目录结构](repo-layout.md) —— db/ 目录总览
- [模块划分](../04-架构/module-breakdown.md) —— 业务域归属与权威方
- [迁移指南](migrations.md) —— 迁移编号、幂等、依赖倒置
- [权限开发](permission-development.md) —— has_permission / RLS / 权限点
- [05.5-DDD 心智模型映射](../../docs/开发实施方案/05.5-DDD心智模型到零后端架构映射-视图与DTO的定位.md) —— DDD→零后端对象映射（视图=DTO、多表视图=Read Model；本文档 §0.2 补充其未覆盖的限界上下文→模块划分）
- [dbmate 官方仓库](https://github.com/amacneil/dbmate) · [多迁移目录讨论 #424](https://github.com/amacneil/dbmate/discussions/424) —— 单目录限制与方案依据
