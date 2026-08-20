# jsquery 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | jsquery |
| **用途** | JSONB 查询语言（复杂 JSONB 谓词匹配） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [jsquery](https://pigsty.cc/ext/e/jsquery/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. 提供 `jsquery` 类型与 `@@` 操作符，声明式表达复杂 JSONB 结构谓词；
2. P1 用途：JSONB 查询语言（24-扩展引入分析 决策）。

## 注意事项

- 仅当业务 JSONB 查询复杂度超出原生 `@>` 与 `?` 操作符时使用，避免过度依赖自定义语法；
- 使用 jsquery 的操作符可能影响既有查询计划，上线前需 EXPLAIN 验证。

## 相关文件

- 声明配置: `infra/pigsty.yml`
