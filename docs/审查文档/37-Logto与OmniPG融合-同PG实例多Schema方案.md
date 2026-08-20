# 37 Logto 与 OmniPG 融合（同 PG 实例多 Schema 方案）评估与实施规划

> **状态**：✅ 已评审，待开发（2026-08-20）
> **决策人**：项目负责人（本文件 §1 四项拍板）
> **分析**：基于仓库代码逐文件核对（镜像表 / webhook 链路 / RLS / 授权函数 / infra 配置 / 部署脚本）
> **前置文档**：`docs/开发实施方案/05-Logto认证与权限架构-完善版.md`、`docs/开发实施方案/06-Logto迁移-开发路线与验收清单.md`、`docs/审查文档/33-Logto镜像表同步与对账审查清单.md`
> **待评估方案**：《Logto 与 OmniPG 融合架构设计规格说明书（同 PG 实例多 Schema 模式）》（下称"规格书"）
> **开发分支**：开发启动时从主干切 `feature/logto-schema-merge`（本次仅文档，未建分支、未改代码）

---

## 1. 决策记录（2026-08-20 用户拍板）

| # | 决策点 | 拍板结论 | 影响 |
|---|---|---|---|
| D1 | 落地口径 | **务实变体**：业务表留在 `public`，仅新增 `logto` schema 承载 Logto 表；不迁移业务表到 `omnipg` schema | 隔离目标达成，工程量较"严格按规格书"降低一个数量级（111 个 `public.` 限定 SQL / 59 处 `SET search_path` 无需改动） |
| D2 | 镜像表退役节奏 | **双轨过渡**：先建 logto 直读安全视图，与镜像表对拍验证一致后，再退役 5 张镜像表与 sync_* 链路 | 可回滚；对拍期需保留镜像表与 sync_* |
| D3 | 文档先行 | 立即创建本文档，作为开发阶段唯一实施依据 | 本文件 |
| D4 | Logto 版本 | **维持 `latest`**（不固定 tag） | 接受 schema 漂移风险；缓解措施 = §6 阶段 1 新增"Logto 升级回归门"（升级后必须跑通 seed 幂等 + 视图对拍 + e2e），禁止绕过 |

---

## 2. 现状核对（代码级事实）

### 2.1 数据库与连接

| 项 | 现状 | 位置 |
|---|---|---|
| 数据库 | 同 PG 实例（Pigsty 单集群 pg_omnipg @127.0.0.1）**两个库**：`app_db`（业务）+ `logto`（Logto 专用） | `infra/pigsty.yml` pg_databases |
| 业务连接 | PostgREST 经 pgBouncer 6432 → app_db（authenticator 角色） | `infra/pgbouncer.ini`、`gateway/docker-compose.yml` |
| Logto 连接 | 容器直连 `host.docker.internal:5433/logto`（**不经 pgbouncer**） | `gateway/docker-compose.yml` logto 服务 |
| ⚠️ 不一致 | compose 用 **5433**，pigsty.yml 单实例实际为 **5432**（5433 为 Docker PG 时代的旧映射，docs/审查文档/22 已移除） | 合并时一并收敛 |

### 2.2 镜像与同步链路

- **6 张镜像表**（`public` schema，text id = Logto nanoid）：`users / tenants / user_tenants / role / organization_role / user_role`。
  - 业务表 FK 依赖：`user_profile.user_id → users CASCADE`、`user_position.user_id → users CASCADE`、`user_tenants.* → users/tenants CASCADE`、`user_role.* → users/role CASCADE`、`user_profile.tenant_id → tenants RESTRICT`。
  - `iam_role_menu(role_code text, menu_id uuid)`：**按角色名绑定，无 FK**（role_code = 镜像 `role.name`）。
  - 位置：`db/migrations/public/064_v010_mirror_tables.sql`、`065_v010_baseline.sql`。
- **同步链路**：Logto webhook → APISIX HMAC 验签 → PostgREST `POST /rpc/webhook_logto`（web_anon）→ `sync_*`（SECURITY DEFINER）→ 镜像表。订阅 15 事件；事件落 `webhook_event_log`（received/success/error/ignored）+ 重放 RPC。
  - 位置：`db/api_v1/public/rpc/rpc_webhook_logto.sql`、`db/src/public/functions/sync_*.sql`（15 个）、`scripts/phase2/init-logto.py`。
