# pgcrypto 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pgcrypto |
| **用途** | 密码哈希、gen_random_uuid()、sha256 等辅助哈希 |
| **安装方式** | Pigsty 预装 + 迁移文件显式启用 |

## 版本信息

- **Pigsty 预装版本**: 随 PostgreSQL 18 自带
- **迁移文件启用**: `db/migrations/sys/001_init_tables.sql` 中 `CREATE EXTENSION IF NOT EXISTS pgcrypto;`

## 主要功能

1. **digest()**: 支持 sha256、sha512 等哈希算法（仅用于非密码场景）
2. **gen_random_uuid()**: 生成 UUID v4（用于 sys_secret 等）
3. **hmac()**: HMAC 哈希

## 注意事项

- **密码哈希使用 pg_pwhash (Argon2id)**，不使用 pgcrypto 的 crypt()
- pgcrypto 仅用于辅助场景：sha256 哈希、随机 UUID 等
- 在 CI 环境（无 Pigsty）中，迁移文件的 `CREATE EXTENSION` 确保测试通过

## 相关文件

- 迁移启用: `db/migrations/sys/001_init_tables.sql`
- sha256 包装函数: `db/src/sys/functions/sha256.sql`
