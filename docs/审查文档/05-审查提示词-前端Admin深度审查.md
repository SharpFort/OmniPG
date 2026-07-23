# 🔍 05-前端Admin 深度审查提示词

> **用途：** 在新对话中粘贴此提示词，对 `05-前端Admin-开发与整体集成验收.md` 进行深度审查，并产出重写方案。
> **创建日期：** 2026-07-08
> **基于：** 04/04.5 审查经验 + 05 审查问题清单（14项）

---

## 任务：深度审查 05-前端Admin-开发与整体集成验收.md

### 项目背景

- **项目根目录：** `D:\WeChat Files\xiangmu`
- **项目目标：** 构建基于 PG + PostgREST + APISIX + Casbin + Casdoor + Policy Syncer(Go) 的零后端代码数据库驱动 Admin 管理系统
- **审查对象：** `05-前端Admin-开发与整体集成验收.md`（634行，20KB）
- **前端方案：** **ART-D Pro**（Vue3 + TypeScript + Element Plus + Tailwind CSS，MIT 许可，GitHub: Daymychen/art-design-pro，5.5k+ Stars）

### 前置条件（已通过审查）

- ✅ 01-环境搭建 v5.1 已审查通过
- ✅ 02-数据库建模 v2.0 已审查通过
- ✅ 03-API与认证层 v1.0 已审查通过
- ✅ 04-网关与同步器 v1.0 已审查通过（P0+P1 已修复）
- ✅ 04.5-Casdoor集成 已创建
- ✅ PostgREST v14 已部署，连接 Pgbouncer
- ✅ APISIX 3.17.0 已部署，内置 authz-casdoor + authz-casbin 插件
- ✅ Casdoor v3.108.0 已部署，连接 PostgreSQL
- ✅ Policy Syncer Go 已部署，Advisory Lock 选主 + SHA256 对账

---

## 一、原始文档（请完整阅读以下四份）

### 1.1 05-前端Admin-开发与整体集成验收.md（审查对象，634行）

> **请阅读完整原文：** `D:\WeChat Files\xiangmu\05-前端Admin-开发与整体集成验收.md`

### 1.2 00-项目总纲-背景理念技术选型.md（架构参考，636行）

> **请阅读完整原文：** `D:\WeChat Files\xiangmu\00-项目总纲-背景理念技术选型.md`
> 重点关注 §2.3 Role-in-JWT 优化、§6.2 JWT 链路（v4 更新）、§6.3 RLS 行级安全

### 1.3 05-审查-前端Admin问题清单.md（214行）

> **请阅读完整原文：** `D:\WeChat Files\xiangmu\审查文档\05-审查-前端Admin问题清单.md`

### 1.4 04.5-Casdoor集成.md（刚创建，896行）

> **请阅读完整原文：** `D:\WeChat Files\xiangmu\04.5-Casdoor集成.md`
> 重点关注 §3 APISIX 路由配置、§5 JWT Claims 与角色映射

---

## 二、已锁定决策（关键约束，不可违反）

### 2.1 后端接口层（02/03/04 已锁定）

| 决策项 | 锁定结论 | 影响05审查 |
|:---|:---|:---|
| JWT 签发架构 | **Casdoor RS256 签发**，PostgREST 仅验签 | 前端登录必须走 Casdoor OAuth 或本地回退 |
| JWKS 端点 | `/.well-known/jwks`（无 `.json` 后缀） | 前端无需直接访问 JWKS |
| RT 存储 | **httpOnly Cookie**（`refresh_token`） | JS 无法读取 RT，401 时直接调刷新接口 |
| AT 存储 | sessionStorage（15分钟有效期） | 前端需处理 AT 过期后的无感刷新 |
| pg_notify payload | JSON 格式 `{op, role_id, api_id, tenant_id, ts}` | 前端无需直接处理 |
| 多租户模型 | 所有表有 tenant_id + RLS | 前端请求自动携带 tenant_id（通过 JWT claim） |
| Soft Delete | 所有业务表含 deleted_at/is_active | 删除操作是 UPDATE 非 DELETE |
| RPC 函数位置 | `api_v1` schema（非 public） | 前端通过 APISIX 访问 `/rpc/*` 路径 |
| Admin API 端口 | **9180**（控制面），9080（数据面） | 前端不直接访问 Admin API |
| Policy Syncer | SHA256 对账 + Advisory Lock 选主 | 前端无需感知 |

