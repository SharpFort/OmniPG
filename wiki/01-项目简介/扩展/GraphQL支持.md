# pg_graphql 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_graphql |
| **用途** | PostgreSQL 原生 GraphQL API（预留，暂未用于业务 API） |
| **安装方式** | Pigsty 集群级安装（`pg_extensions` + `pg_databases[].extensions`） |
| **Pigsty 扩展页** | [pg_graphql](https://pigsty.cc/ext/e/pg_graphql/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. 自动将表/视图/函数暴露为 GraphQL Schema；
2. 通过 `graphql.resolve` RPC 执行查询与变更。

## 注意事项

- **当前状态: 预留**，未用于业务 API；启用前需明确与 PostgREST 暴露层（`api_v1_platform`）的边界，避免双入口；
- 如需停用，从 `pg_databases[].extensions` 移除并 `DROP EXTENSION`（由集群管理员操作）。

## 相关文件

- 声明配置: `infra/pigsty.yml`
