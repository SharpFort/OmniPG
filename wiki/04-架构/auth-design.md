# 认证与授权设计

> 状态：骨架占位 · 待补充
> 定位：Logto 认证 + 吸收 casbin 的 RBAC 授权体系（本 wiki 核心章节）

## 内容清单

- [ ] 认证：Logto OIDC 流程、token 校验（logto_ts / 网关层）
- [ ] 授权模型：菜单、角色、权限、数据范围 scope（current_data_scope / current_visible_dept_ids）
- [ ] 数据行级安全：RLS 策略（db/src/public/privileges/rls_policies.sql）
- [ ] has_permission 与 RPC 内的权限判定
- [ ] webhook 同步：Logto 事件 → sync_* 函数 → 本地表
- [ ] 从 casbin 吸收了什么、放弃了什么
- [ ] 用户-角色-组织关系与 membership 同步

---

## 核心对象

- 角色 / 菜单（iam_menu）/ 用户职位（position）/ 部门
- 数据范围 scope_type：全局/部门/本部门/本人等
- 关键函数：has_permission、get_user_menu、current_data_scope

## 时序：登录 → 授权 → 数据访问（待补）

```text
登录 → Logto 签发 token → APISIX 校验 → PostgREST
      → RLS/函数鉴权 → 返回数据
```

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
