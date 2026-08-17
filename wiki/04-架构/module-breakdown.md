# 模块划分

> 状态：骨架占位 · 待补充
> 定位：按数据库 schema 划分的模块边界

## 内容清单

- [ ] schema 一览：public / api_v1 / extensions（及各自职责）
- [ ] public：核心业务表、RPC、视图、触发器、RLS
- [ ] api_v1：对外暴露的 API 视图与 RPC（db/api_v1）
- [ ] extensions：扩展与辅助数据（ip2region、geolite2 等）
- [ ] 各业务模块（IAM/用户/角色/菜单/组织/字典/审计/运维）归属哪个 schema
- [ ] 模块间依赖与数据流约束

---

## schema 职责表

| schema | 职责 | 目录 |
| --- | --- | --- |
| public | 核心业务逻辑 | db/src/public |
| api_v1 | 对外 API 暴露 | db/api_v1 |
| extensions | 扩展辅助 | db/extensions |

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
