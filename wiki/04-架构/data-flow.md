# 关键数据流

> 状态：骨架占位 · 待补充
> 定位：登录、webhook 同步、权限判定、审计等关键链路

## 内容清单

- [ ] 数据流 1：用户登录与 token 生命周期
- [ ] 数据流 2：Logto webhook 事件 → rpc_webhook_logto → sync_* 函数
- [ ] 数据流 3：菜单/角色/数据范围权限判定
- [ ] 数据流 4：审计与操作日志（log_operate、login_log、审计触发器）
- [ ] 数据流 5：cron 任务与 webhook 事件重放

---

## 待补：每类数据流的时序图/表格

- 登录流程
- webhook 同步流程
- 权限判定流程
- 审计流程
- cron / webhook 重放流程

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
