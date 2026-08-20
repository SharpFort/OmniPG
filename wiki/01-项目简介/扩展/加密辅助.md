# pgcrypto 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pgcrypto |
| **用途** | 密码哈希、gen_random_uuid()、sha256 等辅助哈希 |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`） |
| **Pigsty 扩展页** | [pgcrypto](https://pigsty.cc/ext/e/pgcrypto/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装（PostgreSQL 18 contrib 自带）；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`（`pg_extensions` + `pg_databases[].extensions`）

## 主要功能

1. **digest()**: 支持 sha256、sha512 等哈希算法（仅用于非密码场景）
2. **gen_random_uuid()**: 生成 UUID v4（用于 sys_secret 等）
3. **hmac()**: HMAC 哈希

## 注意事项

- 密码由 Logto 管理，PG 内不存可登录密码；pgcrypto 的 crypt() 不用于密码场景
- pgcrypto 仅用于辅助场景：sha256 哈希、随机 UUID（gen_random_uuid）、HMAC 等
- 在 CI / PGlite 验证环境（无 Pigsty）中，如迁移/测试需要 pgcrypto，需由测试环境自行提供（CI 使用官方镜像 contrib 或桩）

## 相关文件

- 迁移启用: `db/migrations/public/001_init_tables.sql`
- sha256 包装函数: `db/src/public/functions/sha256.sql`
