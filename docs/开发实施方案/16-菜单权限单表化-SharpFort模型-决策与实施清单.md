# 16 — 菜单权限单表化（SharpFort 模型）决策与实施清单

> **创建日期：** 2026-08-12
> **文档类型：** 架构决策记录（ADR）/ 待执行任务清单
> **状态：** ✅ 决策已拍板 → ⏳ 待实施（按 P0 → P1 → P2 逐项推进，每项等用户指令）
> **关联文档：** 05-Logto认证与权限架构-完善版.md、05.2-Admin管理模块函数视图补全分析.md、15-数据库迁移文件治理与合并策略.md、casbin-rbac-best-practices-中文版.md
> **借鉴来源：** SharpFort.Net（GitHub，最终采纳）、Yi.Abp（gitee，对比）、Admin.NET（gitee，对比）
> **执行工具：** apply-src.sh（psql 全量幂等重放）+ PGlite 验证链（~/.hermes_tmp/pglite-verify/）

---

## 1. 决策结论（2026-08-12 拍板）

| # | 决策 | 级别 | 实施位置 |
|---|---|---|---|
| D1 | **采纳 SharpFort 单表模型**：iam_menu 承载菜单 + 权限点 + API 端点信息（api_url/api_method 内嵌按钮行），**删除 iam_api 表**（推翻 038 D2 分离式拍板） | P0 | 迁移 055 |
| D2 | **删除 iam_role_api 绑定表**：角色授权收敛为 iam_role_menu 单表（授权树 = 菜单树勾选） | P0 | 迁移 055 |
| D3 | **has_permission 单通道化**：判定收敛为 role_menu → menu.api_code（超管短路保留）；原双通道（role_api→api_code）随 D2 删除 | P0 | 迁移 055 |
| D4 | **一码多端点 = 多行同 api_code 的 button 行**（PermissionCode 非唯一索引，每行一个端点；button 行不生成前端路由，不污染 UI） | P0 | 迁移 055 |
| D5 | **is_affix 新增**（标签页固定，借鉴 Admin.NET IsAffix，上轮已确认的 P1）随本迁移一并落地 | P1 | 迁移 055 |
| D6 | **api_url/api_method 成对约束 + 部分唯一索引**（WHERE api_url IS NOT NULL），补齐原 iam_api UNIQUE(path, method) 的表级保证 | P2 | 迁移 055 |
| D7 | 设计论证不再引用 RuoYi 方案（用户 2026-08-12 纠正：其存在误导性） | — | 文档约定 |

**一句话结论：** 菜单表单表承载"导航 + 权限码 + 端点信息"，角色授权只走 iam_role_menu——SharpFort 模型与本项目零后端架构完全适配，是"menu 表实现 permission 表功能"的终极形态。

---

## 2. 背景与问题

### 2.1 现状演进史（双表模型的由来）

| 迁移 | 决策 | 形态 |
|---|---|---|
| 009 | iam_menu（基础 9 列）+ iam_api（path/method/name）分表 | 双表起点 |
| 022 | iam_menu + menu_type/perms/component/is_visible（按钮级权限） | 菜单开始承担权限点 |
| 031/032 | menu_type 枚举化 + link 值（四值封闭） | 类型完备 |
| 038 | **D2 拍板 menu/api 分离式**：iam_menu 管导航、iam_api 管权限点目录 | 分离式确认 |
| 039 | iam_api.menu_id 归属关联（接口挂菜单，资源树一体化） | 归属关联 |
| 040 | 单码制双通道 has_permission（role_api→api_code ∪ role_menu→menu.api_code） | 双通道判定 |
| 044 | perms→api_code、path→router 改名；按钮↔接口 1:1 挂接 | 字段统一 |
| 046 | rpc_set_menu_apis（菜单挂接口 RPC） | 挂接管理 |

**核心矛盾**：040 单码制后，iam_api.api_code 与 iam_menu.api_code 已是**同一套码**；044 又建立了按钮↔接口 1:1 挂接——iam_api 事实上退化为"按钮行的端点明细附表"，双表 + 双绑定 + 双通道的复杂度已无信息收益可言。

