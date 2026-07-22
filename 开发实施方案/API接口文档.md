# OmniPG Admin — 后端 API 接口文档

> **版本：** v1.0  
> **日期：** 2026-07-21  
> **项目：** 零后端代码 Admin 管理后端  
> **架构：** PostgreSQL + PostgREST + APISIX + Casdoor

---

## 目录

1. [项目概述](#1-项目概述)
2. [架构说明](#2-架构说明)
3. [Migration 文件目录](#3-migration-文件目录)
4. [认证与权限](#4-认证与权限)
5. [API 接口清单](#5-api-接口清单)
   - 5.1 认证接口
   - 5.2 系统统计
   - 5.3 租户管理
   - 5.4 部门管理
   - 5.5 用户管理
   - 5.6 角色管理
   - 5.7 API 资源管理
   - 5.8 菜单管理
   - 5.9 关联关系管理
   - 5.10 审计与监控
6. [HTTP 请求示例](#6-http-请求示例)
7. [错误码说明](#7-错误码说明)

---

## 1. 项目概述

OmniPG 是一个零后端代码的 Admin 管理后端项目。**所有业务逻辑均在 PostgreSQL 中通过 PL/pgSQL 实现**，API 层由 PostgREST 自动暴露，网关层由 APISIX 处理 JWT 验证和 Casbin 鉴权。

### 核心特性

| 特性 | 实现 | 说明 |
|:---|:---|:---|
| **认证** | JWT + Refresh Token 轮转 + SSO 单设备登录 | 由 Casdoor 统一签发 JWT，APISIX 网关验证签名 |
| **授权** | Casbin (RBAC + RESTful 路径匹配) | 策略存储在 PostgreSQL，通过 Go Syncer 同步至网关内存 |
| **多租户** | `tenant_id` 行级隔离 + RLS | 每个租户独立数据空间，PostgreSQL RLS 强制隔离 |
| **审计** | `sys_audit_log` 记录所有数据变更 | 触发器自动记录 INSERT/UPDATE/DELETE 操作 |
| **安全** | Argon2id 密码哈希 + Token 黑名单 | 密码不可逆存储，登出 Token 即时失效 |

### 技术栈分层

```
┌─────────────────────────────────────────────────────┐
│  接入层                                              │
│  APISIX (Port 9080)                                 │
│  ├─ jwt-auth        → JWT 签名验证 (Casdoor JWKS)  │
│  ├─ authz-casbin    → 内存中 RBAC 策略匹配         │
│  ├─ 限流            → Redis + Token Bucket         │
│  └─ CORS            → 跨域处理                     │
├─────────────────────────────────────────────────────┤
│  同步层                                              │
│  Go Syncer                                          │
│  ├─ pg_notify 监听   → 角色/API 关联变更           │
│  ├─ casbin_rule 视图 → 生成 p 规则                 │
│  └─ Admin API       → 更新 APISIX Plugin metadata  │
├─────────────────────────────────────────────────────┤
│  API 层                                              │
│  PostgREST (Port 3000)                              │
│  ├─ db-schemas: api_v1       → 自动暴露视图/函数   │
│  ├─ db-pre-request           → Token 黑名单检查    │
│  └─ JWT roles → SET ROLE    → 数据库角色切换       │
├─────────────────────────────────────────────────────┤
│  数据层                                              │
│  PostgreSQL                                         │
│  ├─ RLS (Row Level Security) → 行级安全策略        │
│  ├─ GRANT                    → 角色权限分配        │
│  ├─ PL/pgSQL                 → 业务逻辑实现        │
│  ├─ Triggers                 → 审计/安全/通知      │
│  ├─ casbin_rule 视图          → p 规则生成         │
│  └─ pg_notify                → 变更事件推送        │
└─────────────────────────────────────────────────────┘
```

---

PostgREST 根据 `db-schemas = "api_v1"` 自动暴露：

| 类型 | HTTP 方法 | URL 模式 | 示例 |
|:---|:---|:---|:---|
| 视图 | GET | `/view_name` | `GET /v_user_list` |
| 视图 | POST | `/view_name` | `POST /sys_user` |
| 视图 | PATCH | `/view_name?id=eq.xxx` | `PATCH /sys_user?id=eq.xxx` |
| 视图 | DELETE | `/view_name?id=eq.xxx` | `DELETE /sys_user?id=eq.xxx` |
| 函数 | POST/GET | `/rpc/func_name` | `POST /rpc/user_login_sso` |

### Casbin 鉴权流程

```
1. 客户端请求 → APISIX
2. APISIX jwt-auth 插件验证 JWT 签名（Casdoor JWKS）
3. APISIX authz-casbin 插件在内存中匹配策略
4. 匹配规则: p.sub == JWT.roles[0] && keyMatch(r.path, p.obj) && r.act == p.method
5. 通过 → 转发 PostgREST | 拒绝 → 403
```

> **说明：** APISIX authz-casbin 插件基于 Lua Casbin，策略在网关进程内存中匹配。
> 策略由 Go Syncer 通过 pg_notify 监听 `sys_role_api` 变更，经 `casbin_rule` 视图生成 p 规则，
> 再通过 APISIX Admin API 更新 Plugin metadata，触发网关重载。

**Casbin 规则数据源（casbin_rule 视图）：**

```sql
-- casbin_rule 视图自动从 sys_role_api 生成 p 规则
SELECT 'p' AS ptype, role_code AS v0, path AS v1, method AS v2
FROM sys_role_api ra
JOIN sys_role r ON ra.role_id = r.id
JOIN sys_api a ON ra.api_id = a.id
WHERE r.deleted_at IS NULL AND a.deleted_at IS NULL;
```

---

## 3. Migration 文件目录

共 **18 个 migration 文件**（按执行顺序排列）：

| # | 文件名 | 阶段 | 说明 |
|:---:|:---|:---:|:---|
| 001 | `20260707000001_init_tables.sql` | DB Core | 6 张业务表 + 2 张系统表 + 1 个触发器函数 |
| 002 | `20260707000002_create_relation_sessions_blacklist.sql` | DB Core | 关联表 + 会话表 + 黑名单表 + 审批流表 |
| 003 | `20260707000003_create_casbin_view.sql` | DB Core | casbin_rule 视图（p 规则视图，由 sys_role_api 生成，过滤软删除，供 Go Syncer 读取） |
| 004 | `20260707000004_create_notify_triggers.sql` | DB Core | pg_notify 触发器（角色变更通知） |
| 005 | `20260707000005_create_auth_functions.sql` | DB Core | 认证函数（登录/刷新/黑名单/踢人） |
| 006 | `20260707000006_create_permission_functions.sql` | DB Core | 权限管理函数（菜单树/审批） |
| 007 | `20260707000007_create_security_triggers.sql` | DB Core | 安全触发器（角色变更即时生效）+ updated_at |
| 008 | `20260707000008_enable_rls_policies.sql` | DB Core | RLS 行级安全策略（8 张表） |
| 009 | `20260707000009_seed_data.sql` | DB Core | 种子数据（默认租户/部门/管理员/角色） |
| 010 | `20260707000010_cleanup_cron.sql` | DB Core | pg_cron 定时清理任务 |
| 011 | `20260707000011_audit_log_table.sql` | DB Core | 审计日志表 |
| 012 | `20260707000012_audit_triggers.sql` | DB Core | 审计触发器函数 + 4 表绑定 |
| 013 | `20260707000013_postgrest_api_v1.sql` | Phase 1 | api_v1 视图层(15) + RPC 包装(10) + GRANT(32) |
| 014 | `20260707000014_auth_rpc_functions.sql` | Phase 2 | 认证增强 RPC（logout/get_current_user/get_user_permissions/health_check） |
| 015 | `20260707000015_system_management_api.sql` | Phase 3 | 系统管理视图(5) + RPC(8) + GRANT(16) |
| 016 | `20260707000016_relationship_management.sql` | Phase 4 | 关联关系视图(4) + RPC(7) + GRANT(15) |
| 017 | `20260707000017_audit_session_monitoring.sql` | Phase 5 | 审计监控视图(4) + RPC(6) + GRANT(10) |

### 统计汇总

| 阶段 | 视图 | RPC 函数 | GRANT |
|:---|:---:|:---:|:---:|
| DB Core (001-012) | 1 | 9 | 0 |
| Phase 1: 基础设施 (013) | 15 | 10 | 32 |
| Phase 2: 认证增强 (014) | 0 | 4 | 4 |
| Phase 3: 系统管理 (015) | 5 | 8 | 16 |
| Phase 4: 关联关系 (016) | 4 | 7 | 15 |
| Phase 5: 审计监控 (017) | 4 | 6 | 10 |
| **合计** | **29** | **44** | **77** |

---

## 4. 认证与权限

### 4.1 认证流程

```
1. POST /rpc/user_login_sso { username, password }
   → 返回 { access_token, username }
   → Set-Cookie: refresh_token=xxx; HttpOnly; Secure

2. 后续请求携带 JWT:
   Authorization: Bearer <access_token>

3. POST /rpc/refresh_token_rtr { old_refresh_token }
   → 返回新 { access_token, username }

4. POST /rpc/logout
   → 当前 JTI 加入黑名单
```

### 4.2 权限角色

| 角色 | 权限说明 |
|:---|:---|
| `web_anon` | 未认证，仅可调用登录函数 |
| `role_guest` | 只读访问所有视图 |
| `role_editor` | 只读 + 可提交角色申请 |
| `role_admin` | 管理系统表（租户/部门/用户/角色/API/菜单） |
| `super_admin` | 完全控制所有资源 |

### 4.3 JWT Claims 结构

```json
{
  "jti": "01f...uuid",
  "user_id": "00000000-0000-0000-0000-100000000001",
  "username": "admin",
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "dept_id": "00000000-0000-0000-0000-000000000002",
  "roles": ["super_admin"],
  "exp": 1721500000
}
```

**字段说明：**

| 字段 | 含义 | 说明 |
|:---|:---|:---|
| `jti` | JWT ID | 唯一标识，用于 Token 黑名单 |
| `user_id` | 用户 UUID | 关联 `sys_user.id` |
| `username` | 用户名 | 登录名 |
| `tenant_id` | 租户 ID | 多租户隔离标识 |
| `dept_id` | 部门 ID | 所属部门（可为 null） |
| `roles` | 角色列表 | 用于 Casbin RBAC 鉴权 |
| `exp` | 过期时间 | Unix 时间戳（秒），过期后 Token 失效 |

> **说明：** JWT 采用 JWS（签名）而非 JWE（加密），Payload 约 220 字节。
> 因不含敏感数据（密码、密钥），签名已足够防止篡改。

---

## 5. API 接口清单

**统一前缀：** `http://<host>:9080`（通过 APISIX 网关）

### 图例说明

| 标记 | 含义 |
|:---|:---|
| 🔓 | 公开接口（无需 JWT） |
| 🔒 | 需要 JWT 认证 |
| 👤 | 普通用户可调用 |
| 🛡️ | 需要管理员权限 |
| 👑 | 仅 super_admin |

### 路径前缀与命名约定

| 前缀 | 含义 | 来源 | 示例 |
|:---|:---|:---|:---|
| `/rpc/` | **Remote Procedure Call** — 调用 PostgreSQL 函数/存储过程 | PostgREST 规范 | `/rpc/user_login_sso`、`/rpc/get_dept_tree` |
| `/v_` | **View（增强视图）** — 聚合/详情视图，关联多表展示 | 项目命名约定 | `/v_user_list`、`/v_role_list` |
| `/sys_` | **System Table（系统表）** — 直接暴露核心业务表，支持 CRUD | 项目命名约定 | `/sys_user`、`/sys_role` |

**命名规则：**
- **表名格式**：`sys_` + 单数名词（如 `sys_user`、`sys_role`）
- **视图格式**：`v_` + 功能描述（如 `v_user_list` = 用户列表视图）
- **函数格式**：动词 + 名词（如 `get_dept_tree`、`search_users`）
- **RPC 参数前缀**：`p_`（如 `p_username`、`p_user_id`），避免与数据库列名冲突

---

### 5.1 认证接口

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔓 POST | `/rpc/user_login_sso` | 公开 | 用户登录（返回 access_token + httpOnly Cookie） |
| 🔓 POST | `/rpc/refresh_token_rtr` | 公开 | 刷新 Token（RT 轮转 + 防重放） |
| 🔓 GET | `/rpc/health_check` | 公开 | 健康检查 |
| 🔒 POST | `/rpc/logout` | JWT | 用户登出（JTI 加入黑名单） |
| 🔒 GET | `/rpc/get_current_user` | JWT | 获取当前用户信息 |
| 🔒 GET | `/rpc/get_user_permissions` | JWT | 获取当前用户 API 权限列表 |

---

### 5.2 系统统计

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/v_system_stats` | JWT | 系统统计面板（单行汇总） |
| 🔒 GET | `/v_system_stats_realtime` | JWT | 实时系统统计（在线用户/黑名单/审计） |

---

### 5.3 租户管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_tenant` | JWT | 查询租户列表 |
| 🔒 POST | `/sys_tenant` | JWT | 创建租户 |
| 🔒 PATCH | `/sys_tenant?id=eq.xxx` | JWT | 更新租户 |
| 🔒 DELETE | `/sys_tenant?id=eq.xxx` | JWT | 软删除租户（设置 deleted_at） |

---

### 5.4 部门管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_department` | JWT | 查询部门列表 |
| 🔒 GET | `/v_dept_list` | JWT | 部门列表（含用户计数） |
| 🔒 GET | `/rpc/get_dept_tree` | JWT | 递归部门树（按路径排序） |
| 🔒 POST | `/sys_department` | JWT | 创建部门 |
| 🔒 PATCH | `/sys_department?id=eq.xxx` | JWT | 更新部门 |
| 🔒 DELETE | `/sys_department?id=eq.xxx` | JWT | 软删除部门 |

---

### 5.5 用户管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_user` | JWT | 查询用户列表 |
| 🔒 GET | `/v_user_list` | JWT | 用户列表（含 tenant_name, dept_name, roles） |
| 🔒 GET | `/rpc/search_users` | JWT | 分页搜索用户 |
| 🔒 GET | `/rpc/get_user_roles` | JWT | 获取用户的全部角色 |
| 🔒 GET | `/rpc/get_user_sessions` | JWT | 用户会话列表（自己或 super_admin） |
| 🔒 POST | `/rpc/create_user` | JWT | 创建用户（自动生成 Argon2id 密码） |
| 🔒 POST | `/rpc/update_user_status` | JWT | 更新用户状态（激活/禁用/软删除/恢复） |
| 🔒 POST | `/rpc/change_user_password` | JWT | 修改密码（验证旧密码） |
| 🔒 POST | `/rpc/reset_user_password` | JWT | 重置密码（管理员直接设置） |
| 🔒 POST | `/rpc/kick_user` | JWT | 强制踢人下线 |
| 🔒 POST | `/rpc/force_logout_user` | JWT | 强制用户下线并加入黑名单 |
| 🔒 POST | `/sys_user` | JWT | 创建用户（通过视图直接插入） |
| 🔒 PATCH | `/sys_user?id=eq.xxx` | JWT | 更新用户 |
| 🔒 DELETE | `/sys_user?id=eq.xxx` | JWT | 软删除用户 |

---

### 5.6 角色管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_role` | JWT | 查询角色列表 |
| 🔒 GET | `/v_role_list` | JWT | 角色列表（含权限计数统计） |
| 🔒 GET | `/rpc/get_role_users` | JWT | 获取角色的全部用户 |
| 🔒 GET | `/rpc/get_role_permissions` | JWT | 获取角色权限详情 |
| 🔒 POST | `/rpc/assign_role_to_user` | JWT | 分配角色给用户（带租户校验） |
| 🔒 POST | `/rpc/remove_role_from_user` | JWT | 移除用户角色 |
| 🔒 POST | `/rpc/batch_assign_roles` | JWT | 批量分配角色 |
| 🔒 POST | `/rpc/batch_remove_roles` | JWT | 批量移除角色 |
| 🔒 POST | `/rpc/update_role_permissions` | JWT | 批量更新角色权限（API + 菜单） |
| 🔒 POST | `/rpc/approve_role_request` | JWT | 审批角色申请 |
| 🔒 POST | `/rpc/reject_role_request` | JWT | 拒绝角色申请 |
| 🔒 POST | `/rpc/submit_role_request` | JWT | 提交角色申请 |
| 🔒 POST | `/sys_role` | JWT | 创建角色 |
| 🔒 PATCH | `/sys_role?id=eq.xxx` | JWT | 更新角色 |
| 🔒 DELETE | `/sys_role?id=eq.xxx` | JWT | 软删除角色 |

---

### 5.7 API 资源管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_api` | JWT | 查询 API 资源列表 |
| 🔒 GET | `/v_role_api_detail` | JWT | 角色-API 关联详情 |
| 🔒 POST | `/sys_api` | JWT | 创建 API 资源 |
| 🔒 PATCH | `/sys_api?id=eq.xxx` | JWT | 更新 API 资源 |
| 🔒 DELETE | `/sys_api?id=eq.xxx` | JWT | 软删除 API 资源 |

---

### 5.8 菜单管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_menu` | JWT | 查询菜单列表 |
| 🔒 GET | `/rpc/get_user_menu` | JWT | 获取当前用户菜单树（含按钮权限） |
| 🔒 GET | `/rpc/get_menu_tree_admin` | JWT | 获取完整菜单树（管理用） |
| 🔒 GET | `/v_role_menu_detail` | JWT | 角色-菜单关联详情 |
| 🔒 GET | `/casbin_rule` | JWT | Casbin 策略规则（仅供参考） |
| 🔒 POST | `/sys_menu` | JWT | 创建菜单 |
| 🔒 PATCH | `/sys_menu?id=eq.xxx` | JWT | 更新菜单 |
| 🔒 DELETE | `/sys_menu?id=eq.xxx` | JWT | 软删除菜单 |

---

### 5.9 关联关系管理

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_user_role` | JWT | 用户-角色关联列表 |
| 🔒 GET | `/v_user_role_detail` | JWT | 用户-角色关联详情（含用户名/角色名） |
| 🔒 GET | `/sys_role_api` | JWT | 角色-API 关联列表 |
| 🔒 GET | `/sys_role_menu` | JWT | 角色-菜单关联列表 |
| 🔒 GET | `/sys_user_role_request` | JWT | 角色申请列表 |
| 🔒 GET | `/v_role_request_detail` | JWT | 角色申请详情（含申请人/审批人） |
| 🔒 GET | `/rpc/get_user_role_requests` | JWT | 分页查询角色申请 |
| 🔒 POST | `/sys_user_role` | JWT | 创建用户-角色关联 |
| 🔒 DELETE | `/sys_user_role?user_id=eq.xxx&role_id=eq.yyy` | JWT | 删除用户-角色关联 |
| 🔒 POST | `/sys_role_api` | JWT | 创建角色-API 关联 |
| 🔒 DELETE | `/sys_role_api?role_id=eq.xxx&api_id=eq.yyy` | JWT | 删除角色-API 关联 |
| 🔒 POST | `/sys_role_menu` | JWT | 创建角色-菜单关联 |
| 🔒 DELETE | `/sys_role_menu?role_id=eq.xxx&menu_id=eq.yyy` | JWT | 删除角色-菜单关联 |

---

### 5.10 审计与监控

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔒 GET | `/sys_audit_log` | JWT | 审计日志列表 |
| 🔒 GET | `/v_audit_log_detail` | JWT | 审计日志详情（含用户名/租户名） |
| 🔒 GET | `/v_audit_log_timeline` | JWT | 审计时间线（按天聚合） |
| 🔒 GET | `/rpc/search_audit_log` | JWT | 搜索审计日志 |
| 🔒 GET | `/rpc/get_audit_log_timeline` | JWT | 审计时间线查询（指定日期范围） |
| 🔒 GET | `/sys_user_session` | JWT | 用户会话列表 |
| 🔒 GET | `/v_online_users` | JWT | 在线用户视图 |
| 🔒 GET | `/rpc/get_online_users` | JWT | 分页获取在线用户 |
| 🔒 GET | `/sys_token_blacklist` | JWT | Token 黑名单列表 |
| 🔒 GET | `/v_token_blacklist_detail` | JWT | Token 黑名单详情（含用户名） |
| 🔒 GET | `/sys_cron_log` | JWT | Cron 执行日志 |
| 🔒 POST | `/rpc/cleanup_expired_tokens` | JWT | 手动清理过期 Token |
| 🔒 POST | `/rpc/cleanup_expired_sessions` | JWT | 手动清理过期会话 |

---

## 6. HTTP 请求示例

### 6.1 登录

```bash
curl -X POST http://localhost:9080/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "admin123"}'
```

**响应：**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "username": "admin"
}
```

### 6.2 获取当前用户信息

```bash
curl -X GET http://localhost:9080/rpc/get_current_user \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

**响应：**
```json
{
  "id": "00000000-0000-0000-0000-100000000001",
  "username": "admin",
  "email": null,
  "phone": null,
  "tenant_id": "00000000-0000-0000-0000-000000000001",
  "tenant_name": "默认租户",
  "dept_id": "00000000-0000-0000-0000-000000000002",
  "dept_name": "默认部门",
  "is_active": true,
  "deleted_at": null,
  "roles": ["super_admin"],
  "created_at": "2026-07-21T10:00:00+08:00",
  "updated_at": "2026-07-21T10:00:00+08:00"
}
```

### 6.3 创建用户

```bash
curl -X POST http://localhost:9080/rpc/create_user \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..." \
  -H "Content-Type: application/json" \
  -d '{
    "p_username": "newuser",
    "p_password": "password123",
    "p_tenant_id": "00000000-0000-0000-0000-000000000001",
    "p_dept_id": "00000000-0000-0000-0000-000000000002",
    "p_email": "newuser@example.com",
    "p_phone": "13800138000"
  }'
```

**响应：**
```json
"00000000-0000-0000-0000-100000000002"
```

### 6.4 搜索用户

```bash
curl -X GET "http://localhost:9080/rpc/search_users?p_query=admin&p_status=active&p_limit=10&p_offset=0" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

**响应：**
```json
{
  "total": 1,
  "limit": 10,
  "offset": 0,
  "items": [
    {
      "id": "00000000-0000-0000-0000-100000000001",
      "username": "admin",
      "email": null,
      "phone": null,
      "tenant_id": "00000000-0000-0000-0000-000000000001",
      "tenant_name": "默认租户",
      "dept_id": "00000000-0000-0000-0000-000000000002",
      "dept_name": "默认部门",
      "is_active": true,
      "deleted_at": null,
      "roles": ["super_admin"],
      "created_at": "2026-07-21T10:00:00+08:00",
      "updated_at": "2026-07-21T10:00:00+08:00"
    }
  ]
}
```

### 6.5 分配角色

```bash
curl -X POST http://localhost:9080/rpc/assign_role_to_user \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..." \
  -H "Content-Type: application/json" \
  -d '{
    "p_user_id": "00000000-0000-0000-0000-100000000002",
    "p_role_id": "00000000-0000-0000-0000-200000000002"
  }'
```

**响应：**
```json
true
```

### 6.6 获取部门树

```bash
curl -X GET "http://localhost:9080/rpc/get_dept_tree?p_tenant_id=00000000-0000-0000-0000-000000000001" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

**响应：**
```json
[
  {
    "id": "00000000-0000-0000-0000-000000000002",
    "dept_name": "默认部门",
    "parent_id": null,
    "sort_order": 0,
    "deleted_at": null,
    "level": 1,
    "path": "默认部门"
  }
]
```

### 6.7 获取在线用户

```bash
curl -X GET "http://localhost:9080/rpc/get_online_users?p_limit=20&p_offset=0" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

### 6.8 搜索审计日志

```bash
curl -X GET "http://localhost:9080/rpc/search_audit_log?p_table_name=sys_user&p_operation=INSERT&p_limit=20" \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

### 6.9 登出

```bash
curl -X POST http://localhost:9080/rpc/logout \
  -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIs..."
```

**响应：**
```json
true
```

---

## 7. 错误码说明

| HTTP 状态码 | 错误码 | 说明 |
|:---:|:---|:---|
| 400 | `P0001` | 业务异常（如：用户不存在、密码错误、Token 已撤销） |
| 401 | `P0002` | 认证失败（如：账户已禁用） |
| 403 | `P0003` | 权限不足（Casbin 拒绝） |
| 409 | `P0004` | 冲突（如：Refresh Token 重放检测） |
| 422 | `P0005` | 参数校验失败（如：租户隔离违规） |
| 422 | `P0006` | 无效操作（如：无效的用户状态操作） |
| 429 | - | 请求过于频繁（APISIX 限流） |
| 500 | `P0098` | 外部服务异常（如：Casdoor 调用失败） |
| 500 | `P0099` | 内部异常（如：JWT 私钥未配置） |

### 错误响应格式

```json
{
  "code": "P0001",
  "message": "Invalid username or password",
  "details": null,
  "hint": null
}
```

---

## 附录 A：PostgREST 视图与表映射

| 视图名 | 来源 | 说明 |
|:---|:---|:---|
| `api_v1.sys_tenant` | `public.sys_tenant` | 租户表（直接映射） |
| `api_v1.sys_department` | `public.sys_department` | 部门表 |
| `api_v1.sys_user` | `public.sys_user` | 用户表（含 password_hash） |
| `api_v1.sys_role` | `public.sys_role` | 角色表 |
| `api_v1.sys_api` | `public.sys_api` | API 资源表 |
| `api_v1.sys_menu` | `public.sys_menu` | 菜单表 |
| `api_v1.sys_user_role` | `public.sys_user_role` | 用户-角色关联 |
| `api_v1.sys_role_api` | `public.sys_role_api` | 角色-API 关联 |
| `api_v1.sys_role_menu` | `public.sys_role_menu` | 角色-菜单关联 |
| `api_v1.sys_user_session` | `public.sys_user_session` | 用户会话 |
| `api_v1.sys_token_blacklist` | `public.sys_token_blacklist` | Token 黑名单 |
| `api_v1.sys_user_role_request` | `public.sys_user_role_request` | 角色申请 |
| `api_v1.sys_audit_log` | `public.sys_audit_log` | 审计日志 |
| `api_v1.sys_cron_log` | `public.sys_cron_log` | Cron 日志 |
| `api_v1.sys_secret` | `public.sys_secret` | 密钥表（仅 key_name） |

## 附录 B：增强视图清单

| 视图名 | 用途 | 关联表 |
|:---|:---|:---|
| `v_user_list` | 用户列表（含角色） | sys_user + sys_tenant + sys_department |
| `v_role_list` | 角色列表（含统计） | sys_role + sys_tenant |
| `v_dept_list` | 部门列表（含用户计数） | sys_department + sys_tenant |
| `v_audit_log_detail` | 审计日志（含用户名） | sys_audit_log + sys_user + sys_tenant |
| `v_system_stats` | 系统统计面板 | 多表聚合 |
| `v_user_role_detail` | 用户-角色详情 | sys_user_role + sys_user + sys_role |
| `v_role_api_detail` | 角色-API 详情 | sys_role_api + sys_role + sys_api |
| `v_role_menu_detail` | 角色-菜单详情 | sys_role_menu + sys_role + sys_menu |
| `v_role_request_detail` | 角色申请详情 | sys_user_role_request + sys_user |
| `v_online_users` | 在线用户 | sys_user_session + sys_user + sys_tenant |
| `v_audit_log_timeline` | 审计时间线 | sys_audit_log（聚合） |
| `v_token_blacklist_detail` | 黑名单详情 | sys_token_blacklist + sys_user |
| `v_system_stats_realtime` | 实时统计 | 多表聚合 |

## 附录 C：RPC 函数清单

| 函数名 | 参数 | 返回 | 说明 |
|:---|:---|:---|:---|
| `user_login_sso` | username, password | json | 登录 |
| `refresh_token_rtr` | old_refresh_token | json | 刷新 Token |
| `kick_user` | user_id | boolean | 踢人下线 |
| `get_user_menu` | - | json | 用户菜单树 |
| `approve_role_request` | request_id | boolean | 审批角色申请 |
| `cleanup_expired_tokens` | - | void | 清理过期 Token |
| `generate_user_password` | password | text | 生成密码哈希 |
| `create_user` | username, password, tenant_id, dept_id?, email?, phone? | uuid | 创建用户 |
| `change_user_password` | user_id, old_password, new_password | boolean | 修改密码 |
| `reset_user_password` | user_id, new_password | boolean | 重置密码 |
| `logout` | - | boolean | 登出 |
| `get_current_user` | - | json | 当前用户信息 |
| `get_user_permissions` | - | json | API 权限列表 |
| `health_check` | - | json | 健康检查 |
| `get_dept_tree` | tenant_id? | json | 部门树 |
| `get_menu_tree_admin` | - | json | 菜单树（管理） |
| `search_users` | query?, status?, dept_id?, limit?, offset? | json | 搜索用户 |
| `update_user_status` | user_id, action | boolean | 更新用户状态 |
| `assign_role_to_user` | user_id, role_id | boolean | 分配角色 |
| `remove_role_from_user` | user_id, role_id | boolean | 移除角色 |
| `update_role_permissions` | role_id, api_ids?, menu_ids? | boolean | 批量更新权限 |
| `get_role_permissions` | role_id | json | 角色权限详情 |
| `batch_assign_roles` | user_id, role_ids | json | 批量分配角色 |
| `batch_remove_roles` | user_id, role_ids | json | 批量移除角色 |
| `get_user_roles` | user_id | json | 用户全部角色 |
| `get_role_users` | role_id | json | 角色全部用户 |
| `submit_role_request` | role_id, user_id? | uuid | 提交角色申请 |
| `reject_role_request` | request_id | boolean | 拒绝角色申请 |
| `get_user_role_requests` | status?, limit?, offset? | json | 角色申请列表 |
| `get_online_users` | limit?, offset? | json | 在线用户 |
| `force_logout_user` | user_id | json | 强制下线 |
| `get_audit_log_timeline` | start_date?, end_date? | json | 审计时间线 |
| `search_audit_log` | query?, table_name?, operation?, limit?, offset? | json | 搜索审计日志 |
| `get_user_sessions` | user_id | json | 用户会话 |
| `cleanup_expired_sessions` | - | json | 清理过期会话 |

---

> **文档版本：** v1.0  
> **最后更新：** 2026-07-21  
> **维护者：** SnugglePuff (OmniPG Team)
