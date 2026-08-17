# 05-前端Admin 审查问题清单

> **审查对象：** `05-前端Admin-开发与整体集成验收.md`（586行，18KB）
> **审查方法：** 对照 ART-D Pro 开源方案（https://www.artd.pro/docs/zh/）的能力矩阵，识别文档与目标方案的重叠和冲突
> **审查日期：** 2026-07-07
> **目标前端方案：** ART-D Pro（Vue3 + TypeScript + Element Plus + Tailwind CSS，MIT 许可，GitHub: Daymychen/art-design-pro）

---

## 🔴 阻塞级问题

### B1. 05 文档与 ART-D Pro 方案根本冲突 — 大部分代码是冗余的

> ART-D Pro 已经**完整实现了** 05 文档中第 2-7 节的所有内容：

| 05 文档内容 | ART-D Pro 已有能力 | 冲突程度 |
|:---|:---|:---|
| §2 Axios 封装 + Token 刷新拦截器 | 内置 `api-integration` 模块 | 🔴 完全冗余 |
| §3 Pinia 用户状态管理 | 内置 `state-config` 状态体系 | 🔴 完全冗余 |
| §4 路由守卫 + 动态路由 | 内置 `route-permission` 模块 | 🔴 完全冗余 |
| §5 `v-permission` 按钮指令 | 内置权限指令系统 | 🔴 完全冗余 |
| §6 登录页面 | 内置登录页（更完善的 UI） | 🔴 完全冗余 |
| §7 主布局（侧边栏+内容区） | 内置 `layout-theme` 布局系统 | 🔴 完全冗余 |
| §8.1-8.4 CRUD 管理页面 | 内置 CRUD 页面模板 + `useTable` Hook | 🟡 需适配字段 |

- [B1-1] **05 文档需要从根本上重写**，从"从零搭建前端项目"转变为"配置 ART-D Pro 对接 PostgREST 后端"。具体需要覆盖：
  - ART-D Pro 的 `VITE_APP_BASE_API` 环境变量指向 APISIX 网关
  - ART-D Pro 的登录接口适配我们的 `/rpc/user_login_sso` 的请求/响应格式
  - ART-D Pro 的菜单接口适配我们的 `/rpc/get_user_menu` 的响应格式
  - ART-D Pro 的 Token 刷新机制适配我们的 `refresh_token_rtr` 流程
  - ART-D Pro 的 CRUD 页面适配我们的 `sys_user`/`sys_role`/`sys_menu`/`sys_api` 表字段
- [B1-2] 是否考虑使用 ART-D Pro 的**精减版**（Lite Version，`/docs/zh/guide/lite-version.html`）作为起点？精减版是否更适合"只做前端壳，后端完全自定义"的场景？

### B2. ART-D Pro 的权限模型与本方案可能不兼容

> ART-D Pro 有自己的权限体系（文档路径：`/zh/guide/in-depth/permission.html`），其权限模型很可能是传统的"用户→角色→菜单/按钮"三级模型。但本方案还需要额外覆盖：
> - **API 级别的 Casbin 鉴权**（网关层，ART-D Pro 无感知）
> - **数据级 RLS 隔离**（数据库层，ART-D Pro 无感知）
> - **Role-in-JWT + 网关路由级拦截**

- [B2-1] ART-D Pro 的权限系统是"前端路由守卫 + 按钮显隐"，还是也包括后端 API 鉴权？如果 ART-D Pro 的后端接口格式与本方案不同，如何适配？
- [B2-2] ART-D Pro 的"服务端"文档（`/zh/pro/server/introduce.html`）是商业版的 NestJS 后端。本方案用 PostgREST 替代 NestJS，接口格式完全不同。需要明确声明：**"本方案不使用 ART-D Pro 的商业版后端，仅使用开源前端，后端全部由 PostgREST + 02 数据库函数提供"**。

### B3. `get_user_menu` 返回格式与 ART-D Pro 期望的菜单格式未知

> ART-D Pro 有"路由和菜单"（`route.html`）和"接口对接"（`api-integration.html`）文档，定义了前端期望的菜单/路由数据格式。

- [B3-1] ART-D Pro 期望的菜单接口响应格式是什么？是嵌套树（带 `children`）还是扁平数组（带 `parentId`）？这直接决定了 02 文档中 `get_user_menu()` 的返回格式。
- [B3-2] 如果 ART-D Pro 期望的格式与 02 当前实现不一致，需要修改哪一端？建议以 ART-D Pro 的格式为准（因为它是成熟的现成方案），后端 SQL 适配之。

---

## 🟡 重要级问题

### M1. 05 文档的 Axios baseURL 可能不正确

> 05 第 67 行：`baseURL: '/api/v1'` — 前端请求发到 `/api/v1/sys_user`，由 Vite 开发服务器代理或 nginx 转发。

但本方案的架构是：**前端 → APISIX(9080) → PostgREST(3000)**。

