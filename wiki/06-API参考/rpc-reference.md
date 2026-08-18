# RPC 清单

本页是 api_v1_public schema 对外 RPC 的**当前权威索引**：以 `db/api_v1/public/rpc/*.sql`（44 个文件，2026-08 现状）为准，包含签名、参数、返回与权限门槛。PostgREST 会按「函数名 + 参数」把每个函数暴露为 `POST /rpc/<name>`（无参函数也支持 GET）。

> 范围说明：本页只覆盖 **api_v1_public 域**（`db/api_v1/public/`，即 URL 前缀 `/api/v1/sys/*` 重写后的对象）。Schema 布局以 `db/init/02-schemas.sql` 为准（public / api_v1_public / api_v1_sys 兼容 / net，无 extensions schema）；PostgREST **运行态以 `gateway/docker-compose.yml` 为权威，仅暴露 api_v1_public 单 schema**。`postgrest.conf` 参考文件中的 `api_v1_sales`/`api_v1_inventory` 多 schema 声明与运行态不一致（schema 未创建、`db/api_v1/inventory/` 与 `_shared/` 无实体 SQL、对应 URL 路由 2026-08-15 已退役）——详见 [PostgREST 使用指南](./postgrest.md) 与 [网关路由](./gateway-routing.md)「已知不一致/待收敛」。

> ⚠️ 历史 API 文档（API接口文档、API速查表、openapi.yaml，已随 docs/ 归档清理）为 Casdoor 时代旧版，其中 `user_login_sso`、`refresh_token_rtr`、`create_user`、`kick_user`、`health_check`、`logout`、`sys_user` 等端点**已删除**，请勿引用。机器可读的最新契约 = PostgREST 根路径 OpenAPI（见 [PostgREST 使用指南](./postgrest.md)）。

## 调用约定

- 路径：经网关 `http://localhost:9080/rpc/<name>`（jwt-auth 保护）；调试可直连 `http://localhost:3100/rpc/<name>`。
- 鉴权：除 `webhook_logto`（web_anon）外全部 `GRANT EXECUTE ... TO authenticated`，需携带 `Authorization: Bearer <Logto token>`。
- 参数：POST body 中参数名即 SQL 参数名（统一 `p_` 前缀，如 `{"p_user_id": "abc"}`）；DEFAULT 参数可省略。
- 权限模式两类：
  - **SECURITY DEFINER + has_permission('public:xxx')**：管理类写/读 RPC，显式权限点，不通过抛 `42501 permission denied`；
  - **SECURITY INVOKER + RLS**：查询类（search_users / search_audit_log / get_dept_tree 等），靠行级安全隔离。
  - 超管专属（require_super_admin）：cron 与 webhook 管理 RPC。
- 返回：绝大多数为 `json`（直接返回 JSON 对象）；`rpc_list_cron_jobs`/`rpc_list_cron_job_runs` 返回 `TABLE(...)`（JSON 数组）；`update_config` 返回 boolean。

## 全量索引（44 个）

