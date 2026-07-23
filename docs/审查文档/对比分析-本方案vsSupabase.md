# 本方案 vs Supabase：能力对比分析

> **分析日期：** 2026-07-07
> **分析对象：** 本方案（零后端代码统一权限管理 + API 自动生成系统） vs Supabase（开源版）
> **数据来源：** supabase.com/docs、GitHub (supabase/supabase, Apache 2.0, 105k+ stars)、pigsty.io

---

## 一、架构层面对比

```
             本方案                                    Supabase
             ──────                                    ────────
             
  前端 Vue3 (ART-D Pro)                     前端 (任意框架 + Supabase JS SDK)
       │                                          │
       ▼                                          ▼
   APISIX 网关                                Kong / Cloudflare
   ├─ Casbin 权限判定 (内存)                   ├─ 无网关层鉴权
   ├─ JWT 验证 (RS256)                        ├─ JWT 透传
   ├─ 限流 / CORS                             └─ DDoS 防护 (Cloud 版)
   └─ JWKS 端点                                    │
       │                                          ▼
       ▼                                     PostgREST (内置)
   HAProxy + Keepalived (VIP)                 ├─ JWT → PG Role 映射
       │                                      ├─ RLS 数据级鉴权
       ▼                                      └─ RESTful API 自动生成
   PostgREST (×3)                                  │
   ├─ JWT → PG Role 映射                           ▼
   ├─ db-pre-request 黑名单检查               PostgreSQL (Supabase 托管)
   └─ RESTful API 自动生成                    ├─ RLS 策略 (核心安全)
       │                                      ├─ pgvector (向量)
       ▼                                      └─ Realtime (逻辑复制)
   Pigsty PostgreSQL (Patroni ×3)                  │
   ├─ PL/pgSQL 认证函数                       ┌───┴───┬──────────┐
   ├─ Casbin 视图                             ▼       ▼          ▼
   ├─ RLS 行级安全                         GoTrue   Storage    Realtime
   └─ pg_notify 触发器                     (认证)   (S3)     (WebSocket)
       │
       ▼
   Policy Syncer (Go) → etcd → APISIX 刷新
```

---

## 二、逐项能力对比

### 2.1 数据库

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **PG 引擎** | PostgreSQL 16（自管 Pigsty v4） | PostgreSQL（托管，版本由平台决定） |
| **高可用** | Patroni ×3 + etcd + HAProxy + VIP | 平台托管（用户不可见） |
| **连接池** | Pgbouncer（Pigsty 内置） | Pgbouncer（内置） |
| **备份恢复** | pgBackRest PITR（Pigsty 内置） | 平台托管（每天自动备份） |
| **扩展管理** | 531 扩展，自由安装 | 50+ 预装扩展，不可自定义 |
| **监控** | Grafana + VictoriaMetrics（Pigsty 内置） | Supabase Dashboard（只读面板） |
| **多租户** | ✅ **原生支持**（tenant_id + RLS） | ❌ 一个 Project = 一个 PG 实例（物理隔离） |
| **数据库即代码** | Dbmate migration + Git 管理 | Supabase CLI + migration |

> **结论：** Supabase 的 DB 是"交钥匙"模式——你不用管运维，但也无法定制。本方案给你**完全的 PG 控制权**（531 扩展自由装、自主调优），代价是你自己运维。