### 2.2 认证架构（04.5 已锁定）

| 决策项 | 锁定结论 | 影响05审查 |
|:---|:---|:---|
| 主认证流程 | Casdoor OAuth 2.0 / OIDC | 前端使用 Casdoor JS SDK |
| 本地回退 | `user_login_sso`（Casdoor 不可用时） | 前端需实现回退检测 |
| 角色来源 | JWT `roles` 数组（Casdoor 组织内角色） | 前端从 JWT payload 读取角色 |
| Token 刷新 | `refresh_token_rtr`（httpOnly Cookie 自动携带） | 401 → 直接 POST 刷新接口 → 无需传参 |
| 登录响应 | `{"access_token": "...", "username": "..."}` + Set-Cookie | AT 从 body 拿，RT 从 Cookie 拿 |

### 2.3 前端技术栈（00 总纲已锁定）

| 组件 | 版本/方案 | 选型理由 |
|:---|:---|:---|
| 框架 | **Vue 3** + TypeScript | 生态成熟，ART-D Pro 基础 |
| UI 库 | **Element Plus** | ART-D Pro 内置 |
| 状态管理 | **Pinia** | ART-D Pro 内置 |
| 路由 | **Vue Router 4** | ART-D Pro 内置 |
| 前端方案 | **ART-D Pro**（MIT，5.5k+ Stars） | 已内置权限系统、CRUD 模板、动态路由 |
| CSS | **Tailwind CSS** | ART-D Pro 内置 |
| HTTP 客户端 | **Axios** | ART-D Pro 内置封装 |
| 构建工具 | **Vite 5** | ART-D Pro 内置 |

---

## 三、05 文档结构概览（634行）

| 章节 | 行号 | 内容 | 核心审查点 |
|:---|:---|:---|:---|
| §1 ART-D Pro 快速开始 | L1-100 | 克隆 + 适配清单 | 是否与 ART-D Pro 现有能力冲突？ |
| §2 Axios HTTP 封装 | L105-187 | 拦截器 + Token 刷新 | HttpOnly Cookie 读取矛盾？ |
| §3 Pinia 用户状态 | L191-281 | 登录/菜单/路由构建 | 是否与 ART-D Pro 内置状态管理冲突？ |
| §4 路由守卫 | L285-333 | beforeEach + 动态路由 | 是否与 ART-D Pro 内置路由守卫冲突？ |
| §5 按钮权限指令 | L337-372 | v-permission | 是否与 ART-D Pro 内置权限指令冲突？ |
| §6 登录页面 | L376-415 | 登录表单 | 是否与 ART-D Pro 内置登录页冲突？ |
| §7 主布局 | L419-457 | 侧边栏+内容区 | 是否与 ART-D Pro 内置布局冲突？ |
| §8 权限管理页面 | L461-490 | 用户/角色/菜单/API 管理 | 是否与 ART-D Pro CRUD 模板冲突？ |
| §9 全系统端到端验收 | L492-570 | 30 项验收 | 是否覆盖所有关键路径？ |
| §10 验收清单汇总 | L573-588 | 30 项 | 是否完整？ |
| 附录 | L592-634 | bash 冒烟测试脚本 | Windows 兼容性？ |

---

## 四、已知问题清单（来自 05-审查-前端Admin问题清单.md）

### 🔴 阻塞级（3个）— 文档需整体重写

| # | 问题 | 影响 |
|:---|:---|:---|
| **B1** | **05 文档与 ART-D Pro 方案根本冲突** — §2-7 的代码（Axios/Pinia/路由守卫/按钮指令/登录页/主布局）ART-D Pro 已内置，完全冗余 | 文档需从"从零搭建"改为"配置 ART-D Pro 对接" |
| **B2** | **ART-D Pro 权限模型与本方案可能不兼容** — ART-D Pro 是"前端路由守卫+按钮显隐"，本方案还需 API 级 Casbin + 数据级 RLS | 需明确前端权限仅做 UX，后端鉴权才是核心 |
| **B3** | **`get_user_menu` 返回格式与 ART-D Pro 期望的菜单格式未知** — 02 返回扁平数组，ART-D Pro 可能期望嵌套树 | 需确定格式适配方向 |