### 2.2 待解决疑问（2026-08-12 讨论链）

1. menu 表能否完全记录 API 权限点信息（path/method/description）？
2. 权限管理是否可以不再需要 iam_api 表（而非"menu 关联 api"）？
3. 角色 API 授权能否改走菜单（删除 iam_role_api，授权单表）？
4. "一码多端点"到底是什么、概率多高、单表下如何表达？

→ 讨论结论：1/2/3 均为"能"，4 的答案是 SharpFort 给出的"多行同码"（见 §3.1）。上轮曾建议保留 iam_api（双表 + 授权单表），SharpFort 源码证实单表的信息损失可由 ApiUrl/ApiMethod 内嵌完全消除，**本决策采纳更彻底的 SharpFort 单表模型**。

---

## 3. 借鉴来源分析

### 3.1 SharpFort.Net —— 最终采纳模型 ⭐

**来源：** https://github.com/SharpFort/SharpFort.Net
（module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Menu.cs、Role.cs、RoleMenu.cs；Domain.Shared/Enums/MenuType.cs、MenuSource.cs）

**核心设计（源码核查结论）：**

| 设计点 | SharpFort 实现 | 对本项目的意义 |
|---|---|---|
| 单表 | 仅 `casbin_sys_menu`，**无独立 API 表**（Entities 目录已核查） | 单表模型完整实现 |
| 端点内嵌 | `ApiUrl` + `ApiMethod` 列直接挂在菜单行（注释：用于 Casbin 鉴权，如 /api/system/user + GET） | **决定性差异**——权限码与端点信息同处数据层 |
| 权限点 | `PermissionCode`（128 字）+ 普通索引（注释：加速权限验证查询） | 权限点=菜单行，索引即判定路径 |
| 类型 | 四值：Catalogue / Menu / Component / **Button** | 与现状 menu_type 四值同构（directory/menu/link/button） |
| 绑定 | 仅 `RoleMenu` 中间表（Role.Menus 导航已核查） | 授权单表 |
| 一码多端点 | PermissionCode **非唯一索引** → 多行同码，每行一个端点 | 单表下"一码多端点"的标准解 |
| 描述 | Remark（500 字） | description 有处放 |
| 端点级拦截 | Casbin Enforcer：(role, apiUrl, apiMethod) 运行时判定 | 本项目无中间件 → api_url/api_method 作目录/审计元数据（运行时靠 RPC 内 has_permission，052 已废弃 APISIX casbin） |

**为什么它是最优**：它是唯一把"权限码 + 端点信息"**全部放进数据层**的单表模型。对 SharpFort 自身，端点信息服务于 Casbin 运行时拦截；对本项目零后端架构，同样的存储结构服务于目录/资源树/审计——**存储形态一致，消费方式不同，恰好完整适配**。

### 3.2 Yi.Abp —— 对比（不采纳）

**来源：** https://gitee.com/ccnetcore/Yi/blob/main/Yi.Abp.Net8/module/rbac/Yi.Framework.Rbac.Domain/Entities/MenuAggregateRoot.cs
（MenuTypeEnum.cs 同仓库 Domain.Shared）

**缺陷：** 菜单表只有 `PermissionCode` 字符串，**无 ApiUrl/ApiMethod 类端点列**——端点信息在 ABP PermissionDefinitionProvider 代码层定义。对本项目（无代码层）移植后"端点→权限码"映射无处落数据。另有 RouterName/IsCache/IsShow/MenuSource 等导航字段（现状 iam_menu 已等价覆盖）。

### 3.3 Admin.NET —— 对比（不采纳）

**来源：** https://gitee.com/zuohuaijun/Admin.NET/blob/v2/Admin.NET/Admin.NET.Core/Entity/SysMenu.cs
（MenuTypeEnum.cs 同仓库 Admin.NET.Core/Enum）

**缺陷：** 同上，只有 `Permission` 字符串（按钮行挂码），端点信息在控制器特性（[ApiPermission]）代码层。**独有可借鉴字段：`IsAffix`（标签页固定）→ 采纳为 is_affix（D5）**。OutLink 独立列（外链 URL 与 Path 分离）不采纳：现状 link 类型 + CHECK 约束已覆盖，且与 is_iframe 场景重叠。

