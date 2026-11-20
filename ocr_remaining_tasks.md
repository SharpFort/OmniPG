# OmniPG 代码审查与修复——剩余未完成事项（新对话交接文档）

> **交接目的**：本文档为自包含交接件。新对话/新 Agent 无需历史上下文，按本文档即可继续。
> 生成时间：2026-11-20（同日晚：非凭据运维项/pgTAP 补齐/阶段 4 基线更新）· 生成者：OpenCode（GLM-5.3）编排 · 累计 11 个功能提交待推送

---

## 一、背景速览（30 秒版）

1. **阶段 1（静态审计）已完成**：OpenCodeReview（OCR 工具，`ocr` CLI）对 db/ 全部 SQL + gateway/infra/scripts 全量扫描 11 批次，**552 条发现**（critical 14 / high 134 / medium 276 / low 128）。产物：`ocr_review_summary.md`（总报告）、`ocr_security_findings.md`（安全清单，S-A~S-G 编号）、`ocr_performance_findings.md`（性能清单，P-1~P-5 编号）。原始 JSON 为本地证据（已 gitignore，不入库）。
2. **阶段 2（代码修复重构）已完成**：四批修复全部落库并经机器验收（每批 2~3 轮 `ocr review`）——提交 `83fb115`（2a 安全加固）、`2f6b395`（2b PL/pgSQL 正确性）、`7fe4045`（2c 修正迁移 075/076）、`6136bfe`（2d 网关与凭据）、`6e42204`（阶段 3 前置清单）。
3. **阶段 3（WSL3 联调）进行中**：
   - ✅ 迁移 13/13 全应用（含 075 唯一索引 NULLS NOT DISTINCT/菜单父级回填 2 行/`platform:menu:list` 种子、076 GiST(inet_ops)，`transaction:false` 在 dbmate 2.34.1 验证可用）
   - ✅ apply-src 单遍收敛 + reader owner 恢复
   - ✅ pgTAP **152/152 全过**（提交 `099e5a6` 含 casbin 断言去行序依赖修正）
   - ✅ e2e **34/34 全过**（2026-11-20 回调 URI 修复后收尾，提交 `27d8d30`；过程中发现并修复 Logto 只读投影写权限缺口，见二节）

## 二、已解决：Logto SPA 回调 URI + 只读投影写权限收口（2026-11-20）

**状态：✅ 已解决**——Logto Console 补回 `http://localhost:5173/auth/callback` 后 `/oidc/auth` 由 400 `oidc.invalid_redirect_uri` 恢复 303；重跑 e2e 后 19 个 TOKEN 依赖用例全部恢复。

**重跑中暴露并修复的新问题**（提交 `27d8d30`；首次真实运行才显形，旧版断言恒真时代从未执行）：
- `Users Readonly` POST `/api/v1/platform/users` 返回 500（55000）而非 4xx：`zz_grant_all.sql:80` 的 `GRANT ALL ON ALL TABLES IN SCHEMA api_v1_platform TO super_admin` 使 N4「镜像只读」对 super_admin 漏收权；且 users 是 JOIN 视图，PG 在**改写阶段**即抛 55000（早于 ACL 检查）——单纯 REVOKE 无法改变错误类型，恒映射 500。
- 修复（双层）：**077 迁移**收回六投影（users/role/tenants/tenant_role/organizations/user_tenants）全部登录角色 DML（ACL 层统一 403）+ **`reject_projection_write()` INSTEAD OF 触发器**（RAISE 42501 → PostgREST 403；`zz_readonly_guards.sql` 随 views 段每遍重放，对冲视图文件首行 `DROP VIEW ... CASCADE` 连带删触发器）。role/tenants 此前 PASS 实为基表 RLS 侥幸兜底 + payload 列不存在的 PGRST204，非设计保证。
- **机理备注**：PostgREST（14.15）schema 缓存已判定 users 不可插入（OpenAPI 仅暴露 GET）但 POST 仍放行至 PG 执行——readonly 语义必须由 DB 层保证，不能依赖网关/PostgREST 拦截。
- **遗留提醒**：Logto 管理员密码仍为旧值（本次 e2e 以旧密码登录成功）——运维清单第 3 项轮换仍未执行，gateway/.env 仍未写入 `E2E_USER/E2E_PASSWORD` 正式凭据。