### 🟡 重要级（6个）

| # | 问题 |
|:---|:---|
| **M1** | Vite proxy 配置缺失（前端如何访问 APISIX 9080？） |
| **M2** | Axios 拦截器刷新逻辑与 httpOnly Cookie 不兼容（`getCookie('refresh_token')` 返回 null） |
| **M3** | Access Token 存储在 sessionStorage（XSS 风险） |
| **M4** | 双通道 Token 模式（AT from body + RT from Cookie）是否已验证可行？ |
| **M5** | `buildRoutes` 动态 import 路径不通用（运行时崩溃风险） |
| **M6** | 冒烟测试脚本使用 bash 语法（Windows 不兼容） |

### 🟢 增强级（5个）

| # | 问题 |
|:---|:---|
| **E1** | ART-D Pro 适配清单缺失（应列出需修改的配置文件） |
| **E2** | ART-D Pro 开源版 vs 商业版边界不清晰 |
| **E3** | §8 四个管理页面只有骨架无完整实现 |
| **E4** | 验收 F4 需等待 15 分钟（开发环境应缩短 AT 有效期） |
| **E5** | 验收 F27 SSO 语义需澄清（旧 Token 自然过期 vs 立即失效） |

---

## 五、审查要求

### 5.1 线上调研（必须执行）

对文档中涉及的外部组件获取最新信息：

| 组件 | 调研内容 | 禁止行为 |
|:---|:---|:---|
| **ART-D Pro** | 最新开源版能力矩阵（权限系统、动态路由、CRUD 模板、`useTable` Hook） | 禁止用训练数据描述 |
| **ART-D Pro** | 期望的菜单/路由数据格式（嵌套树 vs 扁平数组） | 必须查官方文档 |
| **ART-D Pro** | 开源版 vs 商业版功能边界 | 必须查官方文档 |
| **Casdoor JS SDK** | `casdoor-javascript-sdk` 最新 API | 确认前端集成方式 |
| **PostgREST** | 前端直接访问 PostgREST vs 通过 APISIX 网关的区别 | 确认最佳实践 |
| **Element Plus** | 最新版本（v2.x）的表格/表单/树形组件 API | 确认 CRUD 页面可用 |

### 5.2 审查维度

| 维度 | 检查重点 |
|:---|:---|
| **准确性** | ART-D Pro 实际能力 vs 文档中"手写实现"的冲突程度 |
| **完整性** | 是否覆盖 Casdoor OAuth 登录 + 本地回退 + Token 刷新 + 菜单加载 + 权限管理 |
| **一致性** | 与 02 v2 的 RPC 函数签名、与 03 v1 的 JWT 配置、与 04 v1 的 APISIX 路由、与 04.5 的 Casdoor 配置 |
| **安全性** | httpOnly Cookie 处理、XSS 防护、CSRF 防护、Token 存储 |
| **性能** | Vite proxy 性能、动态路由加载性能、大数据量表格性能 |
| **可执行性** | 文档中的代码是否可直接运行（无 import 路径错误、无 API 不匹配） |
| **ART-D Pro 适配** | 哪些文件需要修改、哪些配置需要新增、哪些 ART-D Pro 内置功能可直接使用 |

### 5.3 子代理分工（启动 3 个并行子代理）

| 子代理 | 任务 | 输出 |
|:---|:---|:---|
| **A：线上调研** | 获取 ART-D Pro 最新文档（能力矩阵、菜单格式、权限系统、CRUD 模板）、Casdoor JS SDK API、Element Plus 最新版本 | 版本事实核对表 |
| **B：技术分析** | 分析 05 文档代码的正确性（Axios 拦截器、Pinia store、路由守卫、buildRoutes）；分析 ART-D Pro 内置能力与文档代码的冲突程度；分析 httpOnly Cookie 刷新方案的可行性 | 技术审查报告 |
| **C：文档对比** | 逐行对比 05 文档与 05-审查-前端Admin问题清单.md，验证已知问题并发现新问题；对比 05 文档与 ART-D Pro 官方文档的能力覆盖度 | 文档对比报告 |

---

## 六、输出物要求

