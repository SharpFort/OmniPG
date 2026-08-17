# Logto Webhook 接入

> 状态：骨架占位 · 待补充
> 定位：Logto 事件如何同步到数据库（rpc_webhook_logto 与 sync_* 函数）

## 内容清单

- [ ] Webhook 触发的事件类型（用户/组织/角色变更）
- [ ] 入口：rpc_webhook_logto 的调用约定
- [ ] sync_user_upsert / sync_user_delete / sync_user_suspension
- [ ] sync_organization_role_upsert / sync_role_upsert 等
- [ ] 事件重放：rpc_replay_webhook_event、rpc_list_webhook_events
- [ ] 幂等性与失败处理
- [ ] 在 Logto 控制台配置 webhook 的步骤

---

## 事件-函数映射表（待补全）

| Logto 事件 | 处理函数 | 幂等策略 |

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
