# Logto Webhook 接入

Logto（自部署 OSS，compose 服务名 `logto`）是用户/组织（租户）/角色目录与分配的权威源。Webhook 把 Logto 的数据变更单向推送到 PostgreSQL 镜像表：**Logto 事件 → APISIX HMAC 验签 → PostgREST `POST /rpc/webhook_logto` → sync_* 函数（SECURITY DEFINER）→ 镜像表**。登录 JIT（`ensure_user`）与每日对账（`scripts/phase2/reconcile-logto.py`）是两条兜底链路。

## 触发的事件类型（当前订阅 15 项）

订阅清单定义在 `scripts/phase2/init-logto.py` 的 `step5_webhook()`（hook 已存在时按 diff PATCH 补齐订阅，N3 修复）：

| 类别 | 事件 | 处理函数 | 载荷要点 |
|:---|:---|:---|:---|
| 用户 | `User.Created` | sync_user_upsert | data = UserEntity 白名单（id/username/primaryEmail/primaryPhone/name/avatar/customData/identities/lastSignInAt/createdAt/isSuspended/profile/ssoIdentities） |
| 用户 | `User.Data.Updated` | sync_user_upsert | 同上（PATCH /users/:id* 触发） |
| 用户 | `User.Deleted` | sync_user_delete | **data=null**，删除 ID 在 params.userId（三键兜底） |
| 用户 | `User.SuspensionStatus.Updated` | sync_user_suspension | data.id + data.isSuspended（PATCH /users/:id/is-suspended 独立事件，不走 Data.Updated） |
| 组织（租户） | `Organization.Created` | sync_tenant_upsert | data = Organization 实体（id/name/description/customData/createdAt） |
| 组织 | `Organization.Data.Updated` | sync_tenant_upsert | 同上 |
| 组织 | `Organization.Deleted` | sync_tenant_delete | **data=null**，ID 在 params.id（三键兜底） |
| 成员关系 | `Organization.Membership.Updated` | sync_membership_delta | 顶层 organizationId + addedUserIds / removedUserIds（增量数组，缺失=无变更；官方上限 5000 静默截断） |
| 组织角色 | `OrganizationRole.Created` | sync_organization_role_upsert | data = {id, name, description}（独立 organization_role 镜像，D4） |
| 组织角色 | `OrganizationRole.Data.Updated` | sync_organization_role_upsert | 同上 |
| 组织角色 | `OrganizationRole.Deleted` | sync_organization_role_delete | data=null，ID 在 params.id（三键兜底） |
| 全局角色 | `Role.Created` | sync_role_upsert | data = {id, name, type, isDefault, description}（role_code 生成列 = name） |
| 全局角色 | `Role.Data.Updated` | sync_role_upsert | 同上 |
| 全局角色 | `Role.Deleted` | sync_role_delete | data=null，ID 在 params.id（三键兜底） |
| 登录 | `PostSignIn` | sync_login_log_write | **interaction payload 顶层平铺**（无 data 包装）：event/interactionEvent/sessionId/applicationId/userIp/userAgent/userId/user/hookId/createdAt |

**不订阅**：`Role.Scopes.Updated` / `OrganizationRole.Scopes.Updated`（角色↔业务权限绑定由 PG 侧 iam_role_menu 自管，决策 D）；用户↔角色分配**无任何 webhook 事件**（Logto 官方 hooks 注册表核实，F12/F13），user_role 镜像只经登录 JIT + 对账收敛。

## 入口：rpc_webhook_logto 调用约定

函数定义：`db/api_v1/public/rpc/rpc_webhook_logto.sql`

| 项 | 值 |
|:---|:---|
| 路径 | `POST /rpc/webhook_logto`（PostgREST）/ 网关 `http://localhost:9080/rpc/webhook_logto` |
| 鉴权 | **无 JWT**（GRANT EXECUTE TO web_anon）；安全性来自网关 HMAC 验签 |
| Content-Type | application/json（body = Logto 原始 webhook payload） |
| 验签 | 请求头 `logto-signature-sha-256` = HMAC-SHA256(signingKey, **rawBody**) 的 hex；由 APISIX `serverless-pre-function` Lua 校验（见 [网关路由](./gateway-routing.md)） |
| 验签失败 | APISIX 直接 401，不进 PostgREST |
| 路由优先级 | 95 > `/rpc/*` 的 40，保证不被 jwt-auth 拦截 |
| 返回 | `{"ok": true}` 或 `{"ok": false, "error": "<SQLERRM>"}` |
| Webhook URL（Logto 侧配置） | `http://host.docker.internal:9080/rpc/webhook_logto`（init-logto.py 默认值：走 APISIX 9080 以便验签，Logto 容器内经 host.docker.internal 回环） |

