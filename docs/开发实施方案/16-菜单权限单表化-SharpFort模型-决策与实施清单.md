# 16 — 菜单权限单表化（SharpFort 模型）决策与实施清单

> **创建日期：** 2026-08-12
> **文档类型：** 架构决策记录（ADR）/ 待执行任务清单
> **状态：** ✅ 决策已拍板 → ✅ 阶段一（P0）完成 → ✅ 阶段二（P1）完成 → ✅ 阶段三（P2：T9/T10 代码 + T11 部分）完成（2026-08-12，pnpm build 全绿）→ ⏳ 收尾待办：前端 commit 重提（commitlint body 超长拦截）、T11 的 05/15 文档标注、T8 存量库 apply-src 两遍演练（WSL 环境）
> **关联文档：** 05-Logto认证与权限架构-完善版.md、05.2-Admin管理模块函数视图补全分析.md、15-数据库迁移文件治理与合并策略.md、casbin-rbac-best-practices-中文版.md
> **借鉴来源：** SharpFort.Net（GitHub，最终采纳）、Yi.Abp（gitee，对比）、Admin.NET（gitee，对比）
> **执行工具：** apply-src.sh（psql 全量幂等重放）+ PGlite 验证链（~/.hermes_tmp/pglite-verify/）
> **审查关联：** docs/审查文档/16-审查-菜单权限单表化SharpFort模型.md（2026-08-12 独立审查：决策层全部成立，P0×3/P1×7/P2×5，本版 v1.1 已吸收全部拍板项）

---

## 1. 决策结论（2026-08-12 拍板，v1.1 修订）

| # | 决策 | 级别 | 实施位置 |
|---|---|---|---|
| D1 | **采纳 SharpFort 单表模型**：iam_menu 承载菜单 + 权限点 + API 端点信息（api_url/api_method 内嵌按钮行），**删除 iam_api 表**（推翻 038 D2 分离式拍板） | P0 | 迁移 055 |
| D2 | **删除 iam_role_api 绑定表**：角色授权收敛为 iam_role_menu 单表（授权树 = 菜单树勾选） | P0 | 迁移 055 |
| D3 | **has_permission 单通道化**：判定收敛为 role_menu → menu.api_code（超管短路保留）；原双通道（role_api→api_code）随 D2 删除 | P0 | 迁移 055 |
| D4 | **一码多端点 = 多行同 api_code 的 button 行**（PermissionCode 非唯一索引，每行一个端点；button 行不生成前端路由，不污染 UI） | P0 | 迁移 055 |
| D5 | **is_affix 新增**（标签页固定，借鉴 Admin.NET IsAffix，上轮已确认的 P1）随本迁移一并落地 | P1 | 迁移 055 |
| D6 | **api_url/api_method 成对约束 + api_method 值域约束 + 部分唯一索引**（v1.1 强化：api_url 非空行 api_method **必填非空**且值域限定 IN（GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*），'*' 保留通配语义；部分唯一索引 WHERE api_url IS NOT NULL，补齐原 iam_api UNIQUE(path, method) 的表级保证） | P2 | 迁移 055 |
| D7 | 设计论证不再引用 RuoYi 方案（用户 2026-08-12 纠正：其存在误导性） | — | 文档约定 |
| D8 | **按钮行导航字段置空 CHECK**（v1.1 新增，用户拍板）：`menu_type='button' → router IS NULL AND component IS NULL`——"按钮行不污染 UI"从约定升级为表级保证（借鉴 Admin.NET v2 CheckMenuParam 服务端强制清空 Name/Path/Component/Icon/Redirect 的实践，零后端项目以 CHECK 落地） | P1 | 迁移 055 |
| D9 | **遗留数据彻底重构**（v1.1 新增，用户拍板）：**无码行（api_code IS NULL）与死端点行（PostgREST 已无对应端点）直接清除，不转换、不赋码**；仅**有码行**按 T1 规则转换。删除影响由超管短路兜底（011 全量绑定丢失无实际影响；tenant_admin 绑定全在有码行，不受波及） | P0 | 迁移 055 |
| D10 | **删除 041 子树授权 RPC**（v1.1 新增，用户拍板）：rpc_grant_menu_subtree_apis / rpc_revoke_menu_subtree_apis 直接删除（单表化后"菜单子树授权"语义由 iam_role_menu 树勾选天然继承，无改造价值） | P0 | 迁移 055 |

**一句话结论：** 菜单表单表承载"导航 + 权限码 + 端点信息"，角色授权只走 iam_role_menu——SharpFort 模型与本项目零后端架构完全适配，是"menu 表实现 permission 表功能"的终极形态。v1.1 在独立审查基础上补强三处：**删除对象清单补全**（041/045/024 RPC + 三个暴露视图 + 权限点清理）、**按钮行 UI 隔离表级化**（D8）、**遗留数据清除策略**（D9）。

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