| # | 函数（URL: /rpc/<name>） | 模块 | 参数（SQL 签名） | 返回 | 权限门槛 |
|:--:|:---|:---|:---|:---|:---|
| 1 | `get_current_user` | 认证与用户 | （无） | json | 有效 JWT |
| 2 | `ensure_user` | 认证与用户 | （无，读 claims） | text | 有效 JWT |
| 3 | `search_users` | 认证与用户 | p_query text, p_status text, p_dept_id uuid, p_limit int=20, p_offset int=0 | json | INVOKER + RLS（limit≤100） |
| 4 | `rpc_get_user_profile` | 认证与用户 | p_user_id text | json | 本人 / 超管 / 同租户 |
| 5 | `rpc_update_user_profile` | 认证与用户 | p_user_id text, p_updates jsonb | json | 本人免门槛；他人 public:profile:update |
| 6 | `rpc_get_user_roles` | 认证与用户 | p_user_id text, p_org_id text DEFAULT NULL | json | public:tenant-member:list |
| 7 | `get_user_menu` | 认证与用户 | （无） | json | 有效 JWT（委托 public.get_user_menu） |
| 8 | `rpc_list_tenants` | 组织与成员 | p_query text, p_limit int=20, p_offset int=0 | json | public:tenant:list |
| 9 | `rpc_list_tenant_members` | 组织与成员 | p_org_id text, p_query text, p_limit int=50, p_offset int=0 | json | public:tenant-member:list |
| 10 | `get_dept_tree` | 组织与成员 | p_tenant_id text DEFAULT NULL | json | INVOKER + RLS |
| 11 | `rpc_get_position_tree` | 组织与成员 | （无） | json | public:position:list |
| 12 | `rpc_assign_user_positions` | 组织与成员 | p_user_id text, p_position_ids uuid[], p_primary_position_id uuid DEFAULT NULL | json | public:position:assign |
| 13 | `rpc_create_department` | 组织与成员 | p_dept_name text, p_parent_id uuid, p_sort_order int=0 | json | public:dept:create |
| 14 | `rpc_update_department` | 组织与成员 | p_id uuid, p_parent_id uuid, p_dept_name text, p_sort_order int, p_is_active boolean | json | public:dept:update |
| 15 | `rpc_delete_department` | 组织与成员 | p_id uuid | json | public:dept:delete |
| 16 | `rpc_create_position` | 组织与成员 | p_pos_name text, p_parent_id uuid, p_pos_code text, p_sort_no int=0 | json | public:position:create |
| 17 | `rpc_update_position` | 组织与成员 | p_id uuid, p_parent_id uuid, p_pos_name text, p_pos_code text, p_sort_no int, p_status boolean | json | public:position:update |
| 18 | `rpc_delete_position` | 组织与成员 | p_id uuid | json | public:position:delete |
| 19 | `get_role_permissions` | 角色权限 | p_role_code text | json | 有效 JWT |
| 20 | `rpc_set_role_menus` | 角色权限 | p_role_code text, p_menu_ids uuid[] | json | public:role-menu:bind |
| 21 | `rpc_set_role_data_scope` | 角色权限 | p_role_code text, p_scope_type text, p_dept_ids uuid[] DEFAULT NULL | json | public:data-scope:bind |
| 22 | `rpc_get_role_data_scope` | 角色权限 | p_role_code text | json | public:data-scope:bind |
| 23 | `rpc_create_dict_type` | 字典 | p_dict_name text, p_dict_label text, p_tenant_scoped boolean=false, p_sort_no int=0 | json | public:dict:create |
| 24 | `rpc_update_dict_type` | 字典 | p_id uuid, p_dict_label text, p_sort_no int, p_status boolean | json | public:dict:update |
| 25 | `rpc_delete_dict_type` | 字典 | p_id uuid | json | public:dict:delete |
| 26 | `rpc_create_dict_data` | 字典 | p_dict_name text, p_item_label text, p_item_value text, p_item_type text='default', p_is_default boolean=false, p_sort_no int=0 | json | public:dict:create |
| 27 | `rpc_update_dict_data` | 字典 | p_id uuid, p_item_label text, p_item_value text, p_item_type text, p_is_default boolean, p_sort_no int, p_status boolean | json | public:dict:update |
| 28 | `rpc_delete_dict_data` | 字典 | p_id uuid | json | public:dict:delete |
| 29 | `get_menu_tree_admin` | 菜单 | （无） | json | 有效 JWT |
| 30 | `rpc_create_menu` | 菜单 | p_menu_name text, p_parent_id uuid, p_menu_type text='menu', p_api_code text, p_router text, p_component text, p_icon text, p_order_num int=0, p_is_visible boolean=true, p_remark text, p_route_name text, p_is_link boolean, p_is_iframe boolean, p_redirect text, p_is_cache boolean, p_api_url text, p_api_method text, p_is_affix boolean | json | public:menu:create |
| 31 | `rpc_update_menu` | 菜单 | p_id uuid + 与 create 相同的 19 个可空字段（含 p_is_active） | json | public:menu:update |
| 32 | `rpc_delete_menu` | 菜单 | p_id uuid | json | public:menu:delete |
| 33 | `get_config` | 配置 | p_config_key text | json | 有效 JWT（仅公开配置） |
| 34 | `get_all_public_configs` | 配置 | （无） | json | 有效 JWT |
| 35 | `update_config` | 配置 | p_config_key text, p_config_value text | boolean | public:config:write |
| 36 | `search_audit_log` | 审计与登录日志 | p_query text, p_table_name text, p_operation text, p_start_date timestamptz, p_end_date timestamptz, p_limit int=20, p_offset int=0 | json | INVOKER + RLS（limit≤100） |
| 37 | `get_audit_log_timeline` | 审计与登录日志 | p_start_date timestamp DEFAULT now()-interval '7 days', p_end_date timestamp DEFAULT now() | json | 有效 JWT |
| 38 | `rpc_search_login_logs` | 审计与登录日志 | p_user_id text, p_result text, p_from timestamptz, p_to timestamptz, p_limit int=50, p_offset int=0, p_login_type text, p_region text | json | public:login-log:list |
| 39 | `rpc_list_cron_jobs` | Cron | （无） | TABLE | require_super_admin |
| 40 | `rpc_list_cron_job_runs` | Cron | p_limit int=100 | TABLE | require_super_admin（limit≤1000） |
| 41 | `webhook_logto` | Webhook | payload jsonb | jsonb | web_anon（网关验签） |
| 42 | `rpc_list_webhook_events` | Webhook | p_result text, p_limit int=50, p_offset int=0 | json | require_super_admin（limit≤100） |
| 43 | `rpc_replay_webhook_event` | Webhook | p_event_id uuid | json | require_super_admin |
| 44 | `import_csv` | 导入 | p_table_name text, p_data jsonb, p_dry_run boolean=true | json | public:import |

