# 测试体系总览

OmniPG 的测试分为三层：**pgTAP 数据库测试**（`db/tests/`）、**E2E 集成测试**（`scripts/e2e-test.sh`）与**冒烟/验证脚本**（`scripts/verify-stack.sh`、`scripts/verify-fresh-db.sh`、`scripts/055-t1-precheck.sql`、`scripts/verify-webhook/`）。本文给出分层、入口命令、运行时机、覆盖范围与盲区；各层的详细用法见对应分册。

## 测试分层

| 层级 | 载体 | 位置 | 入口命令 | 覆盖目标 |
| --- | --- | --- | --- | --- |
| 数据库单元测试 | pgTAP | `db/tests/public/*.sql`（6 个文件，计划断言合计 115 条） | `make test-db` | 表/列/索引/外键/函数/触发器/RLS/casbin_rule 视图的存在性与基础行为 |
| E2E 集成测试 | bash + curl + jq + python3 | `scripts/e2e-test.sh` | `make test-e2e` | Logto OIDC 登录、镜像表只读保障、API 鉴权、租户 RLS 隔离、webhook 同步链路、异常恢复 |
| 冒烟/验证脚本 | bash / SQL | `scripts/verify-stack.sh`、`scripts/verify-fresh-db.sh`、`scripts/055-t1-precheck.sql`、`scripts/verify-webhook/` | 直接执行 `bash scripts/...` | 组件健康、冷启动可复现性、迁移前置核查、webhook payload 语义（历史遗留） |

## 各层入口与命令

```bash
make test       # 全部：test-db + test-e2e
make test-db    # pgTAP 数据库测试
make test-e2e   # E2E 集成测试
```

`make test-db` 实际执行（见仓库根目录 Makefile）：

```bash
cd db && pg_prove -h 127.0.0.1 -U app_owner -d app_db --ext .sql -r tests/ || true
```

> 注意：Makefile 中 `test-db` 以 `|| true` 结尾，pgTAP 失败不会让 `make` 报错，结果以 pg_prove 的 TAP 输出为准。`make test-e2e` 直接执行 `bash scripts/e2e-test.sh`，脚本退出码 = 失败用例数（0 表示全部通过）。

## 运行时机

| 场景 | 命令 | 说明 |
| --- | --- | --- |
| 本地开发 | `make test` | 先 `make dev` 起网关栈并完成数据库迁移（`make migrate`），再跑全量测试 |
| PR CI | `ci.yml` 各 job | 按变更路径过滤触发，见下方 CI 现状 |
| 网关部署 | `deploy-gateway.yml` | 部署后执行 `setup_apisix.sh` + `e2e-test.sh`，`skip_tests=true` 可跳过 |
| 发布硬门槛（文档约定） | `bash scripts/verify-fresh-db.sh` + `make test` | 迁移/部署链变更后的双闸验证（历史文档 18-迁移基线 Squash 指南，已归档；目前为人工执行，未固化到 workflow） |

### CI 现状（`.github/workflows/ci.yml`，PR 到 dev/main 触发）

| Job | 触发条件（paths-filter） | 内容 | 是否实跑测试 |
| --- | --- | --- | --- |
| `detect-changes` | 总是 | 输出 db / gateway / syncer / infra 四个变更标记 | — |
| `db-lint` | db 路径变更 | `sqlfluff lint db/migrations/ db/src/ --dialect postgres`（`|| true`，不阻断） | 否 |
| `db-migrate-test` | db 路径变更 | postgres:18 service + `dbmate up --dry-run` | 否（仅迁移 SQL 干跑） |
| `gateway-check` | gateway 路径变更 | `docker compose config --quiet` + `docker compose build` | 否 |
| `syncer-check` | `db/syncer/**` 变更 | Go build + test | 历史遗留：Go syncer 已退役（webhook 同步在库内完成），`db/syncer` 目录当前不存在，job 实际不触发 |
| `infra-check` | infra 路径变更 | yamllint 检查 3 个 pigsty yml | 否 |

结论：**CI 目前不实跑 pgTAP 与 E2E**，两者主要在本地与部署流水线中执行（盲区，见下）。

## 覆盖范围

### pgTAP（`db/tests/public/`，6 个文件）

