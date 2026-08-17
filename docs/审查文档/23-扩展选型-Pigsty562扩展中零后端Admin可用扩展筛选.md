# 23-扩展选型：Pigsty 562 个扩展中可用于零后端 Admin 项目的筛选与分级

> **目标**：从 Pigsty 收录的 562 个 PG 扩展中，筛选出可服务于 **OmniPG 零后端 Admin 项目**（最终用于 CityWalk 城市漫步项目）的扩展，按应用场景分组、按 P0/P1/P2 分级，附安装方式与落地路线图。
>
> **数据来源**：pigsty.cc/ext/list（2026-08-05 抓取，564 条记录）、各扩展详情页（228 个候选逐一抓取描述/版本/许可证/属性）、Omnigres 官方文档、本项目 `infra/pigsty.yml` 与 `db/init/01-extensions.sql`。
>
> **筛选标准**：①场景匹配度（Admin 后台/CityWalk 业务）；②许可证商用友好度；③成熟度与维护状态；④与现有栈（PostgREST + APISIX + Logto + pg_cron/pg_net/pgaudit 等）互补而非冲突；⑤安装代价（shared_preload 需重启）。

---

## 一、现状盘点：OmniPG 已装扩展

| 扩展 | 用途 | 状态 |
|------|------|------|
| pgcrypto | 辅助加密（sha256 等） | ✅ 已装（Pigsty） |
| pgsodium | 透明列加密（敏感字段） | ✅ 已装（Pigsty） |
| pg_net | 异步 HTTP（Casdoor 集成、回调） | ✅ 已装（Pigsty） |
| pgaudit | SQL 审计日志（DDL/DML） | ✅ 已装（Pigsty） |
| pgtap | 单元测试框架 | ✅ 已装（Pigsty） |
| pg_graphql | GraphQL（与 PostgREST 并存） | ✅ 已装（Pigsty） |
| pg_cron | 定时任务调度器 | ✅ 已装（Pigsty） |
| pg_pwhash | Argon2id 密码哈希（OWASP 首选） | ⚠️ **init 脚本有、Pigsty 配置缺**（需补入 `pg_extensions`） |

> 🔴 **发现的不一致**：`db/init/01-extensions.sql` 声明了 pg_pwhash，但 `infra/pigsty.yml` 的 `pg_extensions` 和 `pg_databases[].extensions` 均未包含——按 Pigsty 方式部署时该扩展不会真正装上。**应补入。**

---

## 二、P0 推荐清单（立即可装，价值明确，风险低）

按 Admin 后台 + CityWalk 业务场景分组。P0 = 直接解决当前痛点、许可证友好、成熟稳定。

### 2.1 搜索与中文分词（CityWalk UGC 内容搜索核心）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **zhparser** | 中文分词全文检索解析器 | PostgreSQL | UGC 帖子/攻略/评论的中文全文搜索（`to_tsvector('zhparser', ...)`） |
| **pg_trgm** | 文本相似度 + 模糊检索（PG 自带） | PostgreSQL | 用户昵称模糊搜索、输入提示、相似内容推荐 |
| **unaccent** | 去重音文本搜索字典（PG 自带） | PostgreSQL | 搜索时忽略重音/变体字符 |

```sql
-- zhparser 安装后配置（Pigsty 已收录，PG18 可用）
CREATE EXTENSION IF NOT EXISTS zhparser;
CREATE TEXT SEARCH CONFIGURATION zh_cn (PARSER = zhparser);
ALTER TEXT SEARCH CONFIGURATION zh_cn ADD MAPPING FOR n,v,a,i,e,l WITH simple;
-- 搜索示例
SELECT * FROM ugc_posts WHERE to_tsvector('zh_cn', title) @@ to_tsquery('zh_cn', '城市漫步');
```

> **建议**：zhparser（分词）+ pg_trgm（模糊）组合覆盖 UGC 搜索 90% 场景；pg_jieba 更新但同为分词器，二选一即可，zhparser 更成熟。