## 模块详解与示例

### 认证与用户

**get_current_user()** — 当前登录用户（users 镜像 + user_profile + tenants + department），并回显 JWT `roles`：

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:9080/rpc/get_current_user
# → {"id":"...","username":"...","email":"...","tenant_id":"...","tenant_name":"...",
#    "dept_id":"...","dept_name":"...","is_active":true,"roles":["role_super_admin"],
#    "created_at":"...","updated_at":"..."}
```

**ensure_user()** — 登录 JIT 兜底建档：读 claims（sub/username/name/avatar/organization_id/global_roles/org_roles），仅缺失补建 users/user_profile；user_role 按 global/org 两段**增量对齐**（角色不变零写入、保留 created_at、空角色清空；无 global_roles/org_roles 的旧 token 跳过）。返回 sub：

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" http://localhost:9080/rpc/ensure_user
# → "logto_user_id"
```

**rpc_get_user_roles(p_user_id, p_org_id DEFAULT NULL)** — 某用户的角色分配镜像（global 段 organization_id='' + 指定 org 段），同租户约束、跨租户仅超管：

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_user_id":"logto_user_id"}' http://localhost:9080/rpc/rpc_get_user_roles
# → {"user_id":"...","org_id":"...","global_roles":[{"role_code":"role_super_admin","role_id":"..."}],"org_roles":[]}
```

**search_users(p_query, p_status, p_dept_id, p_limit=20, p_offset=0)** — 分页搜索（关键词匹配 username/email，p_status ∈ active/inactive，p_dept_id 过滤），返回 {total, limit, offset, items}，limit 上限 100（SECURITY INVOKER + RLS）。

**rpc_get_user_profile(p_user_id)** / **rpc_update_user_profile(p_user_id, p_updates jsonb)** — 用户档案：查/改本人或同租户成员；update 走 user_profile 动态列白名单（排除主键/租户/审计列），他人修改需 public:profile:update，档案缺失时自动补建（JIT 语义）。

**get_user_menu()** — 当前用户菜单树，委托 `public.get_user_menu()`（roles claim → iam_role_menu → iam_menu 递归）。

### 组织与成员

**rpc_list_tenants(p_query, p_limit=20, p_offset=0)** — 租户分页列表（名称模糊，含 member_count），limit≤100。

**rpc_list_tenant_members(p_org_id, p_query, p_limit=50, p_offset=0)** — 租户成员分页列表（默认当前租户；跨租户仅超管），limit≤100：

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{}' http://localhost:9080/rpc/rpc_list_tenant_members
# → {"total":N,"limit":50,"offset":0,"items":[{"user_id":"...","username":"...","email":"...","is_active":true,"joined_at":"..."}]}
```

