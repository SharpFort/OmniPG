# 项目简介

## 一句话定位与核心价值

**OmniPG**（Omnipotent + PostgreSQL）是一个以 **PostgreSQL 为唯一数据与逻辑核心**的"数据库即后端"应用引擎：业务数据、RPC、视图、触发器、行级安全（RLS）全部收敛在数据库内，由 **PostgREST** 自动暴露为 REST API，**APISIX** 作为统一网关入口，**Logto**（自部署 OSS）承担认证与角色/组织管理，**Pigsty** 提供 PostgreSQL 集群与周边基础设施。

核心价值：

| 价值点 | 说明 |
| --- | --- |
| 零后端服务 | 没有独立应用服务器；业务逻辑用 SQL/PL/pgSQL 表达，写路径 = 前端 → APISIX → PostgREST → SQL |
| 一次建模、全栈自动生成 | 表/视图/RPC 自动映射为 REST 接口并生成 OpenAPI 文档（Swagger UI） |
| 授权三层模型 | 前端缓存（UX）→ `has_permission()`（操作级）→ RLS（数据级），深度防御 |
| 授权路径与用户数解耦 | 角色进 JWT（`roles` claim），授权判定读 claims + 角色×权限小表，不随用户数增长 |
| 数据库即代码 | DDL/函数/视图/触发器全部进 Git，dbmate 迁移 + pgTAP 测试 + CI 门禁 |

## 解决的问题与适用场景

传统企业级后台管理系统需要为每种后端语言重复编写权限模块（用户、角色、菜单、API 鉴权、数据隔离），导致权限逻辑分散、不一致，每次权限变更都要重新部署服务。OmniPG 把这一整块收敛到 PostgreSQL 内部：

- **认证（AuthN）**：Logto 托管（登录/注册/第三方/密码策略/会话吊销），JWT 由 Logto 签发；
- **授权（AuthZ）**：判定全部在 PG——路由级 `jwt-auth`（网关）、操作级 `has_permission()`（RPC 内）、数据级 RLS（行过滤）；
- **实体同步**：Logto webhook → `rpc_webhook_logto` → 库内 `sync_*` 函数维护镜像表（用户/租户/角色/成员关系），**无独立同步服务**。

适用场景：

- 企业内部管理后台（Admin UI）的完整后端底座；
- SaaS 多租户系统：租户 = Logto Organization，RLS 按 `organization_id` 隔离；
- 需要"快速搭 API + 权限体系"的新项目（业务表建好后接口即用）。

当前代码落地规模（以 `db/` 实际 SQL 为准）：

- 表结构：`064_v010_mirror_tables.sql`（6 张 Logto 镜像表）+ `065_v010_baseline.sql`（18 张业务表），共 24 张；
- 对外暴露：`db/api_v1/` 含 `_shared` / `inventory`（空目录） / `public`（当前有效暴露代码），`public` 下 **44 个 RPC**、**29 个视图**（v0.1.0 基线，文件数核实）；
- 库内逻辑：`db/src/public/functions/` 37 个函数、10 个触发器、RLS 策略全表启用（`db/src/public/privileges/rls_policies.sql`）。

## 演进历史

| 阶段 | 架构 | 关键决策 |
| --- | --- | --- |
| 早期（casbin + casdoor） | APISIX `authz-casbin` + Go Policy Syncer sidecar（pg_notify → etcd → 网关刷新策略），Casdoor 发 JWT，`sys_*` 前缀表、自建会话/黑名单 | 业务模型视图映射 `casbin_rule`，Role-in-JWT 优化 |
| 2026-08-04（Logto 方案定稿） | Logto 承担认证 + 组织（租户）+ **角色目录与分配**；授权判定在 PG；JWT 由 Logto 签发（Custom Token Claims 脚本从 context 提取 `roles`，零 fetch） | 消灭 Go auth-service / Policy Syncer；角色同步改"JWT 权威 + 镜像 JIT 覆盖/对账"（Logto 无角色分配 webhook 事件） |
| 2026-08-05 ~ 08-12（实现收敛） | webhook 同步全部在库内（`rpc_webhook_logto` + `sync_*`）；`has_permission`（023）；`sys_` 前缀移除；Schema `api_v1_sys` → **`api_v1_public`**（027）；菜单权限单表化（055：`iam_api`/`iam_role_api` 删除，权限点内嵌 `iam_menu` 按钮行，仅剩 `iam_role_menu` 绑定表） | 授权数据收敛为"镜像（Logto 权威）+ 自主（PG 权威）"两类 |
| 2026-08-16（v0.1.0 baseline） | 历史 62 个迁移 squash 为 `064/065/066`（镜像表/业务表/种子数据）；扩展最小集定稿为 `db/init/01-extensions.sql`（pg_pwhash / pgcrypto / pg_net / pgtap） | 无 down 语义基线，历史迁移见 git tag `v0.1.0` |
| 当前（wiki 完成后收敛至 master） | 网关容器 = etcd / apisix / postgrest / swagger-ui / logto（`gateway/docker-compose.yml`）；**目标路由集 = `scripts/init-apisix-routes.sh`**（Logto 版）；⚠️ 部署链仍调用旧 `scripts/setup_apisix.sh`（Casdoor 时代残留，新旧并存待收敛，见[技术栈全景](tech-stack.md)） | wiki 文档重写阶段 |

**为什么放弃 Casdoor / Go Syncer**（依据历史 Logto 方案文档（已归档）已核实事实）：

