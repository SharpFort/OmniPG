# index_advisor 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | index_advisor |
| **用途** | 索引建议工具（基于查询/统计信息） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [index_advisor](https://pigsty.cc/ext/e/index_advisor/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. 对给定查询/负载给出候选索引建议；
2. P1 用途：索引治理与调优辅助。

## 注意事项

- 建议输出需**人工 review 后执行**（索引有写入放大与存储成本）；
- 建议与 EXPLAIN / pg_stat 实际访问模式结合判断。

## 相关文件

- 声明配置: `infra/pigsty.yml`
