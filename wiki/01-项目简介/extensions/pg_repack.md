# pg_repack 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_repack |
| **用途** | 在线表膨胀治理（替代 VACUUM FULL，不阻塞读写） |
| **安装方式** | Pigsty 包安装（`pg_extensions`） |
| **Pigsty 扩展页** | [pg_repack](https://pigsty.cc/ext/e/pg_repack/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml` 的 `pg_extensions`

## 主要功能

1. 在线重建表/索引以回收膨胀空间（`pg_repack --table ...`），读写不被长时间阻塞；
2. P1 用途：膨胀治理（24-扩展引入分析 决策）。

## 注意事项

- 需 DDL 权限（由集群管理员执行）；大表 repack 期间仍有额外 I/O 与锁窗口，需在运维窗口执行；
- repack 对象含外键/触发器的表时注意约束处理（官方工具自动处理，但需测试验证）；
- 生产使用前在预发布环境演练。

## 相关文件

- 声明配置: `infra/pigsty.yml`
