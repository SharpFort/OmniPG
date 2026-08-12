# 16-审查-菜单权限单表化（SharpFort 模型）决策与实施清单

> **审查日期：** 2026-08-12
> **审查对象：** `docs/开发实施方案/16-菜单权限单表化-SharpFort模型-决策与实施清单.md`（v1.0）
> **审查方式：** 主代理直接执行（B 方案）；本地仓库逐文件核查（迁移 009/022/023/024/028/031/032/033/038/039/040/041/042/043/044/045/046/052/053 + src 层 + api_v1 层 + 验证链 11 脚本 + 测试）；互联网源码核实（SharpFort.Net / Yi.Abp / Admin.NET 最新 main/v2 分支 raw 抓取，2026-08-12）
> **审查结论：** 决策方向（D1-D7）与核心事实全部成立 ✅；发现 **P0 问题 3 项**（删除对象清单遗漏 4 组 DB 对象、casbin_rule 菜单段语义遗漏、T1 数据迁移策略 3 个未覆盖数据前提）、**P1 问题 7 项**、**P2 问题 5 项**；任务清单 T1-T11 可细化（给出细化版）。

---

## 1. 决策正确性总评（先给结论）

| 决策 | 结论 | 依据 |
|---|---|---|
| D1 单表化删 iam_api | ✅ 成立 | SharpFort `casbin_sys_menu` 单表（Entities 目录无任何 API 实体）；Yi/Admin.NET 端点信息确实不在数据层 |
| D2 删 iam_role_api 授权单表 | ✅ 成立 | SharpFort `casbin_sys_role_menu`（RoleMenu.cs 联合唯一索引）+ Role.Menus 导航 |
| D3 has_permission 单通道 | ✅ 成立 | 现状双通道（040/044）已核实；单通道后 role_menu→menu.api_code 语义自洽 |
| D4 一码多端点=多行同码 | ✅ 成立（有前提） | SharpFort PermissionCode **普通索引**（SugarIndex 非 IsUnique）已核实；⚠️ 现状 iam_api.api_code 是**部分唯一索引**（023），迁移前数据一码一行——D4 是 055 后的新能力 |
| D5 is_affix | ✅ 成立 | Admin.NET v2 SysMenu.cs `IsAffix`（是否固定）已核实 |
| D6 成对约束+部分唯一索引 | ✅ 成立（需补语义） | ⚠️ 原 iam_api.method **允许 '*'**（009 默认值）且 SharpFort 策略构建也默认 '*'——api_method 的 '*' 兼容语义文档未写明 |
| D7 不引用 RuoYi | ✅ 已执行 | 本文档全文无 RuoYi 论证引用（仅 038/022 历史迁移头部注释存在，不影响本文档） |

**一句话：** 文档的架构结论经源码与仓库双重核实全部成立，主要问题集中在**删除对象清单不完整**（4 组依赖对象漏列，其中视图源文件遗漏会导致 apply-src 全量重放失败）与 **T1 数据迁移策略未覆盖 3 个真实数据前提**（14 行 api_code NULL、method='*'、死端点行转换）。

---

## 2. 🔴 P0 问题（影响实施正确性，须在 055 实施前解决）

### P0-1 删除对象清单（§5.3/§6）遗漏 4 组依赖对象

文档 §5.3 删除清单与 §6 影响面均**未覆盖以下对象**（本地逐文件核查确认全部存在）：

| # | 遗漏对象 | 位置 | 证据 | 建议 |
|---|---|---|---|---|
| ① | `rpc_set_role_apis(p_role_code, p_api_codes text[])` | 024 迁移 §（api_v1_sys → 027 后 api_v1_public） | 024 L577-601，门槛 sys:role-api:bind，**全量覆盖绑定 iam_role_api** | 删除（.deprecated）+ DROP FUNCTION；权限点 sys:role-api:bind 一并清理 |
| ② | `rpc_grant_menu_subtree_apis` / `rpc_revoke_menu_subtree_apis` | 041 迁移 | 041 L：递归子树授权/撤销 iam_role_api，门槛复用 sys:role-api:bind | 删除（单表化后语义被"菜单树勾选"取代，无改造价值）；权限点随 ① 清理 |
| ③ | `rpc_create_menu_with_api` | 045_rpc_create_menu_with_api.sql | 合并创建菜单+接口（事务内写 iam_menu+iam_api） | 删除（055 后无 iam_api 可写；合并语义并入 rpc_create_menu 新签名） |
| ④ | 暴露视图 `api_v1_public.iam_api`、`api_v1_public.iam_role_api`、`api_v1_public.v_role_api_detail` | api_v1/public/views/{iam_api,iam_role_api,v_role_api_detail}.sql | 三文件均存在；grant_all.sql L12/L15/L28 有 GRANT | **git rm 源文件 + 055 迁移 DROP VIEW IF EXISTS**（见 P0-2） |