### 2.2 ID 生成（新表主键规范）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pg_uuidv7** | UUIDv7（时间有序） | MPL-2.0 | 新表主键默认值，时间有序 → 索引友好、天然带时间信息；CityWalk 所有新表推荐 |
| **pg_hashids** | 加盐短 ID | MIT | 订单号/邀请码/分享码（短、不可枚举） |

```sql
CREATE EXTENSION IF NOT EXISTS pg_uuidv7;
CREATE TABLE ugc_posts (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  share_code text DEFAULT pg_hashids.encode(123456, 'citywalk-salt')
);
```

### 2.3 报表与统计（Admin 后台高频）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **tablefunc** | crosstab 交叉表（PG 自带） | PostgreSQL | Admin 后台行列透视报表（每日注册/活跃/内容量矩阵） |
| **hll** | HyperLogLog 基数估计 | Apache-2.0 | UV 去重统计（亿级量不落明细） |
| **count_distinct** | 精确 COUNT DISTINCT 加速 | BSD-2-Clause | 需要精确去重计数的报表 |

```sql
-- 交叉表：最近7天各模块内容量
SELECT * FROM crosstab(
  'SELECT module, date_trunc(''day'', created_at)::date d, count(*) FROM contents
   GROUP BY 1,2 ORDER BY 1,2',
  'SELECT generate_series(CURRENT_DATE-6, CURRENT_DATE, 1)::date'
) AS ct(module text, d1 bigint, d2 bigint, d3 bigint, d4 bigint, d5 bigint, d6 bigint, d7 bigint);
```

### 2.4 数据导入导出（Admin 数据管理）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **omni_csv** | Omnigres CSV 工具箱 | Apache-2.0 | Admin CSV 导入导出（用户批量导入、数据备份导出） |
| **pg_csv** | 灵活 CSV 聚合函数 | MIT | 查询结果直接生成 CSV 字符串 |
| **file_fdw** | 文件外部表（PG 自带） | PostgreSQL | 服务端 CSV/文件直接当表查询 |

### 2.5 认证与安全补充（在 Logto 定稿之上）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pgjwt** | JWT 生成/校验（SQL 实现） | MIT | PostgREST 自定义 JWT 校验、`authenticator` 角色切换前的签名验证（与 Logto JWKS 校验互补） |
| **pg_pwhash** | Argon2id/argon2/scrypt 密码哈希 | MIT | **补入 Pigsty 配置**——现有 init 脚本已声明但未生效；Argon2id 为 OWASP 首选 |
| **citext** | 大小写不敏感文本类型（PG 自带） | PostgreSQL | 登录名/邮箱唯一约束（`citext` 免去 lower() 索引） |

### 2.6 类型与索引基础设施

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **intarray** | 整数数组索引（PG 自带） | PostgreSQL | 标签 ID 数组、多对多关联的 GIN 加速 |
| **btree_gin / btree_gist** | 常用类型 GIN/GiST 索引（PG 自带） | PostgreSQL | 复合条件查询、范围+等值混合查询加速 |

---

## 三、P1 推荐清单（按需引入，价值明确但场景特定）

### 3.1 消息队列与异步（通知/审核链路）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pgmq** | SQS 风格消息队列（纯 SQL） | PostgreSQL | 通知投递队列、审核任务队列、异步任务（替代自建队列表） |
| **pg_task** | 定时/延迟执行 SQL | MIT | 与 pg_cron 互补：延迟重试、一次性定时任务 |

```sql
CREATE EXTENSION IF NOT EXISTS pgmq;
SELECT pgmq.create('audit_queue');
SELECT pgmq.send('audit_queue', '{"content_id": 123, "action": "review"}');
SELECT * FROM pgmq.recv('audit_queue');  -- 审核 worker 消费
```

### 3.2 审计与数据版本（合规 + 内容历史）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pgauditlogtofile** | pgaudit 子扩展：审计日志独立文件 | PostgreSQL | 审计日志落独立文件便于归档/采集（若需区分应用与审计流） |
| **pgmemento** | 事务级审计追踪 + 数据恢复 | LGPL-3.0 | 业务表变更留痕、误删恢复（比 trigger 自建更完整） |
| **temporal_tables** | 时态表（有效期双列） | BSD-2-Clause | 内容版本历史、价格/规则变更留痕 |
| **table_log** | 表修改日志 + 行级 PITR | PostgreSQL | 关键表（订单/钱包）操作日志 |