### 3.4 三方对比总表

| 维度 | Yi.Abp | Admin.NET | SharpFort ⭐ |
|---|---|---|---|
| 权限码列 | PermissionCode | Permission | PermissionCode |
| 端点信息（path/method） | ❌ 代码层 | ❌ 代码层 | ✅ **ApiUrl/ApiMethod 内嵌** |
| Button 类型 | ❌（三值无按钮） | ✅ | ✅ |
| 角色绑定 | role_menu | role_menu | role_menu |
| 一码多端点 | ❌ | ❌ | ✅ 多行同码 |
| 描述承载 | Remark | Remark | Remark |
| 零后端（无代码层）适配 | ❌ 缺端点信息 | ❌ 缺端点信息 | ✅ **完整** |

---

## 4. 方案优势（对比现状双表模型）

| # | 优势 | 说明 |
|---|---|---|
| 1 | **单表心智** | 权限点 = 菜单行（button + api_code），无"两张表 + 两套绑定 + 双通道"的认知负担；授权弹窗 = 菜单树勾选，所见即所得 |
| 2 | **端点信息不丢失** | api_url/api_method 内嵌按钮行，原 iam_api 的 path/method/name/description 全部有落点（name→menu_name、description→remark） |
| 3 | **一码多端点自然表达** | 多行同 api_code（每行一端点），无需 JSONB/子表；button 行不生成前端路由，多行不污染 UI |
| 4 | **授权收敛单表** | iam_role_api 删除 → has_permission 单通道、角色 API 授权随菜单绑定继承（接口归属的按钮被绑 = 接口可调） |
| 5 | **资源树一体化** | 菜单树即权限树即资源树（接口 = 按钮行属性），039 的 menu_id 归属关联随表删除自然消解 |
| 6 | **约束不降级** | 原 iam_api UNIQUE(path,method) → 部分唯一索引补回；api_url/api_method 成对 CHECK；button 必填 api_code 保留 |
| 7 | **与现有资产兼容** | 单码制（040/044）、四值枚举（031/032）、表级 CHECK（038/040）全部保留，迁移为"列收编 + 表删除" |
| 8 | **未来可回 Casbin** | 若网关层恢复端点级拦截（052 之前曾走 APISIX casbin），menu 行的 api_url/api_method 即现成策略数据源 |

**代价（诚实评估）：** ① 055 迁移数据整理工作量较大（iam_api 行并入按钮行）；② 前端接口管理页需并入菜单管理；③ 验证链 verify-n4-d3.js 等 iam_api 口径断言需重写。

---

## 5. 目标模型

### 5.1 iam_menu 列清单（现状 22 列 + 新增 3 列）

> 按项目惯例，本文档不含 DDL 代码；列定义直接落迁移文件。

| 分组 | 列 | 说明 | 来源 |
|---|---|---|---|
| 主键/树 | id / parent_id | 现状保留（uuidv7 / 自引用 FK SET NULL） | 现状 |
| 基础 | menu_name / icon / order_num | 现状保留 | 现状 |
| 类型 | menu_type（ENUM 四值） | directory/menu/button/link | 现状（031/032） |
| 权限 | api_code | button 必填（040 CHECK 保留）；**非唯一索引**（一码多端点，D4，借鉴 SharpFort PermissionCode 索引） | 现状+SharpFort |
| 导航 | router / route_name / component / redirect / query / is_link / is_iframe / keep_alive / is_visible / remark | 现状保留（038/044） | 现状 |
| **端点** | **api_url** | 按钮行可选绑定端点路径（原 iam_api.path） | **SharpFort ApiUrl** |
| **端点** | **api_method** | 与 api_url 成对（原 iam_api.method） | **SharpFort ApiMethod** |
| 状态 | is_active | 现状保留 | 现状 |
| **导航** | **is_affix** | 标签页固定，默认 false | **Admin.NET IsAffix（D5）** |
| 审计 | created_at / updated_at / created_by / updated_by | 现状保留 | 现状 |

