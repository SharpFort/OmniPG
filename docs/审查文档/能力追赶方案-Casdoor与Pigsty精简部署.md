# 能力追赶方案：补齐 OAuth + 精简部署 + 借鉴 Supabase 组件

> **背景：** 基于之前的本方案 vs Supabase 对比分析，识别可追赶的能力差距，提出具体的技术方案
> **前提：** 充分利用 Pigsty v4.3.0 的内置能力（Docker 模块、MinIO、Redis、监控栈）
> **数据来源：** GitHub API、APISIX 文档、Casdoor 文档、Pigsty 文档（2026-07-07）

---

## 一、OAuth 社交登录 → Casdoor + APISIX authz-casdoor

### 1.1 Casdoor 是什么

| 属性 | 值 |
|:---|:---|
| 仓库 | github.com/casdoor/casdoor |
| Stars | **13,890** |
| 语言 | Go |
| 许可 | **Apache 2.0** |
| 定位 | AI-Native IAM / SSO 平台 |

**Casdoor 提供的认证能力**（远超本方案当前的"用户名+密码"）：

| 能力 | 说明 |
|:---|:---|
| 🔷 OAuth 2.0 / OIDC | 完整实现，可做 Provider 和 Client |
| 🔷 社交登录 | GitHub, Google, WeChat, QQ, 钉钉, 飞书等 **100+** 提供商 |
| 🔷 SAML 2.0 | 企业 SSO（如对接 Microsoft 365、Okta） |
| 🔷 LDAP | 对接企业目录服务 |
| 🔷 WebAuthn | 生物识别 / 硬件密钥（Passkey） |
| 🔷 MFA | TOTP、短信、邮箱验证码 |
| 🔷 MCP Server | 支持 AI Agent 认证（独特优势 🔥） |
| 🔷 Web UI | 内置管理后台，用户自助注册/登录 |

### 1.2 与本方案的集成架构

```
用户 → APISIX (9080)
         │
         ├─ 未登录 → authz-casdoor 插件 → 重定向到 Casdoor 登录页
         │                                    │
         │                          ┌─────────┴──────────┐
         │                          │ GitHub / Google /   │
         │                          │ WeChat / LDAP / ... │
         │                          └─────────┬──────────┘
         │                                    │ 认证成功
         │                                    ▼
         │                              Casdoor 签发 JWT
         │                              (含 roles 数组)
         │                                    │
         └─ 已登录 ← JWT ←────────────────────┘
              │
              ├─ jwt-auth 插件 (RS256 验签)
              ├─ authz-casbin 插件 (API 鉴权)
              └─ → PostgREST → PG (RLS)
```

### 1.3 对现有方案的影响

| 现有组件 | 变化 | 说明 |
|:---|:---|:---|
| `user_login_sso()` | **保留** | 作为"本地账号密码登录"的回退方案 |
| `refresh_token_rtr()` | **保留** | Token 刷新逻辑不变 |
| `generate_rs256_jwt()` | **委托给 Casdoor** | Casdoor 负责 JWT 签发，本方案不再需要 plpython3u！ |
| `sys_secret` 中的私钥 | **移到 Casdoor** | 私钥由 Casdoor 管理，不再存 PG 中 |
| `sys_user` 表 | **同步** | Casdoor 用户 ↔ `sys_user` 需要同步机制 |
| plpython3u 依赖 | **🎉 消除！** | 不再需要，解决了 00 审查的 #1 阻塞问题 |

> **🎉 关键收益：接入 Casdoor 后，`generate_rs256_jwt()` 不再需要由 PG 实现。Casdoor 本身就是 JWT 签发服务。这意味着 plpython3u 的阻塞问题被**彻底绕过**。**

### 1.4 集成步骤概览

```
阶段 N（新增）：Casdoor 集成
├── 1. 通过 Pigsty Docker 模块部署 Casdoor 容器
├── 2. 配置 Casdoor：组织、应用、OAuth 提供商
├── 3. APISIX 启用 authz-casdoor 插件
├── 4. 配置 JWT claims 映射（Casdoor roles → JWT roles 数组）
├── 5. 同步 Casdoor 用户 → sys_user 表（可选）
├── 6. sys_user_session / sys_token_blacklist 保持独立
└── 7. 验收：GitHub/微信登录 → JWT → 调用 API → 200
```

---

## 二、Pigsty Docker 模块 → 精简部署架构

### 2.1 Pigsty Docker 模块能力

> Pigsty v4.3.0 的 DOCKER 模块（`pigsty.io/docs/docker/`）提供：

| 能力 | 说明 |
|:---|:---|
| **Docker 守护进程** | 在 Pigsty 管理的节点上启用 Docker |
| **容器模板** | 预配置的 MinIO、Redis、Grafana 等服务模板 |
| **统一监控** | Pigsty 的 Prometheus + Grafana 自动发现并监控这些容器 |
| **MinIO 集成** | Pigsty 内置 MinIO（pgsty 分支，带 CVE 修复） |
| **Redis 集成** | Pigsty 内置 Redis，带监控 Dashboard |
| **统一管理** | 所有服务在 Pigsty 的 inventory 中声明式管理 |

