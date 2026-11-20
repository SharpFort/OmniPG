# OmniPG 代码审查与修复——剩余未完成事项（新对话交接文档）

> **交接目的**：本文档为自包含交接件。新对话/新 Agent 无需历史上下文，按本文档即可继续。
> 生成时间：2026-11-20 · 生成者：OpenCode（GLM-5.3）编排 · 累计 7 个功能提交待推送

---

## 一、背景速览（30 秒版）

1. **阶段 1（静态审计）已完成**：OpenCodeReview（OCR 工具，`ocr` CLI）对 db/ 全部 SQL + gateway/infra/scripts 全量扫描 11 批次，**552 条发现**（critical 14 / high 134 / medium 276 / low 128）。产物：`ocr_review_summary.md`（总报告）、`ocr_security_findings.md`（安全清单，S-A~S-G 编号）、`ocr_performance_findings.md`（性能清单，P-1~P-5 编号）。原始 JSON 为本地证据（已 gitignore，不入库）。
2. **阶段 2（代码修复重构）已完成**：四批修复全部落库并经机器验收（每批 2~3 轮 `ocr review`）——提交 `83fb115`（2a 安全加固）、`2f6b395`（2b PL/pgSQL 正确性）、`7fe4045`（2c 修正迁移 075/076）、`6136bfe`（2d 网关与凭据）、`6e42204`（阶段 3 前置清单）。
3. **阶段 3（WSL3 联调）进行中**：
   - ✅ 迁移 13/13 全应用（含 075 唯一索引 NULLS NOT DISTINCT/菜单父级回填 2 行/`platform:menu:list` 种子、076 GiST(inet_ops)，`transaction:false` 在 dbmate 2.34.1 验证可用）
   - ✅ apply-src 单遍收敛 + reader owner 恢复
   - ✅ pgTAP **152/152 全过**（提交 `099e5a6` 含 casbin 断言去行序依赖修正）
   - ⚠️ e2e **15/34**——唯一根因见下节【阻塞项】

## 二、当前唯一阻塞：Logto SPA 回调 URI（等你操作）

**现象**：`/oidc/auth` 返回 400 `oidc.invalid_redirect_uri`——Logto SPA 应用 `0d4o8wb6qk9bar0egelb4` 的注册 Redirect URIs 不再包含 e2e 使用的 `http://localhost:5173/auth/callback`。登录无法建立 → 19 个依赖 TOKEN 的 e2e 用例连锁失败（15 个不依赖登录的用例全过，含 webhook HMAC 验签双用例）。
**注意**：这不是阶段 2 代码回归（Logto 应用注册属环境配置）；旧版 e2e 断言恒真，此问题可能存在已久但从未暴露。

**修复路径（三选一）**：
1. Logto Console（http://localhost:3002）→ Applications → 前端 SPA → Redirect URIs 添加 `http://localhost:5173/auth/callback`
2. 提供 `LOGTO_M2M_SECRET`（写入 gateway/.env 或对话中给出）→ 经 Management API PATCH redirectUris
3. 若前端回调地址实际已变更（非 5173/auth/callback）→ 告知正确值，改 e2e 脚本 `scripts/e2e-test.sh` 顶部 `REDIRECT_URI`

**修复后重跑**（WSL 内）：`E2E_USER=admin E2E_PASSWORD=<Logto管理员密码> bash scripts/e2e-test.sh`
重跑后重点观察（阶段 2 行为变化的首次真实验证）：
- `Menu Loaded` 断言（`length >= 1`，075 父级回填后菜单树应非空）
- `get_menu_tree_admin` 新鉴权门（`platform:menu:list` 或 menu:update/create/delete/role-menu:bind 任一）
- `search_user_positions` 无邮箱列
- security_invoker 视图（audit_log/department/cron_job_log/login_log/organizations）各登录角色行可见性
- `app_config` 视图 is_public 过滤、`v_dept_list` 租户/组织谓词

## 三、运维动作清单（你执行；S-F/S-G 编号见 ocr_security_findings.md）