**约束（迁移内补齐）：** 保留 3 个现状 CHECK（link_path / is_link_path / button_perms）；新增 api_url/api_method 成对 CHECK + 部分唯一索引（WHERE api_url IS NOT NULL，D6）。

### 5.2 权限语义（单表化后）

- **按钮行 = 权限点 = 端点绑定载体**：`menu_type='button'` + `api_code` 必填；`api_url/api_method` 可选（绑定端点则成对填写）
- **一码多端点**：多行同 api_code，每行一个端点（如 sys:user:list 挂 GET /sys_user + GET /rpc/search_users 两行）
- **角色授权**：仅 iam_role_menu；绑按钮 = 拥有该权限码 = 可调该按钮下挂的端点
- **has_permission(p_code)**：role_menu → menu.api_code 单通道 + 超管短路（D3）

### 5.3 删除对象清单

| 对象 | 说明 |
|---|---|
| `iam_api` 表 | 端点信息并入 iam_menu（D1） |
| `iam_role_api` 表 + `trg_audit_role_api` 触发器 | 授权收敛（D2） |
| 046 rpc_set_menu_apis | 挂接操作并入菜单表单（按钮行编辑 api_url/api_method） |
| 043 API CRUD RPC（rpc_create_api 等） | 接口管理页并入菜单管理 |
| casbin_rule 视图 API 段 | 数据源改为 menu（v0=role_code, v1=api_url, v2=api_method），保留运行视图语义 |

---

## 6. 实施影响面（涉及文件）

| 文件 | 动作 | 级别 |
|---|---|---|
| `db/migrations/public/055_iam_menu_permission_unify.sql` | **新建**（加列 + 数据迁移 + 删表 + 函数/视图重建 + 验证 DO 块） | P0 |
| `db/api_v1/public/views/iam_menu.sql` | 视图 +3 列（api_url/api_method/is_affix） | P1 |
| `db/src/public/views/casbin_rule.sql` | 数据源改为 menu（api_url/api_method） | P1 |
| `db/src/public/functions/get_user_menu.sql` | 输出 +is_affix（可选消费） | P1 |
| has_permission / rpc_create_menu / rpc_update_menu（迁移层定义） | 单通道化 + 新参数字段 | P0 |
| `db/api_v1/public/rpc/rpc_get_role_permissions.sql`（044 重建于迁移，源文件待查） | API 授权展示改为"角色菜单下挂接口" | P1 |
| `db/api_v1/public/views/v_system_stats.sql` | total_apis 口径改为 button 行（api_url 非空） | P1 |
| `db/api_v1/public/rpc/rpc_import_csv.sql` | 清单移除 iam_api | P1 |
| `db/api_v1/public/rpc/rpc_set_menu_apis.sql` | 删除（.deprecated 后缀） | P1 |
| 043 API CRUD RPC 文件 | 删除（.deprecated 后缀） | P1 |
| `db/api_v1/public/grant_all.sql` | 清理 iam_api / iam_role_api 授权 | P1 |
| `db/src/public/triggers/trg_audit_role_api.sql` | 删除（.deprecated 后缀） | P1 |
| `db/tests/public/test_casbin_view.sql` | 断言改 menu 口径 | P1 |
| `~/.hermes_tmp/pglite-verify/verify-n4-d3.js` | 重写为 menu 口径（死权限点清理语义保留） | P1 |
| `~/.hermes_tmp/pglite-verify/verify-055.js` | **新建**（单表化专项验证） | P1 |
| 前端 admin 管理页 | 菜单表单 +api_url/api_method/is_affix；接口管理页并入菜单管理；授权弹窗 = 菜单树勾选 | P1 |
| `docs/开发实施方案/` 本文档 | 实施后状态勾选 | P2 |

---

## 7. 待执行任务清单

> 状态列：⬜ 待办 / ✅ 完成。按 P0 → P1 → P2 逐项实施，**每项完成等用户指令再进下一步**。