**补充核实（v1.1，审查确认）：** 现状 iam_api 中存在的"无码行"（api_code IS NULL，043 实测 ≈14 行）= 011 从旧 sys_api 目录迁移、从未赋码的接口行（含 /sys_api、/sys_menu、/sys_role、/sys_user 等死端点与 /rpc/get_user_menu 等历史行）——它们无权限码 = 无 has_permission 判定键 = 纯目录元数据，且其中死端点行在 015/018 清理后 PostgREST 已无对应端点。SharpFort 中 button 必有 PermissionCode（跑通方案），本项目 040 CHECK 亦已保证 button 行 api_code 非空——**无码行本就不该存在**，按 D9 直接清除（与 RouterName 无关：RouterName 是 SharpFort Menu 的路由名称字段 = 本项目 iam_menu.route_name，不是权限码）。

---

## 3. 借鉴来源分析

### 3.1 SharpFort.Net —— 最终采纳模型 ⭐

**来源：** https://github.com/SharpFort/SharpFort.Net
（module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Menu.cs、Role.cs、RoleMenu.cs；Domain.Shared/Enums/MenuType.cs、MenuSource.cs；Domain/Managers/CasbinPolicyManager.cs；Application/Services/System/MenuService.cs）

**核心设计（源码核查结论，2026-08-12 复审与决策时点缓存 diff 一致）：**

| 设计点 | SharpFort 实现 | 对本项目的意义 |
|---|---|---|
| 单表 | 仅 `casbin_sys_menu`，**无独立 API 表**（Entities 目录已核查） | 单表模型完整实现 |
| 端点内嵌 | `ApiUrl` + `ApiMethod` 列直接挂在菜单行（注释：用于 Casbin 鉴权，如 /api/system/user + GET） | **决定性差异**——权限码与端点信息同处数据层 |
| 权限点 | `PermissionCode`（128 字）+ 普通索引（注释：加速权限验证查询）；button 业务上必有码（权限点=菜单行） | 权限点=菜单行，索引即判定路径；**印证 D9：无码行不应存在** |
| 类型 | 四值：Catalogue / Menu / Component / **Button** | 与现状 menu_type 四值同构（directory/menu/link/button） |
| 绑定 | 仅 `RoleMenu` 中间表（Role.Menus 导航已核查；联合唯一索引 (RoleId, MenuId)） | 授权单表 |
| 一码多端点 | PermissionCode **非唯一索引** → 多行同码，每行一个端点 | 单表下"一码多端点"的标准解 |
| 描述 | Remark（500 字） | description 有处放 |
| 端点级拦截 | Casbin Enforcer：(role, apiUrl, apiMethod) 运行时判定；**策略构建仅对 ApiUrl 非空行生成规则，ApiMethod 空则默认 '*'** | 本项目无中间件 → api_url/api_method 作目录/审计元数据（运行时靠 RPC 内 has_permission，052 已废弃 APISIX casbin）；**'*' 通配语义与 009 iam_api.method DEFAULT '*' 一脉相承 → D6 值域保留 '*'** |
| 端点校验 | MenuService.ValidateApiUrl：ApiUrl 须 /api/ 开头、全小写、无 {param}（Casbin keyMatch2 约束）；ApiUrl 非空且 ApiMethod 空 → 创建时默认 GET | 本项目 PostgREST 端点无 /api/ 前缀；可借鉴"以 / 开头、不含 {}"格式校验（RPC 层，P2） |
| 菜单来源 | `MenuSource`（Ruoyi=0 / Pure=1）：兼容两种前端框架路由生成逻辑 | 双前端兼容字段，本项目不引入（单前端） |

**为什么它是最优**：它是唯一把"权限码 + 端点信息"**全部放进数据层**的单表模型。对 SharpFort 自身，端点信息服务于 Casbin 运行时拦截；对本项目零后端架构，同样的存储结构服务于目录/资源树/审计——**存储形态一致，消费方式不同，恰好完整适配**。

### 3.2 Yi.Abp —— 对比（不采纳）

**来源：** https://gitee.com/ccnetcore/Yi/blob/main/Yi.Abp.Net8/module/rbac/Yi.Framework.Rbac.Domain/Entities/MenuAggregateRoot.cs
（MenuTypeEnum.cs 同仓库 Domain.Shared）

**缺陷：** 菜单表只有 `PermissionCode` 字符串，**无 ApiUrl/ApiMethod 类端点列**——端点信息在 ABP PermissionDefinitionProvider 代码层定义。对本项目（无代码层）移植后"端点→权限码"映射无处落数据。另有 RouterName/IsCache/IsShow/MenuSource 等导航字段（现状 iam_menu 已等价覆盖）。MenuTypeEnum 三值（Catalogue/Menu/Component）**无按钮**——按钮级权限点无法表达。

### 3.3 Admin.NET —— 对比（不采纳）

