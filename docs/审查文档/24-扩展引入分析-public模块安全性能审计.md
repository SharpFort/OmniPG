# 24-扩展引入分析：public 模块（安全/性能/审计）15 扩展 × 现有代码映射

> **状态**：✅ **用户已拍板（2026-08-05）**——最终决策见 §五；安装批次见 §六
> ⚠️ **035 修订（2026-08-07）**：`omni_csv` 由「P0 必装」降级为「**暂不引入**」——原 P0 理由（修复 `export_csv` 半成品）随 `export_csv` 删除而消失（035：导出 = `GET /api_v1_public/{view}?select=...` 原生能力，前端拼 CSV；`import_csv` 保留 JSON 数组入口并安全重写，无需 SQL 内 CSV 解析）。官方能力已核实（`csv_info`/`parse`/`csv_agg` 三件套，`csv_agg` 即序列化），待「前端直传 CSV 文件」需求出现再装。
> **范围**：用户圈定 15 个扩展（citext / pgjwt / pgauditlogtofile / pgmemento / temporal_tables / table_log / plpgsql_check / pg_mockable / safeupdate / pg_jsonschema / jsquery / index_advisor / pg_repack / omni_csv / count_distinct），对照 `05.4-权限校验三层模型.md`、`05.2-Admin管理模块函数视图补全分析.md` 与 public 模块现有代码，判定每个扩展**能替代/优化哪些现有实现**。
> **代码勘察范围**：`db/api_v1/public/rpc/*`（16 个 RPC）、`db/src/sys/functions/*`、`db/migrations/sys/019/023/024/029`、`009_logto_mirror`、`010_logto_webhook`、`infra/pigsty.yml`。
> **官方依据**：pigsty.cc/ext/e/{safeupdate,jsquery,pgaudit}/ 详情页 + 三个扩展官方 README（2026-08-05 抓取）。

---

## 一、public 模块现状速览