## 三、运维动作清单（你执行；S-F/S-G 编号见 ocr_security_findings.md）

| # | 动作 | 关联 | 状态（2026-11-20） |
|---|---|---|---|
| 1 | 轮换 **APISIX admin key**（`edd1c9f0...` 为文档公开默认值）→ 同步 gateway/.env 与 APISIX 运行时 | S-F1 | ⏸ 凭据项押后（你指示最后做，目前随时在用） |
| 2 | 轮换 **DB 密码** `admin@password` → 同步 .env.development / gateway/.env / pgbouncer userlist（已 SCRAM 形态，轮换后经 `scripts/pgbouncer-userlist-scram.sh` 重新生成）/ pigsty | S-F3 | ⏸ 同上 |
| 3 | 轮换 **Logto 管理员密码**（`Admin@112104` 已入仓库历史且仍有效）→ 正式值写入 gateway/.env 的 `E2E_USER/E2E_PASSWORD` | S-F4 | ⏸ 同上（当前 e2e 即以旧密码跑通） |
| 4 | `infra/redis.conf` 加 `requirepass`（建议收窄 bind） | S-G1 | ✅ bind 127.0.0.1 已入库（a16a249；实测部署态本就回环监听）；requirepass 属凭据项押后 |
| 5 | `infra/userlist.txt` 改 SCRAM verifier 形态（pgbouncer ≥1.14 支持） | S-G2 | ✅ 完成（a16a249）：verifier 与库端 pg_authid 逐字节一致（passthrough 硬要求）；明文/md5 不再落地；部署期权威生成 `scripts/pgbouncer-userlist-scram.sh`；render-config.sh 改为格式 + tpl 角色集校验后复制（离线渲染 verifier 必与库端漂移）；casdoor 死条目移除（T7 退役，角色/库均不存在） |
| 6 | MaxMind key 视需要轮换（脚本已脱敏回显） | S-F6 | ⏸ 凭据项押后 |
| 7 | `infra/pg_hba.conf` 收窄 Docker 网段的 `all/all` 规则（按 compose 服务拆分） | S-G3 | ✅ 完成（a16a249）：三网段（172.17/172.20/192.168.65）角色白名单 = logto + **logto_tenant_app_db_default/_admin**（Logto 租户隔离角色）+ authenticator + app_owner（另一项目 Windows 后端池 21 conn @172.17.112.1）+ mcp_admin；postgres 超管仅本地 peer；移除 127.0.0.1/::1 md5 死规则。⚠️ 教训：首版漏租户角色 → e2e 12/34 回退（Logto 容器日志 `no pg_hba.conf entry for user "logto_tenant_app_db_default"` 定位）——连接 census 快照对短生命周期连接（Logto Prisma per-op）有盲区，白名单须按「实际架构路径」而非单点快照 |

## 四、代码/测试跟进项（可选小批次，新对话可按此执行）