| # | 产出物 | 格式 | 说明 |
|:---|:---|:---|:---|
| 1 | **审查报告** | Markdown | 每个问题的准确性判定 + 修复建议 |
| 2 | **技术审查报告** | Markdown | 代码冲突分析、ART-D Pro 能力映射、安全性评估 |
| 3 | **文档对比报告** | Markdown | 已知问题验证状态 + 新发现问题（含严重程度） |
| 4 | **版本事实核对表** | Markdown | 组件名/文档声称版本/实际最新版本/来源URL |
| 5 | **ART-D Pro 适配方案** | Markdown | 明确列出：哪些 ART-D Pro 内置功能可直接使用、哪些需要配置、哪些需要自定义开发 |
| 6 | **重写后的完整文档** | Markdown | 覆盖 05 文档（修复所有问题，或标注为"设计保留"） |
| 7 | **优先级修复清单** | Checklist | P0/P1/P2/P3 四级排序 |

---

## 七、执行流程

```
Step 1: 加载 skill（hermes-agent、systematic-debugging）
Step 2: 阅读四份原始文档（05目标文档 + 00总纲 + 05审查清单 + 04.5 Casdoor集成）
Step 3: 输出审查方案（调研计划、子代理分工），等待确认
Step 4: 确认后启动 3 个子代理并行执行
Step 5: 汇总结果 → 审查报告 + 适配方案 + 重写文档 + 优先级清单
Step 6: 更新 MEMORY.md（记录已通过审查的里程碑）
```

---

## 八、已知经验（来自 01/02/03/04/04.5 审查）

| 经验 | 说明 |
|:---|:---|
| ✅ Casdoor JWKS 端点无 `.json` 后缀 | 04/04.5 已确认 |
| ✅ JWT 签发已委托 Casdoor | 05 不能有本地 JWT 签名代码 |
| ✅ APISIX Admin API 端口是 9180 | 05 不直接访问 Admin API |
| ✅ pg_notify payload 是 JSON | 05 无需直接处理 |
| ✅ 开发/生产环境通过 .env 管理 | 05 配置文件需支持环境变量替换 |
| ✅ RT 在 httpOnly Cookie 中 | JS 无法读取，401 时直接调刷新接口 |
| ✅ AT 在 sessionStorage 中（15分钟） | 前端需处理无感刷新 |
| ✅ `get_user_menu` 返回扁平数组（含 parent_id） | 前端或 SQL 需构造嵌套树 |
| ✅ ART-D Pro 已内置权限系统/CRUD/动态路由 | 05 文档不应重复造轮子 |
| ⚠️ GitHub API 可能受限 | 如 curl 失败，使用 web_search 作为 fallback |

---

## 九、审查重点（避免重蹈 02/03/04 中发现的问题）

| 02/03/04 典型错误 | 05 对应检查点 |
|:---|:---|
| JWT 签发架构冲突 | 前端登录是否走 Casdoor OAuth？本地回退是否正确调用 `user_login_sso`？ |
| Admin API 端口错误 | 05 不涉及 Admin API（前端不直接访问） |
| RLS 仅覆盖部分表 | 前端无需直接处理 RLS，但需确认多租户数据隔离的验收方法 |
| 缺 updated_at 自动更新 | 05 不涉及建表 |
| pg_notify payload 过简 | 05 无需直接处理 |
| CSV 格式与 MD5 不匹配 | 05 不涉及 |
| 缺少 Advisory Lock | 05 不涉及 |
| 未容器化 | 前端是否加入 Docker Compose？ |
| **新增：与 ART-D Pro 能力冲突** | 05 文档的代码是否与 ART-D Pro 内置功能重复？ |
| **新增：httpOnly Cookie 读取矛盾** | `getCookie('refresh_token')` 在 HttpOnly 下返回 null |
| **新增：双通道 Token 模式** | AT from body + RT from Cookie 是否前端已验证可行？ |

---

## 十、审查通过标准