### 2.2 API 生成

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **API 引擎** | PostgREST v14 | PostgREST（版本由平台控制） |
| **自动 CRUD** | ✅ 表/视图 → RESTful | ✅ 表/视图 → RESTful |
| **自定义 RPC** | ✅ PL/pgSQL 函数 → /rpc/* | ✅ PL/pgSQL 函数 → /rpc/* |
| **API 文档** | Swagger UI（自动生成） | 内置 API 文档 |
| **SDK** | 无（直接用 fetch/axios） | JS/Dart/Python/C#/Swift/Kotlin SDK |
| **GraphQL** | ❌ 需另配 pg_graphql | ✅ 内置（pg_graphql） |
| **Realtime** | ❌ 无 | ✅ WebSocket + 逻辑复制 |
| **Edge Functions** | ❌ 无 | ✅ Deno Edge Functions |

> **结论：** 核心 API 能力几乎一致（都用 PostgREST）。Supabase 多了 SDK、GraphQL、Realtime 和 Edge Functions。但你的 RPC 函数（`user_login_sso`、`get_user_menu`）比 Supabase 的标准 CRUD 更灵活——你可以在数据库里写任意复杂业务逻辑，Supabase 会建议你放到 Edge Functions 里。

### 2.3 认证 (Auth)

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **认证引擎** | PL/pgSQL + plpython3u (JWT) | GoTrue（独立微服务，Go 语言） |
| **认证方式** | 用户名密码登录 | 邮箱/手机/ OAuth (Google, GitHub, etc.) / SAML |
| **JWT 签名** | RS256（数据库内签名）⚠️ plpython3u 依赖 | HS256/RS256（GoTrue 签名） |
| **Token 管理** | AT(15min) + RT(7天) + httpOnly Cookie | AT(1h) + RT(可配置) + 自动刷新 |
| **OAuth 社交登录** | ❌ 需自行实现 | ✅ 内置 20+ 提供商 |
| **MFA** | ❌ 无 | ✅ TOTP / 手机验证 |
| **Session 管理** | `sys_user_session` 表（自建） | GoTrue `auth.sessions` 表 |
| **Token 黑名单** | `sys_token_blacklist` + db-pre-request | GoTrue 内置 |
| **SSO 单设备登录** | ✅ 自建实现 | ✅ GoTrue 配置 |

> **结论：** 这是差距最大的领域。GoTrue 是经过实战检验的认证服务，支持 OAuth、MFA、密码重置、邮箱验证等开箱即用。你的方案认证能力止步于"用户名密码 + JWT"，如果需要社交登录或 MFA，需要大量额外开发。

### 2.4 权限控制 — 🏆 本方案的核心差异优势

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **权限模型** | **双层防御**：Casbin(API级) + RLS(数据级) | **单层**：RLS(数据级) |
| **API 鉴权位置** | APISIX 网关层（请求到达 DB 前拦截） | PostgREST → DB 内 RLS |
| **权限引擎** | Casbin (Lua) — 支持 RBAC/ABAC/自定义 | RLS USING 子句 — 只能做行级 |
| **权限规则管理** | `sys_role_api` 表 → 视图 → Casbin 策略 | RLS Policy SQL（写在 migration 中） |
| **权限变更生效** | **秒级**（pg_notify → Syncer → etcd → APISIX） | **即时**（RLS 始终生效） |
| **权限可视化** | Admin UI 直接管理角色-API 映射 | Dashboard 只读 RLS Policy SQL |
| **按钮级权限** | ✅ `sys_menu.permission_code` → 前端指令 | ❌ 需自行处理 |
| **多租户** | ✅ tenant_id + RLS (AS RESTRICTIVE) | ❌ 一个 Project 一个租户 |
| **角色动态分配** | ✅ 变更后即时黑名单旧 Token | ✅ RLS 基于 JWT claim 即时生效 |

> **🏆 这是你的方案对 Supabase 最显著的差异化优势。**
>
> Supabase 的权限完全依赖 RLS，这意味着：
> - 你能看哪些**行**由 RLS 控制（数据级）
> - 但你能调哪些**API**没有网关层拦截——请求总是到达 PostgREST，由 RLS 判断
>
> 你的方案在网关层就做了 API 鉴权。一个没有 DELETE 权限的用户的 DELETE 请求在 APISIX 就被 403 了，连 PG 都到不了。这在以下场景有实际价值：
> - **防御 DDoS/恶意扫描**：网关直接拒绝，不消耗 PG 连接
> - **审计清晰**：网关日志天然区分"鉴权拒绝"和"业务拒绝"
> - **第三方 API 接入**：给外部系统分配有权限限制的 API Key，但不能看其他数据

### 2.5 存储

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **存储引擎** | MinIO (S3 兼容) | Supabase Storage (S3 兼容) |
| **权限控制** | 未明确（MinIO 无集成到 Casbin） | ✅ RLS 集成（Storage 鉴权走 PG RLS） |
| **CDN** | ❌ 需自配 | ✅ Cloud 版内置 CDN |
| **图片变换** | ❌ 无 | ✅ 内置 (resize/format) |

> **结论：** 你的 MinIO 在方案中几乎是"悬挂状态"——架构图中不可见，与 Casbin/RLS 权限体系无集成。Supabase Storage 与 RLS 深度集成，上传的文件自动继承 bucket 的 RLS 策略。

### 2.6 开发体验

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **本地开发** | Docker Compose（8 个容器） | `supabase start`（Docker，一键启动全部） |
| **CLI 工具** | Dbmate + psql + curl | `supabase` CLI（migration、typegen、deploy） |
| **TypeScript 类型生成** | ❌ 无 | ✅ `supabase gen types` |
| **CI/CD 集成** | 需自建 | ✅ GitHub Actions 集成 |
| **客户端 SDK** | 无（裸 HTTP） | JS/Dart/Python/C#/Swift/Kotlin |
| **文档质量** | 6 份内部开发文档 | 业界顶级的文档 + 教程 + 示例 |

> **结论：** Supabase 的开发体验远胜于本方案。`supabase start` 一条命令起全栈，类型生成、SDK、CLI 都是成熟产品。你的方案目前只有内部文档，没有 CLI 工具链。

### 2.7 运维

| 维度 | 本方案 | Supabase |
|:---|:---|:---|
| **部署方式** | 裸机/VM（Pigsty Ansible） | 自托管 Docker / 托管云 |
| **最小部署** | 8 个容器 + Pigsty 节点 | 1 个 Docker Compose |
| **监控** | Grafana + VictoriaMetrics（完善） | Dashboard（基础） |
| **日志** | Vector → Loki | 平台日志 |
| **升级** | 手动逐组件升级 | `supabase upgrade` / 平台自动 |
| **成本** | 仅服务器费用 | 免费额度有限，Pro $25/月起 |

> **结论：** 运维复杂度是你的方案的主要成本。Pigsty + APISIX + etcd + Syncer + MinIO 的运维需要专业的 DBA/SRE 技能。Supabase 在这方面完全是"帮你做了"。

---

## 三、关键差异总结

### 你的方案显著优于 Supabase 的地方

| 优势 | 说明 |
|:---|:---|
| 🏆 **网关层 API 鉴权** | Casbin 在请求入口拦截，减轻 DB 压力，审计清晰 |
| 🏆 **真正的多租户** | tenant_id + RLS 共享 PG 实例，Supabase 做不到 |
| 🏆 **权限规则可视化** | sys_role_api 表可直接在 Admin UI 管理，Supabase 需写 SQL |
| 🏆 **完全自主可控** | 不绑定云平台，数据在自己服务器上 |
| 🏆 **531 个 PG 扩展** | Pigsty 的扩展生态远超 Supabase 的 50+ |
| 🏆 **无厂商锁定** | 所有组件都是标准开源软件，可替换 |
| 🏆 **角色变更秒级生效** | pg_notify → Syncer → etcd → APISIX 全链路自动化 |

### Supabase 显著优于你的方案的地方

| 优势 | 说明 |
|:---|:---|
| 🔷 **OAuth 社交登录** | 20+ 提供商开箱即用，无需写代码 |
| 🔷 **Realtime WebSocket** | 数据变更实时推送，IM/协作应用必备 |
| 🔷 **Edge Functions** | 在边缘运行业务逻辑，低延迟 |
| 🔷 **SDK 覆盖** | 6 种语言，前端开发效率翻倍 |
| 🔷 **开发体验** | 一条命令起全栈，CLI + 类型生成 + Dashboard |
| 🔷 **运维零负担** | 托管版免运维，自托管版也远比你的方案轻量 |
| 🔷 **GraphQL** | 内置 pg_graphql |
| 🔷 **社区与生态** | 105k+ Stars，海量教程和示例 |

### 可以相互"偷师"的地方

| 你可以借鉴 Supabase 的 | Supabase 可以从你借鉴的 |
|:---|:---|
| SDK 封装思路 | 网关层 Casbin 鉴权模式 |
| `supabase gen types` 类型生成 | 多租户 RLS 模式 |
| GoTrue 的 OAuth 流程 | API 权限可视化管理 |
| Edge Functions 的边缘计算理念 | pg_notify 实时策略同步 |
| Storage 与 RLS 的深度集成 | Role-in-JWT 的优化思路 |

---

## 四、完全 MIT 开源的优缺点

### 优点

| 优点 | 说明 |
|:---|:---|
| ✅ **零许可成本** | 商业使用无需付费或开源自己的代码，企业用户最关注 |
| ✅ **生态兼容性** | MIT 与 GPL/Apache 等所有许可兼容，打包分发无顾虑 |
| ✅ **社区吸引力** | MIT 是 GitHub 上最受欢迎的许可之一，降低贡献门槛 |
| ✅ **Pigsty 兼容** | Pigsty 本身也是宽松许可（Apache 2.0），无冲突 |
| ✅ **商业化友好** | 如果未来想做 SaaS/企业版，MIT 允许闭源商业化 |

### 缺点

| 缺点 | 说明 |
|:---|:---|
| ❌ **云厂商白嫖** | AWS/Azure 可以拿你的代码做托管服务，不贡献回社区（参考 Elasticsearch → SSPL） |
| ❌ **无 copyleft 保护** | 别人改进了你的代码不需要开源改进，可能导致碎片化 |
| ❌ **品牌稀释** | 任何人都可以 fork 后改个名字发布，用户分不清"官方版" |
| ❌ **对 Supabase 无竞争壁垒** | Supabase 本身是 Apache 2.0，MIT 不比它更有许可优势 |

### 对比 Supabase 的许可策略

| 维度 | 本方案 (MIT) | Supabase (Apache 2.0) |
|:---|:---|:---|
| 是否可闭源商用 | ✅ | ✅ |
| 是否必须公开修改 | ❌ | ❌ |
| 专利授权条款 | ❌ 无 | ✅ 明示专利授权 |
| 商标保护 | ❌ 无 | ✅ 有注册商标保护 |
| 对付云厂商 | ❌ 弱 | ❌ 同样弱 |

> **关键认识：** MIT 和 Apache 2.0 在这方面几乎等价——都无法阻止云厂商白嫖。真正能阻止的是 AGPL/SSPL/BSL 等。但选择 MIT 意味着你选择了"最大化采用率"而非"最大化控制权"。

---

## 五、战略建议

### 你的项目的合理定位

你的方案**不应该作为 Supabase 的竞品**，而应该定位为：

> **"自托管、多租户、网关层细粒度鉴权的企业级后端底座"**

目标场景是：
1. **已有多个微服务**，需要一个统一权限层
2. **SaaS 多租户**，需要在一个 PG 实例内隔离上百个租户
3. **合规要求高**，数据不能出自己机房
4. **权限管理精细化**，需要"谁能调哪个 API"的可视化管理
5. **团队已经有 DBA**，愿意用 SQL 写业务逻辑

### Supabase 更适合的场景

1. **新项目快速启动**，需要全栈能力（Auth + DB + API + Realtime + Storage）
2. **个人开发者/小团队**，没精力运维数据库
3. **需要实时推送**（聊天、协作、通知）
4. **需要社交登录**
5. **前端开发者主导**，不想写 SQL

### 一条可能的互补路线

你的方案甚至可以**作为 Supabase 的补充层**：

```
前端
  │
  ▼
Supabase (Auth/OAuth + SDK + Realtime + Storage)
  │
  ▼
你的方案 (APISIX Casbin 网关)
  │
  ▼
你的 Pigsty PG (多租户 + RLS + 自定义业务逻辑)
```

即：用 Supabase 解决"快"的部分（Auth、Realtime、SDK），用你的方案解决"深"的部分（多租户、网关鉴权、自定义权限）。但这需要评估集成成本。

---

## 六、总结

| 维度 | 你更强 | 差不多 | Supabase 更强 |
|:---|:---:|:---:|:---:|
| API 自动生成 | | ✅ | |
| 网关层鉴权 | 🏆 | | |
| 多租户 | 🏆 | | |
| 权限可视化管理 | 🏆 | | |
| PG 扩展生态 | 🏆 | | |
| 数据自主可控 | 🏆 | | |
| Auth / OAuth | | | 🔷 |
| Realtime | | | 🔷 |
| SDK / DX | | | 🔷 |
| 运维复杂度 | | | 🔷 |
| GraphQL | | | 🔷 |
| Edge Functions | | | 🔷 |
| 社区规模 | | | 🔷 |
| RLS 数据级安全 | | ✅ | |
| RESTful API | | ✅ | |

**一句话：** 你的方案在"权限控制的深度和灵活性"上胜过 Supabase，但在"开箱即用的广度"上远不及。MIT 许可对项目生态是正面的——你的核心优势（Casbin 双层鉴权 + 多租户）靠的是架构设计，不是靠许可限制来保护的。