1. ~~**pgTAP 补用例**（阶段 2 新语义零覆盖）~~ ✅ 完成（提交 68e68e6）：
   - ✅ `current_logto_tenant_id_strict()` 三态 + 兼容版回退对照（7 用例）
   - ✅ `audit_created_at()` 受控旁路（GUC + session_user 白名单，pg_prove 即 app_owner 会话；authenticator 反例需独立会话已文档化）（5 用例）
   - ✅ `rpc_create_dict_type` 重名预检（23505，全局字典路径不依赖 Logto 组织数据）+ 无角色权限门（42501）（3 用例）
   - ✅ user_profile `WITH CHECK` 租户/组织/本人三重拒绝 + 谓词 introspection（会话内 FORCE RLS；INSERT 拒绝路径不依赖种子行，fresh DB 兼容）（4 用例）
   - 🚨 **附带战果**：用例 18 抓出 **FOR KEY SHARE 授权断链生产 bug**——2b 批次 TOCTOU 加固要求基表 UPDATE 权限，app_owner（D25 只读）从未持有 → 带组织的档案/岗位写入（岗位分配等核心管理流）生产全断（e2e 只读不写从未暴露）。修复走 **locker 方案**（68e68e6）：`logto_locker`（NOLOGIN+BYPASSRLS）独占 `organization_user_relations` 的 SELECT/UPDATE，`check_user_org_membership()` DEFINER 函数收敛行锁——app_owner 本体仍无 Logto 表写权，D25 边界保持；冷库 psql \gset+\if 条件创建 + 无锁 EXISTS 回退（apply-src 单遍契约不破）
   - 验收：**pgTAP 171/171**（152 既有 + 19 新增零回归）
2. ~~`scripts/verify-fresh-db.sh:155-157`：casbin "预期失败 3 例"特判分支已过时~~ ✅ 完成（77ecb65）：收敛为 `Result: PASS` 直判
3. ~~`Makefile` `dev` 目标（:37）仍是 `export $(grep|xargs)` 老模式~~ ✅ 完成（77ecb65）：改白名单键导出（仅 init-apisix-routes.sh 消费的 4 键），对齐批次 2d 契约
4. `scripts/phase2/init-logto.py` webhook 创建的 `config.headers` 为空 `{}`——APISIX 验签已闭环，降为加固项
5. docs/15/17 号文档的 apply-src 迁移顺序描述与新顺序（init 前置、migrations 不再重放）同步
6. **strict 租户函数"可用未接线"**：`current_logto_tenant_id_strict()` 已定义（db/src/platform/functions/current_logto_tenant_id.sql），当前仅 `write_audit_log` 采用；RLS 全面切换须等 Logto claims 注入完成后统一接线（切换点：rls_policies.sql 各谓词 + organizations/app_config 视图谓词）
7. e2e 恒真断言虽已真实化，但 `.github/workflows/deploy-all.yml:56`、`deploy-gateway.yml:74` 引用 e2e 未注入 E2E 凭据——CI 侧需补 Secrets（E2E_USER/E2E_PASSWORD/APISIX_ADMIN_KEY）
8. 调试脚本（`.hermes_tmp/`，已 gitignore）：`loadtest.mjs` + `stage4_http_baseline.sh`（阶段 4 压测基线复跑入口）、`probe_users_write.sh`（登录 + 投影写探测复验——077/触发器行为回归时一键复验）、`pgbouncer-userlist-scram.sh`（已转正入库 scripts/）、其余 SQL 探针（verify_077/grant_probe/role_probe/auth_probe/logto_grants/conn_census 等）

## 五、阶段 4/5 规划（阶段 4 已启动：基线采集完成，2026-11-20）