**来源：** https://gitee.com/zuohuaijun/Admin.NET/blob/v2/Admin.NET/Admin.NET.Core/Entity/SysMenu.cs
（MenuTypeEnum.cs 同仓库 Admin.NET.Core/Enum；Service/Menu/SysMenuService.cs）

**缺陷：** 同上，只有 `Permission` 字符串（按钮行挂码），**端点信息不在数据层**（v2 实测：服务方法仅 [DisplayName] + IDynamicApiController 动态 API，权限判定在服务层；端点 URL/Method 由方法签名确定，sys_menu 无任何端点列）。**独有可借鉴字段：`IsAffix`（标签页固定）→ 采纳为 is_affix（D5）**。OutLink 独立列（外链 URL 与 Path 分离）不采纳：现状 link 类型 + CHECK 约束已覆盖，且与 is_iframe 场景重叠。

**v1.1 新增核实：** `SysMenuService.CheckMenuParam`——Btn 行写入时**服务端强制清空** Name/Path/Component/Icon/Redirect/OutLink/IsHide/IsKeepAlive/IsAffix/IsIframe，且 Permission 必填并**必须含 ':'**（格式校验）；非 Btn 行 Permission 强制置 NULL。**本项目零后端无服务层 → 该语义升级为表级 CHECK（D8）**；Permission 含 ':' 格式校验可借鉴为 api_code 格式约定（RPC 层软校验，P2）。

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
| 按钮行 UI 隔离 | 约定 | ✅ 服务端强制（CheckMenuParam） | 约定（路由构建过滤 Component + 按钮行无 Router） |
| 端点格式校验 | ❌ | ❌ | ✅ ValidateApiUrl |

---

## 4. 方案优势（对比现状双表模型）

| # | 优势 | 说明 |
|---|---|---|
| 1 | **单表心智** | 权限点 = 菜单行（button + api_code），无"两张表 + 两套绑定 + 双通道"的认知负担；授权弹窗 = 菜单树勾选，所见即所得 |
| 2 | **端点信息不丢失** | api_url/api_method 内嵌按钮行，原 iam_api 的 path/method/name/description 全部有落点（name→menu_name、description→remark） |
| 3 | **一码多端点自然表达** | 多行同 api_code（每行一端点），无需 JSONB/子表；button 行不生成前端路由，多行不污染 UI |
| 4 | **授权收敛单表** | iam_role_api 删除 → has_permission 单通道、角色 API 授权随菜单绑定继承（接口归属的按钮被绑 = 接口可调） |
| 5 | **资源树一体化** | 菜单树即权限树即资源树（接口 = 按钮行属性），039 的 menu_id 归属关联随表删除自然消解 |
| 6 | **约束不降级且更严** | 原 iam_api UNIQUE(path,method) → 部分唯一索引补回；api_url/api_method 成对 CHECK + **值域 CHECK（D6）**；button 必填 api_code 保留；**按钮行导航置空 CHECK（D8）**——"不污染 UI"从约定升级为表级保证 |
| 7 | **与现有资产兼容** | 单码制（040/044）、四值枚举（031/032）、表级 CHECK（038/040）全部保留，迁移为"列收编 + 表删除" |
| 8 | **未来可回 Casbin** | 若网关层恢复端点级拦截（052 之前曾走 APISIX casbin），menu 行的 api_url/api_method 即现成策略数据源（SharpFort CasbinPolicyManager 同款构建逻辑） |

**代价（诚实评估）：** ① 055 迁移数据整理工作量较大（iam_api 有码行并入按钮行；v1.1 按 D9 清除无码/死端点行后工作量下降）；② 前端接口管理页需并入菜单管理；③ 验证链 verify-n4-d3.js 保持历史链回归 + verify-055.js 新建（v1.1 修正：n4-d3 验证 055 之前的 028/040/044/045 链，无需重写）。

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
| 导航 | router / route_name / component / redirect / query / is_link / is_iframe / keep_alive / is_visible / remark | 现状保留（038/044）；**button 行 router/component 强制 NULL（D8 CHECK）** | 现状 |
| **端点** | **api_url** | 按钮行可选绑定端点路径（原 iam_api.path）；格式约定：以 / 开头、不含 {}（RPC 层软校验，P2） | **SharpFort ApiUrl** |
| **端点** | **api_method** | 与 api_url 成对；**api_url 非空行必填非空，值域 IN (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*)（D6 CHECK）**；'*' 保留通配语义 | **SharpFort ApiMethod** |
| 状态 | is_active | 现状保留 | 现状 |
| **导航** | **is_affix** | 标签页固定，默认 false | **Admin.NET IsAffix（D5）** |
| 审计 | created_at / updated_at / created_by / updated_by | 现状保留 | 现状 |

**约束（迁移内补齐）：** 保留 3 个现状 CHECK（link_path / is_link_path / button_perms）；**新增 4 项（v1.1）**：① api_url/api_method 成对 CHECK（api_url IS NOT NULL → api_method IS NOT NULL）；② api_method 值域 CHECK（D6）；③ 部分唯一索引（WHERE api_url IS NOT NULL，D6）；④ **按钮行导航置空 CHECK（menu_type='button' → router IS NULL AND component IS NULL，D8）**。