⚠️ 两条铁律（脚本注释强调）：**不可叠加 request-validation 插件**（其 JSON 重排会破坏 rawBody 签名）；**缺 `LOGTO_WEBHOOK_SIGNING_KEY` 时部署脚本 exit 1**（fail-closed，N15）。

### 载荷结构要点

- 数据变更事件：顶层 `event` 字段 + 受影响实体在 `data`；删除类事件 **data 为 null**，ID 在 `params`（User.Deleted → params.userId；Organization/Role/OrganizationRole.Deleted → params.id）。webhook_logto 统一三键兜底：`COALESCE(params->>'userId', params->>'id', data->>'id')`（N1 修复）。
- 成员关系事件：顶层 `organizationId` / `addedUserIds` / `removedUserIds`。
- PostSignIn：顶层平铺，无 data 包装（官方 payload 结构核实，v2.4）。
- 时间戳（createdAt/updatedAt 等毫秒/ISO）经 `logto_ts(text)` 归一化为 timestamptz。

## sync_* 函数（db/src/public/functions/）

全部 SECURITY DEFINER、幂等（ON CONFLICT），由 webhook_logto 调用；对账脚本也直接复用：

| 函数 | 签名 | 行为 / 幂等策略 |
|:---|:---|:---|
| sync_user_upsert | (data jsonb) → void | users 镜像 upsert；**乱序守护**：ON CONFLICT DO UPDATE WHERE 存量 logto_updated_at IS NULL OR EXCLUDED.logto_updated_at >= 存量值（051/061）；webhook 无 updatedAt 时落 now() |
| sync_user_delete | (user_id text) → void | **硬删**（061：Logto 删除=行删除）；user_profile/user_role/user_tenants/user_position 经 FK ON DELETE CASCADE 连带清理 |
| sync_user_suspension | (p_user_id text, p_suspended boolean) → void | 幂等仅改 is_suspended（0 行更新无害）；带 logto_updated_at 水位 |
| sync_tenant_upsert | (data jsonb) → void | tenants 镜像 upsert（id/name/description/custom_data） |
| sync_tenant_delete | (org_id text) → void | 硬删；先解除该租户用户档案的 tenant_id（RESTRICT FK 前置），user_tenants 经级联清理 |
| sync_membership_delta | (org_id text, added jsonb, removed jsonb) → void | added→INSERT ON CONFLICT DO NOTHING；removed→DELETE；空 delta / 缺失字段**早退**（N21） |
| sync_organization_role_upsert | (data jsonb) → void | organization_role 镜像 upsert（独立命名空间，D4） |
| sync_organization_role_delete | (p_id text) → void | organization_role 硬删（绑定经 FK CASCADE） |
| sync_role_upsert | (data jsonb) → void | role 镜像 upsert（role_code = 生成列 name） |
| sync_role_delete | (role_id text) → void | role 硬删（user_role/绑定表经 FK CASCADE 清理） |
| sync_login_log_write | (payload jsonb) → void | PostSignIn → login_log（含 region 解析；tenant_id 留 NULL——事件无组织上下文；023 后表名为 login_log） |
| logto_ts | (v text) → timestamptz | 时间戳归一化（IMMUTABLE） |

## 事件落库与重放（webhook_event_log，N6/046）

每次调用 `webhook_logto` 先在 `webhook_event_log` 落一行（hookId/event/logto_created/原始 payload），随后按结果更新：

| result | 含义 |
|:---|:---|
| received | 已接收，处理中 |
| success | 分发成功 |
| error | 同步失败（保留 SQLERRM） |
| ignored | 未知事件（测试负载/订阅缺口可观测） |

管理端 RPC（均 require_super_admin，见 [RPC 清单](./rpc-reference.md)）：

- `rpc_list_webhook_events(p_result DEFAULT NULL, p_limit=50, p_offset=0)`：按 result 过滤分页（limit≤100），返回 {total, rows}（含 payload，注意 payload 含 PII，RLS 仅超管可读）。
- `rpc_replay_webhook_event(p_event_id)`：把历史 payload 重喂 `webhook_logto`；sync_* 幂等保证重放不产生重复行，重放结果新落一行并写 log_operate 审计。

## 幂等性与失败处理