- [M1-1] 前端开发时（Vite dev server，端口 5173），请求 `/api/v1/sys_user` 如何到达 APISIX 的 9080 端口？需要配置 Vite proxy：
  ```js
  // vite.config.js
  server: {
    proxy: {
      '/api/v1': 'http://localhost:9080'
    }
  }
  ```
  05 文档未提及此配置。

- [M1-2] 生产环境前端部署在哪里？如果前端静态文件由 APISIX 直接 serve（或 nginx），`/api/v1` 路径会被 APISIX 路由拦截——这是正确的。但文档未描述生产部署架构。

### M2. Axios 拦截器刷新逻辑与 httpOnly Cookie 不兼容

> 05 第 103 行：`const refreshToken = getCookie('refresh_token')` — 从 Cookie 中读取 Refresh Token。
> 05 第 105 行：`axios.post('/api/v1/rpc/refresh_token_rtr', { p_old_rt: refreshToken })` — 将 RT 放在请求体中。

但 02 的 `refresh_token_rtr` 函数（第 393 行）从 `p_old_rt` 参数接收 RT。

- [M2-1] httpOnly Cookie 意味着 JavaScript 可以读取 Cookie（通过 `document.cookie`，因为 Cookie 没有设置 `HttpOnly` 属性？不对——02 的 Set-Cookie 明确设置了 `HttpOnly`！第 378/469 行）。

**这是矛盾：** 02 的 Cookie 设置了 `HttpOnly`，意味着 JavaScript **无法**通过 `document.cookie` 读取它。05 第 103 行的 `getCookie('refresh_token')` 会返回 `null`。刷新逻辑失效。

- [M2-2] 两种修复方向：
  - 方案 A：去掉 HttpOnly，让 JS 能读取（安全风险：XSS 可窃取 RT）
  - 方案 B：保留 HttpOnly，不通过 JS 读取，依赖浏览器的自动 Cookie 携带 + 后端的 Cookie 验证
  - 方案 C：RT 不放在 Cookie 中，改为放在 response body 中（失去 CSRF 防护）

### M3. Access Token 存储方式不安全

> 05 第 154 行：`token: sessionStorage.getItem('access_token')` — AT 存在 sessionStorage。

- [M3-1] sessionStorage 对 XSS 攻击不设防（任何脚本可以读取）。虽然 AT 只有 15 分钟有效期，但仍然存在窗口期。是否考虑：
  - 将 AT 也放在 httpOnly Cookie 中（完全无 JS 访问）
  - 或在 Service Worker 中存储
  - 或接受 sessionStorage 的权衡（社区常见做法）

### M4. 登录后将 AT 放在 sessionStorage 但 RT 在 httpOnly Cookie

> 05 第 168 行：`sessionStorage.setItem('access_token', data.access_token)` — 登录后 AT 存入 sessionStorage。

但 02 的 `user_login_sso` 响应是 `{"access_token": "...", "username": "..."}`——AT 在 response body 中，RT 在 Set-Cookie 头中。前端需要同时处理两者。

- [M4-1] 同一登录响应中，AT 从 body 拿，RT 从 Cookie 拿——这种"双通道"设计是否已经在 02→03→05 的链条中验证可行？ART-D Pro 的登录流程是否支持这种模式？

### M5. `buildRoutes` 的动态 import 路径不通用

> 05 第 199 行：`component: () => import(`@/views/${item.component}/index.vue`)`

- [M5-1] 这要求 `sys_menu.component` 字段的值能直接映射到 `@/views/` 下的目录。种子数据中（02 第 811 行）：`component: 'system/user/index'` — 这在 Vite 中是可以的（`@/views/system/user/index.vue`）。但如果菜单的 component 指向了不存在或名称不同的路径，会运行时崩溃。是否需要 fallback 或验证机制？
- [M5-2] ART-D Pro 自己如何管理动态路由？如果用 ART-D Pro 的方案，05 的 `buildRoutes` 是否还需要？

### M6. 全链路冒烟测试脚本使用 bash 语法

> 05 第 549 行起：`#!/bin/bash` — 完整的 bash 脚本。

- [M6-1] 06-06 审查已在多处指出 Windows/PowerShell 兼容性问题。这个冒烟测试脚本同样需要 PowerShell 版本，或者明确标注"Linux/macOS 环境执行"。
- [M6-2] 第 582 行：`curl ... http://localhost:9080/well-known/jwks.json` — JWKS 端点端口是 9080（网关数据面），这是正确的。但第 555/576 行：`$BASE_URL/rpc/user_login_sso` 使用 `localhost:9080/api/v1/rpc/...` — 这个 URL 经过 APISIX 的 proxy-rewrite（去 `/api/v1` 前缀）后转发到 PostgREST，路径变为 `/rpc/user_login_sso`。确认 proxy-rewrite 规则正确处理了 RPC 路径。

---

## 🟢 增强级问题