> 连带：043 的权限点 `sys:api:create / sys:api:update / sys:api:delete`（043 seed，仅绑 role_super_admin）须随 043 RPC 删除一并清理——035 确立的惯例是"废弃 RPC 删除时同时删权限点及 iam_role_api 绑定"。

### P0-2 🔴 视图源文件不删 = apply-src 全量重放必炸（顺序链）

**这是本审查最重要的发现，直接影响 T2 迁移编写。**

apply-src 重放顺序为 **src → api_v1 → init → migrations**（038 迁移头部注释确认）。055 在 migrations 层 `DROP TABLE iam_api`，但：

- `api_v1/public/views/iam_api.sql`、`iam_role_api.sql`、`v_role_api_detail.sql` 三个源文件若不同步删除，**下次全量重放时 api_v1 阶段会先于 055 重建视图（FROM public.iam_api / iam_role_api）→ 表不存在 → 重放中断**；
- 同理 `db/src/public/views/casbin_rule.sql`（引用 iam_role_api）与 `db/api_v1/public/rpc/rpc_get_role_permissions.sql`（引用 iam_role_api + iam_api）**必须同步改造**（文档 §6 已列 ✅，但建议在 T4/T5 中明确"源文件与迁移同批提交"）；
- `db/src/public/triggers/trg_audit_role_api.sql`（CREATE TRIGGER ON iam_role_api）同样必须 .deprecated（文档已列 ✅）。

**建议**：055 实施时把"源文件 git rm / 改造"与迁移文件**同一提交**完成，并在验收标准中新增："grep 全仓无 `FROM public.iam_api` / `FROM iam_role_api` / `CREATE TRIGGER ... ON iam_role_api` 残留（.deprecated 文件除外）"。

### P0-3 T1 数据迁移策略未覆盖 3 个真实数据前提

文档 T1 只描述了"同码 button 行回填 / 无 button 新建行 / role_api 转 role_menu"三条，但本地核查发现现状数据存在 3 个未覆盖前提：

| # | 数据前提 | 证据 | 风险 | 建议 |
|---|---|---|---|---|
| ① | **约 14 行 iam_api.api_code IS NULL** | 043 迁移头注："既有 14 行 api_code IS NULL 现状兼容"（043 D5 允许创建无码行） | 单表化后 menu button 行被 040 CHECK 强制 api_code 非空——**无码端点无处安放**：并入 button 行违反 CHECK，新建 button 行也违反 | T1 增加前置步骤：**无码行清单梳理 + 赋码策略**（按 path/menu 归属推导 sys:xxx:list 类码，或按业务拍板；赋码在 055 迁移内完成，赋码前先确认与 iam_menu 已有码无冲突） |
| ② | **iam_api.method 允许 '*'（009 DEFAULT '*'）** | 009 L133 `method varchar(20) NOT NULL DEFAULT '*'`；SharpFort CasbinPolicyManager 同样"ApiMethod 空→*" | 数据迁移后 menu 行会出现 api_method='*'；D6 成对 CHECK 不冲突（'*' 非空）但文档未说明该语义 | 文档 §5.2 明确："api_method 保留 '*' 通配语义（兼容 009 存量）；CHECK 只做 api_url↔api_method 成对约束，不做值域枚举（或值域约束含 '*'）" |
| ③ | **039 D3 死端点行保留未删**（/sys_api、/sys_menu、/sys_role、/sys_user 等 PostgREST 已无的端点，role_api 绑定可能引用） | 039 迁移头注 D3："历史死端点保留不删（55 条 role_api 绑定中可能引用）" | T1 未明确死端点行如何转换：它们也有 role_api 绑定，转换后绑定到新建 button 行（挂 ApiList/API管理 目录下） | T1 明确："死端点行同样按 menu_id 归属新建 button 行（无归属则挂 'API管理' 目录），转换绑定；055 后可另行拍板是否清理" |

