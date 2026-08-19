# pgTAP 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pgtap |
| **用途** | PostgreSQL 数据库单元测试框架 |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`，仅测试/CI 环境启用） |
| **Pigsty 扩展页** | [pgtap](https://pigsty.cc/ext/e/pgtap/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`（`pg_extensions` + `pg_databases[].extensions`）

## 环境隔离策略

| 环境 | pgtap 安装 | 说明 |
|:---|:---|:---|
| **生产** | ❌ 不安装 | 避免测试框架引入安全风险 |
| **预发布** | ❌ 不安装 | 生产数据的副本 |
| **开发** | ✅ 安装 | 本地开发运行测试 |
| **CI** | ✅ 安装 | CI 流水线自动运行测试 |

## 启用方式

由 Pigsty 在数据库层创建（`pg_databases[].extensions` 含 pgtap 时自动执行 CREATE EXTENSION）；检查是否已启用：

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'pgtap';
```

## 相关文件

- 测试文件目录: `db/tests/`
- 测试运行命令: `make test-db`（使用 pg_prove）
- pg_prove 路径: `docker compose exec app-postgres pg_prove -U app_owner -d app_db --ext .sql db/tests/`
