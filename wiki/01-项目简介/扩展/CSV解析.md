# omni_csv 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | omni_csv |
| **用途** | CSV 解析与加载（omni 系列扩展） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [omni_csv](https://pigsty.cc/ext/e/omni_csv/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. 在 SQL 中直接解析 CSV 文本为行集（供 COPY/INSERT 或导入导出逻辑使用）；
2. P0 用途：`export_csv` / `import_csv` 相关 RPC 重写（24-扩展引入分析 决策）。

## 注意事项

- CSV 解析选项（分隔符/引号/编码）按需在调用时指定；
- 导入类功能涉及数据写入，权限与审计按既有 RPC 规范处理。

## 相关文件

- 声明配置: `infra/pigsty.yml`