> 另注：P0-3① 的赋码决策涉及业务口径（无码端点是否该有权限码），建议作为 055 实施前的独立拍板点（T1 冻结时与用户确认）。

---

## 3. 🟡 P1 问题（重要补充/细化，建议纳入实施）

### P1-1 casbin_rule 视图"双段"语义遗漏

现状 casbin_rule（044 版，src 与迁移一致）是**双段**：API 段（role_api→path/method）+ **菜单段（role_menu→router/'menu'）**。文档 §5.3 只写了"API 段数据源改为 menu"，§8 验收 6 只写"role_code → api_url/method 映射"——**菜单段未提及，易被理解为删除**。055 后 iam_role_menu 仍在，菜单段应**原样保留**。

**建议**：§5.3 与验收 6 明确："casbin_rule = role_menu→button 行（api_url 非空，v1=api_url/v2=api_method）∪ role_menu→菜单行（v1=router/v2='menu'，原样保留）"。

### P1-2 T2 迁移内 DROP 顺序需显式化

删表顺序有 FK 依赖：`iam_role_api.api_id REFERENCES iam_api ON DELETE CASCADE`（009），直接 `DROP TABLE iam_api` 会因 iam_role_api 引用报错（PG 默认 RESTRICT）——文档 T2 写"删 iam_api/iam_role_api"但**顺序未明确**。

**建议** T2 顺序显式化：① DROP 依赖视图/函数（P0-1 清单 + has_permission + casbin_rule + get_role_permissions）→ ② DROP TABLE iam_role_api → ③ DROP TABLE iam_api（或 `DROP TABLE iam_api CASCADE` 并显式列出连带对象防误伤）→ ④ 权限点/GRANT 清理。同时注意 iam_api 上 023 挂的审计触发器（trg_audit_iam_api）随表自动删除，无需单列。

### P1-3 授权弹窗/管理树数据源缺口（T10 落地依据缺失）

现状 `get_menu_tree_admin()`（044 版，api_v1 层）只输出 `id/parent_id/name/path/icon/sort_order/is_active/level`——**无 menu_type/api_code/端点列**。文档 T10"授权弹窗 = 菜单树勾选（按钮叶子展示权限码 + 端点信息）"需要数据源，文档 §6 未列 `get_menu_tree_admin`。

**建议**：§6 影响面增加 `db/api_v1/public/rpc/rpc_get_menu_tree_admin.sql`（函数名 get_menu_tree_admin）：+menu_type/api_code/api_url/api_method/is_affix（管理树与授权弹窗共用）；或 T10 明确授权弹窗数据源改用 `GET /iam_menu` 视图全列 + 前端组树。

### P1-4 v_role_menu_detail 视图联动遗漏

`api_v1_public.v_role_menu_detail`（044 版）在 055 后保留（role_menu 未删），但授权弹窗"角色菜单下挂接口"展示需要它输出 api_url/api_method/is_affix——文档 §6 未列该视图。

**建议**：§6 增加"`db/api_v1/public/views/v_role_menu_detail.sql`：+api_url/api_method/is_affix（角色授权明细展示）"。

### P1-5 verify-n4-d3.js 的处置需要重新评估（可能无需重写）

文档 T6 说"verify-n4-d3.js 重写为 menu 口径"。但本地核查 verify-n4-d3.js 验证的是 **028/040/044/045 历史迁移链**（N4 镜像写授权 + D3 死权限点清理）——这些迁移在 apply-src 顺序上**先于 055 执行**，其桩环境（iam_api 表、040 回填断言、045 清理断言）在 055 时代依然成立（045 清理的 iam_api 死行在 055 删表前执行）。

**建议**：verify-n4-d3.js **保持原样**（历史链回归）；新增 verify-055.js 覆盖 055 本体（见 T6 细化）。若追求"055 后环境不再出现 iam_api"的强语义，可加一个 055 后置断言（information_schema 无 iam_api），但放 verify-055.js 而非重写 n4-d3。

### P1-6 get_role_permissions 源文件状态已查明（更正文档描述）