### 5.2 权限语义（单表化后）

- **按钮行 = 权限点 = 端点绑定载体**：`menu_type='button'` + `api_code` 必填；`api_url/api_method` 可选（绑定端点则成对填写，method 非空 + 值域限定）
- **一码多端点**：多行同 api_code，每行一个端点（如 sys:user:list 挂 GET /sys_user + GET /rpc/search_users 两行——示例为 055 后能力，现状数据一码一行受 023 部分唯一索引约束，055 删除该索引后开放）
- **角色授权**：仅 iam_role_menu；绑按钮 = 拥有该权限码 = 可调该按钮下挂的端点
- **has_permission(p_code)**：role_menu → menu.api_code 单通道 + 超管短路（D3）
- **遗留数据（D9）**：无码行/死端点行不转换直接清除；有码行（024/029/040/042/043 seed ≈26 行）按 T1 转换

### 5.3 删除对象清单（v1.1 补全）

| 对象 | 说明 |
|---|---|
| `iam_api` 表 | 端点信息并入 iam_menu（D1）；RLS 策略（api_read_policy）、审计触发器（023 挂）、部分唯一索引 idx_iam_api_code 随表删除 |
| `iam_role_api` 表 + `trg_audit_role_api` 触发器 | 授权收敛（D2）；RLS 策略（role_api_read_policy）随表删除 |
| 046 `rpc_set_menu_apis` | 挂接操作并入菜单表单（按钮行编辑 api_url/api_method） |
| 043 API CRUD RPC（rpc_create_api / rpc_update_api / rpc_delete_api）+ 权限点 sys:api:create/update/delete | 接口管理页并入菜单管理；**权限点及 role_super_admin 绑定一并清理（035 惯例）** |
| 024 `rpc_set_role_apis` + 权限点 **sys:role-api:bind** | 角色 API 授权收敛（D2）；rpc_set_role_menus 保留（授权弹窗保存通道） |
| 041 `rpc_grant_menu_subtree_apis` / `rpc_revoke_menu_subtree_apis` | **直接删除（D10 拍板）**：子树授权语义由菜单树勾选继承 |
| 045 `rpc_create_menu_with_api` | 合并创建菜单+接口 RPC，055 后无 iam_api 可写，删除（合并语义并入 rpc_create_menu 新签名） |
| 暴露视图 `api_v1_public.iam_api` / `iam_role_api` / `v_role_api_detail`（含源文件） | **git rm 源文件 + 迁移 DROP VIEW IF EXISTS**（⚠️ 源文件不删则 apply-src 重放 api_v1 阶段先于 055 建视图引用不存在的表 → 全链失败，必须同批提交） |
| casbin_rule 视图 API 段 | 数据源改为 menu（v0=role_code, v1=api_url, v2=api_method）；**菜单段（role_menu→router/'menu'）原样保留**——视图为双段结构 |
| 遗留无码行 / 死端点行（≈14 行级） | **直接清除（D9 拍板）**：011 迁移的旧目录行（/sys_api、/sys_menu、/sys_role、/sys_user、/rpc/get_user_menu 等），不转换不赋码；绑定随行消失，超管短路兜底 |
| grant_all.sql 中 iam_api / iam_role_api / v_role_api_detail GRANT | 清理（role_admin INSERT/UPDATE 授权 + authenticated SELECT） |

---

## 6. 实施影响面（涉及文件，v1.1 补全）

