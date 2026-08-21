# 44 "移除 public 即可"可行性核查：逐处语义分析与副作用

> **状态**：✅ 核查完成（2026-08-21）。基于 logto v1.42.0 源码逐文件核实
> **回答的核心问题**：解决"Logto 装进非 public schema"，是否"仅仅移除那几个文件里的 public 即可"？有无副作用？新用户/升级是否无影响？
> **一句话结论**：**不能简单说"移除即可"。** 那几处 public 分两类：一类"移除后确实等价于官方正确改法、副作用极小"，另一类"移除会破坏安全模型或引入新的不一致（有实质副作用）"，还有一类"只改源码对已经存在的存量库无效（需要额外做迁移）"。更关键的是：**官方历史上是刻意把这些地方从"不带 schema"加固成"显式 public"的**（见 §3 的 1.9.0 alteration 原文），"移除 public"等于把官方已修复的东西退回去，不是无副作用。

---

## 1. 逐处拆分：这 6 处 public 不是一回事

| # | 文件 | 硬编码内容 | 类别 | "移除 public"的后果 |
|---|---|---|---|---|
| A | _after_all.sql L6 | grant ... on all tables in schema public to logto_tenant_${database} | 安全授权 | 直接删 → 租户角色失去所有表 DML，运行时 42501。应"参数化"而非"删除"；且 in schema public 是显式 schema 限定，与 search_path 无关，必须改成变量 |
| B | roles.sql L25 | create function **public**.check_role_type(...) | DDL 显式 schema 限定 | 删掉 public. → 函数建到"当前 search_path 第一个 schema"。官方第 1.9.0 alteration 特意反向加固成 public，说明这是有意的 |
| C | roles.sql L27 | 函数体 select type from **public**.roles | 函数体显式限定 | 与 B 配合；删掉后按调用者 search_path 解析，可能被同名对象劫持 |
| D | applications.sql L49 | set search_path = public | 函数 search_path 固定 | 这（含 organization_roles）是 PR #6101 故意加的（cloud 多 schema 确定性）；删掉后继承调用环境 search_path，可能解析错 schema |
| E | 三张表 CHECK | check (public.check_role_type(role_id, ...)) | 约束 deparse 绑定 | 这些 public. 是建表时 PG 自动 deparse（因源函数是 public），改 B/C 会自动跟随；但仍要确保与 B/C 一致 |
| F | models/tenants.ts | createModel(..., 'public') | 代码层 model schema 声明 | 删/改这个 'public' 只影响新库 seed；存量库要另跑 ALTER TABLE tenants SET SCHEMA |

---

## 2. 直接回答四个问题

### 2.1 "是不是仅仅移除那几个文件里的 public 即可？"

**不是。** 因为：
- **A（_after_all 的 grant）不能"移除"，只能"参数化"**——移除会让租户角色失去表权限，Logto 直接起不来；
- **D（set search_path = public）移除后行为变回"继承 search_path"**，单 schema 能跑、但失去 PR #6101 想要的确定性，属"能删但违背官方意图"；
- **B/C 移除后虽功能上等价于"跟随 search_path"，但官方在 1.9.0 专门反向加固过**（§3），说明这个等价在 cloud 多 schema 语境会失效。

**正确改法是"参数化"而非"移除"**：引入 schema 变量（env/config），让 A/B/C/D/F 都引用它，默认仍是 public（保证向后兼容），用户配了自定义 schema 才生效。这才是无副作用的 feature 形态。

### 2.2 "这样是否会引发其他问题？"

**会。** 具体副作用：
1. **A 直接删 = 权限崩塌**：_after_all 是全表授权，删掉后 seed 通过但运行时 permission denied for table users；
2. **B/C 删 = 安全语义回退**：函数从"确定性解析 public"变成"跟随 search_path"，同名对象可被劫持（1.9.0 注释原文说明）；
3. **D 删 = 失去 cloud 确定性**：PR #6101 的动机就是"cloud 多 schema 下 search_path 会错"，删掉后在自定义 schema 部署反而可能踩到它当初要修的坑；
4. **F 只改源码 = 存量库不生效**：createModel 声明只影响新 seed，已存在的 tenants 表不会自动 SET SCHEMA；
5. **E 必须同步**：CHECK 里的 public.check_role_type 是 deparse 出来的，B/C 改了但 E 没对应，会出现"新库 CHECK 指向旧函数/schema"的不一致。

