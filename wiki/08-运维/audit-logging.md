# 审计与日志

> 状态：骨架占位 · 待补充
> 定位：审计触发器、登录日志、操作日志与 cron 任务

## 内容清单

- [ ] 审计字段与审计触发器（trg_audit_*、trg_updated_at）
- [ ] login_log 与登录日志查询（rpc_search_login_logs）
- [ ] 操作日志（log_operate、logto_ts）
- [ ] cron 任务与执行记录（rpc_list_cron_jobs / rpc_list_cron_job_runs）
- [ ] 日志保留与清理策略
- [ ] 对接外部日志系统的建议

---

## 审计对象清单（待补全）

| 表 | 审计触发器 | 审计内容 |

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