文档 §6 写"`rpc_get_role_permissions.sql`（044 重建于迁移，源文件待查）"——**已查明**：源文件存在于 `db/api_v1/public/rpc/rpc_get_role_permissions.sql`（函数名 `get_role_permissions`，无 rpc_ 前缀；文件头注释残留旧路径 `db/api_v1/sys/rpc/`），与 044 迁移定义一致（044 先 DROP 再 CREATE，源文件为同款）。055 改造时两处同步（迁移重建 + 源文件），并顺手修正文件头旧路径注释。

### P1-7 迁移编号 054 空缺说明

当前迁移目录最新为 053；15 号文档（迁移治理）规划"发布前 squash 后 054+ 继续编号"。本文档直接用 055，**054 编号空闲**。建议文档补一句编号说明（如"054 预留迁移治理 baseline，055 为下一下推迁移"），避免后续迁移误用 054 造成编号冲突。

---

## 4. 🟢 P2 问题（表述/文档质量/可选增强）

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| P2-1 | §2.1 表格 038 行 | "**D2 拍板** menu/api 分离式"——038 的历史决策编号 D2 与本文档 D2（删 iam_role_api）**撞号**，跨文档引用易混淆 | 改为"038 决策 D2"或"038 §决策D2 拍板分离式" |
| P2-2 | §3.1 | 引用了 MenuSource.cs 但未解释：`MenuSource`（Ruoyi=0/Pure=1）是"兼容两种前端框架路由生成逻辑"的字段，与本项目无关 | 加一句"MenuSource 为 SharpFort 双前端兼容字段，本项目不引入" |
| P2-3 | §3.3 | "端点信息在控制器特性（[ApiPermission]）代码层"——Admin.NET **v2 分支实测 SysUserService 无 [ApiPermission] 特性**（v1 时代特征；v2 服务方法仅 [DisplayName] + IDynamicApiController 动态 API） | 表述精确化："端点 URL/Method 信息不存在于 sys_menu 数据层（按钮行仅 Permission 权限码；端点由动态 API 方法签名确定，权限判定在服务层）"——结论不变（无端点列） |
| P2-4 | §5.2 一码多端点示例 | "sys:user:list 挂 GET /sys_user + GET /rpc/search_users 两行"——现状数据 sys:user:list 仅 1 行（040 回填 GET /sys_user），示例是 055 后能力 | 标注"示例为 055 后能力（现状一码一行，见 idx_iam_api_code 唯一索引）" |
| P2-5 | §8 验收 4 | "(api_url, api_method) 全局唯一"——部分唯一索引只约束 api_url 非空行，表述可精确为"api_url 非空行 (api_url, api_method) 唯一"（与 D6 一致，现状写法易歧义） | 同步措辞 |

---

## 5. 互联网源码核实结果（2026-08-12 抓取，全部 raw 直拉 + diff 与决策时点缓存比对一致）

### 5.1 SharpFort.Net（GitHub main 分支，无漂移）

| 文件 | 核实结果 | 与文档一致性 |
|---|---|---|
| `Entities/Menu.cs` | `[SugarTable("casbin_sys_menu")]`；PermissionCode(128, 可空) + **普通索引**（注释"加速权限验证查询"）；ApiUrl(255, 注释"用于 Casbin 鉴权，如 /api/system/user")；ApiMethod(10, "如 GET, POST, PUT, DELETE")；Router/RouterName/IsLink/IsCache/IsShow/Remark(500)/MenuSource；**无独立 API 表** | ✅ 全部吻合 |
| `Entities/Role.cs` | `casbin_sys_role`；RoleCode 唯一索引；`[Navigate(typeof(RoleMenu))] List<Menu>? Menus`（授权单表） | ✅ 吻合 |
| `Entities/RoleMenu.cs` | `casbin_sys_role_menu`；**联合唯一索引 (RoleId, MenuId)** | ✅ 吻合 |
| `Enums/MenuType.cs` | **Catalogue=0 / Menu=1 / Component=2（组件-特殊）/ Button=3（按钮/权限点）** | ✅ 吻合（四值） |
| `Enums/MenuSource.cs` | Ruoyi=0 / Pure=1（双前端路由生成兼容） | ⚠️ 文档引用未解释（P2-2） |
| `Managers/CasbinPolicyManager.cs` | **策略构建：ApiUrl 为空行直接跳过（continue）；ApiMethod 空 → '*'**（`string.IsNullOrWhiteSpace(menu.ApiMethod) ? "*" : ...`） | 🔍 **新增事实**：印证 P0-3②（method='*' 语义是 SharpFort 官方行为） |
| `Services/System/MenuService.cs` | **ValidateApiUrl**：ApiUrl 必须 /api/ 开头、全小写、无 {param}（Casbin keyMatch2 约束）；CreateInternalAsync：**ApiUrl 非空且 ApiMethod 空 → 默认 GET**；新建菜单自动关联超管 RoleMenu（associateAdminRole） | 🔍 **新增事实**：端点格式校验/成对默认值可借鉴（P2 建议：本项目 RPC 层可加"api_url 以 / 开头、不含 {}"校验；超管关联不需要——本项目超管短路） |
| 路由构建（Menu.cs 扩展） | `Vue3RuoSfRouterBuild` / `Vue3PureRouterBuild` 显式过滤的是 `MenuType.Component`（非 Button）；**Button 行靠 Router 为空 + 前端 auths（PermissionCode）自然不生成路由** | ⚠️ 文档 D4"button 行不生成前端路由（借鉴 SharpFort）"方向正确但机制表述需精确（见 P2-6 补充） |

