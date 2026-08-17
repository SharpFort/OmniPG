# pgTAP 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pgtap |
| **用途** | PostgreSQL 数据库单元测试框架 |
| **安装方式** | Pigsty 预装（仅测试/CI 环境） |

## 版本信息

- **Pigsty 预装版本**: 随 PostgreSQL 18 自带（测试/CI 环境）
- **迁移文件启用**: 仅测试环境通过 `DBMATE_ENV=test` 条件加载

## 环境隔离策略

| 环境 | pgtap 安装 | 说明 |
|:---|:---|:---|
| **生产** | ❌ 不安装 | 避免测试框架引入安全风险 |
| **预发布** | ❌ 不安装 | 生产数据的副本 |
| **开发** | ✅ 安装 | 本地开发运行测试 |
| **CI** | ✅ 安装 | CI 流水线自动运行测试 |

## 启用方式

```sql
-- 仅限测试环境执行（通过 DBMATE_ENV=test 条件加载）
CREATE EXTENSION IF NOT EXISTS pgtap;
```

## 相关文件

- 测试文件目录: `db/tests/`
- 测试运行命令: `make test-db`（使用 pg_prove）
- pg_prove 路径: `docker compose exec app-postgres pg_prove -U app_owner -d app_db --ext .sql db/tests/`