### 2.2 精简后的部署架构

**之前（Docker Compose 8 个独立容器 + Pigsty）：**

```
Docker Compose (docker-compose.yml)
├── postgres (pgcharles/pgtap:16)
├── redis
├── etcd
├── apisix
├── postgrest
├── swagger-ui
├── minio
└── loki

Pigsty (裸机 Ansible 部署)
├── PostgreSQL 集群 (Patroni ×3)
├── etcd 集群 (Patroni DCS)
├── Pgbouncer
├── HAProxy + Keepalived
├── Grafana + Prometheus/VictoriaMetrics
└── pgBackRest
```

**之后（Pigsty 统一管理 + 少量 Docker）：**

```
Pigsty (Ansible 声明式管理一切)
│
├── PostgreSQL 集群 (Patroni ×3)
├── Pgbouncer (连接池)
├── HAProxy + Keepalived (VIP)
├── etcd 集群 (Patroni DCS + APISIX 共用)
├── Grafana + VictoriaMetrics (统一监控) ← 监控所有!
│
├── Docker 模块管理的容器:
│   ├── MinIO (Pigsty 内置模板)        ← Pigsty 监控
│   ├── Redis (Pigsty 内置模板)        ← Pigsty 监控
│   ├── APISIX (自定义容器或裸机部署)   ← Pigsty 监控
│   ├── PostgREST                     ← Pigsty 监控
│   ├── Casdoor                       ← Pigsty 监控
│   ├── Policy Syncer (Go binary)     ← Pigsty 监控
│   └── Swagger UI                    ← Pigsty 监控
│
└── pgBackRest (PITR 备份)
```

### 2.3 Docker Compose 文件缩减

从 8 个独立容器缩减为：

```yaml
# 仅保留不能由 Pigsty 原生管理的无状态组件
services:
  apisix:
    image: apache/apisix:3.10.0-debian
    # ... 配置不变，连接 Pigsty 的 etcd

  postgrest:
    image: postgrest/postgrest:v14.14
    # ... 通过 Pgbouncer 连接 PG

  casdoor:
    image: casbin/casdoor:latest
    # ... 新增

  swagger-ui:
    image: swaggerapi/swagger-ui
    # ... 不变
```

> PG、etcd、Redis、MinIO、Pgbouncer、HAProxy、Grafana、Prometheus 全部由 Pigsty 原生管理，不出现在 Docker Compose 中。

### 2.4 统一监控的收益

Pigsty 的 Grafana（40+ Dashboard）可以直接监控：

| 服务 | Pigsty 监控方式 |
|:---|:---|
| PostgreSQL | pg_exporter → VictoriaMetrics |
| Pgbouncer | 内置 Dashboard |
| etcd | etcd Overview Dashboard |
| MinIO | MinIO Overview Dashboard |
| Redis | Redis Cluster/Instance Dashboard |
| HAProxy | Node HAProxy Dashboard |
| APISIX | Prometheus plugin → VictoriaMetrics |
| PostgREST | 健康检查端点 |
| Casdoor | 健康检查端点 (Go pprof) |
| Policy Syncer | 自定义 metrics 端点 |

---

## 三、可以从 Supabase 借鉴（甚至直接复用的）开源组件

### 3.1 强烈推荐复用

| 组件 | Stars | 许可 | 价值 | 集成难度 |
|:---|:---:|:---|:---|:---:|
| **pg_graphql** | 3,343 | Apache 2.0 | 直接安装在 PG 上，零额外服务 | 🟢 低 |
| **postgres-meta** | 1,213 | Apache 2.0 | RESTful API 管理 PG schema/roles | 🟡 中 |

#### pg_graphql — 零成本获得 GraphQL 能力

```sql
-- 在 Pigsty PG 中直接安装
CREATE EXTENSION pg_graphql;

-- 自动将 public/api_v1 schema 的表/视图暴露为 GraphQL
-- 无需额外服务，PostgREST 的 REST API 和 GraphQL 同时可用
```

> **价值：** 前端可以用 GraphQL 查询精确字段，减少 over-fetching。对比 Supabase：它用的也是同一个 pg_graphql。

#### postgres-meta — PG 管理 API

> 提供 `/tables`、`/roles`、`/extensions`、`/query` 等管理端点。可用于 Admin UI 中动态展示数据库结构。

### 3.2 评估后可考虑

| 组件 | Stars | 许可 | 价值 | 注意事项 |
|:---|:---:|:---|:---|:---|
| **Supabase Realtime** | 7,602 | Apache 2.0 | WebSocket 实时推送 | Elixir 语言，运维成本高；可用 pg_notify + WebSocket 轻量替代 |