- **兜底链路**：登录 JIT `ensure_user`（补建 users/user_profile + user_role 分段增量对齐）+ 每日对账 `scripts/phase2/reconcile-logto.py`（Management API 全量 → sync_*）。

### 2.3 授权判定路径（融合后零改动）

- JWT claims（`roles` 角色名数组 + `global_roles` / `org_roles` + `pg_role`）→ PostgREST 角色 → RLS / `has_permission`。
- `get_user_menu`：`iam_role_menu.role_code IN (claims roles)` → 菜单树；`current_user_roles / is_super_admin` 纯 claims 解析。
- **授权判定不读镜像表** —— 这是融合方案最大的兼容性基础。
- 位置：`db/src/public/functions/get_user_menu.sql`、`current_user_roles.sql`、`is_super_admin.sql`、`db/src/public/privileges/rls_policies.sql`、`scripts/phase2/init-logto.py` CLAIMS_SCRIPT。

### 2.4 暴露层

- PostgREST 仅暴露 `api_v1_public`（29 视图 + 44 RPC），extra search path = `api_v1_public,public`。
- 视图"名 = 底层表名"规则（027 定稿）：`api_v1_public.users / role / organization_role / user_tenants` 等直接投影镜像表。

---

## 3. 目标架构（务实变体）

```
                 [ PostgreSQL 实例 · 数据库 app_db ]
┌──────────────────────────────────────────────────────────────┐
│  Schema: logto                        Schema: public          │
│  (Logto 服务独占，仅 app_owner 只读)    (OmniPG 业务表原位保留)  │
│  logto.users          ◄── 安全视图 ──   api_v1_public.*        │
│  logto.roles          ◄── SECURITY    iam_menu / iam_role_menu│
│  logto.organizations     BARRIER      user_profile / …        │
│  …(Logto 全表)                            │                   │
└───────────────────────┬────────────────┼──────────────────────┘
                        │ DB_URL         │
                 ┌──────┴──────┐   ┌─────┴──────┐
                 │ Logto 服务  │   │ PostgREST  │
                 └─────────────┘   └────────────┘
```

要点：

1. **Logto 表**从独立库迁入 `app_db` 的 `logto` schema（一次性 pg_dump/恢复 + 后续 search_path 收敛）。
2. **OmniPG 业务表原地不动**（public），`api_v1_public` 视图换源为 logto 安全视图。
3. 镜像表退役顺序：`role / organization_role / tenants / users / user_tenants`（对拍后），`user_role` 视 D5 决策（§9）处理。
4. 授权判定、菜单绑定、RLS 主体不变；webhook 保留 `PostSignIn`（登录日志）。

---

## 4. 可行性结论与关键前提（Spike 项）

**结论：技术可行，方向合理；最大不确定性在"Logto 是否支持把表建进非 public schema"。**

### 4.1 必须 Spike 验证（阶段 0，不动业务代码）