### 阶段一：迁移核心（P0）
- [ ] ⬜ **T1. 数据迁移策略冻结**：iam_api 行 → 同 api_code 已有 button 行则回填 api_url/api_method（044 的 1:1 实例直接并入）；无 button 的按原 menu_id 归属新建 button 行（menu_name=api.name，api_code/api_url/api_method 迁移，描述→remark）；iam_role_api 绑定 → 对应 button 行补绑 iam_role_menu（授权不丢）
- [ ] ⬜ **T2. 055 迁移编写**：iam_menu +3 列（幂等）→ 数据迁移（T1 策略）→ 删 iam_api/iam_role_api + trg_audit_role_api → has_permission 单通道重建 → casbin_rule 重建 → 约束/索引补齐 → 验证 DO 块
- [ ] ⬜ **T3. rpc_create_menu / rpc_update_menu 重建**：新签名 +api_url/api_method/is_affix（DROP 旧签名防 PGRST203）

### 阶段二：联动改造（P1）
- [ ] ⬜ **T4. 视图与 RPC 联动**：iam_menu 视图、casbin_rule、get_user_menu、get_role_permissions、v_system_stats、rpc_import_csv、grant_all 按 §6 清单更新
- [ ] ⬜ **T5. 清理类删除**：046 rpc_set_menu_apis、043 API CRUD RPC、trg_audit_role_api 置 .deprecated
- [ ] ⬜ **T6. 验证链**：verify-n4-d3.js 重写 + verify-055.js 新建 + test_casbin_view.sql 更新
- [ ] ⬜ **T7. 全链验证**：`npm run test` 全绿（断言数 ≥ 当前基线 152+）
- [ ] ⬜ **T8. 存量库演练**：WSL Pigsty 执行 apply-src 全量重放，无冲突、无异常 NOTICE

### 阶段三：前端与收尾（P2）
- [ ] ⬜ **T9. 前端菜单管理**：表单 +api_url/api_method/is_affix；接口管理页并入菜单管理
- [ ] ⬜ **T10. 授权弹窗**：菜单树勾选（按钮叶子展示权限码 + 端点信息）
- [ ] ⬜ **T11. 文档同步**：本文档状态勾选完成、修订记录追加 v1.1；05-Logto认证与权限架构 关联段落标注变更

---

## 8. 验收标准

1. `iam_api`、`iam_role_api` 表在 information_schema 中不存在（含依赖对象清理干净）
2. 原 iam_api 全部端点行在 iam_menu 有对应 button 行（api_url+api_method 一一对应，无丢失）
3. 原 iam_role_api 绑定全部转换为 iam_role_menu 绑定（角色授权不缩水，抽查角色逐项核对）
4. button 行 api_code 非空（040 CHECK 生效）；api_url 非空行 api_method 必填且 (api_url, api_method) 全局唯一
5. has_permission 单通道判定正确：超管短路、role_menu→menu.api_code、未绑角色拒绝（055 验证 DO 块断言）
6. casbin_rule 视图输出与迁移前语义等价（role_code → api_url/method 映射，无缺失行）
7. PGlite 验证链全绿，断言数 ≥ 152；存量库 apply-src 重放两遍不炸（幂等）
8. 前端授权弹窗 = 菜单树勾选；接口信息在按钮行可见可编辑

---

## 9. 修订记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-08-12 | 初稿：SharpFort 单表模型决策（D1-D7）+ 实施清单 |

---

## 附：借鉴来源链接

| 来源 | 链接 | 用途 |
|---|---|---|
| SharpFort Menu.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Menu.cs | 单表模型主参考（ApiUrl/ApiMethod/PermissionCode） |
| SharpFort MenuType.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain.Shared/Enums/MenuType.cs | 四值枚举（Button=3）确认 |
| SharpFort Role.cs / RoleMenu.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Role.cs | 授权单表（RoleMenu）确认 |
| Yi.Abp MenuAggregateRoot.cs | https://gitee.com/ccnetcore/Yi/blob/main/Yi.Abp.Net8/module/rbac/Yi.Framework.Rbac.Domain/Entities/MenuAggregateRoot.cs | 对比（无端点列，不采纳） |
| Admin.NET SysMenu.cs | https://gitee.com/zuohuaijun/Admin.NET/blob/v2/Admin.NET/Admin.NET.Core/Entity/SysMenu.cs | 对比（IsAffix 借鉴，OutLink 不采纳） |