### 3.3 地理与 LBS（CityWalk 地图模块增强）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pg_eviltransform** | BD09/GCJ02/WGS84 坐标互转 | MIT | **直接替换自研 GCJ02 转换函数**（Map 模块已自研，官方实现更可靠） |
| **postgis** | 几何/地理空间扩展 | GPL-2.0 | 若未来需要空间索引/范围查询（ST_DWithin 附近搜索），可替代自研 Haversine |
| **pg_geohash** | GeoHash 编码 | MIT | 附近搜索简化（前缀匹配）、区域聚合 |
| **geoip** | IP 地理位置（MaxMind） | BSD-2-Clause | Admin 后台用户 IP 归属地展示、反欺诈（设备信誉模块） |
| **earthdistance** | 大圆距离（PG 自带） | PostgreSQL | 轻量距离计算（不引入 PostGIS 时） |

> ⚠️ **postgis 许可证注意**：GPL-2.0。作为独立扩展通过 SQL 调用不传染业务代码，但若嵌入分发需注意；当前 Map 模块自研方案（WGS84+GCJ02 + Haversine）已满足需求，postgis 仅在需要空间索引时引入。

### 3.4 运维与性能（生产必备）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pg_repack** | 在线清理膨胀 | PostgreSQL | 大表 VACUUM FULL 在线替代（UGC 大表定期治理） |
| **pg_profile** | AWR 风格负载报表 | BSD-2-Clause | 性能基线、容量规划 |
| **hypopg** | 假设索引 | PostgreSQL | 索引设计验证（开发期） |
| **index_advisor** | 查询索引建议 | PostgreSQL | 慢查询自动建议 |
| **pg_stat_statements** | SQL 执行统计（PG 自带） | PostgreSQL | 慢 SQL 定位（Pigsty 默认可能已装，确认即可） |

### 3.5 开发与质量保障

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **plpgsql_check** | plpgsql 函数静态检查 | MIT | CI 质量门禁：函数语法/类型/权限问题提前发现 |
| **pg_mockable / pgsqlmock** | 函数 Mock | PostgreSQL | RPC 单元测试（配合 pgtap） |
| **faker** | 测试数据生成 | PostgreSQL | 开发/演示环境造数 |

### 3.6 事务与可靠性

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **omni_txn** | 事务重试（SERIALIZABLE 自动退避） | Apache-2.0 | 高并发写场景（订单/库存）自动重试，避免应用层重试逻辑 |
| **pg_retry** | 临时错误指数退避重试 | PostgreSQL | 与 omni_txn 二选一即可（omni_txn 更完整，含参数化与调试视图） |
| **safeupdate** | 强制 UPDATE/DELETE 带 WHERE | ISC | 防误删全表（开发环境/运维习惯） |

### 3.7 JSON 与数据校验（Admin 表单/API 入参）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **pg_jsonschema / jsonschema** | JSON Schema 校验 | Apache-2.0 / MIT | Admin 表单提交校验、动态配置项校验（两个二选一） |
| **jsquery** | JSONB 查询类型 | PostgreSQL | 复杂 JSONB 条件查询（标签/扩展属性过滤） |

### 3.8 压缩与文件（存储优化）

| 扩展 | 描述 | 许可证 | 场景 |
|------|------|--------|------|
| **gzip / zstd** | SQL 内压缩/解压 | MIT / ISC | 大文本内容压缩存储、日志归档 |
| **lo** | 大对象（PG 自带） | PostgreSQL | 小文件直接入库（文件模块的补充方案） |

---

## 四、P2 / 观望清单（暂不引入，记录价值）

