# 权限模型开发

> 状态：骨架占位 · 待补充
> 定位：菜单、角色、数据范围 scope 与 RLS 的开发指南

## 内容清单

- [ ] 权限模型总览（角色-菜单-数据范围）
- [ ] 菜单（iam_menu）与按钮权限
- [ ] 角色与数据范围 scope_type
- [ ] RLS 策略编写规范（rls_policies.sql）
- [ ] has_permission 的用法
- [ ] 新增一种数据范围的完整例子
- [ ] 授权相关 RPC 清单（set_role_menus、set_role_data_scope 等）

---

## 示例：给角色挂菜单

```sql
-- 参考 rpc_set_role_menus.sql 的实现
SELECT * FROM rpc_set_role_menus(...);
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