- Casdoor webhook payload 无 `event` 字段、`object` 为 JSON 字符串，结构不可靠；`update-role` API 存在 500 风险；
- Casdoor 角色分配无可靠事件推送，需自建 Go auth-service 做 token exchange + 同步管道；
- Logto OSS 原生提供 Organizations、组织级 RBAC、Webhooks、Custom JWT Claims、终端用户 MFA，且自部署免费开放——少一个自建服务组件。

**吸收了什么**：casbin 的 RBAC 思路保留在数据库内——`casbin_rule` 视图（仅 p 规则，055 双段投影：API 段 = `role_menu → iam_menu` 按钮行端点，菜单段 = `role_menu → router`）作为授权数据的只读投影；角色→权限绑定表（`iam_role_menu`）继续承载 RBAC 语义；RLS 数据隔离是独立于网关的第二道防线。另外 `public.sys_user`（users + user_profile 投影，`password_hash` 恒 NULL——密码由 Logto 管理）与 `public.casbin_rule` 是**刻意保留的兼容视图层**，供旧接口/旧查询过渡，并非"未清理的 sys_ 残留"。

## 与 Pigsty / PostgreSQL 扩展生态的关系

- **Pigsty v4.4.0** 统一管理 PGSQL / INFRA / ETCD / REDIS / DOCKER 模块（`infra/pigsty.yml`、`infra/pigsty.db.yml`、`infra/pigsty.gateway.yml`），PostgreSQL 18 单主实例（`pg_role: primary`），pgBouncer（6432）、Redis（6379）、监控（Grafana/VictoriaMetrics）由 Pigsty 部署；
- **扩展选型**以历史扩展选型审查（23/24 号，已归档）的决策为纲，落地现状见 `db/init/01-extensions.sql`（最小依赖集）与 `infra/pigsty.yml`（扩展目录）：
  - 当前已启用最小集：`pg_pwhash`（Argon2id 密码哈希）、`pgcrypto`、`pg_net`（异步 HTTP）、`pgtap`（测试）；
  - Pigsty 集群级安装：`pg_cron`（定时任务）、`pg_graphql`（预留）；
  - 已拍板待同步：safeupdate / plpgsql_check / pg_jsonschema / omni_csv / pgmemento / pg_mockable / jsquery / index_advisor / pg_repack（24 号文档批次，`infra/pigsty.yml` 已列条目）；
  - 已退役/不启用：pgaudit（不配 GUC 不生效）、pgsodium（全项目零使用，2026-08-16 退役）、pg_smtp_client（归档）、plpython3u（不再使用）。
- ⚠️ **已知不一致（TODO，扩展侧）**：`infra/pigsty.yml` 的 `pg_extensions` 仍含 `pgaudit` / `pgsodium`，与 `db/init/01-extensions.sql` 头注释（已移除/退役）冲突，需以 01-extensions.sql 为准并同步 infra 配置。
- ⚠️ **已知不一致（TODO，网关侧）**：`scripts/setup_apisix.sh` 与 `gateway/apisix/apisix.yaml` 仍是 Casdoor 时代残留（前者仍被 `Makefile dev` / `scripts/deploy-all.sh` / `.github/workflows/deploy-gateway.yml` 调用，后者已不再加载）；目标 Logto 路由脚本 `scripts/init-apisix-routes.sh` 未被部署链引用（仅 `scripts/e2e-test.sh` 注释作为前置说明）——部署链应切换到 Logto 版路由脚本，详见 [技术栈全景](tech-stack.md)「APISIX：已知不一致/待收敛」。

## 当前版本与里程碑状态

| 里程碑 | 时间 | 状态 |
| --- | --- | --- |
| Logto 认证 + PG 授权架构定稿 | 2026-08-04 | ✅（05 文档 v2.0/v3.x 修订链） |
| 镜像表 + webhook RPC + RLS helper + `has_permission` | 2026-08-04 ~ 08-05 | ✅ |
| Schema 收敛 `api_v1_public`、菜单权限单表化（055） | 2026-08-05 ~ 08-12 | ✅ |
| **v0.1.0 squash baseline**（064/065/066） | 2026-08-16 | ✅ 当前基线 |
| P1 剩余：user_role 镜像对账、失败登录对账 | — | ⏳ 见 05 文档 P1/P2 路线图 |
| P2 备选：perms-in-JWT（Logto scope）、秒级吊销、镜像对账任务 | — | ⏳ 未实现 |

CI/CD（`.github/workflows/`）：PR 到 `dev`/`main` 触发 `ci.yml`（SQL lint、dbmate dry-run、gateway compose 校验、infra YAML lint）；`deploy-db.yml` / `deploy-gateway.yml` / `deploy-infra.yml` / `deploy-all.yml` 为 `workflow_dispatch` 手动部署（staging / production，经 SSH + `scripts/deploy-*.sh`）。⚠️ `ci.yml` 的 `syncer-check` 作业与 `scripts/deploy-gateway.sh` 的 syncer build 段为历史遗留（`db/syncer` 目录已不存在，Go syncer 已退役）。

---

> 参考：[技术栈全景](tech-stack.md) · [架构总览](../04-架构/architecture-overview.md) · [认证与授权设计](../04-架构/auth-design.md) · [部署指南总览](../03-部署指南/deployment-overview.md) · 设计决策过程见历史文档（00 号项目总纲、05 号 Logto 方案，已归档）；正文以当前代码为准。