| 扩展 | 描述 | 观望原因 |
|------|------|----------|
| **omni_httpd** | Omnigres 内嵌 HTTP 服务器 | 安全沙箱有已知漏洞（procedure 可 SET ROLE 逃逸）；且与 APISIX/PostgREST 职责重叠 |
| **omni_rest** | 内嵌 PostgREST 兼容实现 | 官方声明兼容性未完成，68 张表 RPC 迁移风险高 |
| **omni_auth** | Omnigres 密码认证 | 仅密码认证，无法替代 Logto OIDC 定稿 |
| **omni_vfs** | 虚拟文件系统 | 官方 WIP：无写能力、无流式 |
| **omni_python** | PG 内 Python/Flask | 重量级，引入 Python 运行时与零后端理念冲突 |
| **pg_tde** | 全库透明加密 | 性能开销大，现有 pgsodium 列加密已覆盖敏感字段 |
| **anon** | 数据匿名化 | Rust 实现较新；测试环境脱敏可用，非生产刚需 |
| **pg_search** | ParadeDB BM25 搜索 | **AGPL-3.0** 商用传染风险；且需 shared_preload，暂用 zhparser+pg_trgm 足够 |
| **topn** | Top-N 聚合 | **AGPL-3.0**；CityWalk 热榜可用 hll+普通聚合替代 |
| **pgroonga** | Groonga 全文检索 | 与 zhparser 方案重叠，仅超大规模中文检索才考虑 |
| **pg_jieba** | jieba 分词 | 与 zhparser 二选一，zhparser 更成熟 |
| **pg_bigm** | 二字组检索 | 与 pg_trgm 重叠，日文场景为主 |
| **h3** | H3 六边形网格 | 城市热力图/区域分析才需要，当前无此需求 |
| **pg_graphql** | GraphQL（已装） | 已装但 PostgREST 为主 API 层，评估是否保留 |
| **omni_ledger** | 金融账本 | 若未来做积分/钱包系统可评估，当前无需求 |
| **pgmqtt / pgq** | MQTT 桥接 / 队列 | 场景不符（IoT）或与 pgmq 重叠 |
| **snowflake / typeid / pg_idkit** | 其他 ID 方案 | 与 pg_uuidv7 重叠，多 ID 方案反而增加复杂度 |
| **semver / unit / uri / emailaddr** | 领域类型 | 锦上添花，按需启用 |

---

## 五、明确排除清单（不适合本项目）

| 类别 | 扩展举例 | 排除理由 |
|------|----------|----------|
| OLAP/数仓 | citus、pg_duckdb、pg_parquet、pg_lake*、columnar、pg_mooncake | 单机 Admin 无分布式/数仓需求；需要时用 Pigsty 独立集群 |
| 语言运行时 | plv8、pljava、plr、pllua、plprql、pgwasm | 零后端理念 = 逻辑在 SQL/PLpgSQL，不引入 JS/Java/R 运行时 |
| 外部数据源 FDW | mysql_fdw、oracle_fdw、mongo_fdw、kafka_fdw 等 | 当前无跨库/迁移需求；需要时按目标源单独评估 |
| 复制/HA | pglogical、pgactive、spock、repmgr | 单机部署，Pigsty+Patroni 已覆盖 HA |
| 数据库兼容层 | orafce、babelfish*、ivorysql、documentdb | 无 Oracle/SQL Server/Mongo 兼容需求 |
| 图数据库 | age、graph、onesparse | 社交图谱若未来需要再评估 |
| 向量/RAG | vector、vchord、vectorscale、pgml | AI 搜索未来可能，届时按 RAG 专项方案引入（注意 AGPL 的 pg_search） |
| 系统内核级 | sepgsql、pg_strom、pg_snakeoil、pg_crash | SELinux 复杂/GPU 需求/概念性 |
| 其他 | q3c（天文索引）、pg_cardano（区块链）、rdkit（化学）、pg_sphere（天文） | 领域不符 |

---

## 六、CityWalk 业务落地映射