| 文件 | 动作 | 级别 |
|---|---|---|
| `db/migrations/public/055_iam_menu_permission_unify.sql` | **新建**（加列 + 数据迁移 + 删表 + 函数/视图重建 + 权限点清理 + 验证 DO 块） | P0 |
| `db/api_v1/public/views/iam_menu.sql` | 视图 +3 列（api_url/api_method/is_affix） | P1 |
| `db/api_v1/public/views/iam_api.sql`、`iam_role_api.sql`、`v_role_api_detail.sql` | **git rm（源文件删除）** + 055 迁移 DROP VIEW IF EXISTS | P0 |
| `db/api_v1/public/views/v_role_menu_detail.sql` | 视图 +api_url/api_method/is_affix（授权明细展示；055 后保留——role_menu 未删） | P1 |
| `db/api_v1/public/rpc/rpc_get_menu_tree_admin.sql` | get_menu_tree_admin +menu_type/api_code/api_url/api_method/is_affix（管理树 + 授权弹窗数据源） | P1 |
| `db/src/public/views/casbin_rule.sql` | API 段数据源改为 menu（api_url/api_method）；菜单段保留；**源文件与迁移同批提交** | P1 |
| `db/src/public/functions/get_user_menu.sql` | 输出 +is_affix（可选消费）；源文件同步 | P1 |
| has_permission / rpc_create_menu / rpc_update_menu（迁移层定义） | 单通道化 + 新参数字段 + D8 校验 + D6 校验（DROP 旧签名防 PGRST203） | P0 |
| `db/api_v1/public/rpc/rpc_get_role_permissions.sql`（函数名 get_role_permissions；源文件已确认存在，文件头注释残留旧路径 `db/api_v1/sys/rpc/` 顺手修正） | API 授权展示改为"角色菜单下挂接口"（join iam_menu WHERE api_url IS NOT NULL） | P1 |
| `db/api_v1/public/rpc/rpc_set_role_apis.sql`（024 迁移层定义，无源文件） | 删除（DROP FUNCTION IF EXISTS） | P0 |
| 041 两个子树授权 RPC（迁移层定义） | 删除（DROP FUNCTION IF EXISTS，D10） | P0 |
| 045 `rpc_create_menu_with_api`（迁移层定义） | 删除（DROP FUNCTION IF EXISTS） | P0 |
| `db/api_v1/public/rpc/rpc_import_csv.sql` | 白名单移除 iam_api | P1 |
| `db/api_v1/public/rpc/rpc_set_menu_apis.sql` | 删除（.deprecated 后缀） | P1 |
| 043 API CRUD RPC 文件 | 删除（.deprecated 后缀）；**权限点 sys:api:create/update/delete 清理** | P1 |
| `db/api_v1/public/privileges/grant_all.sql` | 清理 iam_api / iam_role_api / v_role_api_detail 授权 | P1 |
| `db/src/public/triggers/trg_audit_role_api.sql` | 删除（.deprecated 后缀） | P1 |
| `db/tests/public/test_casbin_view.sql` | 断言改 menu 口径（第 5 条 JOIN iam_api → JOIN iam_menu） | P1 |
| `~/.hermes_tmp/pglite-verify/verify-n4-d3.js` | **保持原样**（v1.1 修正：验证 055 之前历史链 028/040/044/045，apply-src 顺序先于 055，无需重写） | — |
| `~/.hermes_tmp/pglite-verify/verify-055.js` | **新建**（单表化专项验证，断言清单见 T6） | P1 |
| 前端 admin 管理页 | 菜单表单 +api_url/api_method/is_affix（button 类型时导航字段禁用）；接口管理页并入菜单管理；授权弹窗 = 菜单树勾选 | P1 |
| `docs/开发实施方案/` 本文档 | 实施后状态勾选 | P2 |

---

## 7. 待执行任务清单（v1.1 细化版）

> 状态列：⬜ 待办 / ✅ 完成。按 P0 → P1 → P2 逐项实施，**每项完成等用户指令再进下一步**。

### 阶段一：迁移核心（P0）✅ 已完成（2026-08-12）

- [x] ✅ **T1. 数据迁移策略冻结（v1.1 按 D9 简化）**
  - 前置核查（存量库执行，输出清单供核对）：① 有码行清单（api_code IS NOT NULL，预期 ≈26 行：024×19 + 029×2 + 040×1 + 042×1 + 043×3）与无码行/死端点行清单（预期 ≈14 行级，D9 清除对象）；② 每 button 行挂接 api 行数核查（>1 冲突清单，044 仅 3 个用户按钮有 1:1 先例）；③ iam_api.menu_id IS NULL 孤儿行数（D9 一并清除）
  - 转换规则（仅对有码行）：同 api_code 已有 button 行 → 回填 api_url/api_method（044 的 1:1 实例直接并入）；无 button 的按原 menu_id 归属新建 button 行（menu_name=api.name，api_code/api_url/api_method 迁移，描述→remark）；**一码多行时逐行映射不合并**（每行一个端点，D4）
  - 授权转换：iam_role_api 绑定 → 对应 button 行补绑 iam_role_menu（逐行映射；无码/死端点行上的绑定随行清除，超管短路兜底）
  - ⚠️ 无码行赋码**不做**（D9 拍板：直接清除，不赋码）
  - 交付：`scripts/055-t1-precheck.sql`（只读 11 段）+ `docs/开发实施方案/16-055-T1前置核查-存量数据清单.md`（静态基线：有码 27 行/无码 ≈14 行）+ PGlite 桩验证 verify-t1-precheck.js（8/8）已入链；**存量库实测回填待 T8 演练时执行**（本机无 WSL/存量库）