| # | 动作 | 关联 |
|---|---|---|
| 1 | 轮换 **APISIX admin key**（`edd1c9f0...` 为文档公开默认值）→ 同步 gateway/.env 与 APISIX 运行时 | S-F1 |
| 2 | 轮换 **DB 密码** `admin@password` → 同步 .env.development / gateway/.env / infra userlist.txt / pigsty | S-F3 |
| 3 | 轮换 **Logto 管理员密码**（`Admin@112104` 已入仓库历史）→ 正式值写入 gateway/.env 的 `E2E_USER/E2E_PASSWORD` | S-F4 |
| 4 | `infra/redis.conf` 加 `requirepass`（建议收窄 bind；当前无密码全网可达） | S-G1 |
| 5 | `infra/userlist.txt` 改 SCRAM verifier 形态（pgbouncer ≥1.14 支持） | S-G2 |
| 6 | MaxMind key 视需要轮换（脚本已脱敏回显） | S-F6 |
| 7 | `infra/pg_hba.conf` 收窄 Docker 网段的 `all/all` 规则（按 compose 服务拆分） | S-G3 |

## 四、代码/测试跟进项（可选小批次，新对话可按此执行）

1. **pgTAP 补用例**（阶段 2 新语义零覆盖，建议优先）：
   - `current_logto_tenant_id_strict()` 三态（无 claim/无 tenant claim/有 claim）——db/tests/platform/02_function_test.sql
   - `audit_created_at()` 旁路（GUC + session_user 白名单；需 psql 以 app_owner 会话验证）
   - `rpc_create_dict_type` 重名预检（23505）
   - user_profile `WITH CHECK` 租户/组织约束（跨租户写入须拒）
2. `scripts/verify-fresh-db.sh:155-157`：casbin "预期失败 3 例"特判分支已过时（075 回填后全过）→ 清理为直接 `Result: PASS` 判定
3. `Makefile` `dev` 目标（:37）仍是 `export $(grep|xargs)` 老模式 → 同 deploy-all 的白名单键导出法
4. `scripts/phase2/init-logto.py` webhook 创建的 `config.headers` 为空 `{}`——APISIX 验签已闭环，降为加固项
5. docs/15/17 号文档的 apply-src 迁移顺序描述与新顺序（init 前置、migrations 不再重放）同步
6. **strict 租户函数"可用未接线"**：`current_logto_tenant_id_strict()` 已定义（db/src/platform/functions/current_logto_tenant_id.sql），当前仅 `write_audit_log` 采用；RLS 全面切换须等 Logto claims 注入完成后统一接线（切换点：rls_policies.sql 各谓词 + organizations/app_config 视图谓词）
7. e2e 恒真断言虽已真实化，但 `.github/workflows/deploy-all.yml:56`、`deploy-gateway.yml:74` 引用 e2e 未注入 E2E 凭据——CI 侧需补 Secrets（E2E_USER/E2E_PASSWORD/APISIX_ADMIN_KEY）
8. 调试脚本保留在 `.hermes_tmp/`（已 gitignore）：`phase3_e2e.sh`（重跑入口）、`phase3_login_debug.sh`、`phase3_auth_debug.sh`（回调修复后可复验）

## 五、阶段 4/5 规划（按原流程，未开始）

- **阶段 4 性能压测**：函数级优化归此（P-2/P-3 组：has_permission 单次解析、sargable 化、视图预聚合、pgbouncer 事务池）——用 EXPLAIN ANALYZE + k6/autocannon 压测驱动；基线采集建议先跑 `scripts/e2e-test.sh` + `EXPLAIN ANALYZE geo_locate(...)`（076 GiST 后应走索引扫描）
- **阶段 5 门禁固化**：`check-extensions.sh` 已可入 CI；OCR GitHub Action（ocr --format sarif）沉淀到 .github/workflows

## 六、新对话操作提示

- **LLM/OCR 配置已就绪**：`ocr` CLI 全局已配置 OpenCode Go `deepseek-v4.1-flash`（含 `x-opencode-session` 头，见 `~/.opencodereview/config.json`）；DeepSeek 官方条目保留为后备
- **机器验收成本实测**：全 workspace `ocr review` ≈ 27~32M tokens/轮；小批量改动用 `ocr scan --path <files>`（1~2M）更经济
- **开工顺序建议**：你修 Logto 回调（二节）→ 新对话重跑 e2e 收尾阶段 3 → 运维动作（三节）→ pgTAP 补用例（四节 1）→ 阶段 4
- **上下文文件**：本文档 + `ocr_review_summary.md` + 两份 findings 清单（含修复状态附录）即完整背景；dbmate 版本 2.34.1 已验证支持 076

---
*本文件随其余 3 份 ocr_*.md 报告一并入库；原始扫描/验收 JSON（~7.8MB）保留本地，已被 .gitignore 排除。*
