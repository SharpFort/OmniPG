# OmniPG Admin — API 速查表

> 打印友好 | 一页速查 | v1.0

---

## 🔑 认证

| 方法 | 路径 | 认证 | 说明 |
|:---|:---|:---|:---|
| 🔓 POST | `/rpc/user_login_sso` | - | 登录（返回 access_token） |
| 🔓 POST | `/rpc/refresh_token_rtr` | - | 刷新 Token（RT 轮转） |
| 🔓 GET | `/rpc/health_check` | - | 健康检查 |
| 🔒 POST | `/rpc/logout` | JWT | 登出 |
| 🔒 GET | `/rpc/get_current_user` | JWT | 当前用户 |
| 🔒 GET | `/rpc/get_user_permissions` | JWT | API 权限列表 |

## 📊 系统统计

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 GET | `/v_system_stats` | 系统统计面板 |
| 🔒 GET | `/v_system_stats_realtime` | 实时统计 |

## 🏢 租户 & 部门

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 CRUD | `/sys_tenant` | 租户管理 |
| 🔒 CRUD | `/sys_department` | 部门管理 |
| 🔒 GET | `/rpc/get_dept_tree` | 部门树（递归） |
| 🔒 GET | `/v_dept_list` | 部门列表（含统计） |

## 👥 用户管理

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 CRUD | `/sys_user` | 用户基础 CRUD |
| 🔒 GET | `/v_user_list` | 用户列表（含角色/部门） |
| 🔒 GET | `/rpc/search_users` | 分页搜索用户 |
| 🔒 GET | `/rpc/get_user_roles` | 用户角色 |
| 🔒 GET | `/rpc/get_user_sessions` | 用户会话 |
| 🔒 POST | `/rpc/create_user` | 创建用户（含密码哈希） |
| 🔒 POST | `/rpc/update_user_status` | 激活/禁用/删除/恢复 |
| 🔒 POST | `/rpc/change_user_password` | 修改密码 |
| 🔒 POST | `/rpc/reset_user_password` | 重置密码（管理员） |
| 🔒 POST | `/rpc/kick_user` | 踢人下线 |

## 🛡️ 角色管理

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 CRUD | `/sys_role` | 角色基础 CRUD |
| 🔒 GET | `/v_role_list` | 角色列表（含统计） |
| 🔒 GET | `/rpc/get_role_users` | 角色用户 |
| 🔒 GET | `/rpc/get_role_permissions` | 角色权限详情 |
| 🔒 POST | `/rpc/assign_role_to_user` | 分配角色 |
| 🔒 POST | `/rpc/remove_role_from_user` | 移除角色 |
| 🔒 POST | `/rpc/batch_assign_roles` | 批量分配 |
| 🔒 POST | `/rpc/batch_remove_roles` | 批量移除 |
| 🔒 POST | `/rpc/update_role_permissions` | 批量更新权限 |
| 🔒 POST | `/rpc/approve_role_request` | 审批申请 |
| 🔒 POST | `/rpc/submit_role_request` | 提交申请 |

## 🔌 API 资源 & 菜单

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 CRUD | `/sys_api` | API 资源管理 |
| 🔒 CRUD | `/sys_menu` | 菜单管理 |
| 🔒 GET | `/rpc/get_user_menu` | 用户菜单树 |
| 🔒 GET | `/rpc/get_menu_tree_admin` | 完整菜单树 |
| 🔒 GET | `/v_role_api_detail` | 角色-API 关联 |
| 🔒 GET | `/v_role_menu_detail` | 角色-菜单关联 |

## 📋 审计 & 监控

| 方法 | 路径 | 说明 |
|:---|:---|:---|
| 🔒 GET | `/sys_audit_log` | 审计日志 |
| 🔒 GET | `/v_audit_log_detail` | 审计详情（含用户名） |
| 🔒 GET | `/v_audit_log_timeline` | 按天聚合 |
| 🔒 GET | `/rpc/search_audit_log` | 搜索审计日志 |
| 🔒 GET | `/rpc/get_audit_log_timeline` | 时间线查询 |
| 🔒 GET | `/v_online_users` | 在线用户 |
| 🔒 GET | `/rpc/get_online_users` | 分页在线用户 |
| 🔒 GET | `/sys_token_blacklist` | Token 黑名单 |
| 🔒 GET | `/v_token_blacklist_detail` | 黑名单详情 |
| 🔒 GET | `/sys_cron_log` | Cron 日志 |
| 🔒 POST | `/rpc/cleanup_expired_tokens` | 清理 Token |
| 🔒 POST | `/rpc/cleanup_expired_sessions` | 清理会话 |

---

## PostgREST 过滤语法

| 操作符 | 含义 | 示例 |
|:---|:---|:---|
| `eq` | 等于 | `?id=eq.123` |
| `neq` | 不等于 | `?id=neq.123` |
| `gt/gte/lt/lte` | 比较 | `?created_at=gte.2026-01-01` |
| `like/ilike` | 模糊匹配 | `?username=like.*admin*` |
| `in` | 包含于 | `?id=in.(1,2,3)` |
| `is` | NULL 判断 | `?deleted_at=is.null` |
| `not` | 取反 | `?status=not.eq.disabled` |
| `order` | 排序 | `?order=created_at.desc` |
| `limit/offset` | 分页 | `?limit=20&offset=0` |

## 示例

```bash
# 登录
curl -X POST http://localhost:9080/rpc/user_login_sso \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'

# 查询（带过滤+排序+分页）
curl "http://localhost:9080/v_user_list?is_active=eq.true&order=created_at.desc&limit=10" \
  -H "Authorization: Bearer $TOKEN"

# 创建用户
curl -X POST http://localhost:9080/rpc/create_user \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_username":"u1","p_password":"p1","p_tenant_id":"00000000-0000-0000-0000-000000000001"}'
```

---

> 📄 完整文档见 `API接口文档.md` | 🔧 OpenAPI 规范见 `openapi.yaml`