| # | 验证项 | 依据 | 影响 |
|---|---|---|---|
| S1 | Logto 对 `search_path` 的管理行为：是否显式 `SET search_path`、pool 是否透传连接串参数 | Logto 源码有 "explicitly set search path" 类改动（[PR #6101](https://github.com/logto-io/logto/pull/6101) 佐证）；[数据库结构/多租户设计](https://deepwiki.com/logto-io/logto/2.4-cloud-features-and-tenant-management) | 决定采用 `ALTER ROLE logto SET search_path` / 连接串 `options` 参数 / 迁后维护模式的哪一条路径 |
| S2 | `db seed`（`npm run cli db seed -- --swe`）与启动期 alteration 是否与运行时同连接配置 | [Database alteration 文档](https://docs.logto.io/logto-oss/using-cli/database-alteration)；`gateway/docker-compose.yml` entrypoint | 决定迁移与升级路径是否自动落 schema |
| S3 | Logto 表名/列名精确清单（`users / roles / users_roles / organizations / organization_roles / organization_users …`，以 `packages/schemas/tables` 为准）与 `tenant_id` 列语义 | DeepWiki 多租户/表管理；仓库 `064` 镜像列清单为近似 | 视图映射、外键类型、tenant_id 过滤 |
| S4 | node-postgres `pg-connection-string` 对 `options` 参数的透传（本地 node 验证，无需网络） | 规格书步骤 2 的机制 | 连接串方案可行性 |
| S5 | Logto 所需扩展是否已覆盖（pgcrypto 等） | 同库后扩展库级共享；app_db 已装 pgcrypto/pg_net/pgtap 等 | 搬迁前置 |

### 4.2 规格书五步落地路径逐条评审结论

| 规格书步骤 | 评审 | 结论 |
|---|---|---|
| 1. 建 logto/omnipg 两 schema | 跨 schema 成熟能力；前置 = Logto 数据跨库搬迁（pg_dump/恢复） | ✅ 可行（omnipg schema 在务实变体下退化为视图容器或省略） |
| 2. Logto DB_URL 指向主实例 | **最大风险点**；Logto 显式管理 search_path 的行为决定机制 | ⚠️ 依赖 §4.1 S1/S2 |
| 3. GRANT SELECT | 应授 `app_owner`（DEFINER 侧）而非 authenticated；必须列级授权或安全视图隔离密码散列；全查询过滤 tenant_id | ⚠️ 可行，需收窄 |
| 4. 视图映射 | 与仓库既有"视图 = 暴露层"模式契合；29 视图联动换源，工作量集中在 api_v1_public | ✅ 可行 |
| 5. RPC 查询构建 | 授权链路（claims）零改动；`iam_role_menu` 按 role_code 继续成立；可退役 sync_* 与镜像 | ✅ 可行，收益最大 |

---

## 5. 改造清单（文件级）

### 5.1 infra / gateway

| 文件 | 改动 |
|---|---|
| `infra/pigsty.yml`、`infra/pigsty.yml.tpl` | `logto` 库声明改为 schema 方案（或删除库声明 + 新增 schema owner 角色）；`logto` 用户 `search_path` 收敛；顺带修正 5433/5432 不一致（统一直连 5432 或按实际拓扑声明） |
| `infra/pgbouncer.ini` | 清理 `casdoor` 残留（顺带） |
| `gateway/docker-compose.yml` | Logto `DB_URL` → 单库 + schema 机制（阶段 0 结论落地）；端口统一；entrypoint 保持不变（seed 幂等） |

### 5.2 db（新迁移，编号待定，建议 `067_logto_schema_merge.sql` 起）

| 文件 | 改动 |
|---|---|
| 新迁移 | 建 `logto` schema；迁入 Logto 数据（pg_dump/恢复产物）；列级授权；`ALTER ROLE logto SET search_path`（按 S1 结论） |
| 新迁移 | 建安全视图：`logto` 只读投影（过滤 tenant_id、排除敏感列） |
| `db/api_v1/public/views/users.sql` 等（29 个联动） | 数据源镜像表 → logto 安全视图；`v_user_list / v_user_roles / v_role_users / v_role_menu_detail / casbin_rule / iam_role_menu` 等同步换源 |
| `db/src/public/privileges/rls_policies.sql` | 镜像表 RLS 退役（对拍完成后）；视图层补 tenant_id 过滤（owner 视图绕过 RLS，需显式实现） |
| `db/src/public/functions/sync_*.sql`（15 个） | 退役（对拍完成后） |
| `db/api_v1/public/rpc/rpc_webhook_logto.sql` | 删除数据事件分支，**保留 PostSignIn → login_log** |
| `db/api_v1/public/rpc/rpc_ensure_user.sql` | 删 users / user_role 镜像写入段；保留 user_profile 兜底（校验 logto 侧存在性改为 SELECT） |
| `db/migrations/public/064/065` 中镜像表与 FK | 双轨期保留；退役期按 D5（§9）执行级联清理并调整业务 FK 目标 |

### 5.3 scripts / docs

| 文件 | 改动 |
|---|---|
| `scripts/phase2/reconcile-logto.py` | 主体退役或缩减为登录日志对账；双轨期保留用于对拍 |
| `scripts/phase2/init-logto.py` | 基本不动（webhook 订阅减至 PostSignIn 后可裁剪 events 清单） |
| `docs/开发实施方案/05/06`、`docs/审查文档/33`、`wiki/*` | 架构图、数据流、同步链路章节改写 |

---

## 6. 分阶段实施路线（每阶段含验收门）

| 阶段 | 内容 | 验收门 |
|---|---|---|
| **0. Spike** | §4.1 S1-S5 验证；产出机制结论 | 结论文档 + 最小 PGlite/真实库实验通过 |
| **1. 基础设施合并** | logto 数据迁入 schema；DB_URL 重指；**Logto 升级回归门**（升级后 seed 幂等 + Console 登录 + OIDC discovery） | 回归门通过；镜像链路不受影响（双轨未动） |
| **2. 双轨只读接入** | 建 logto 安全视图 → 改 api_v1_public 视图换源 → 镜像表与直读视图**对拍**（复用 PGlite/测试基建） | 对拍零差异；RLS/权限回归全绿 |
| **3. 退役镜像** | 删 5 张镜像表 + sync_* + webhook 数据分支 + reconcile 主体；FK 调整（user_profile/user_position 改指新目标）；RLS 迁移 | e2e 全绿；管理端用户/角色/租户/成员页数据一致 |
| **4. 菜单绑定落位** | `iam_role_menu` role_id 跨 schema FK（可选）或维持 role_code；`get_user_menu` 联动验证 | 菜单/权限回归全绿 |
| **5. 收尾** | 单库备份（PITR）策略、文档、e2e、灰度 | 上线检查单通过 |

> D4 缓解：因 Logto 维持 `latest`，阶段 1 的"升级回归门"在每次镜像更新后强制执行（seed 幂等 + 视图对拍 + e2e），任何一步失败禁止推进阶段 2。

---

## 7. 风险登记册

| 风险 | 等级 | 缓解 |
|---|---|---|
| Logto search_path 不支持（S1 不通过） | P0 | 采用"public 建表 + ALTER SET SCHEMA + 包装层跟随 alteration"维护模式（成本高，需重新评估）；或在保持双库前提下仅做视图联邦（本方案降级） |
| Logto `latest` 升级漂移（D4 未固定版本） | P1 | 阶段 1 升级回归门；视图隔离（规格书原则 2）；升级演练纳入发布流程 |
| 同库故障域耦合（Logto 迁移/锁影响业务库） | P1 | 低峰窗口执行；alteration 在测试环境全量演练；pgBouncer/直连分离保持 |
| 敏感列暴露（logto.users.password_encrypted 等） | P0 | 列级授权 / SECURITY BARRIER 视图；仅 app_owner 可读；禁止授 authenticated |
| tenant_id 未过滤导致跨租户数据串 | P0 | 安全视图强制过滤默认租户；对拍脚本含租户隔离断言 |
| 一次性搬迁窗口（跨库 pg_dump/恢复） | P1 | 停机窗口 + 备份回滚预案（保留 logto 库快照至验收通过） |
| 5433/5432 不一致遗留 | P2 | 阶段 1 统一收敛 |

---

## 8. 待办（双轨期跟踪）

- [ ] 阶段 0 Spike 立项（S1-S5）
- [ ] 双轨对拍脚本设计（镜像表 vs logto 视图，含 tenant_id 断言）
- [ ] Logto 表名/列名清单导出（S3 产出物，作为视图映射基线）

---

## 9. 遗留决策点（开发前确认）

| # | 决策点 | 建议 |
|---|---|---|
| D5 | `user_role` 镜像表（用户↔角色分配，admin 展示用）：保留轻量镜像 vs 改 logto.users_roles 直读视图 | 改直读视图（JWT 授权不变；admin 展示零延迟）；注意 Logto 无分配事件，直读天然解决 33 号审查的"唯一权威通道"问题 |
| D6 | `login_log` 数据源：保留 PostSignIn webhook vs 直读 Logto logs 表 | 保留 webhook（Logto logs 表结构不稳定、含交互明细，耦合更深） |
| D7 | `webhook_event_log` / 重放 RPC 去留 | PostSignIn 保留时建议保留（可观测 + 重放兜底） |
| D8 | `omnipg` schema 是否创建 | 务实变体下可省略；如需落规格书命名，仅作视图/RPC 容器（不迁业务表） |

---

## 10. 参考

- 《Logto 与 OmniPG 融合架构设计规格说明书（同 PG 实例多 Schema 模式）》（待评审方案原文）
- [Logto PR #6101（schemas: explicitly set search path 相关）](https://github.com/logto-io/logto/pull/6101)
- [DeepWiki: logto-io/logto — Database and Schema Management](https://deepwiki.com/logto-io/logto/2.4-cloud-features-and-tenant-management)
- [Logto Docs: Database alteration](https://docs.logto.io/logto-oss/using-cli/database-alteration)
- 仓库：`docs/开发实施方案/05`、`06`；`docs/审查文档/33`；`db/migrations/public/064/065`；`gateway/docker-compose.yml`；`infra/pigsty.yml`
