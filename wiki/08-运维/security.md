# 安全设计

> 状态：骨架占位 · 待补充
> 定位：认证、防注入、密钥管理等安全基线

## 内容清单

- [ ] 认证安全：Logto token 校验、密钥轮换
- [ ] 防注入：PostgREST 参数化、函数内动态 SQL 规范
- [ ] 密钥管理：.env 敏感项、DB_PASSWORD、Logto app secret
- [ ] 网络安全：pg_hba.conf 访问控制、pgbouncer、APISIX 安全头/CSP
- [ ] RLS 作为数据访问的最后防线
- [ ] 审计与合规：登录日志、操作日志保留策略
- [ ] 安全 Checklist

---

## 安全 Checklist（待补全）

- [ ] 所有敏感变量不入库、不入日志
- [ ] 数据库账号最小权限（app_owner 等角色）
- [ ] RLS 覆盖所有业务表
- [ ] 网关启用 CSP/安全头
- [ ] 密钥定期轮换

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