| 文件 | 计划断言数 | 覆盖内容 |
| --- | ---: | --- |
| `01_schema_test.sql` | 64 | 表/列/索引/外键/视图/扩展存在性；`sys_*`、Casdoor 时代表已移除断言 |
| `02_function_test.sql` | 13 | sha256、`current_user_id/current_tenant_id/current_user_roles`、`update_updated_at`、`is_super_admin`、pg_pwhash 函数 |
| `03_trigger_test.sql` | 4 | 审计触发器 `trg_audit_department`、`audit_trigger_func`、`updated_at` 自动更新 |
| `05_rls_test.sql` | 12 | 关键表 RLS 启用状态；`iam_api`/`iam_role_api` 已删除（055 单表化） |
| `test_casbin_view.sql` | 8 | `casbin_rule` 视图列、ptype/v0 输出格式、is_active 过滤（其中 3 条依赖运行时绑定数据） |
| `test_rls_isolation.sql` | 14 | 镜像表存在性、RLS 策略存在性、RLS helper 函数与返回类型 |

### E2E（`scripts/e2e-test.sh`）

8 个阶段（Phase 0–7），固定用例约 33 项 + 可选/手工项 2 项：环境就绪（PostgREST/APISIX/Logto/Swagger/JWKS）、Logto OIDC 登录、镜像表只读保障、API 鉴权、JWT roles claim、租户 RLS、webhook 验签与镜像同步、异常恢复。

### 冒烟/验证脚本

- `verify-stack.sh`：10 项组件健康检查（依赖预检、网络链路、pgbouncer、PostgREST、APISIX、登录链路等）；其中 4/8/9 项与路由数 8 的校验仍指向 Casdoor 时代组件，与当前 Logto 架构不一致（见 [冒烟验证脚本](verify-scripts.md)）。
- `verify-fresh-db.sh`：8 步全新库冷启动验证（重建 scratch 库 → 建扩展 → dbmate up → apply-src 两遍幂等 → 结构比对 → pgTAP），迁移/部署链变更后的发布硬门槛。
- `055-t1-precheck.sql`：055 菜单权限单表化迁移的 T1 数据前置核查（只读，11 段）。
- `verify-webhook/`：Casdoor 时代 webhook payload/JWT 验证工具集（历史遗留，Logto 架构下由 e2e Phase 6 与 `reconcile-logto.py` 覆盖）。

## 盲区（当前未覆盖）

1. **请求级权限行为**：pgTAP 以 `app_owner` 直连数据库执行，不模拟 JWT/PostgREST 请求；权限的端到端行为只由 e2e 覆盖。
2. **前端/按钮权限**：无浏览器端（v-permission 等）自动化测试。
3. **性能基线**：历史方案中的登录耗时 / API P99 脚本未保留在仓库。
4. **CI 缺口**：`ci.yml` 未接入 `test-db` / `test-e2e`，仅做迁移干跑与 lint。
5. **验证脚本过时项**：`verify-stack.sh` 与 `deploy-gateway.yml` 仍引用 Casdoor 时代脚本/组件（见 [冒烟验证脚本](verify-scripts.md) 的 TODO）。
6. **e2e 环境依赖**：登录与同步断言依赖真实 Logto 实例、种子应用/组织/用户（`CLIENT_ID`/`ORG_ID` 等默认值），换环境需同步更新。

## 新增功能应补哪些测试

| 改动类型 | 必补测试 | 位置 |
| --- | --- | --- |
| 新表/新列/新迁移 | `has_table` / `has_column` / `fk_ok` / 索引断言 | `01_schema_test.sql`（或新编号文件） |
| 新函数（RPC/helper） | `has_function` + `is` / `lives_ok` 行为断言 | `02_function_test.sql` |
| 新触发器 | `has_trigger` + `lives_ok` | `03_trigger_test.sql` |
| 新 RLS 策略/镜像表 | `relrowsecurity` / `pg_policies` 断言 | `05_rls_test.sql`、`test_rls_isolation.sql` |
| 新菜单权限点/API 端点 | `casbin_rule` 视图断言 | `test_casbin_view.sql` |
| 新 API 视图/RPC/路由 | e2e 增加 curl 用例（Phase 3/4） | `scripts/e2e-test.sh` |
| 新 Logto webhook 事件/同步函数 | e2e Phase 6（验签 401 + 镜像数据）+ 对账 dry-run | `scripts/e2e-test.sh`、`scripts/phase2/reconcile-logto.py` |
| 迁移/部署链变更 | 冷启动 + 结构比对 + pgTAP | `bash scripts/verify-fresh-db.sh` + `make test` |

通用规则：数据库层改动先在 pgTAP 补“存在性 + 行为”断言，再在 e2e 补“请求级”用例；验证脚本只在部署结构变化（端口/路由集）时同步更新。

---

> 参考：[pgTAP 测试指南](pgtap-guide.md) · [E2E 集成测试](e2e-tests.md) · [冒烟验证脚本](verify-scripts.md) · [数据库迁移](../05-开发指南/migrations.md) · [认证与授权设计](../04-架构/auth-design.md) · [Logto Webhook 接入](../06-API参考/logto-webhook.md)