- **阶段 4 基线实测（WSL 环境）**：
  - **P-2a 结构性验证 ✅**：`EXPLAIN (ANALYZE, BUFFERS)` 确认 `network >>= cidr` 走 `Bitmap Index Scan on idx_ip_geolite2_city_network_gist`——076 修复达成目的（修复前为 Seq Scan）。⚠️ `ip_geolite2_city` 与 `ip_region_v4` **均 0 行**（数据从未导入）——GeoLite2 ~300 万行的真实定量收益待导入后复测（MaxMind key 属凭据项）
  - **P-2d**：`has_permission` 全路径（role_admin）均耗 ~1.4μs/次、超管短路 ~0.86μs——热缓存小表下绝对成本可忽略；RLS per-row 放大场景待大表复测
  - **HTTP 基线**（`role?select=...&limit=5`，真实 admin token，keep-alive）：
    | 链路 | 并发 | QPS | p50 | p90 | p99 |
    |---|---|---|---|---|---|
    | 直连 PostgREST 3100 | 5 | 250 | 14.8ms | 53.2ms | 65.8ms |
    | 直连 PostgREST 3100 | 50 | 204 | 177.6ms | 502.6ms | 1016ms |
    | 全链路 APISIX 9080 | 5 | 125 | 29.4ms | 73.0ms | 153.9ms |
    | 全链路 APISIX 9080 | 50 | 168 | 269.2ms | 331.1ms | 1150ms |
  - **瓶颈定位**：并发 5→50 QPS 不升反降 = **双重连接池排队主导**（PostgREST 池 10 + pgbouncer `pool_mode=session` 池 20+5，50 并发大量排队）；APISIX 层增量 ~15ms/请求（jwt-auth 验签 + 转发）
  - **✅ 事务池实验完成并转正（同日晚，提交见下方）**：pgbouncer `pool_mode=transaction` + `max_prepared_statements=200`（1.25 协议级跟踪），PostgREST `PGRST_DB_POOL=20` + `PGRST_DB_CHANNEL=""`（LISTEN 会话级特性弃用）。同口径复测：
    | 链路 | 并发 | session 基线 | transaction | 收益 |
    |---|---|---|---|---|
    | 直连 PostgREST 3100 | 5 | 250 QPS / p90 53.2ms | 280 QPS / p90 25.3ms | +12% QPS，p90 减半 |
    | 直连 PostgREST 3100 | 50 | 204 QPS / p50 177.6ms / p99 1016ms | **318 QPS / p50 132.0ms / p99 481ms** | **+56% QPS，p99 减半** |
    | 全链路 APISIX 9080 | 50 | 168 QPS / p99 1150ms | 200 QPS / p99 668ms | +19% QPS，p99 -42% |
    功能门禁：e2e 34/34（SET LOCAL claims/ROLE 事务池语义完好）；死别名 logto/casdoor 已清（库不存在）。**残余瓶颈**：p50@50 仍 132ms = PostgREST 20 池槽排队 + CPU 混合（8 核 WSL 与 Windows 共享）——下一个杠杆是 P-2/P-3 函数级优化（降低每请求 CPU/耗时）与池槽再调参
  - 压测工具：`.hermes_tmp/loadtest.mjs`（node 24 零依赖）+ `stage4_http_baseline.sh`（登录 + 双链路跑批入口，gitignored）；k6/autocannon WSL 未装，需要时 npx 引入或固化脚本入库
- **阶段 5 门禁固化**：`check-extensions.sh` 已可入 CI；OCR GitHub Action（ocr --format sarif）沉淀到 .github/workflows

## 六、新对话操作提示

- **LLM/OCR 配置已就绪**：`ocr` CLI 全局已配置 OpenCode Go `deepseek-v4.1-flash`（含 `x-opencode-session` 头，见 `~/.opencodereview/config.json`）；DeepSeek 官方条目保留为后备
- **机器验收成本实测**：全 workspace `ocr review` ≈ 27~32M tokens/轮；小批量改动用 `ocr scan --path <files>`（1~2M）更经济
- **开工顺序建议**：~~修 Logto 回调~~ ✅ → ~~e2e 收尾阶段 3~~ ✅（34/34）→ ~~非凭据运维项~~ ✅（S-G1 bind / S-G2 SCRAM / S-G3 白名单）→ ~~pgTAP 补用例~~ ✅（171/171 + FOR KEY SHARE 断链修复）→ ~~四节 2/3 跟进~~ ✅ → ~~pgbouncer 事务池实验~~ ✅（+56% QPS / p99 减半，e2e 34/34）→ **阶段 4 P-2/P-3 函数级优化**（池结构瓶颈已解，压测驱动逐项验证）→ 凭据轮换批（三节 1/2/3/6，你指示最后做）→ 阶段 5 门禁固化
- **上下文文件**：本文档 + `ocr_review_summary.md` + 两份 findings 清单（含修复状态附录）即完整背景；dbmate 版本 2.34.1 已验证支持 076

---
*本文件随其余 3 份 ocr_*.md 报告一并入库；原始扫描/验收 JSON（~7.8MB）保留本地，已被 .gitignore 排除。*
