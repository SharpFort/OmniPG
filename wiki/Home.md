# OmniPG 项目 Wiki

> **一句话介绍**：OmniPG 是一个基于 **Pigsty** 与 PostgreSQL 扩展生态构建的后端项目——以 PostgreSQL 为唯一数据与逻辑核心，通过 **PostgREST** 对外暴露 REST API，由 **APISIX** 网关统一路由与鉴权入口，并由 **Logto** 负责认证与授权，实现"数据库即后端"的极简架构。

## 技术栈

| 层次 | 组件 | 说明 |
| --- | --- | --- | --- |
| 基础设施 | Pigsty | 一键拉起 PostgreSQL 集群与周边组件（pgbouncer、redis 等） |
| 数据库 | PostgreSQL + 扩展 | 业务数据、RPC、视图、触发器、RLS 均在库内实现 |
| API 层 | PostgREST | 将数据库表/视图/RPC 直接暴露为 REST 接口 |
| 网关 | APISIX | 统一入口、路由、限流、CORS、安全头 |
| 认证授权 | Logto | OIDC 认证；RBAC/菜单/数据范围授权（吸收 casbin 方案） |
| 迁移 | dbmate | 数据表演进管理（`db/migrations/public`） |
| 测试 | pgTAP + E2E | 数据库单元测试与端到端集成测试 |

## 快速导航

| 目录 | 内容 | 适合谁 |
| --- | --- | --- | --- |
| [01-项目简介](01-项目简介/overview.md) | 定位、演进历史、技术栈全景 | 所有人 |
| [02-快速开始](02-快速开始/one-click-dev.md) | 本地开发环境一站式搭建 | 新开发者 |
| [03-部署指南](03-部署指南/deployment-overview.md) | 脚本一键 / 手动逐步两套部署方案 | 部署与运维 |
| [04-架构](04-架构/architecture-overview.md) | 系统拓扑、模块划分、认证授权设计、关键决策 | 架构师/后端 |
| [05-开发指南](05-开发指南/adding-api.md) | dbmate 迁移、新增 API 全流程、权限开发 | 后端开发者 |
| [06-API参考](06-API参考/postgrest.md) | PostgREST、网关路由、RPC 清单、Logto webhook | API 使用方 |
| [07-测试](07-测试/testing-overview.md) | pgTAP 测试、E2E、冒烟验证脚本 | 测试/开发者 |
| [08-运维](08-运维/security.md) | 安全设计、审计日志、备份恢复、分支策略 | 运维 |

## 快速入口

- 想跑起来看效果？→ [一键搭建本地开发环境](02-快速开始/one-click-dev.md)
- 想部署到服务器？→ [部署指南总览](03-部署指南/deployment-overview.md)
- 想了解认证授权怎么做的？→ [认证与授权设计](04-架构/auth-design.md)
- 想新增一个接口？→ [新增一个 API 的完整流程](05-开发指南/adding-api.md)
- 想查接口怎么调用？→ [PostgREST 使用指南](06-API参考/postgrest.md)

## 项目状态

- 当前主线：`feature/logto-authn`（Logto 认证授权改造）
- 认证授权演进：casbin / casdoor → Logto（后端吸收部分 casbin 方案）
- 分支策略：wiki 完成后收缩为 main 单主线 + 短生命周期分支（见 [分支策略](08-运维/branch-strategy.md)）

