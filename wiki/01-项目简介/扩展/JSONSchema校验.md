# pg_jsonschema 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_jsonschema |
| **用途** | JSONB 数据按 JSON Schema 校验（P0 update_config 校验） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [pg_jsonschema](https://pigsty.cc/ext/e/pg_jsonschema/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. **`jsonschema.is_valid` / `jsonschema.validate`**: 校验 JSONB 是否符合给定 JSON Schema；
2. P0 用途：`update_config` 等配置类 JSONB 列写入前的结构校验。

## 注意事项

- 校验规则（Schema）需与应用约定一致，Schema 变更属向后兼容考量；
- 大 JSONB 频繁校验有性能成本，建议仅在写路径（RPC 内）使用。

## 相关文件

- 声明配置: `infra/pigsty.yml`