| CityWalk 模块 | 推荐扩展 | 典型用法 |
|---------------|----------|----------|
| **用户/账号** | citext、pg_uuidv7、pgjwt、pg_pwhash | 邮箱登录名唯一性、用户表 uuidv7 主键、PostgREST JWT 校验、密码 Argon2id |
| **UGC 内容（帖子/攻略/评论）** | zhparser、pg_trgm、pg_uuidv7、temporal_tables | 中文全文搜索、昵称模糊匹配、内容版本历史 |
| **地图与 LBS** | pg_eviltransform、pg_geohash、earthdistance | GCJ02 坐标转换（替换自研）、附近搜索简化、距离计算 |
| **通知系统** | pgmq、pg_net、omni_httpc | 通知队列、异步推送回调 |
| **审核/举报** | pgmq、pg_cron | 审核任务队列、超时自动处理 |
| **反欺诈/风控** | geoip、pg_auth_mon、ip4r | IP 归属地、登录尝试监控、IP 段匹配 |
| **Admin 后台** | tablefunc、omni_csv、pg_csv、file_fdw、pg_jsonschema | 交叉表报表、CSV 导入导出、表单校验 |
| **运营统计** | hll、count_distinct、pg_stat_statements | UV 统计、精确计数、慢查询监控 |
| **内容热榜** | hll（替代 topn，规避 AGPL） | 浏览/点赞去重计数排序 |

---

## 七、落地路线图

### Phase 1（本周，零风险批量装）

```yaml
# infra/pigsty.yml → pg_extensions 追加：
# pg_pwhash（补漏）、zhparser、pg_uuidv7、citext、intarray、
# btree_gin、btree_gist、tablefunc、hll、count_distinct、
# omni_csv、pg_csv、file_fdw、pgjwt、pg_trgm、unaccent、pg_hashids
```

安装后执行：
```sql
CREATE EXTENSION IF NOT EXISTS pg_pwhash;
CREATE EXTENSION IF NOT EXISTS zhparser;
CREATE EXTENSION IF NOT EXISTS pg_uuidv7;
CREATE EXTENSION IF NOT EXISTS pgjwt;
-- ...（其余同理，无需 shared_preload 的扩展 CREATE 即用）
```

### Phase 2（本月，按模块引入）

- 通知/审核模块：pgmq、pg_task
- 地图模块：pg_eviltransform、pg_geohash
- 审计合规：pgauditlogtofile、pgmemento（或 temporal_tables）
- 运维：pg_repack、pg_profile、hypopg、index_advisor
- 质量：plpgsql_check（进 CI）

### Phase 3（按需评估）

- 内容版本：temporal_tables / table_version
- 文件存储：lo / omni_vfs（等写能力完善）
- 未来 AI：vector 专项方案

---

## 八、安装要点（Pigsty 方式）

1. **shared_preload 类**（pgaudit/pg_net/pg_cron/pg_task 等）：在 `infra/pigsty.yml` 的 `pg_extensions` 列出，Pigsty 会写入 `shared_preload_libraries` 并需重启 PG 生效——**已在用的保持不动**。
2. **普通类**（zhparser/pg_uuidv7/pgjwt/omni_csv 等绝大多数）：无需重启，`CREATE EXTENSION IF NOT EXISTS <name>;` 即用。建议统一在 `db/init/` 新增 `02-extensions-admin.sql` 管理。
3. **补漏**：pg_pwhash 加入 `pg_extensions` + `pg_databases[].extensions`（当前 init 脚本声明与 Pigsty 配置不一致）。
4. **许可证合规**：引入前核对上表许可证列——AGPL-3.0（pg_search、topn）与 GPL-3.0（emaj、pg_background、pg_math、login_hook）在本项目（商业闭源）中**默认排除**。

---

## 九、结论摘要

- **562 个扩展中，对本项目真正值得引入的：P0 ≈ 20 个，P1 ≈ 25 个**（含 PG 自带 CONTRIB 类），其余按场景观望或明确排除。
- **最高性价比**：zhparser（中文搜索）、pg_uuidv7（主键规范）、tablefunc+omni_csv（Admin 报表/导入导出）、pgmq（异步链路）、pg_eviltransform（地图模块瘦身）。
- **Omnigres 结论维持上轮**：平台级（omni_httpd/omni_rest/omni_vfs/omni_python）观望，组件级（omni_csv/omni_worker/omni_httpc/omni_txn）可用。
- **立即行动项**：①补 pg_pwhash 进 Pigsty 配置；②Phase 1 扩展批量安装；③zhparser 中文搜索 POC。
