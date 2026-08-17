# 02 — 数据库建模：核心表结构详解（v5 补充文档）

> **定位：** 本文档是 v3 主文档的补充——详细解释核心表的设计原理和相互关系，作为开发时的快速参考。
> **设计原则：** 仅解释说明，不包含可执行的 DDL（DDL 在 v3 主文档维护）。

---

## 0. 三个核心安全表的作用

### 0.1 `sys_secret`（密钥配置表）

#### 作用
存储系统级敏感配置，当前主要存放 JWT RS256 签名的私钥（PEM 格式）。

#### 设计原理
```
POSTGRES 中存储的密钥:
┌─────────────────────────────────────────────────┐
│ sys_secret                                       │
├──────────────┬──────────────────────────────────┤
│ key_name     │ key_value                        │
├──────────────┼──────────────────────────────────┤
│ jwt_private_ │ -----BEGIN RSA PRIVATE KEY-----  │
│ key_pem      │ MIIEowIBAAKCAQEA3Tz2...          │
│              │ -----END RSA PRIVATE KEY-----    │
└──────────────┴──────────────────────────────────┘
```

#### 安全机制
| 层级 | 机制 | 效果 |
|:---|:---|:---|
| RLS | RESTRICTIVE 策略 `is_super_admin()` | 仅超级管理员可读 |
| 应用层 | PostgREST 的 `db-pre-request` 使用 SECURITY DEFINER 函数 | 普通用户无法直接 SELECT |

#### 使用场景
- `user_login_sso()` 读取私钥签发 JWT
- `refresh_token_rtr()` 读取私钥签发新 JWT

---

### 0.2 `sys_user_session`（用户会话表）

#### 作用
管理 Refresh Token 生命周期，实现 SSO 单设备登录 + 轮转刷新 + 防重放攻击。

#### 表结构核心字段
```
┌───────────────────────────────────────────────────────────┐
│ sys_user_session                                          │
├──────────────────┬────────────────────────────────────────┤
│ id               │ UUID PK (uuidv7)                       │
│ user_id          │ UUID FK → sys_user                     │
│ refresh_token_   │ VARCHAR(64) UNIQUE                     │
│ hash             │ = sha256(明文 RT)                      │
│ active_jti       │ VARCHAR(50)                            │
│                  │ 当前活跃 Access Token 的 JTI            │
│ is_used          │ BOOLEAN                                │
│                  │ TRUE = 该 RT 已被轮转过（作废）        │
│ expired_at       │ TIMESTAMPTZ                            │
│                  │ RT 过期时间（通常 7 天）               │
└──────────────────┴────────────────────────────────────────┘
```

#### 三大核心机制

##### 机制 1：SSO 单设备登录
```
用户 A 在设备 1 登录 → 创建会话 S1 (active_jti=jti_1)
用户 A 在设备 2 登录 → 
  1. UPDATE sys_user_session SET is_used=TRUE WHERE user_id=A AND is_used=FALSE
     → S1 被标记为已使用（失效）
  2. 创建会话 S2 (active_jti=jti_2)
→ 设备 1 的旧 JWT 通过 refresh_token_rtr 获取新 Token（设备 2 登录后设备 1 自动下线）
```

##### 机制 2：Refresh Token 轮转（Refresh Token Rotation）
```
客户端调用 refresh_token_rtr(old_rt)
  1. 计算 old_rt_hash = sha256(old_rt)
  2. 查询 sys_user_session WHERE refresh_token_hash = old_rt_hash
  3. 检查 is_used = FALSE（未被轮转过）
  4. UPDATE sys_user_session SET is_used=TRUE WHERE id = current_session_id
     → 旧 RT 标记为已使用（作废）
  5. 生成 new_rt, 创建新会话记录
  6. 返回新 AT + 新 RT
```

##### 机制 3：防重放攻击（Replay Attack Detection）
```
如果攻击者盗取了 old_rt，但合法用户已经使用过它：
  1. 用户使用 old_rt 轮转成功 → is_used 被设为 TRUE
  2. 攻击者使用同一个 old_rt 再次请求
  3. 查询到 is_used = TRUE → 判定为盗用！
  4. DELETE FROM sys_user_session WHERE user_id = attacked_user
     → 该用户所有会话被删除（全端下线）
  5. 抛出异常 'Security Breach Detected: Replay Attack!'
  6. 用户必须重新登录
```

---

### 0.3 `sys_token_blacklist`（Token 黑名单表）

#### 作用
即时撤销 JWT，解决 Role-in-JWT 方案中「角色变更后旧 JWT 仍然有效」的问题。