### E1. 与 ART-D Pro 的集成适配清单缺失

> 05 文档应增加一节"ART-D Pro 适配清单"，明确需要修改的配置文件和代码文件：

| ART-D Pro 文件 | 需要修改的内容 |
|:---|:---|
| `.env.development` | `VITE_APP_BASE_API = http://localhost:9080` |
| `vite.config.ts` | proxy 配置指向 APISIX |
| `src/api/` 下的接口文件 | 替换为本方案的 PostgREST 端点 |
| `src/store/` 权限模型 | 适配 `roles` 数组而非单一 `role` |
| `src/router/` 路由守卫 | 适配 `get_user_menu` 返回格式 |
| 登录页 | 适配 `user_login_sso` 的请求/响应格式 |
| Token 刷新 | 适配 httpOnly Cookie + body AT 双通道模式 |

### E2. ART-D Pro 的开源版 vs 商业版边界

- [E2-1] ART-D Pro 开源版中哪些功能可用，哪些仅在商业版中？例如：
  - 权限系统完整度？
  - CRUD 表格模板？
  - `useTable` Hook？
  - 如果核心权限功能仅在商业版，本方案需要回退到 05 文档原有的自建方案。

### E3. 05 文档中的 Vue 组件只有骨架无完整实现

> §8 中四个管理页面（user/role/menu/api）只有功能描述，没有具体代码。

- [E3-1] 使用 ART-D Pro 后，这些页面的开发策略是什么？
  - 直接使用 ART-D Pro 的 CRUD 页面模板 + `useTable` Hook？
  - 还是需要从 ART-D Pro 的示例页面复制修改？
  - 05 文档应该包含至少一个完整页面的示例代码作为模板。

### E4. 验收清单 F4（Token 无感刷新 15 分钟）需要实际等待

> 第 455 行："等 15 分钟后操作页面" — 这在实际验收中不现实。

- [E4-1] 是否可以将 AT 有效期在开发环境设为 1 分钟（通过 JWT payload 的 `exp` 字段），以便快速验证刷新逻辑？

### E5. 验收清单 F27（SSO 踢前登录）语义需澄清

> 第 513 行：02 的 `user_login_sso` 中 `is_used = TRUE` 的逻辑是：旧会话被标记为已用但**不会被立即踢下线**。旧 Access Token 仍然有效（直到过期或被加入黑名单）。真正的"踢下线"依赖 `kick_user` 函数将 jti 加入黑名单。

- [E5-1] SSO 登录后旧设备的行为是"Token 自然过期后刷新失败"还是"立即无法使用"？当前实现是前者。验收项 F27 的预期可能需要修正。

---

## 交叉依赖总结

05 文档的前端代码是否能运行，串联了整个项目的依赖链：

```
前端登录按钮
  → POST /rpc/user_login_sso
    → 02: generate_rs256_jwt() 🔴 未定义
    → 02: sha256() 🔴 未定义
    → 03: RPC 函数在 public 非 api_v1 🔴 404
    → 返回 AT + httpOnly Cookie RT
    
前端 Axios 拦截器
  → 读取 httpOnly Cookie 🔴 HttpOnly 导致 JS 读不到
  → POST /rpc/refresh_token_rtr
    → 同上依赖链
```

**这意味着即使 ART-D Pro 配置完美，如果 02 和 03 的阻塞问题不解决，前端登录/刷新都不会成功。**

---

## 总结概况

| 类别 | 数量 | 最关键的问题 |
|:---|:---:|:---|
| 🔴 阻塞级 | 3 | ① **文档需要整体重写**：从"从零搭建"变为"配置 ART-D Pro 对接" ② ART-D Pro 权限模型与本方案的兼容性待验证 ③ `get_user_menu` 格式未知 |
| 🟡 重要级 | 6 | Vite proxy 缺失、HttpOnly Cookie 矛盾、AT 存储、双通道 Token、动态路由、bash 脚本 |
| 🟢 增强级 | 5 | ART-D Pro 适配清单、开源/商业边界、页面代码骨架、验收时间、SSO 语义 |
| **合计** | **14** | |

### 核心建议

**05 文档目前是一份"通用 Vue3 前端开发指南"，与用户选择的 ART-D Pro 方案高度重叠。建议将 05 文档定位调整为：**

> **"ART-D Pro 集成指南：对接 PostgREST + Casbin 后端"**

包含：
1. ART-D Pro 安装与基础配置
2. 环境变量与 Vite proxy 配置
3. 登录接口适配（`user_login_sso` 的请求/响应格式映射）
4. 菜单接口适配（`get_user_menu` 的格式转换或后端 SQL 调整）
5. Token 刷新机制适配（httpOnly Cookie 方案选择）
6. CRUD 页面字段映射（sys_user/sys_role/sys_menu/sys_api）
7. 权限系统说明（前端路由守卫 + 后端 Casbin 的双层防护）