- [x] ✅ **T2. 055 迁移编写（顺序显式化）**：`db/migrations/public/055_iam_menu_permission_unify.sql`（§1 DROP 依赖 → §2 加列 → §2.5 button 导航清理（D8 前置）→ §3 约束/索引 → §4 数据迁移（4.1 权限点删除 / 4.2 回填 / 4.3 新建 / 4.4 非 button 码收敛 / 4.5 绑定转换 / 4.6 无码清除 / 4.7 完整性断言）→ §5/§6 DROP 表 → §7 重建 has_permission/casbin_rule/get_role_permissions/rpc_create_menu/rpc_update_menu → §10 验证 DO 块）
  - 实施中两项细化（v1.2 记录）：① **非 button 行 api_code 强制 NULL**（数据迁移 4.4 + RPC CASE 落库，Admin.NET CheckMenuParam 同款语义，D8 的镜像补充）；② **D8 CHECK 创建前必须先清理存量 button 行导航字段**（§2.5 前置，否则存量数据违例导致约束创建失败）
  - 同批源文件（全链重放约束——055 删表后 src/api_v1 阶段不得残留 iam_api/iam_role_api 引用，否则 42P01 全链失败）：git rm `views/iam_api.sql`、`views/iam_role_api.sql`、`views/v_role_api_detail.sql`；改写 `src/public/views/casbin_rule.sql`（API 段 menu 口径）、`views/v_system_stats.sql`（total_apis 口径）、`rpc/rpc_get_role_permissions.sql`（apis 段菜单口径）、`privileges/grant_all.sql`（移除 5 处 GRANT）
- [x] ✅ **T3. rpc_create_menu / rpc_update_menu 重建**（随 055 §7.4/7.5 交付）：新签名 +p_api_url/p_api_method/p_is_affix（DROP 旧签名防 PGRST203）；**D8 校验**（button 时强制 router/component 置空——RPC 友好报错 22023 + 表级 CHECK 兜底）；**D6 校验**（api_url 与 api_method 成对 + 值域）；非 button 行权限字段强制 NULL；api_code 格式软校验（含 ':'，P2 可选）；verify-055.js 覆盖全部拒绝/成功路径（12 项 ⑧ 断言）

### 阶段二：联动改造（P1）✅ 已完成（2026-08-12）

- [x] ✅ **T4. 视图与 RPC 联动**：`views/iam_menu.sql`（+api_url/api_method/is_affix）、`v_role_menu_detail.sql`（+3 列）、`rpc_get_menu_tree_admin.sql`（+menu_type/api_code/api_url/api_method/is_affix——授权弹窗数据源）、`get_user_menu.sql`（+is_affix）、`rpc_import_csv.sql`（白名单移除 iam_api）按 §6 清单更新；casbin_rule/v_system_stats/get_role_permissions/grant_all 已在 P0 同批完成；**审查遗漏 2 处当场发现并修复**：`v_role_list.sql`（api_count 子查询引用 iam_role_api——api_v1 阶段重放 42P01，改为"角色绑定的带端点按钮数"）、`src/public/privileges/rls_policies.sql`（iam_api/iam_role_api RLS 策略段——src 阶段重放 42P01，删除并留 055 注释）；verify-t4-src.js（11 断言）覆盖 7 个联动源文件重放
- [x] ✅ **T5. 清理类删除**：`trg_audit_role_api.sql` → `.deprecated`（git mv，引用已删表）；046 rpc_set_menu_apis / 043 API CRUD RPC / 024 rpc_set_role_apis / 041×2 / 045 rpc_create_menu_with_api 均无源文件（函数仅迁移层定义），055 §1 已 DROP；权限点 sys:api:create/update/delete、sys:role-api:bind 及绑定行已随 055 §4.1 清理
- [x] ✅ **T6. 验证链**：verify-n4-d3.js 保持原样（历史链回归）；verify-055.js（84 断言）+ verify-t4-src.js（11 断言）已入链；`test_casbin_view.sql` §5 改 JOIN iam_menu 口径；**pgTAP 测试同步更新**（make test-db 依赖）：`01_schema_test.sql`（plan 67→62：iam_api/iam_role_api → hasnt_table，+iam_menu 端点/固定标签列断言，索引断言改 iam_menu 口径，删 role_api FK 断言）、`05_rls_test.sql`（plan 12：iam_api/iam_role_api RLS 断言 → "已删除"断言，iam_api 激活项可读 → iam_menu 端点行可读）
- [x] ✅ **T7. 全链验证**：`npm run test` 全绿 **253 断言 / 0 失败**（verify-020/ensure-user/n4-d3/n6/p1/p2/052/053/054/t1-precheck/055/t4-src + test_step5 + test_reconcile），含 verify-055 幂等两遍
- [ ] ⬜ **T8. 存量库演练**（本机部分完成）：grep 全仓复查无 `FROM public.iam_api` / `FROM iam_role_api` / `ON iam_role_api` 代码引用残留（.deprecated 除外；仅历史迁移 009-054 保留——apply-src 重放循环设计内）；**WSL Pigsty apply-src 全量重放两遍 + pgTAP（make test-db）待用户环境执行**（本机无 psql/存量库）

### 阶段三：前端与收尾（P2）✅ 代码完成（2026-08-12，pnpm build 全绿）

