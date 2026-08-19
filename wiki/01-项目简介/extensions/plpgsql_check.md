# plpgsql_check 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | plpgsql_check |
| **用途** | PL/pgSQL 静态检查器（P0 静态检查） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [plpgsql_check](https://pigsty.cc/ext/e/plpgsql_check/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. **`plpgsql_check_function()`**: 静态检查函数中的未声明变量、未解析依赖、潜在运行时错误；
2. 可与 CI 的 SQL lint 流程集成，前置发现 PL/pgSQL 缺陷。

## 注意事项

- P0 静态检查（24-扩展引入分析 决策）；建议纳入 CI 门禁，与 `sqlfluff` 互补；
- 检查为只读分析，不改变函数行为。

## 相关文件

- 声明配置: `infra/pigsty.yml`