| 能力域 | 现状实现 | 文件 |
|:---|:---|:---|
| 操作级权限 | `has_permission(code)`：超管短路 + claims roles ∩ iam_role_api→iam_api.api_code | 023 §3 |
| 权限门槛 | 29 个 RPC 均带 has_permission（029 补 4 个旧 DEFINER 写/管理 RPC） | 024/025/029 |
| 数据级隔离 | RLS 全表策略（租户/全局/超管豁免） | 017/019/023/024 |
| 审计（差异） | `audit_trigger_func()` + `write_audit_log()` → audit_log 单表，**11 个触发器** | src/sys + 023 §4 |
| 审计（操作） | `log_operate()` → audit_log（log_type='operate'） | 024 §1 |
| 审计查询 | `search_audit_log`（old_data/new_data::text ILIKE 全文匹配）、`get_audit_log_timeline` | rpc/*.sql |
| CSV 导入 | `import_csv(p_table_name, p_data jsonb, p_dry_run)`——接收 JSON 数组，逐条动态 INSERT | rpc_import_csv.sql（029 已补 sys:import） |
| CSV 导出 | `export_csv(...)`——**返回提示文本而非 CSV 数据**（半成品） | rpc_export_csv.sql（029 已补 sys:export） |
| 配置管理 | `update_config(p_key, p_value text)`——**无类型校验** | rpc_update_config.sql（029 已补 sys:config:write） |
| 用户搜索 | `search_users`：username/email ILIKE 模糊匹配 | rpc_search_users.sql |
| 认证验签 | **APISIX 验签 + Logto JWKS**，PG 内信任 `request.jwt.claims` | 010 注释、05.4 文档 |
| 已装扩展 | pgcrypto / pgsodium / pg_net / **pgaudit** / pgtap / pg_graphql / pg_cron | infra/pigsty.yml |

---

## 二、逐扩展分析（15 个）

### A. 安全类

#### A1. citext —— 🟡 P2 可选（镜像表收益有限）

| 项 | 结论 |
|:---|:---|
| 现有代码 | `users.primary_email varchar(255)`（009 镜像表）；`search_users` 已用 ILIKE（大小写不敏感已满足） |
| 扩展能力 | 大小写不敏感字符串类型（唯一约束/等值比较自动忽略大小写） |
| 可优化点 | ① users.primary_email 唯一约束改大小写不敏感；② 等值查询免写 lower() |
| **关键判断** | users 是 Logto 镜像表——唯一性由 Logto 权威保证，PG 侧只是防御；改列类型需同步 009 迁移与 sync 函数，收益有限 |
| **决策** | **P2 可选**（暂不装，未来若做业务表 email 校验再评估） |

#### A2. pgjwt —— ❌ P3 不引入（职责重复）

| 项 | 结论 |
|:---|:---|
| 现有代码 | APISIX jwt-auth（Logto JWKS 验签）→ 注入 `request.jwt.claims` → PG 内直接消费 claims，**PG 内无验签需求** |
| **关键判断** | 05.4 已定稿"验签在网关、授权在 PG"。PG 内验签仅"绕过网关直连 PG 端口"场景有价值，生产链路被 APISIX 强制 |
| **决策** | **P3 不引入**（记录在案，未来开放直连端口再评估） |

#### A3. pgaudit + pgauditlogtofile —— 🟢 P1 启用（已装未启用！）

| 项 | 结论 |
|:---|:---|
| 现状核查 | **pgaudit 已在 `infra/pigsty.yml` 的 pg_extensions + pg_databases.extensions 中（扩展已安装），但全仓无任何 `pgaudit.*` GUC 配置 → 装了但审计功能未启用**（pgaudit 默认不记录任何语句） |
| 官方定位 | pgAudit README："provides detailed session and/or object audit logging via the standard PostgreSQL logging facility"，目标："comply with government, financial, or ISO certifications"——**SQL 语句级审计，写日志文件** |
| 与现有 audit_log 的关系 | **互补，不替代**：<br>① pgaudit = SQL 级（谁执行了什么 SQL/DDL，写日志文件，**应用无法篡改**）→ 合规取证；<br>② audit_log 表 = 业务级（old/new 数据差异、module/action 操作事件，可查询可展示）→ 业务追踪；<br>③ pgaudit 覆盖"绕过 RPC 直连 SQL"盲区；audit_log 覆盖"业务可读可查"需求 |
| 落地改动 | ① `infra/pigsty.yml` 加 GUC：`pgaudit.log = write, ddl, role`（或 object audit 精确到表）→ 重启；② 可选加装 pgauditlogtofile（审计日志独立文件，便于归档采集） |
| 风险 | 低-中；日志量控制（先 role/write 子集，勿开 all）；与 audit_log 表体系并存无冲突 |
| **决策** | **P1 启用**——补 GUC 配置激活已装的 pgaudit；pgauditlogtofile 一并装（审计文件独立） |

#### A4. safeupdate —— 🟢 P0 全局安装（用户拍板）

| 项 | 结论 |
|:---|:---|
| 官方 README（已核实） | ① `UPDATE/DELETE` 无 WHERE 直接报错 `ERROR: UPDATE requires a WHERE clause`；② **CTE 内修改同样被阻止**（`WITH updates AS (UPDATE ... RETURNING *) SELECT * FROM updates` 报错）；③ 官方明示设计初衷："initially designed to protect data from accidental obliteration of data that is writable by **PostgREST**"——**与本项目 PostgREST 直写场景完全吻合**；④ 管理员可临时禁用：`SET safeupdate.enabled = 0;` |
| 现有代码 | 所有写路径经 RPC + has_permission + RLS；误删风险在运维/直连 psql 场景 |
| 可优化点 | 防 `UPDATE users SET ...`（无 WHERE 全表更新）；防 PostgREST 意外全表 DELETE |
| 落地改动 | ① pigsty.yml `shared_preload_libraries` 加 safeupdate（**重启**）；② 全局扫描 db/ 确认无 WHERE-less 的 UPDATE/DELETE（排查后再装）；③ 运维手册记录 `SET safeupdate.enabled=0` 逃生通道 |
| 风险 | 中→可控；需先排查现有 RPC/触发器/迁移中是否有无 WHERE 语句（如 cleanup 类操作）；迁移脚本重放时若含无 WHERE 语句会被拦（好事，暴露隐患） |
| **决策** | **P0 全局安装**（用户拍板）——装前先做全库 WHERE 排查 |

---

### B. 审计类（pgmemento 入选，temporal_tables / table_log 不引入）

#### B1. pgmemento —— 🟢 P1 先行试点（用户拍板）

| 项 | 结论 |
|:---|:---|
| 现有代码 | audit_trigger_func + write_audit_log：每次变更记 old/new jsonb（11 表）；无"时间旅行"查询能力 |
| 扩展能力 | 事务级审计 + **时间旅行查询**（query_as_of / query_between）+ 模式版本管理 |
| 可优化点 | 补现有方案缺的能力：任意时刻数据回溯（admin 误改恢复、审计"当时看到的数据"） |
| 落地改动 | 安装 + 试点表（department / position / dict_type / dict_data）执行 `audit_table()`；现有 audit_log 体系**不动**；新增 `rpc_get_history(p_table, p_id)` 封装 |
| 风险 | 中；双轨审计增加存储；试点表先跑通再扩 |
| **决策** | **P1 试点**（用户拍板）——department/position/dict 四表先行 |

#### B2. temporal_tables —— ❌ P3 不引入（与 pgmemento 重叠）

| 项 | 结论 |
|:---|:---|
| 关键判断 | 需改表结构（加系统周期列），迁移成本高于 pgmemento（后者不改业务表）；时间旅行能力与 pgmemento 重叠 |

#### B3. table_log —— ❌ P3 不引入（与 pgmemento 重叠度最高）

| 项 | 结论 |
|:---|:---|
| 关键判断 | 功能与 pgmemento 高度重叠（审计 + 恢复），社区活跃度不及；重复引入无增益 |

---

### C. 开发质量类

#### C1. plpgsql_check —— 🟢 P0 首批（零风险高收益）

| 项 | 结论 |
|:---|:---|
| 现有代码 | 29 个 RPC + src 函数全部 plpgsql；无静态检查 |
| 扩展能力 | 编译期静态检查：未定义对象、类型不匹配、安全缺陷（search_path）、权限问题 |
| 落地改动 | 安装（无需重启）+ `scripts/plpgsql_check_all.sh`（遍历 pg_proc 调 `plpgsql_check_function_tb`）接入 CI |
| 风险 | 零（只读检查） |
| **决策** | **P0 必装** |

#### C2. pg_mockable —— 🟢 P1（配合 pgtap）

| 项 | 结论 |
|:---|:---|
| 现有代码 | pgtap 已装 |
| 扩展能力 | 函数级 Mock（测试中替换函数实现，如 mock has_permission 恒真/恒假） |
| **决策** | **P1 推荐**（与 pgtap 配套，量力引入） |

---

### D. 校验与查询优化类

#### D1. pg_jsonschema —— 🟢 P0 必装（补 update_config 校验缺口）

| 项 | 结论 |
|:---|:---|
| 现有代码 | update_config 无类型校验：config_type='json' 可写入任意字符串 |
| 落地改动 | 029 版 update_config 加校验分支（json 类先 is_valid，number/boolean 原生转换校验）；可选 app_config 加 value_schema 列 |
| **决策** | **P0 必装** |

#### D2. jsquery —— 🟢 P1（与 GIN 不冲突，是 GIN 的查询语言层）

| 项 | 结论 |
|:---|:---|
| 官方定位（README 已核实） | **"JsQuery – json query language with GIN indexing support"**——jsquery 是 jsonb 的**查询语言**（jsquery 数据类型，类似 tsquery 之于全文搜索）+ `@@` 匹配操作符，**依赖 GIN 索引加速** |
| 与 GIN 的关系（用户问） | **不冲突，是互补增强**：<br>① 原生 GIN（jsonb_ops/jsonb_path_ops）只支持 `@>`、`?`、`@@ jsonpath` 等有限操作符；<br>② jsquery 提供**更丰富的查询语言**（路径通配 `*`/`#`/`%`、嵌套对象/数组条件、比较操作符 `>=`、`IN`、类型判断 IS NUMERIC 等）且**支持 GIN 索引**——建 `CREATE INDEX ... USING GIN (col)` 后 jsquery 查询走索引；<br>③ 与现有 jsonb GIN 索引可共存（不同 opclass） |
| 可优化点 | audit_log.old_data/new_data 建 GIN 索引 + jsquery 结构化条件（`new_data @@ '$.status = "published"'`），替代 ILIKE 全文扫 |
| 落地改动 | `CREATE INDEX idx_audit_new_data_gin ON audit_log USING GIN (new_data)`；search_audit_log 重写 WHERE（jsquery @@ 结构化检索 + ILIKE 降级保留） |
| 风险 | 低；索引增存储（audit_log 只追加，维护成本低） |
| **决策** | **P1 推荐**——装 jsquery + GIN 索引（比裸 GIN 更强的查询语言） |

#### D3. index_advisor —— 🟢 P1 工具（零风险）

| 项 | 结论 |
|:---|:---|
| 决策 | **P1 工具类**（对 search_users/search_audit_log 等核心查询跑建议） |

#### D4. pg_repack —— 🟢 P1 运维必备

| 项 | 结论 |
|:---|:---|
| 现有代码 | audit_log 只追加 + 高增长；login_log 同；无在线膨胀清理 |
| 落地改动 | 安装（bin 工具）+ pg_cron 定时（`0 3 * * 0` 跑 pg_repack） |
| **决策** | **P1 推荐** |

---

### E. 数据处理类

#### E1. omni_csv —— 🟢 P0 必装（修复 export_csv 半成品）

| 项 | 结论 |
|:---|:---|
| 现有代码 | ① export_csv **是半成品**：返回提示文本（"Use GET ... convert to CSV in frontend"），没有真正导出数据；② import_csv 接收 JSON 数组（前端需先 CSV→JSON），逐条动态 INSERT |
| 与手写对比（用户问） | **omni_csv 必装优于手写**：<br>① **CSV 规范处理**：引号/逗号/换行转义、BOM、类型转换（手写字符串拼接易踩引号转义坑）；<br>② 官方维护的 C 实现，性能与边界正确性有保障；<br>③ export_csv 现在**根本没实现**，用 omni_csv 是补全而非替换 |
| 落地改动 | rpc_export_csv 重写（查询 → omni_csv 序列化 → 返回 text）；rpc_import_csv 加 p_format 分支（csv 文本 / jsonb） |
| 风险 | 低-中；大结果集内存（加 LIMIT）；PostgREST 返回 text 前端 Blob 下载 |
| **决策** | **P0 必装**（用户拍板） |

#### E2. count_distinct —— 🟡 P2 观望

| 项 | 结论 |
|:---|:---|
| 关键判断 | CityWalk 当前量级原生 COUNT(DISTINCT) 已足够，量级上来再引入 |
| **决策** | **P2 观望** |

---

## 三、汇总决策表（2026-08-05 定稿）

| 扩展 | 判定 | 级别 | 核心理由 |
|:---|:---|:---|:---|
| **safeupdate** | ✅ **全局安装** | **P0** | 用户拍板；官方 README 确认 CTE 阻止 + 专为 PostgREST 设计 + `SET safeupdate.enabled=0` 逃生 |
| **pg_jsonschema** | ✅ 装 | **P0** | 补 update_config 校验缺口 |
| **omni_csv** | ⏸️ **暂不引入**（035 修订） | ~~P0~~ | ⚠️ 035：export_csv 已删除（半成品 + 注入面），导出走 GET /view 原生；import_csv 保留 JSON 入口 + 安全重写——原「必装」理由消失。官方能力已核实（csv_info/parse/csv_agg），待前端直传 CSV 需求再装 |
| **plpgsql_check** | ✅ 装 | **P0** | 静态检查零风险，CI 门禁 |
| **pgaudit** | ⏸️ **暂不启用** | P2 | 用户最终决策（2026-08-05）：现有 audit_log 已够用；扩展保持已装状态，不配 GUC 不生效 |
| **pgauditlogtofile** | ❌ 暂不装 | P2 | 随 pgaudit 一起暂缓（用户决策：audit_log 已够用） |
| **pgmemento** | ✅ **试点** | **P1** | 用户拍板；department/position/dict 四表先行，不动现有审计体系 |
| **pg_mockable** | ✅ 装 | **P1** | 配合 pgtap 做 RPC 单测 |
| **jsquery** | ✅ 装 | **P1** | JSONB 查询语言 + GIN 索引支持，与 GIN 不冲突 |
| **index_advisor** | ✅ 装 | **P1** | 索引建议工具 |
| **pg_repack** | ✅ 装 | **P1** | audit_log/login_log 膨胀治理 |
| citext | ⏸️ 可选 | **P2** | 镜像表收益有限 |
| count_distinct | ⏸️ 观望 | **P2** | 量级未到 |
| temporal_tables | ❌ 不装 | P3 | 与 pgmemento 重叠 |
| table_log | ❌ 不装 | P3 | 与 pgmemento 重叠 |
| pgjwt | ❌ 不装 | P3 | 与 APISIX 验签职责重复 |

---

## 四、与现有 audit_log 体系的关系（用户问题 5 专项澄清）

**结论：pgaudit 不替代 audit_log 相关函数，两者是互补的两层审计。**

| 维度 | pgaudit（SQL 级） | audit_log 表体系（业务级） |
|:---|:---|:---|
| 记录内容 | 执行的 SQL 语句 / DDL / 对象（语句文本 + 对象名） | 业务语义：old/new 数据差异、module/action、target、result |
| 存储位置 | **日志文件**（OS 层，应用不可篡改） | **数据库表**（可查询、可展示、RLS 保护） |
| 审计粒度 | 语句级（含绕过 RPC 的直连 SQL） | 触发器/函数级（挂触发器的表 + 调 log_operate 的 RPC） |
| 合规价值 | ✅ 政府/金融/ISO 取证（README 明示） | 业务追踪、误改恢复 |
| 可篡改性 | 应用无法删日志文件 | DEFINER 函数可删 audit_log 行（需 has_permission 防） |
| 覆盖盲区 | 业务语义（old→new）不落 | 未挂触发器的表、直连 SQL 不落 |

**结论**：现有 `write_audit_log` / `audit_trigger_func` / `log_operate` **全部保留不动**；pgaudit 只是补上"SQL 级合规审计"这一层（且它已经装了，缺的是配置激活）。

---

## 五、用户决策记录（2026-08-05）

| # | 审查问题 | 用户决策 |
|:---|:---|:---|
| 1 | pgmemento 试点范围 | ✅ **接受先行试点**（department/position/dict 等管理表） |
| 2 | safeupdate 是否安装 | ✅ **全局安装**（引用官方：CTE 修改也被阻止、专为 PostgREST 设计、`SET safeupdate.enabled=0` 临时禁用） |
| 3 | omni_csv 是否必装 | ✅ **必装**（比手写 export_csv 好：CSV 规范转义/类型处理，且 export_csv 当前是半成品） |
| 4 | jsquery 与 GIN 冲突？ | ✅ **不冲突**——jsquery 官方定位就是 "json query language with **GIN indexing support**"，是 GIN 之上的查询语言层，可共存 |
| 5 | 是否装 pgaudit 弥补/替代 audit_log | ✅ **暂不启用 pgaudit**——现有 audit_log 已够用；扩展保持已装状态（不配 GUC 即不生效），pgauditlogtofile 一并暂缓 |

---

## 六、安装批次（用户审查后执行）

### 批次 1（P0，无 shared_preload，CREATE EXTENSION 即用）
```
plpgsql_check / pg_jsonschema / omni_csv
```
落地：plpgsql_check 检查脚本 + update_config 校验分支 + export/import_csv 重写

### 批次 2（P1，含 shared_preload，需重启——合并一次维护窗口）
```
safeupdate（P0 但需重启） / pgmemento / pg_mockable / jsquery / index_advisor / pg_repack
```
前置：① **全库 WHERE-less UPDATE/DELETE 排查**（safeupdate 装前必做）；② safeupdate 装包后需 `pg edit-config` 加 shared_preload_libraries + `pg restart`；③ pgmemento 四表试点
（pgaudit / pgauditlogtofile：用户决策暂不启用，保持已装状态）

### 批次 3（P2，按需）
```
citext / count_distinct
```

---

## 七、结论摘要

- **本批 15 个扩展最终决策：9 个装（P0×4 + P1×5，safeupdate 含 preload）、2 个可选（P2）、4 个不装（P3）；pgaudit 保持已装不启用**。
- **最大收益点**：omni_csv 修复 export_csv 半成品；pg_jsonschema 补 update_config 校验；**pgaudit 已装未启用（配置缺口）**；safeupdate 补 PostgREST 直写防误删。
- **审计域**：现有 audit_log 体系保留，pgaudit 补 SQL 级合规层，pgmemento 补时间旅行——三层互补不重复。
- **架构一致性**：pgjwt 不引入（05.4 验签在网关定稿不变）；jsquery 与 GIN 是互补关系。