#### 为什么需要黑名单？
```
Role-in-JWT 方案的问题：
  1. 用户登录 → JWT 中包含 roles=["editor"]
  2. 管理员将用户角色改为 admin
  3. 旧 JWT 在过期前仍然有效（直至 exp 时间）
  4. 旧 JWT 中的 roles 仍然是 ["editor"]（权限缓存）
  5. 存在时间窗口，用户可能利用旧 JWT 进行未授权操作

黑名单的解决方案：
  1. 用户角色变更时，将旧 JWT 的 jti 加入黑名单
  2. 每次 API 调用时检查 jti 是否在黑名单
  3. 如果在黑名单 → 拒绝请求 → 客户端通过 RT 获取新 JWT（包含新角色）
```

#### 黑名单写入时机
| 触发场景 | 写入方式 | 原因 |
|:---|:---|:---|
| 角色变更（INSERT/UPDATE/DELETE sys_user_role） | 触发器 `trg_blacklist_on_role_change` | 即时生效，无需用户重新登录 |
| 管理员强制踢人（调用 `kick_user`） | 函数内循环写入 | 立即撤销所有活跃会话 |
| 轮转刷新 RT | 无需写入黑名单 | 旧 RT 通过 `is_used=TRUE` 作废，不依赖黑名单 |

---

## 1. 角色变更后 JWT 自动更新的完整流程

### 流程图：用户无感知的角色变更
```
┌─────────────────────────────────────────────────────────────────┐
│ 1. 管理员修改用户角色（INSERT/DELETE sys_user_role）            │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. 触发器 trg_blacklist_on_role_change 自动执行                │
│    将该用户所有活跃会话的 active_jti 写入 sys_token_blacklist   │
│    写入 reason = 'role_changed'                                 │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. 客户端使用旧 JWT 发起 API 请求                               │
│    POSTGREST 检查请求头中的 JWT                                 │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. db-pre-request 函数 check_token_blacklist() 执行            │
│    从 JWT 中提取 jti                                            │
│    SELECT 1 FROM sys_token_blacklist WHERE jti = extracted_jti │
│    → 找到记录 → 抛出异常 'Token Has Been Revoked'              │
│    → 返回 HTTP 401                                             │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. 客户端收到 401 → 自动调用 refresh_token_rtr()               │
│    传递旧的 Refresh Token                                       │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. refresh_token_rtr() 执行                                     │
│    a. 验证旧 RT 有效                                            │
│    b. 作废旧 RT (is_used = TRUE)                                │
│    c. 查询用户最新角色（包含新角色）                            │
│    d. 签发新的 JWT（包含新角色）+ 新的 RT                       │
│    e. 返回新 AT + 新 RT                                         │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. 客户端用新的 JWT 继续访问 API                                │
│    用户角色已更新，全程无感知（无需重新登录）                   │
└─────────────────────────────────────────────────────────────────┘
```

### 关键设计决策

| 决策 | 选择 | 理由 |
|:---|:---|:---|
| 强制重新登录？ | ❌ 否 | 用户体验差，需要重新输入密码 |
| 静默获取新 JWT？ | ✅ 是 | 客户端自动通过 RT 获取新 JWT，用户无感知 |
| RT 被盗时？ | 全端下线 | 防重放攻击触发 → 删除所有会话 → 必须重新登录 |
| 黑名单自动清理？ | ✅ 是 | pg_cron 每小时清理过期 jti，避免表无限增长 |

---

## 2. 三个表的相互关系

```
┌─────────────────────────────────────────────────────────────────┐
│                         用户登录                                 │
│                     user_login_sso()                             │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────────┐
│ sys_secret    │      │ sys_user_     │      │ sys_token_        │
│               │      │ session       │      │ blacklist         │
│ 读取私钥      │      │               │      │                   │
│ 签发 JWT      │      │ 创建会话记录  │      │ 记录被撤销的 jti  │
│               │      │ RT 哈希       │      │                   │
└───────────────┘      │ active_jti    │      └───────────────────┘
                       └───────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         刷新 Token                               │
│                     refresh_token_rtr()                          │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────────┐
│ sys_secret    │      │ sys_user_     │      │ sys_token_        │
│               │      │ session       │      │ blacklist         │
│ 读取私钥      │      │               │      │                   │
│ 签发新 JWT    │      │ 作废旧 RT     │      │ 检查 jti 是否     │
│               │      │ 创建新会话    │      │ 在黑名单          │
└───────────────┘      └───────────────┘      └───────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      角色变更 / 踢人                              │
│              trg_blacklist_on_role_change                        │
│              kick_user()                                         │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
                       ┌───────────────┐
                       │ sys_token_    │
                       │ blacklist     │
                       │               │
                       │ 批量写入 jti  │
                       │ reason =      │
                       │ 'role_changed'│
                       │ 或 'kicked'   │
                       └───────────────┘
```

