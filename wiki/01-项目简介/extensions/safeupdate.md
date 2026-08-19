# safeupdate 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | safeupdate |
| **用途** | 防误删/误更新：强制 UPDATE/DELETE 携带 WHERE 条件（Load=是 Create=否） |
| **安装方式** | Pigsty 包安装（`pg_extensions`）**仅装包 + preload，无需 CREATE EXTENSION** |
| **Pigsty 扩展页** | [safeupdate](https://pigsty.cc/ext/e/safeupdate/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml` 的 `pg_extensions`（不在 `pg_databases[].extensions`）

## 主要功能

1. 通过 GUC 控制（如 `safeupdate.force_update_safe` / `safeupdate.force_delete_safe`）拦截无 WHERE 的 UPDATE/DELETE；
2. P0 防误删措施（24-扩展引入分析 决策）。

## 注意事项

- **仅装包 + preload**：safeupdate 是 load-only 扩展（Load=是 Create=否），无需也不能 CREATE EXTENSION；
- **需 shared_preload_libraries**：装包后需在 Pigsty `pg_libs` 加 preload 并重启集群；
- 生效范围与 GUC 作用域（集群/库/会话）以实际配置为准，开启前需评估对批量运维 SQL 的影响。

## 相关文件

- 声明配置: `infra/pigsty.yml`