### 2.3 "新用户更新也不会影响表结构？"

**不完全对。** 要区分：
- **新库（seed）**：改源码 + 配好自定义 schema 后，新用户 seed 出的表**全部落在自定义 schema**，结构不变、只是所在 schema 变了——这部分"不影响结构"成立；
- **存量库（升级）**：Logto 升级走 db alteration deploy，它**只跑 alterations 目录的增量脚本**，不会重新跑 tables/*.sql 的 create（幂等跳过）。所以**只改 tables/*.sql 源码对存量库升级毫无作用**——必须额外提供一条 alteration 做迁移。

### 2.4 "没有任何副作用，对吗？"

**不对。** 有副作用，但**可被控制到"仅 schema 名变化"这种最小副作用**，前提是：① 按"参数化 + 一条新 alteration"来做，而不是全局删 public；② 新 alteration 的 down 能把 schema 迁回 public（可回滚）；③ 升级路径被官方 e2e 覆盖。

---

## 3. 决定性证据：官方把"不带 schema"反向加固成"显式 public"

v1.42.0 里 packages/schemas/alterations/1.9.0-1694418765-specify-check-role-type-function-to-be-public-schema.ts 的注释原文：

```
This alteration is a fix on check_role_type function, since this function could be called by
cloud (at the time the DB schema is cloud and can not find public functions/tables).
As a result, we need to specify the function to be with public schema.
```

其 up 脚本明确做了：drop 掉不带 schema 的 check_role_type → 重建为 public.check_role_type，且函数体从 select type from roles 改成 select type from public.roles，再重挂 CHECK 约束。

**这说明：历史上这些函数本来就不带 public（等于你设想的"移除 public"的样子），但官方在 1.9.0 把它改回显式 public，原因正是多 schema 下会找不到表。** 所以"移除 public"不是无副作用的简化，而是退回一个官方已经修复的状态。

同理，PR #6101（1.18.0）给两个函数加 set search_path = public，也是同方向加固。

---

## 4. 结论与建议

1. **不能"只删 public"**：A 是授权（删了权限崩塌），B/C/D 是官方刻意加固（删了安全语义回退），F 是 model 声明（只改源码对存量库无效），E 是 deparse 跟随（要同步）。
2. **正确的 feature 形态 = 参数化 + 存量迁移**：引入 schema 变量替换 A/B/C/D/F，默认 public 向后兼容；新增一条带 down 的 alteration 处理存量库；保证 seed/alteration/runtime + 租户角色三层都用同一 schema。
3. **副作用真实存在但可控**：只要按参数化 + alteration 做，副作用收敛到"仅 schema 名变化"；若图省事全局删 public，则会引入权限崩塌 + 安全回退 + 存量库不迁移三类实质副作用。

---

## 5. 证据索引

- v1.42.0：packages/schemas/tables/_after_all.sql（L6）、roles.sql（L25-27）、applications.sql（L49）、organization_roles.sql（L29）、users_roles.sql / applications_roles.sql / application_access_control_user_role_relations.sql（CHECK）、_after_each.sql / _functions.sql / _before_all.sql（无 public 依赖）、packages/schemas/src/models/tenants.ts（L24 'public'）
- alterations：1.9.0-1694418765-specify-check-role-type-function-to-be-public-schema.ts（决定性证据）、1.18.0-1719221205-fix-functions.ts（PR #6101）、1.19.0-1721483240-multiple-app-secrets.ts、1.22.0-1731900596-add-saml-application-type.ts、1.40.0-1779421396-add-application-access-control-schema.ts
- 关联：#3795（feature request）、#8607（运行时 unqualified 读）、PR #6101