### 5.2 Yi.Abp（gitee main 分支）

| 文件 | 核实结果 | 与文档一致性 |
|---|---|---|
| `MenuAggregateRoot.cs` | `[SugarTable("Menu")]`；PermissionCode(可空)、Router/RouterName/IsLink/IsCache/IsShow/Remark；**无任何 ApiUrl/ApiMethod 端点列** | ✅ 吻合（无端点列） |
| `MenuTypeEnum.cs` | **Catalogue=0 / Menu=1 / Component=2（三值，无按钮）** | ✅ 吻合（三值无按钮） |

### 5.3 Admin.NET（gitee v2 分支）

| 文件 | 核实结果 | 与文档一致性 |
|---|---|---|
| `Entity/SysMenu.cs` | **IsAffix（是否固定）✅ 存在**；OutLink（外链，256）✅ 存在；Permission(128)；IsIframe/IsHide/IsKeepAlive/Redirect/OrderNo/Status | ✅ 吻合（D5 依据成立） |
| `Enum/MenuTypeEnum.cs` | **Dir=1 / Menu=2 / Btn=3（三值含按钮）** | ✅ 吻合（有 Button） |
| `Service/Menu/SysMenuService.cs` | **CheckMenuParam（新增事实，P1-8 建议）**：Btn 行**服务端强制清空** Name/Path/Component/Icon/Redirect/OutLink/IsHide/IsKeepAlive/IsAffix/IsIframe；Permission 必填且**必须含 ':'**；非 Btn 行 Permission 强制置 NULL | 🔍 **新增事实**：Admin.NET 用"写入时强制清空导航字段"保证按钮行不污染 UI——零后端项目应升级为**表级 CHECK**（见 P1-8） |
| 端点信息 | v2 服务方法仅 [DisplayName] + IDynamicApiController（动态 API）；未见 [ApiPermission] 特性（v1 特征） | ⚠️ 文档 §3.3 表述需精确（P2-3）；"端点信息不在数据层"结论不变 |

### 5.4 补充建议（源码新发现，P1-8）

**借鉴 Admin.NET CheckMenuParam 的表级约束**：新增 CHECK `menu_type <> 'button' OR (router IS NULL AND component IS NULL)`——"按钮行不生成前端路由"的**数据层保证**（SharpFort 靠约定 + 路由构建过滤，Admin.NET 靠服务端强制；零后端项目无服务端，CHECK 是最佳落点）。文档 §5.1 约束清单只有 3 个现状 CHECK + 成对 CHECK + 部分唯一索引，未含此约束。

---

## 6. 任务清单细化建议（T1-T11 增强版）

### 阶段一：迁移核心（P0）

- [ ] **T1. 数据迁移策略冻结（补 3 个前置核查）**
  - 前置核查 A：`SELECT count(*) FROM iam_api WHERE api_code IS NULL`（预期 ≈14 行）→ **无码行赋码策略拍板**（P0-3①，需用户确认）
  - 前置核查 B：每 button 行挂接 api 行数核查（`SELECT m.id, count(a.id) FROM iam_menu m LEFT JOIN iam_api a ON a.menu_id=m.id WHERE m.menu_type='button' GROUP BY m.id HAVING count(a.id) > 1`）——>1 的冲突清单（044 仅 3 个用户按钮 1:1，其余 button 无挂接先例）
  - 前置核查 C：`SELECT count(*) FROM iam_api WHERE menu_id IS NULL`（孤儿行，039 之后理论上 0，确认兜底）
  - 转换规则（文档已有）：同码 button 行回填 / 无 button 按 menu_id 新建（menu_name=api.name、描述→remark）/ **死端点行同样转换**（P0-3③）/ role_api 绑定 → 对应 button 行补绑 iam_role_menu（按行映射，一码多行时逐行对应不合并）
