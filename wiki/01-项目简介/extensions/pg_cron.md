# pg_cron 扩展说明

## 扩展信息

| 项目 | 内容 |
|:---|:---|
| **扩展名称** | pg_cron |
| **用途** | 数据库内定时任务调度（`cron.job` / `cron.job_run_details`），宿主 schema `cron` |
| **安装方式** | Pigsty 集群级安装（`pg_extensions` + `pg_databases[].extensions`）；需 shared_preload_libraries（后台进程） |
| **Pigsty 扩展页** | [pg_cron](https://pigsty.cc/ext/e/pg_cron/) |

## 版本信息

- **Pigsty 版本**: 随 Pigsty v4.4.0 扩展源安装；实际版本以 `pg_available_extensions` 查询为准
- **声明位置**: `infra/pigsty.yml`

## 主要功能

1. **`cron.schedule` / `cron.unschedule`**: 管理定时任务（标准 cron 表达式）
2. **任务表**: 定义存 `cron.job`，执行记录存 `cron.job_run_details`
3. **项目内暴露**: 经 `rpc_list_cron_jobs` 等只读 RPC 暴露给前端

## 注意事项

- **需 shared_preload_libraries**：pg_cron 由独立后台进程驱动，装包后需在 Pigsty `pg_libs` 加 preload 并重启集群；
- 定时任务消耗真实数据库资源，生产环境需评估调度密度；
- 任务行为写入 `cron.job_run_details`，可结合监控做失败告警。

## 相关文件

- 声明配置: `infra/pigsty.yml`