| 场景 | 策略 |
|:---|:---|
| 重复投递 / 重放 | 全部 sync_* ON CONFLICT 幂等（upsert 或 DO NOTHING）；成员增删用 INSERT ON CONFLICT / DELETE，天然幂等 |
| 事件乱序 | 镜像表 `logto_updated_at` 水位，旧事件不覆盖新状态（051 乱序守护）；同时间戳允许覆盖不误伤 |
| 同步失败 | webhook_logto 不 RAISE（避免函数体异常回滚事件日志），落 error 并返回 `{ok:false}`；Logto 侧重试 3 次/超时 10s（F15），仍失败由 Console 手动 Replay 或 rpc_replay_webhook_event 兜底 |
| PostSignIn 失败 | 独立容错：落 error 不阻断（避免重试双写登录日志） |
| 未知事件 | 落 ignored，不报错 |
| 验签失败 | APISIX 401（缺头/签名不匹配）；缺 signing key 部署即拒绝（fail-closed） |
| 删除事件 | data=null 三键兜底（N1） |
| 成员 5000 截断 | Logto 官方静默截断；当前策略 = 每日全量对账兜底（D9，N21 移除旧标记逻辑） |
| webhook 丢失 / 首次登录竞态 | 登录 JIT：前端登录回调调 `ensure_user()`（仅缺失补建 users/user_profile + user_role 分段增量对齐，不覆盖 webhook 权威值，N7/D5/D6） |
| 长期漂移 | `scripts/phase2/reconcile-logto.py`：M2M token → Management API 全量拉取（users/roles/organization-roles/organizations/成员/逐用户角色分配）→ sync_* 幂等写入；user_role 全局段全量重建；--dry-run 可预览；每日 crontab 调度 |

**user_role 特殊说明**：Logto 官方无「用户↔角色分配」webhook 事件（PR #8674 被拒、issue #5099 挂起，F21），因此 user_role 镜像的唯一实时通道是登录 JIT（claims 即权威快照），对账为长期口径；镜像延迟不影响授权判定（授权读 JWT claims，不读镜像表）。

## 在 Logto 控制台配置 webhook 的步骤

手动步骤（与 `scripts/phase2/init-logto.py` 自动化等价；脚本幂等，推荐直接运行）：

1. **首次启动**：访问 `http://localhost:3002`（Admin Console），创建首个管理员账号（OSS 单管理员限制）。
2. **创建 M2M 应用**：Applications → 新建 machineToMachine 应用（init-logto.py 用 `omnipg_management_m2m` / `omnipg_m2m_app`），并授予 Management API 角色——供脚本/对账任务拿管理 token。
3. **创建全局角色**：Roles → `role_super_admin`（type=User）。
4. **创建组织角色**：Organization roles → `tenant_admin` / `editor` / `viewer`。
5. **创建组织（租户）**：Organizations → 新建默认组织，关联组织角色并分配成员。
6. **创建 Webhook**：Webhooks → 新建：
   - URL：`http://host.docker.internal:9080/rpc/webhook_logto`（经 APISIX 验签）；
   - 订阅 15 个事件（见上文表格）；
   - 生成/记录 **Signing Key** → 写入 `gateway/.env` 的 `LOGTO_WEBHOOK_SIGNING_KEY`；
   - 若 hook 已存在但订阅有差异，init-logto.py 会 PATCH 补齐（diff 更新）。
7. **配置 Custom Token Claims**（API resources → Custom JWT Claims，tokenType=access-token）：脚本注入 `roles`（全局∪当前组织角色并集）、`global_roles` / `org_roles`（user_role 镜像 JIT 用）、`pg_role`（PostgREST 角色映射：role_super_admin→super_admin，role_admin→role_admin，role_editor→role_editor，默认 role_guest）。脚本纯读 context、零 fetch。同时建议把 access token 寿命设为 15 分钟（D11/D12）。

自动化：

```bash
export LOGTO_M2M_SECRET='<m2m-secret>'        # N23：不再硬编码
python scripts/phase2/init-logto.py --endpoint http://localhost:3001
python scripts/phase2/init-logto.py --endpoint http://localhost:3001 --verify
```

> ⚠️ 顺序要求（033）：init-logto.py 把 **webhook 创建放在角色/组织创建之前**，否则 Role.Created/Organization.Created 事件发生在 webhook 配置前，PG 镜像会缺失（如 role_super_admin 不进 role 镜像）。

---

> 参考：[RPC 清单](./rpc-reference.md) · [网关路由](./gateway-routing.md) · [PostgREST 使用指南](./postgrest.md) · [认证与授权设计](../04-架构/auth-design.md) · [数据流](../04-架构/data-flow.md) · [安全](../08-运维/security.md)