- [ ] **T2. 055 迁移编写（顺序显式化）**：DROP 依赖视图/函数（P0-1 全部 + has_permission + casbin_rule + get_role_permissions）→ iam_menu +3 列（幂等）→ 新约束/索引（成对 CHECK + 部分唯一索引 + **button 导航置空 CHECK（P1-8）** + api_code 非唯一索引）→ 数据迁移（T1 规则 + 无码行赋码）→ DROP TABLE iam_role_api → DROP TABLE iam_api → 重建 has_permission（单通道）/casbin_rule（双段）/get_role_permissions → 权限点清理（sys:api:create/update/delete + sys:role-api:bind + iam_role_api 绑定）→ grant_all 同步 → 验证 DO 块（含删表断言 + 迁移完整性断言）
- [ ] **T3. rpc_create_menu / rpc_update_menu 重建**：+p_api_url/p_api_method/p_is_affix；button 行强制 router/component 置空（RPC 校验 + 表级 CHECK 兜底）；api_url↔api_method 成对校验（RPC 友好报错 22023 + CHECK）；DROP 旧签名防 PGRST203；**删除 rpc_create_menu_with_api（045）并确认前端无调用**

### 阶段二：联动改造（P1）

- [ ] **T4. 视图与 RPC 联动（补 4 项）**：文档 §6 清单 + `iam_api.sql / iam_role_api.sql / v_role_api_detail.sql` **git rm**（P0-2）+ `v_role_menu_detail` +api_url/api_method/is_affix（P1-4）+ `get_menu_tree_admin` +menu_type/api_code/api_url/api_method/is_affix（P1-3）+ 源文件与迁移同批提交（P0-2）
- [ ] **T5. 清理类删除（补 3 组）**：文档 §6 清单 + `rpc_set_role_apis`（024）+ `rpc_grant_menu_subtree_apis / rpc_revoke_menu_subtree_apis`（041）+ `rpc_create_menu_with_api`（045）置 .deprecated；权限点 sys:api:create/update/delete、sys:role-api:bind 清理（含 iam_role_api 绑定行）
- [ ] **T6. 验证链（修正处置）**：**verify-n4-d3.js 保持原样**（历史链 028/040/044/045 回归，P1-5）；**verify-055.js 新建**，断言覆盖：① 加列/约束/索引存在性（含 button 导航置空 CHECK）② 数据迁移完整性（端点行一一对应：`EXCEPT` 差集 = 0；无码行赋码结果）③ role_api→role_menu 绑定转换（逐角色抽查，授权不缩水）④ has_permission 单通道行为（超管短路/role_menu 绑定/未绑拒绝/一码多行 EXISTS 语义）⑤ casbin_rule 双段语义（API 段 menu 口径 + 菜单段保留）⑥ information_schema 无 iam_api/iam_role_api ⑦ 幂等重放两遍；`test_casbin_view.sql` 更新（第 5 条断言 JOIN iam_api → JOIN iam_menu）
- [ ] **T7. 全链验证**：`npm run test` 全绿（断言数 ≥ 152 + verify-055 新增数）
- [ ] **T8. 存量库演练**：WSL Pigsty 执行 apply-src 全量重放两遍（第一遍验证 040/044/045 历史链 + 055 迁移，第二遍验证幂等）；grep 全仓确认无 iam_api/iam_role_api 残留引用（P0-2 验收）

### 阶段三：前端与收尾（P2）

