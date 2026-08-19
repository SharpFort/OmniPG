# OmniPG 项目 Wiki

> **一句话介绍**：OmniPG 是一个基于 **Pigsty** 与 PostgreSQL 扩展生态构建的后端项目——以 PostgreSQL 为唯一数据与逻辑核心，通过 **PostgREST** 对外暴露 REST API，由 **APISIX** 网关统一路由与鉴权入口，并由 **Logto** 负责认证与授权（RLS 行级安全做数据级授权），实现"数据库即后端"的极简架构。

## 技术栈

| 层次 | 组件 | 说明 |
| --- | --- | --- |
| 基础设施 | Pigsty v4.4.0 | 拉起 PostgreSQL 18 集群与周边组件（pgBouncer、Redis、etcd、监控） |
| 数据库 | PostgreSQL 18 + 扩展 | 业务数据、RPC、视图、触发器、RLS 均在库内实现（db/） |
| API 层 | PostgREST v14.15 | 将 api_v1_public 的视图/RPC 自动暴露为 REST（宿主 3100） |
| 网关 | APISIX 3.17.0 | 统一入口、路由、jwt-auth 验签、webhook HMAC 验签、CORS（etcd 存储） |
| 认证授权 | Logto OSS v1.42 | OIDC 认证、组织/角色管理、Webhook 事件推送；授权判定在 PG（RLS + has_permission） |
| 迁移 | dbmate | 数据表演进管理（db/migrations/public，当前 v0.1.0 基线 064/065/066） |
| 测试 | pgTAP + E2E | 数据库单元测试与端到端集成测试（make test） |

## 快速导航

| 目录 | 内容 | 适合谁 |
| --- | --- | --- |
| [01-项目简介](01-项目简介/overview.md) | 定位、演进历史、技术栈全景 | 所有人 |
| [02-快速开始](02-快速开始/one-click-dev.md) | 本地开发环境一站式搭建 | 新开发者 |
| [03-部署指南](03-部署指南/deployment-overview.md) | 脚本一键 / 手动逐步两套部署方案 | 部署与运维 |
| [04-架构](04-架构/architecture-overview.md) | 系统拓扑、模块划分、认证授权设计、关键决策 | 架构师/后端 |
| [05-开发指南](05-开发指南/adding-module.md) | 新建业务模块、新增 API 全流程、迁移、权限开发 | 后端开发者 |
| [06-API参考](06-API参考/postgrest.md) | PostgREST、网关路由、RPC 清单、Logto webhook | API 使用方 |
| [07-测试](07-测试/testing-overview.md) | pgTAP 测试、E2E、冒烟验证脚本 | 测试/开发者 |
| [08-运维](08-运维/security.md) | 安全设计、审计日志、备份恢复、分支策略 | 运维 |

## 快速入口

- 想跑起来看效果？→ [一键搭建本地开发环境](02-快速开始/one-click-dev.md)
- 想部署到服务器？→ [部署指南总览](03-部署指南/deployment-overview.md)
- 想了解认证授权怎么做的？→ [认证与授权设计](04-架构/auth-design.md)
- 想新建一个业务模块？→ [新建业务模块完整指南](05-开发指南/adding-module.md)
- 想新增一个接口？→ [新增一个 API 的完整流程](05-开发指南/adding-api.md)
- 想查接口怎么调用？→ [PostgREST 使用指南](06-API参考/postgrest.md)
- 想排查线上问题？→ [生产问题排查](08-运维/production-troubleshooting.md)

## 项目状态

- 当前主线：master（已收敛：feature/logto-authn 与 wiki 编写成果全部合并，旧分支已归档删除）
- 代码基线：v0.1.0（迁移 064/065/066）
- 认证授权演进：casbin / casdoor → **Logto**（认证）+ **RLS / has_permission**（授权，吸收 casbin 的 RBAC 思路）
- ✅ 2026-08-19 网关侧收敛：Casdoor / Syncer 残留已清理（setup_apisix.sh、apisix.yaml、verify-webhook/ 已删除；部署链统一 init-apisix-routes.sh；ci.yml syncer-check 已移除）
- 分支策略：master 单主线 + 短生命周期分支，收敛已于 2026-08-18 完成（见 [分支策略](08-运维/branch-strategy.md)）

> 说明：本 wiki 以当前代码为准编写；历史过程文档 docs/ 已在 wiki 完成后归档清理（git 历史可查）。