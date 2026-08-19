# pg_mockable 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_mockable |
| **用途** | 函数 mock / 测试替身（pgTAP 配套单测） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [pg_mockable](https://pigsty.cc/ext/e/pg_mockable/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. **`pg_mockable.mock`**: 将函数临时替换为桩实现，便于隔离测试（如 mock 外部 HTTP/IO）；
2. P1 用途：pgTAP 单元测试配套。

## 注意事项

- **仅测试环境使用**：与 pgtap 环境策略一致（开发/CI 启用，生产不启用）；
- mock 仅在测试事务/会话内有效，须随测试回滚清理，避免污染运行态。

## 相关文件

- 声明配置: `infra/pigsty.yml`
- 测试指南: `wiki/07-测试/pgtap-guide.md`