**get_dept_tree(p_tenant_id DEFAULT NULL)** — 部门树（递归 CTE，返回 level/path，如 "总部 > 研发部"），INVOKER + RLS。

**rpc_get_position_tree()** — 岗位树（递归，含 pos_code/status/depth/path_name），public:position:list。

**rpc_assign_user_positions(p_user_id, p_position_ids uuid[], p_primary_position_id DEFAULT NULL)** — 用户岗位**全量覆盖**分配（先删后插，可指定主岗位），目标用户须为本租户成员，public:position:assign。

**部门/岗位 CRUD**：rpc_create/update/delete_department、rpc_create/update/delete_position——统一模式：SECURITY DEFINER + 对应权限点 + log_operate 审计 + 返回 {ok, id?}；删除时校验子节点/引用（有子节点或挂用户/岗位则拒绝）。department 按 current_tenant_id() 隔离。

### 角色权限

**get_role_permissions(p_role_code)** — 角色权限详情（055 单表化后 apis 段 = 角色菜单下挂 button 行的 api_url/api_method，menus 段 = 菜单）：

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_role_code":"tenant_admin"}' http://localhost:9080/rpc/get_role_permissions
# → {"role_id":"...","role_code":"tenant_admin","role_name":"tenant_admin","type":"User",
#    "apis":[...],"menus":[...],"api_count":N,"menu_count":M}
```

**rpc_set_role_menus(p_role_code, p_menu_ids uuid[])** — 角色菜单绑定**全量覆盖**（role_code = Logto 角色名，须存在于 role 镜像），public:role-menu:bind。

**rpc_set_role_data_scope(p_role_code, p_scope_type, p_dept_ids DEFAULT NULL)** / **rpc_get_role_data_scope(p_role_code)** — 数据范围绑定/查询。p_scope_type ∈ `all / dept_and_child / self / custom`；custom 必须带 dept_ids，非 custom 禁止带；全量覆盖写入 iam_role_data_scope；门槛 public:data-scope:bind。

### 字典

rpc_create/update/delete_dict_type 与 rpc_create/update/delete_dict_data——六件套 CRUD，public:dict:create/update/delete。要点：

- 全局字典（p_tenant_scoped=false / tenant_id NULL）仅超管可写；
- 租户字典作用域校验（非本租户拒绝）；
- delete_dict_type 级联删除同作用域 dict_data（无 FK，手动清理）。

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_dict_name":"gender","p_dict_label":"性别","p_tenant_scoped":true}' \
  http://localhost:9080/rpc/rpc_create_dict_type
# → {"ok":true,"id":"<uuid>"}
```

### 菜单

**get_menu_tree_admin()** — 管理端完整菜单树（含 menu_type/api_code/api_url/api_method/is_affix，授权弹窗数据源）。

**rpc_create_menu(...)** / **rpc_update_menu(...)** / **rpc_delete_menu(p_id)** — 菜单 CRUD，public:menu:create/update/delete。约束（代码内校验 + 表级 CHECK 兜底）：

- p_menu_type ∈ `directory / menu / button / link`（PG ENUM iam_menu_type）；
- **button 必须 api_code**（单码制，040），且禁止携带 router/component 等导航字段（055 D8）；
- api_url/api_method **仅 button 行**可用，且端点成对（055 D6）；
- route_name 手填优先，否则 directory/menu 行按 router 末段推导（056 B2）；
- 删除时校验无子节点，并级联清理 iam_role_menu。