---

## 3. 其他核心表的作用速览

### 3.1 `sys_tenant`（租户表）
- 多租户隔离的核心
- 存储租户状态：`active`/`suspended`/`disabled`
- `suspended` = 暂停（用户无法登录，数据保留）
- `disabled` = 禁用（等同于逻辑删除）
- 通过 `deleted_at` 实现软删除

### 3.2 `sys_department`（部门表）
- 支持树形结构（`parent_id` 自引用）
- 租户隔离：`tenant_id NOT NULL`
- RESTRICT 删除：租户下存在部门时不允许删除租户

### 3.3 `sys_user`（用户表）
- 用户归属租户：`tenant_id NOT NULL`
- 用户归属部门：`dept_id NULLABLE`
- 密码存储：`password_hash = generate_user_password(明文)`
- 账户激活：通过 `deleted_at IS NULL` 判断

### 3.4 `sys_role`（角色表）
- 支持全局角色 + 租户角色
- `tenant_id = NULL` → 全局角色（所有租户可见）
- `tenant_id = 'xxx'` → 租户私有角色
- 唯一约束：`(role_code, tenant_id)` 保证全局和租户级别的唯一性

### 3.5 `sys_api`（API 资源表）
- 定义 Casbin 边界防御规则
- 系统级共享（无 `tenant_id`）
- 唯一约束：`(path, method)`
- casbin_rule 视图自动过滤 `deleted_at IS NULL`

### 3.6 `sys_menu`（菜单与前端权限表）
- 菜单类型：`DIR`（目录）/ `MENU`（页面）/ `BUTTON`（按钮）
- `permission_code` 仅 `type='BUTTON'` 时有效
- 系统级共享

### 3.7 `sys_user_role`（用户-角色关联表）
- M:N 关联表
- 租户隔离：`tenant_id NOT NULL`
- 级联删除：用户或角色删除时自动清理关联

### 3.8 `sys_role_api`（角色-API 关联表）
- Casbin p 规则的数据源
- 变更时触发 `pg_notify('casbin_channel', 'reload')`
- 触发 `FOR EACH STATEMENT`（非 ROW）减少高频写入风暴

### 3.9 `sys_role_menu`（角色-菜单关联表）
- 控制用户能看到哪些菜单和按钮
- 配合 `get_user_menu()` 函数返回嵌套菜单树

### 3.10 `sys_user_role_request`（角色分配审批流表）
- 记录谁申请、谁审批、审批状态
- 审批通过时自动写入 `sys_user_role`

### 3.11 `sys_audit_log`（审计日志表）
- 记录所有关键业务表的数据变更
- 包含 `old_data` 和 `new_data` JSONB
- 按 `tenant_id` 隔离

### 3.12 `sys_cron_log`（Cron 任务日志表）
- 记录 pg_cron 定时任务的执行情况
- 用于排查定时清理任务是否正常运行

---

## 4. 核心函数速查

| 函数名 | 作用 | 调用位置 |
|:---|:---|:---|
| `user_login_sso()` | 登录，签发双 Token，SSO | PostgREST RPC |
| `refresh_token_rtr()` | RT 轮转，签发新双 Token | PostgREST RPC |
| `check_token_blacklist()` | db-pre-request，检查 jti | 每个 API 请求前 |
| `kick_user()` | 强制踢人，批量写黑名单 | 管理员操作 |
| `get_user_menu()` | 获取当前用户的菜单树 | PostgREST RPC |
| `approve_role_request()` | 审批角色申请 | PostgREST RPC |
| `generate_rs256_jwt()` | RS256 签名 JWT | 内部调用 |
| `generate_user_password()` | Argon2id 生成密码哈希 | 创建用户时 |
| `sha256()` | SHA256 哈希（非密码场景） | RT 哈希、辅助校验 |
| `notify_policy_reload()` | pg_notify 触发器函数 | role_api 变更时 |
| `blacklist_at_on_role_change()` | 角色变更触发器函数 | user_role 变更时 |
| `update_updated_at()` | 自动维护 updated_at | 每个业务表 |
| `current_user_id()` | 从 JWT 提取用户 ID | 触发器、RLS 策略 |
| `current_tenant_id()` | 从 JWT 提取租户 ID | RLS 策略 |
| `is_super_admin()` | 检查是否超级管理员 | RLS 策略 |

---

## 5. 修订日志

| 版本 | 日期 | 变更内容 |
|:---|:---|:---|
| v5.0 | 2026-07-21 | 初始版本：三个核心安全表详解 + 角色变更完整流程 |
