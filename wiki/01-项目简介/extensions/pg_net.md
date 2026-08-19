# pg_net 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_net |
| **用途** | 数据库内异步 HTTP 请求（webhook 回调、pg_notify 增强），宿主 schema `net` |
| **安装方式** | Pigsty 包安装（`pg_extensions`）+ 数据库启用（`pg_databases[].extensions`）；需 shared_preload_libraries（后台 worker） |
| **Pigsty 扩展页** | [pg_net](https://pigsty.cc/ext/e/pg_net/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`（`pg_extensions` + `pg_databases[].extensions`）

## 主要功能

1. **`net.http_post` / `net.http_get`**: 在数据库内异步发起 HTTP 请求（请求排队异步执行，不阻塞事务）
2. **结果可查**: 请求结果写入 pg_net 内部表，可轮询/回调确认

## 注意事项

- **需 shared_preload_libraries**：pg_net 依赖后台 worker，装包后需在 Pigsty `pg_libs` 加 preload 并重启集群；
- **权限收紧（2026-08-16 拍板）**：pg_net 可发任意外网 HTTP 请求，直接授 EXECUTE = SSRF 后门。`db/init/02-schemas.sql` 已 `REVOKE` `authenticated` 对 `net` schema 的 EXECUTE/USAGE，HTTP 调用一律经 SECURITY DEFINER 封装函数（如 webhook 相关 RPC）；
- **依赖方**: Logto webhook → `rpc_webhook_logto` 回调链路依赖本扩展。

## 相关文件

- 声明配置: `infra/pigsty.yml`
- 权限收紧: `db/init/02-schemas.sql`