### 配置

- `get_config(p_config_key)`：单个公开配置（is_public=true）。
- `get_all_public_configs()`：全部公开配置（前端初始化）。
- `update_config(p_config_key, p_config_value)`：更新配置（public:config:write），键不存在抛 P0001。

### 审计与登录日志

**search_audit_log(p_query, p_table_name, p_operation, p_start_date, p_end_date, p_limit=20, p_offset=0)** — 审计日志搜索（036 增强：p_query 匹配操作人 username 或 old/new_data 文本；p_table_name 模糊；时间范围），INVOKER + RLS 超管/本租户隔离，limit≤100。

**get_audit_log_timeline(p_start_date DEFAULT 近7天, p_end_date DEFAULT now())** — 按天聚合（v_audit_log_timeline），返回 {start_date, end_date, items}。

**rpc_search_login_logs(p_user_id, p_result, p_from, p_to, p_limit=50, p_offset=0, p_login_type, p_region)** — 登录日志（数据源 = Logto PostSignIn webhook 写入的 login_log），门槛 public:login-log:list；租户管理员仅看本租户成员（超管豁免），limit≤100。

### Cron

- `rpc_list_cron_jobs()` → TABLE(jobid, jobname, schedule, command, nodename, nodeport, database, username, active)，来源 pg_cron cron.job，**仅超管**（非超管返回空）。
- `rpc_list_cron_job_runs(p_limit=100)` → TABLE(runid, jobid, status, return_message, start_time, end_time)，来源 cron.job_run_details，仅超管，limit≤1000。

### Webhook

- `webhook_logto(payload jsonb)`：Logto webhook 唯一入口（web_anon，网关 HMAC 验签），事件分发 + webhook_event_log 落库。事件与 sync_* 映射、幂等与失败处理见 [Logto Webhook 接入](./logto-webhook.md)。
- `rpc_list_webhook_events(p_result DEFAULT NULL, p_limit=50, p_offset=0)`：事件日志查询（result ∈ received/success/error/ignored），require_super_admin，limit≤100，返回 {total, rows}（含 payload）。
- `rpc_replay_webhook_event(p_event_id)`：把历史 payload 重喂 webhook_logto（sync_* 幂等，重放结果新落一行 + log_operate 审计），require_super_admin。

### 导入

**import_csv(p_table_name, p_data jsonb, p_dry_run=true)** — 通用导入（public:import）：

- 显式白名单：`department / position / user_position / dict_type / dict_data / iam_menu`（镜像表/审计/日志/绑定表禁止；055 后 iam_api 已并入 iam_menu 从白名单移除）；
- jsonb_populate_record 参数化列子集插入（防注入），dry_run 预览 + 逐行错误收集；
- 返回 {table, total, inserted, errors, dry_run}。

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_table_name":"department","p_dry_run":true,"p_data":[{"dept_name":"研发部","sort_order":1}]}' \
  http://localhost:9080/rpc/import_csv
```

## 一致性提示

- 所有 SECURITY DEFINER 管理 RPC 均写 `log_operate(...)` 审计（audit_log 的 operate 类记录），镜像表只读原则（写入仅 sync_*/JIT/对账）。
- 分页类 RPC 的 p_limit 统一上限 100（cron 1000）；PostgREST 对视图分页另有 max-rows=1000 全局限制。
- 新增 RPC：在 `db/api_v1/public/rpc/` 新建 SQL（CREATE OR REPLACE FUNCTION api_v1_public.xxx），文件末尾 GRANT EXECUTE TO authenticated，然后跑 `scripts/apply-src.sh` 重放；PostgREST 无需重启即可在 OpenAPI 中出现。

---

> 参考：[PostgREST 使用指南](./postgrest.md) · [Logto Webhook 接入](./logto-webhook.md) · [网关路由](./gateway-routing.md) · [权限开发指南](../05-开发指南/permission-development.md) · [数据库测试](../07-测试/pgtap-guide.md)