- [ ] **T9. 前端菜单管理**：表单 +api_url/api_method/is_affix；**menu_type=button 时导航字段禁用/清空**（对齐 P1-8 服务端语义）；接口管理页并入菜单管理（删除独立 API 管理页）；MenuAdminNode 接口 +3 字段（前端方案 §2.2 286 行）
- [ ] **T10. 授权弹窗**：菜单树勾选（数据源 = 扩展后 get_menu_tree_admin 或 GET /iam_menu 视图）；按钮叶子展示 api_code + api_url/api_method；复用 rpc_set_role_menus 全量覆盖保存；**父子联动复用前端既有组树两遍构建逻辑**（frontend-alignment-decisions）
- [ ] **T11. 文档同步**：本文档修订记录追加 v1.1（含本审查 P0/P1 采纳项）；05-Logto认证与权限架构 关联段落标注变更；**15 号文档 M4 验证链重构条目同步**（055 后验证链文件清单变化）

---

## 7. 验收标准完善建议（§8 增补）

在现有 8 条基础上建议增补/修正：

| # | 建议 |
|---|---|
| 2' | 修正："原 iam_api 全部端点行 → iam_menu button 行一一对应（api_url+api_method 精确匹配，含 method='*' 行；api_code NULL 行按拍板赋码后对应）" |
| 4' | 修正："api_url 非空行 api_method 必填且 (api_url, api_method) 部分唯一（WHERE api_url IS NOT NULL）" |
| 6' | 修正："casbin_rule 双段语义等价：API 段 = role_menu→button 行（api_url/api_method），菜单段 = role_menu→菜单行（router/'menu'）原样保留，两段均无缺失行" |
| 9（新增） | 全仓 grep 无 `FROM public.iam_api` / `FROM iam_role_api` / `ON iam_role_api` 残留（.deprecated 除外）——视图/触发器/函数源文件同步完成 |
| 10（新增） | 权限点 sys:api:create/update/delete、sys:role-api:bind 及其 iam_role_api 绑定行已清理（has_permission 引用核对无悬空） |
| 11（新增） | button 行 router/component 置空 CHECK 生效（若采纳 P1-8） |

---

## 8. 审查结论

1. **决策层（D1-D7）**：全部成立，无推翻项。SharpFort 单表模型是三方对比中唯一"权限码+端点信息全在数据层"的方案，与零后端架构适配的结论**经源码再次确认**。
2. **文档完整性**：删除对象清单与影响面表存在 4 组遗漏（P0-1），其中**视图源文件不同步删除将导致 apply-src 全量重放失败**（P0-2）——这是实施前必须补上的。
3. **数据迁移策略**：T1 需补充 3 个前置核查与处置规则（无码行赋码、method='*'、死端点行转换）（P0-3），其中无码行赋码需要用户拍板。
4. **新增借鉴点**：Admin.NET CheckMenuParam 的"按钮行导航字段置空"应升级为表级 CHECK（P1-8）；SharpFort ValidateApiUrl/ApiMethod 默认值可作 RPC 层参考（P2）。
5. **任务清单**：按 §6 细化版执行即可；verify-n4-d3.js 建议保持原样（P1-5）。

---

## 附：核实证据路径

| 项目 | 路径 |
|---|---|
| 本地迁移 | `D:\WeChat Files\OmniPG\db\migrations\public\`（009/022/023/024/028/031/032/033/038/039/040/041/042/043/044/045/046/052/053） |
| src/api_v1 层 | `db/src/public/`（casbin_rule/get_user_menu/trg_audit_role_api）、`db/api_v1/public/`（views/iam_api|iam_role_api|v_role_api_detail|v_role_menu_detail|v_system_stats、rpc/get_role_permissions|import_csv、privileges/grant_all） |
| 验证链 | `C:\Users\财务\.hermes_tmp\pglite-verify\`（package.json 11 脚本；verify-n4-d3.js 全文核查） |
| 测试 | `db/tests/public/test_casbin_view.sql`（8 断言，第 5 条 JOIN iam_api 需改） |
| SharpFort 源码 | GitHub main：Entities/{Menu,Role,RoleMenu}.cs、Domain.Shared/Enums/{MenuType,MenuSource}.cs、Domain/Managers/CasbinPolicyManager.cs、Application/Services/System/{MenuService,RoleService,UserService}.cs（raw 直拉 2026-08-12，diff 与决策缓存一致） |
| Yi.Abp 源码 | gitee main：MenuAggregateRoot.cs、MenuTypeEnum.cs |
| Admin.NET 源码 | gitee v2：Entity/SysMenu.cs、Enum/MenuTypeEnum.cs、Service/Menu/SysMenuService.cs（CheckMenuParam）、Service/User/{SysUserService,SysUserMenuService,UserManager}.cs |
