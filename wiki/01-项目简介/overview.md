# 项目简介

> 状态：骨架占位 · 待补充
> 定位：OmniPG 是什么、解决什么问题、以及从 casbin/casdoor 演进到 Logto 的历史

## 内容清单

- [ ] 一句话定位与核心价值
- [ ] 解决的问题与适用场景（多租户后台管理系统的后端）
- [ ] 演进历史：casbin / casdoor → Logto，为什么换
- [ ] 与 Pigsty / pg 扩展生态的关系
- [ ] 项目里程碑与当前版本状态

---

## 项目定位

OmniPG 以 PostgreSQL 为唯一数据与逻辑核心……

## 演进历史

- 早期：casbin 负责权限、casdoor 负责认证
- 现状：Logto 统一认证与授权
- 后端权限判定吸收 casbin 的 RBAC 思路（菜单/角色/数据范围/RLS）

## 适用范围

- 基于 Pigsty 部署的 PostgreSQL 集群
- 数据库即后端：RPC/视图/触发器承载业务逻辑
- PostgREST + APISIX 暴露 API

---

> 参考：本页内容需与当前代码保持一致，补充时请核对 `feature/logto-authn` 分支。