#### Realtime — 需要权衡

Supabase Realtime 通过 PostgreSQL 逻辑复制（Logical Replication）监听数据变更，通过 WebSocket 推送给前端。

**替代方案：** 本方案已经有 `pg_notify → Policy Syncer → etcd → APISIX` 的事件链路。可以扩展 Syncer 增加 WebSocket 推送能力（Go 原生支持 WebSocket），避免引入 Elixir 运行时。

### 3.3 不推荐复用的（有更好的替代）

| Supabase 组件 | 为什么不推荐 | 本方案替代 |
|:---|:---|:---|
| **GoTrue** | Casdoor 功能更强（OAuth/OIDC/SAML/MFA），且与 APISIX 原生集成 | **Casdoor** |
| **Storage API** | 多一层 TypeScript 服务，MinIO 直接 S3 协议更高效 | **MinIO 直连** (Pigsty 托管) |
| **Kong** | APISIX 性能更好，且内置 authz-casbin + authz-casdoor | **APISIX** |
| **Supabase Studio** | 绑定 Supabase 生态，不自洽 | 自建 Admin UI (ART-D Pro) |

### 3.4 Supabase 之外的优质开源组件

| 组件 | 用途 | 与本方案的关系 |
|:---|:---|:---|
| **pg_cron** | 定时任务（已在方案中） | ✅ Pigsty 已内置 |
| **pg_net** | 异步 HTTP 请求（已在方案中） | ✅ Pigsty 已内置 |
| **pgsodium** | 透明列加密（已在方案中） | ⚠️ 许可需确认 |
| **pgjwt** | JWT 验证辅助（备选） | 🟡 Casdoor 签 JWT，可不依赖 |
| **pgvector** | 向量嵌入 | 🔮 未来可扩展 AI 搜索 |
| **pg_partman** | 自动分区管理 | 🔮 大规模租户数据优化 |
| **WAL-G** | 备份工具 | Pigsty 已内置 pgBackRest，但 WAL-G 是备选 |

---

## 四、追赶 Supabase 的路线图建议

### 当前能力 vs 追赶后

| 能力 | 当前 | 追赶到 |
|:---|:---|:---|
| 用户名密码登录 | ✅ | ✅ |
| OAuth 社交登录 | ❌ | ✅ Casdoor (100+ 提供商) |
| SAML/LDAP 企业 SSO | ❌ | ✅ Casdoor |
| MFA 多因素认证 | ❌ | ✅ Casdoor |
| WebAuthn/Passkey | ❌ | ✅ Casdoor |
| GraphQL API | ❌ | ✅ pg_graphql |
| Realtime WebSocket | ❌ | 🟡 轻量替代 / Supabase Realtime |
| Edge Functions | ❌ | ❌ (非必需，PG 函数已覆盖) |
| SDK 多语言支持 | ❌ | ❌ (投资回报低，用 OpenAPI 自动生成) |
| 统一监控 | ⚠️ 部分 | ✅ Pigsty 全面监控 |
| 精简部署 | 8 容器 + Pigsty | 3-4 容器 + Pigsty 内置服务 |

### 实施优先级

```
第一阶段（核心补强）
├── 1. Casdoor 集成 ← 解决 OAuth + 消除 plpython3u 依赖
├── 2. 精简部署 ← Pigsty Docker 模块统一管理
└── 3. pg_graphql ← 零成本添加 GraphQL

第二阶段（体验提升）
├── 4. 统一监控 ← Pigsty 内置 Grafana Dashboard
├── 5. 更新 01 文档 ← 反映新的部署架构
└── 6. 更新 02 文档 ← 移除 plpython3u 依赖

第三阶段（生态扩展）
├── 7. Realtime 方案评估
├── 8. pg_partman 多租户优化
└── 9. OpenAPI → 客户端 SDK 自动生成
```

---

## 五、对现有 6 份文档的影响

| 文档 | 主要变化 |
|:---|:---|
| **00-项目总纲** | 技术选型增加 Casdoor、pg_graphql；移除 plpython3u 和 pg_smtp_client |
| **01-环境搭建** | Docker Compose 大幅精简；Pigsty Docker 模块配置；Casdoor 容器 |
| **02-数据库建模** | 移除 `generate_rs256_jwt()` 依赖；`user_login_sso` 改为对接 Casdoor JWT |
| **03-API与认证层** | PostgREST JWT secret 对接 Casdoor 公钥；新增 Casdoor callback 路由 |
| **04-网关与同步器** | APISIX 增加 authz-casdoor 插件；Casbin model.conf 兼容 Casdoor JWT claims |
| **05-前端Admin** | 登录页增加"GitHub/微信登录"按钮；对接 Casdoor OAuth 流程 |

> **🎉 最重要的：接入 Casdoor 后，00-A3-1（plpython3u 缺失）和 02-B1（generate_rs256_jwt 未定义）两个阻塞问题被一并消除。**