- ✅ 所有 🔴 P0 阻塞级问题已修复（文档定位调整、ART-D Pro 兼容性确认、菜单格式确定）
- ✅ 所有 🟡 P1 重要级问题已修复或明确标注为"设计保留"
- ✅ 前端代码可直接运行（无 import 路径错误、无 API 不匹配）
- ✅ 与 02 v2 / 03 v1 / 04 v1 / 04.5 的跨文档一致性确认
- ✅ ART-D Pro 适配方案明确（哪些内置、哪些配置、哪些自定义）
- ✅ 验收清单覆盖所有关键路径（含 Casdoor OAuth + 本地回退 + Token 刷新 + 权限管理）
- ✅ 冒烟测试脚本兼容 Windows（PowerShell 版本）

---

## 十一、ART-D Pro 核心调研问题清单

在审查过程中，子代理 A 需要重点回答以下问题：

### 11.1 ART-D Pro 开源版能力边界

1. ART-D Pro 开源版（GitHub: Daymychen/art-design-pro）的权限系统具体包含哪些功能？
   - 是否支持动态路由（从后端获取菜单生成路由）？
   - 是否支持按钮级权限指令？
   - 是否支持角色管理？
2. ART-D Pro 的 CRUD 页面模板（`useTable` Hook）是否支持自定义字段映射？
3. ART-D Pro 的登录流程是否可自定义（替换为 `user_login_sso`）？
4. ART-D Pro 的 Token 刷新机制是否可自定义（适配 httpOnly Cookie 方案）？
5. ART-D Pro 的菜单接口期望的格式是什么（嵌套树 vs 扁平数组）？

### 11.2 ART-D Pro 与本方案的适配点

1. ART-D Pro 的 `api-integration` 模块如何适配 PostgREST 的 RESTful 风格？
2. ART-D Pro 的 `route-permission` 模块如何适配 Casbin 的 API 鉴权？
3. ART-D Pro 的 `state-config` 模块如何适配本方案的双 Token 模式？
4. ART-D Pro 的 `layout-theme` 模块是否需要修改以适配本方案的菜单结构？

### 11.3 Casdoor JS SDK 集成

1. `casdoor-javascript-sdk` 的最新 API 是什么？
2. 如何配置 SDK 的 `serverUrl`、`clientId`、`redirectPath`？
3. SDK 是否支持静默登录（silentSignin）？
4. SDK 是否支持 Token 自动刷新？

---

## 十二、预期重写方向（供审查时参考）

基于 B1 问题（文档与 ART-D Pro 冲突），05 文档可能需要从以下方向重写：

### 方向 A：ART-D Pro 集成指南（推荐）

将 05 文档定位为 **"ART-D Pro 集成指南：对接 PostgREST + Casbin 后端"**，包含：

1. **ART-D Pro 安装与基础配置**
   - 克隆项目、安装依赖
   - `.env.development` 配置（`VITE_APP_BASE_API` 指向 APISIX）
   - `vite.config.ts` proxy 配置

2. **登录接口适配**
   - 替换 ART-D Pro 默认登录逻辑为 `user_login_sso`
   - 适配请求/响应格式（`p_username`/`p_password` → `access_token`）
   - 处理 httpOnly Cookie（RT 不可 JS 读取）

3. **Casdoor OAuth 集成**
   - 集成 Casdoor JS SDK
   - 配置 OAuth 重定向流程
   - 实现本地回退检测

4. **菜单接口适配**
   - 适配 `get_user_menu` 返回格式
   - 扁平数组 → ART-D Pro 期望格式的转换
   - 动态路由生成

5. **Token 刷新机制**
   - 401 自动无感刷新
   - httpOnly Cookie 自动携带
   - 新 AT 更新到 sessionStorage

6. **CRUD 页面字段映射**
   - `sys_user`/`sys_role`/`sys_menu`/`sys_api` 字段 → Element Plus 表格/表单
   - 使用 ART-D Pro 的 `useTable` Hook

7. **权限系统说明**
   - 前端路由守卫（UX 层）
   - 后端 Casbin 鉴权（安全层）
   - 双层防护的职责分工

### 方向 B：保留现有代码但标注 ART-D Pro 替代方案

如果审查后认为部分代码仍需保留（如高度定制化的逻辑），应在每个代码块旁标注：

> **ART-D Pro 替代：** 此功能可使用 ART-D Pro 内置的 `xxx` 模块替代，配置方式如下...

---

> **本提示词由主代理根据 01/02/03/04/04.5 审查经验 + 05 审查问题清单自动生成，确保审查标准一致、无遗漏。**