- [x] ✅ **T9. 前端菜单管理**（OmniAdmin 仓库，main 分支）：`menu-dialog.vue` 表单 +api_url/api_method/is_affix（api_method 下拉值域对齐 D6 八值：GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*）；**menu_type=button 时导航字段（router/component/redirect/query/route_name）watch 清空 + 提交时强制 NULL**（对齐 D8 服务端语义）；接口管理页并入菜单管理（git rm `views/system/api/` 三文件 + 路由 Api 块 + locales key）；`MenuAdminNode` +3 字段；删除 046 绑定接口选择器（setMenuApis 已删）与 040 权限码软校验（055 后权限点=按钮行自身，一码多端点合法）；`menu/index.vue` 改纯菜单树（按钮行 api_method 徽标 + 接口列 api_url）；`system-manage.ts` createMenu/updateMenu +3 参数
- [x] ✅ **T10. 授权弹窗**（`role-permission-dialog.vue` 重写）：菜单树勾选 = **唯一授权通道**（删除 API 权限 tab / 041 一键授权联动 / setRoleApis 保存通道——保存只走 rpc_set_role_menus 全量覆盖）；按钮叶子行内展示 api_code + api_url/api_method；父子联动保留（checked + halfChecked 合并）；保存按钮 v-perm 改 `sys:role-menu:bind`；数据源 = GET /iam_menu 视图全列 + 前端组树（get_role_permissions.menus 回显）
- [x] ✅ **T11. 文档同步**：本文档状态勾选 + 修订记录 v1.4 ✅；05-Logto认证与权限架构 关联段落标注 ✅（修订记录 v3.11 + 5 处核心段落就地标注：一句话概述/表清单/has_permission/③ PG 自主/E3 casbin_rule）；15 号文档 M4 验证链重构条目同步 ✅（验证链 12 JS + 2 PY 共 253 断言基线、验收标准 3 更新、涉及范围 55 文件）
- [x] ✅ **实施中发现（审查清单外）**：`usePermission.ts` 通道1 数据源 v_role_api_detail → **v_role_menu_detail**（该视图随 055 删除，不改则前端 v-perm 权限码收集 404 全哑）——RoleApiPerm 类型同步改为 RoleMenuPerm；`useAuth.ts` 注释同步
- [x] ✅ **构建验证**：pnpm build（vue-tsc + vite）全绿；auto-imports.d.ts 由 vite 生成（gitignore 约定，clean clone 首次需先跑 vite）
- [ ] ⬜ **前端提交**：commit 被 commitlint body-max-line-length 拦截（body 行 >100 字符），短 body 重提后 push 待执行

---

## 8. 验收标准（v1.1 修订）

1. `iam_api`、`iam_role_api` 表在 information_schema 中不存在（含依赖对象清理干净：RLS 策略、审计触发器、索引、授权）
2. **有码 iam_api 行全部在 iam_menu 有对应 button 行**（api_url+api_method 精确匹配，无缺失）；**无码行/死端点行已清除**（D9 核对清单）
3. 原 iam_role_api 绑定中**有码行绑定**全部转换为 iam_role_menu 绑定（角色授权不缩水，抽查角色逐项核对；无码/死端点行绑定随行清除，超管短路兜底）
4. button 行 api_code 非空（040 CHECK 生效）；**api_url 非空行 api_method 必填且值域合法（D6 CHECK）；(api_url, api_method) 部分唯一（WHERE api_url IS NOT NULL）**；**button 行 router/component 为 NULL（D8 CHECK）**
5. has_permission 单通道判定正确：超管短路、role_menu→menu.api_code、未绑角色拒绝（055 验证 DO 块断言）
6. **casbin_rule 双段语义等价**：API 段 = role_menu→button 行（v1=api_url/v2=api_method），菜单段 = role_menu→菜单行（v1=router/v2='menu'）原样保留，两段均无缺失行
7. PGlite 验证链全绿（断言数 ≥ 152 + verify-055 新增）；存量库 apply-src 重放两遍不炸（幂等）
8. 前端授权弹窗 = 菜单树勾选；接口信息在按钮行可见可编辑
9. **全仓 grep 无 `FROM public.iam_api` / `FROM iam_role_api` / `ON iam_role_api` 残留（.deprecated 除外）**——视图/触发器/函数源文件同步完成（P0-2）
10. **权限点 sys:api:create/update/delete、sys:role-api:bind 及其绑定行已清理**（has_permission 引用核对无悬空）

---

## 9. 修订记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-08-12 | 初稿：SharpFort 单表模型决策（D1-D7）+ 实施清单 |
| v1.1 | 2026-08-12 | **独立审查吸收（docs/审查文档/16-审查-菜单权限单表化SharpFort模型.md）**：① 用户拍板 D8（按钮行导航置空 CHECK，借鉴 Admin.NET CheckMenuParam 服务端强制 → 表级化）、D9（遗留无码行/死端点行直接清除，彻底重构不兼容遗留）、D10（删除 041 子树授权 RPC）；② D6 强化（api_method 非空 + 值域约束含 '*'）；③ 删除对象清单补全（024 rpc_set_role_apis、041×2、045 rpc_create_menu_with_api、三个暴露视图源文件、权限点 sys:api:*/sys:role-api:bind）；④ casbin_rule 双段语义明确（菜单段保留）；⑤ T2 DROP 顺序显式化（FK 依赖）；⑥ verify-n4-d3.js 处置修正（保持原样，新建 verify-055.js）；⑦ get_role_permissions 源文件状态查明；⑧ 影响面补 v_role_menu_detail / get_menu_tree_admin；⑨ 验收标准 2/4/6 修正 + 新增 9/10 |
| v1.2 | 2026-08-12 | **阶段一（P0）实施完成记录**：① T1 冻结（precheck 脚本 + 静态基线文档 + verify-t1-precheck.js 8/8 入链；存量库实测回填留待 T8）；② 055 迁移交付（结构 §1-§10，verify-055.js 84 断言两遍幂等全绿，已入验证链）；③ 实施细化两项——非 button 行 api_code 强制 NULL（Admin.NET CheckMenuParam 语义扩展，D8 镜像）、D8 约束前置清理存量 button 导航字段（§2.5，否则 CHECK 创建失败）；④ **全链重放约束 → 4 个源文件提前至 P0 同批**（casbin_rule / v_system_stats / rpc_get_role_permissions / grant_all——055 删表后 src/api_v1 阶段残留 iam_api 引用会 42P01，v1.1 中标注 P1 的这几项实际必须随 055 同批提交）；⑤ 验收标准 7 提前达成（npm run test 全链绿，断言数 152+84） |
| v1.3 | 2026-08-12 | **阶段二（P1）实施完成记录**：① T4 五源文件联动（iam_menu 视图/v_role_menu_detail/get_menu_tree_admin/get_user_menu/rpc_import_csv）；② **审查遗漏 2 处当场发现修复**——v_role_list.sql（api_count 引用 iam_role_api）、rls_policies.sql（iam_api/iam_role_api RLS 段），均为 src/api_v1 阶段重放 42P01 炸弹；③ T5 trg_audit_role_api.sql → .deprecated；④ T6 pgTAP 同步更新（01_schema_test plan 62 / 05_rls_test plan 12 到 055 语义）+ verify-t4-src.js（11 断言）入链；⑤ T7 全链 253 断言全绿；⑥ T8 本机部分完成（grep 全仓干净），WSL apply-src 两遍演练待用户环境 |
| v1.4 | 2026-08-12 | **阶段三（P2）前端实施完成记录**：① T9/T10 代码交付（OmniAdmin 仓库，pnpm build 全绿——vue-tsc 类型检查 + vite 构建）；② **审查清单外发现**：usePermission.ts 通道1 依赖 v_role_api_detail（055 已删）→ 改 v_role_menu_detail + RoleMenuPerm 类型，否则前端按钮权限全哑；③ 接口管理页整体删除（视图/RPC/页面/路由/i18n 四层联动）；④ 前端 commit 被 commitlint body-max-line-length 拦截，短 body 重提待执行；⑤ T11 进行中（05/15 文档标注待办） |

---

## 附：借鉴来源链接

| 来源 | 链接 | 用途 |
|---|---|---|
| SharpFort Menu.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Menu.cs | 单表模型主参考（ApiUrl/ApiMethod/PermissionCode） |
| SharpFort MenuType.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain.Shared/Enums/MenuType.cs | 四值枚举（Button=3）确认 |
| SharpFort Role.cs / RoleMenu.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain/Entities/Role.cs | 授权单表（RoleMenu）确认 |
| SharpFort CasbinPolicyManager.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Domain/Managers/CasbinPolicyManager.cs | 策略构建（ApiUrl 非空才生成规则；ApiMethod 空默认 '*'） |
| SharpFort MenuService.cs | https://github.com/SharpFort/SharpFort.Net/blob/main/module/casbin-rbac/SharpFort.CasbinRbac.Application/Services/System/MenuService.cs | ValidateApiUrl 端点格式校验；ApiMethod 默认 GET |
| Yi.Abp MenuAggregateRoot.cs | https://gitee.com/ccnetcore/Yi/blob/main/Yi.Abp.Net8/module/rbac/Yi.Framework.Rbac.Domain/Entities/MenuAggregateRoot.cs | 对比（无端点列，不采纳） |
| Admin.NET SysMenu.cs | https://gitee.com/zuohuaijun/Admin.NET/blob/v2/Admin.NET/Admin.NET.Core/Entity/SysMenu.cs | 对比（IsAffix 借鉴，OutLink 不采纳） |
| Admin.NET SysMenuService.cs | https://gitee.com/zuohuaijun/Admin.NET/blob/v2/Admin.NET/Admin.NET.Core/Service/Menu/SysMenuService.cs | CheckMenuParam（按钮行导航字段强制清空 → 本项目 D8 CHECK 依据） |
