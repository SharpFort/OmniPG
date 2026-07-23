# 02 — 数据库建模：审计字段模板参考（v4 补充文档）

> **定位：** 本文档是 v3 主文档的补充——提供基于 ABP.io Auditing Interfaces 的审计字段模板，作为新建表时的字段参考。
> **设计原则：** 模板仅定义字段清单（不建表），开发新表时按需复制字段组。
> **参考：** [ABP.io - Auditing Interfaces](https://abp.io/docs/latest/framework/architecture/domain-driven-design/entities)

---

## 0. 需求分析

### 0.1 这个需求是否合理？

**结论：合理，但有边界条件。**

| 维度 | 分析 |
|:---|:---|
| ✅ 一致性 | 所有表使用相同的审计字段命名，降低认知成本 |
| ✅ 可追溯 | 每条记录知道"谁创建、谁修改、何时删除" |
| ✅ DDD 对齐 | 与 ABP.io / 领域驱动设计最佳实践一致 |
| ⚠️ 非强制性 | 模板只是注释/片段，不强制约束——实际约束靠 RLS + 触发器 + Code Review |
| ⚠️ 命名差异 | ABP 的 `IsDeleted`（BOOLEAN）与 v3 的 `deleted_at`（TIMESTAMPTZ）需统一 |

### 0.2 关键决策：`deleted_at` vs `IsDeleted`

ABP 的 `ISoftDelete` 使用 `IsDeleted`（BOOLEAN，true/false）表示软删除。  
我们使用 `deleted_at TIMESTAMPTZ`（NULL=未删除，有值=已删除）。

| 方案 | 表达式 | 保留删除时间 | 索引友好 | 兼容 ABP |
|:---|:---|:---|:---|:---|
| `IsDeleted BOOLEAN` | `WHERE is_deleted = false` | ❌ | ✅ | ✅ |
| `deleted_at TIMESTAMPTZ` | `WHERE deleted_at IS NULL` | ✅ | ✅ | ⚠️ 需适配 |

**决策：使用 `deleted_at TIMESTAMPTZ`**（与 v3 一致），原因：
1. 保留删除时间，可审计"何时删除"
2. `deleted_at IS NOT NULL` 语义等价 `IsDeleted = true`
3. 避免布尔字段未来扩展性差（如需要"计划删除"）

### 0.3 `IDataFilter` 说明

ABP 的 `IDataFilter` 是**运行时数据过滤机制**，不是实体字段：

- **作用：** 开启 `ISoftDelete` 过滤后，所有查询自动追加 `WHERE IsDeleted = false`
- **实现：** EF Core 全局过滤器 / PostgREST RLS 策略
- **影响范围：** `ISoftDelete`、`IHasDeletionTime`、`IDeletionAuditedObject`、`IFullAuditedObject`

> **我们的实现：** 通过 RLS 策略和手动 `WHERE deleted_at IS NULL` 实现等效过滤。

---

## 1. ABP 审计接口完整映射表（10 个接口）

| # | C# 接口名 | 继承关系 | 定义的性质（Properties） | PostgreSQL 字段数 | 适用场景 |
|:---:|:---|:---|:---|:---:|:---|
| 1 | `IHasCreationTime` | - | `CreationTime` | **1** | 仅需知道创建时间 |
| 2 | `IMayHaveCreator` | - | `CreatorId` | **1** | 仅需知道创建者 |
| 3 | `ICreationAuditedObject` | 1 + 2 | `CreationTime`, `CreatorId` | **2** | 创建审计 |
| 4 | `IHasModificationTime` | - | `LastModificationTime` | **1** | 仅需知道修改时间 |
| 5 | `IModificationAuditedObject` | 4 | `LastModificationTime`, `LastModifierId` | **2** | 修改审计 |
| 6 | `IAuditedObject` | 3 + 5 | `CreationTime`, `CreatorId`, `LastModificationTime`, `LastModifierId` | **4** | 创建+修改审计 |
| 7 | `ISoftDelete` | - | `IsDeleted` | **1** | 仅软删除 |
| 8 | `IHasDeletionTime` | 7 | `IsDeleted`, `DeletionTime` | **2** | 软删除+时间 |
| 9 | `IDeletionAuditedObject` | 8 | `IsDeleted`, `DeletionTime`, `DeleterId` | **3** | 删除审计 |
| 10 | `IFullAuditedObject` | 6 + 9 | `CreationTime`, `CreatorId`, `LastModificationTime`, `LastModifierId`, `IsDeleted`, `DeletionTime`, `DeleterId` | **7** | 完整审计 ⭐ |

---

## 2. 10 个接口各自的 PostgreSQL 字段定义

> **使用说明：** 建表时按需复制对应模板的字段代码块。

---

### 接口 1：`IHasCreationTime`

**性质：** `CreationTime`  
**PostgreSQL 字段：** `created_at`

```sql
    -- ============================================================
    -- 【模板 1】接口 IHasCreationTime
    -- 性质：CreationTime
    -- 适用：仅需记录创建时间，如日志表、配置表
    -- ============================================================

    -- 审计字段：创建时间（不可变，记录首次创建时间）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 注释：记录创建时间，由数据库自动填充，应用层不可修改
```

---

### 接口 2：`IMayHaveCreator`

**性质：** `CreatorId`  
**PostgreSQL 字段：** `created_by`

```sql
    -- ============================================================
    -- 【模板 2】接口 IMayHaveCreator
    -- 性质：CreatorId
    -- 适用：仅需知道创建者，如自动采集的数据
    -- ============================================================

    -- 审计字段：创建者用户 ID（NULL 表示系统/匿名创建）
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：NULL 表示系统自动创建或匿名创建
```

---

### 接口 3：`ICreationAuditedObject`

**性质：** `CreationTime`, `CreatorId`（继承 1 + 2）  
**PostgreSQL 字段：** `created_at`, `created_by`

```sql
    -- ============================================================
    -- 【模板 3】接口 ICreationAuditedObject
    -- 性质：CreationTime, CreatorId
    -- 适用：需要完整创建审计的实体
    -- ============================================================

    -- 审计字段：创建者 + 创建时间
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：记录创建者和创建时间
```

---

### 接口 4：`IHasModificationTime`

**性质：** `LastModificationTime`  
**PostgreSQL 字段：** `updated_at`

```sql
    -- ============================================================
    -- 【模板 4】接口 IHasModificationTime
    -- 性质：LastModificationTime
    -- 适用：仅需记录最后修改时间，如无需追踪修改者的实体
    -- ============================================================

    -- 审计字段：最后修改时间（触发器自动维护）
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 注释：由 update_updated_at() 触发器自动维护，应用层不可修改
```

---

### 接口 5：`IModificationAuditedObject`

**性质：** `LastModificationTime`, `LastModifierId`（继承 4 + 新增）  
**PostgreSQL 字段：** `updated_at`, `updated_by`

```sql
    -- ============================================================
    -- 【模板 5】接口 IModificationAuditedObject
    -- 性质：LastModificationTime, LastModifierId
    -- 适用：需要完整修改审计的实体（不关心创建信息）
    -- ============================================================

    -- 审计字段：最后修改时间 + 最后修改者
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：updated_at 由触发器自动维护
    -- 注释：updated_by 由应用层或 audit_user_fields() 触发器填充
```

---

### 接口 6：`IAuditedObject` ⭐

**性质：** `CreationTime`, `CreatorId`, `LastModificationTime`, `LastModifierId`（继承 3 + 5）  
**PostgreSQL 字段：** `created_at`, `created_by`, `updated_at`, `updated_by`

```sql
    -- ============================================================
    -- 【模板 6】接口 IAuditedObject（推荐：创建+修改审计）
    -- 性质：CreationTime, CreatorId, LastModificationTime, LastModifierId
    -- 适用：需要完整生命周期追踪（创建+修改），但不需要软删除的实体
    -- ============================================================

    -- 审计字段：创建 + 修改
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：updated_at 由 update_updated_at() 触发器自动维护
    -- 注释：updated_by 由应用层或 audit_user_fields() 触发器填充
```

---

### 接口 7：`ISoftDelete`

**性质：** `IsDeleted`（BOOLEAN，true/false）  
**PostgreSQL 字段：** `deleted_at`（TIMESTAMPTZ 等价替代）

```sql
    -- ============================================================
    -- 【模板 7】接口 ISoftDelete
    -- 性质：IsDeleted (BOOLEAN true/false)
    -- PostgreSQL 实现：deleted_at TIMESTAMPTZ（NULL=未删除, NOT NULL=已删除）
    -- 适用：仅需软删除能力的实体（不关心删除者和删除时间）
    -- ============================================================

    -- 审计字段：软删除标记
    deleted_at TIMESTAMPTZ,
    -- 注释：NULL = 未删除，有值 = 已软删除（删除时间）
    -- 注释：等效于 ABP 的 IsDeleted（deleted_at IS NOT NULL = true）
```

---

### 接口 8：`IHasDeletionTime`

**性质：** `IsDeleted`, `DeletionTime`（继承 7 + 新增）  
**PostgreSQL 字段：** `deleted_at`

```sql
    -- ============================================================
    -- 【模板 8】接口 IHasDeletionTime
    -- 性质：IsDeleted, DeletionTime
    -- PostgreSQL 实现：deleted_at TIMESTAMPTZ（取代表示）
    -- 适用：需要软删除+删除时间，但不需要删除者的实体
    -- ============================================================

    -- 审计字段：软删除 + 删除时间
    deleted_at TIMESTAMPTZ,
    -- 注释：NULL = 未删除，有值 = 已软删除（记录删除时间）
    -- 注释：deleted_at 同时承载 IsDeleted 和 DeletionTime 两个语义
```

---

### 接口 9：`IDeletionAuditedObject`

**性质：** `IsDeleted`, `DeletionTime`, `DeleterId`（继承 8 + 新增）  
**PostgreSQL 字段：** `deleted_at`, `deleted_by`

```sql
    -- ============================================================
    -- 【模板 9】接口 IDeletionAuditedObject
    -- 性质：IsDeleted, DeletionTime, DeleterId
    -- PostgreSQL 实现：deleted_at TIMESTAMPTZ, deleted_by UUID
    -- 适用：需要完整删除审计的实体（删除标记+时间+删除者）
    -- ============================================================

    -- 审计字段：完整删除审计
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：deleted_at = 删除时间（NULL=未删除）
    -- 注释：deleted_by = 执行删除操作的用户 ID
    -- 注释：deleted_by 由应用层或 audit_deletion_user() 触发器填充
```

---

### 接口 10：`IFullAuditedObject` ⭐⭐

**性质：** `CreationTime`, `CreatorId`, `LastModificationTime`, `LastModifierId`, `IsDeleted`, `DeletionTime`, `DeleterId`（继承 6 + 9）  
**PostgreSQL 字段：** `created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`, `deleted_by`

```sql
    -- ============================================================
    -- 【模板 10】接口 IFullAuditedObject（推荐：完整审计）
    -- 性质：CreationTime, CreatorId, LastModificationTime, LastModifierId,
    --        IsDeleted, DeletionTime, DeleterId
    -- PostgreSQL 实现：6 个字段（deleted_at 取代表示 IsDeleted + DeletionTime）
    -- 适用：核心业务实体，需要完整生命周期追踪（创建+修改+删除）
    -- ============================================================

    -- 审计字段：完整审计（创建 + 修改 + 软删除）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 注释：created_at = 创建时间，不可变
    -- 注释：created_by = 创建者（NULL=系统创建）
    -- 注释：updated_at = 最后修改时间（触发器自动维护）
    -- 注释：updated_by = 最后修改者（应用层/触发器填充）
    -- 注释：deleted_at = 软删除时间（NULL=未删除）
    -- 注释：deleted_by = 删除者（应用层/触发器填充）
```

---

## 3. 字段类型对照总表

| ABP 性质 | ABP 类型 | PostgreSQL 列名 | PostgreSQL 类型 | 默认值 | 约束 |
|:---|:---|:---|:---|:---|:---|
| `CreationTime` | `DateTime` | `created_at` | `TIMESTAMPTZ` | `now()` | NOT NULL |
| `CreatorId` | `Guid?` | `created_by` | `UUID` | NULL | FK → sys_user(id), ON DELETE SET NULL |
| `LastModificationTime` | `DateTime?` | `updated_at` | `TIMESTAMPTZ` | `now()` | NOT NULL |
| `LastModifierId` | `Guid?` | `updated_by` | `UUID` | NULL | FK → sys_user(id), ON DELETE SET NULL |
| `IsDeleted` | `bool` | `deleted_at` | `TIMESTAMPTZ` | NULL | - |
| `DeletionTime` | `DateTime?` | `deleted_at` | `TIMESTAMPTZ` | NULL | - |
| `DeleterId` | `Guid?` | `deleted_by` | `UUID` | NULL | FK → sys_user(id), ON DELETE SET NULL |

> **注：** `deleted_at` 同时承载 `IsDeleted` 和 `DeletionTime` 两个语义。

---

## 4. 触发器绑定（配合审计字段）

### 4.1 `updated_at` 自动维护（必需）

```sql
-- 每个使用 updated_at 的表都需要绑定此触发器
-- 函数 update_updated_at() 已在 v3 Migration 001 中定义

CREATE TRIGGER trg_<表名>_updated_at
    BEFORE UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

### 4.2 `created_by` / `updated_by` 自动填充（可选）

```sql
-- 可选：通过触发器自动维护 created_by / updated_by
-- 注意：需要从 JWT claims 中获取当前用户 ID（current_user_id() 函数已在 v3 定义）

CREATE OR REPLACE FUNCTION audit_user_fields()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        NEW.created_by := current_user_id();
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.updated_by := current_user_id();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 绑定到表
CREATE TRIGGER trg_<表名>_audit_user
    BEFORE INSERT OR UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION audit_user_fields();
```

### 4.3 `deleted_by` 自动填充（可选）

```sql
-- 可选：通过触发器自动维护 deleted_by
-- 注意：仅在 deleted_at 从 NULL 变为非 NULL 时触发

CREATE OR REPLACE FUNCTION audit_deletion_user()
RETURNS TRIGGER AS $$
BEGIN
    IF (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
        NEW.deleted_by := current_user_id();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 绑定到表
CREATE TRIGGER trg_<表名>_audit_deletion
    BEFORE UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION audit_deletion_user();
```

---

## 5. 查询辅助

### 5.1 软删除过滤（必须）

```sql
-- 所有查询软删除表时，必须添加此条件
-- WHERE deleted_at IS NULL

-- 示例：
SELECT * FROM <表名> WHERE deleted_at IS NULL;
```

### 5.2 查询已删除数据

```sql
-- 查询已软删除的数据
SELECT * FROM <表名> WHERE deleted_at IS NOT NULL;
```

### 5.3 创建过滤视图（可选）

```sql
-- 为高频查询的表创建自动过滤软删除的视图
CREATE OR REPLACE VIEW <表名>_active AS
SELECT * FROM <表名> WHERE deleted_at IS NULL;

-- 使用：
SELECT * FROM <表名>_active;
```

---

## 6. 模板选择决策树

```
新建表需要审计吗？
├── 否 → 不添加审计字段（如 sys_secret、sys_token_blacklist）
└── 是 → 需要哪种审计？
    ├── 仅创建相关
    │   ├── 仅需时间 → 模板 1（IHasCreationTime）
    │   ├── 仅需创建者 → 模板 2（IMayHaveCreator）
    │   └── 时间+创建者 → 模板 3（ICreationAuditedObject）
    ├── 仅修改相关
    │   ├── 仅需修改时间 → 模板 4（IHasModificationTime）
    │   └── 时间+修改者 → 模板 5（IModificationAuditedObject）
    ├── 创建+修改 → 模板 6（IAuditedObject）⭐
    ├── 仅删除相关
    │   ├── 仅软删除 → 模板 7（ISoftDelete）
    │   ├── 删除+时间 → 模板 8（IHasDeletionTime）
    │   └── 删除+时间+删除者 → 模板 9（IDeletionAuditedObject）
    └── 完整审计（创建+修改+删除）→ 模板 10（IFullAuditedObject）⭐⭐ 推荐
```

---

## 7. 现有表审计字段完整性分析（v3 已定义）

| 表名 | 当前审计字段 | 对应 ABP 模板 | 完整度 | 建议 |
|:---|:---|:---|:---|:---|
| `sys_tenant` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_department` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_user` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_role` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_api` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_menu` | created_at, updated_at, deleted_at | 7 + 8 混合 | ⚠️ 缺 _by | 补全 _by |
| `sys_user_session` | created_at | 1 | ✅ | 会话表无需软删除 |
| `sys_token_blacklist` | blacklisted_at | 无 | ✅ | 系统级表 |
| `sys_secret` | 无 | 无 | ✅ | 系统级配置 |
| `sys_audit_log` | created_at | 1 | ✅ | 审计日志本身无需审计 |
| `sys_cron_log` | execution_time | 无 | ✅ | 系统级日志 |

---

## 8. 建议：为现有表补全审计字段（Migration 013）

```sql
-- migrate:up

-- 为所有业务表补全 created_by / updated_by / deleted_by
-- 注意：这些字段允许 NULL，避免影响现有数据

ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL;

-- migrate:down
ALTER TABLE sys_menu DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_menu DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_menu DROP COLUMN IF EXISTS created_by;
ALTER TABLE sys_api DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_api DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_api DROP COLUMN IF EXISTS created_by;
ALTER TABLE sys_role DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_role DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_role DROP COLUMN IF EXISTS created_by;
ALTER TABLE sys_user DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_user DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_user DROP COLUMN IF EXISTS created_by;
ALTER TABLE sys_department DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_department DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_department DROP COLUMN IF EXISTS created_by;
ALTER TABLE sys_tenant DROP COLUMN IF EXISTS deleted_by;
ALTER TABLE sys_tenant DROP COLUMN IF EXISTS updated_by;
ALTER TABLE sys_tenant DROP COLUMN IF EXISTS created_by;
```

---

## 9. 使用示例：创建新表时引用模板

### 9.1 示例：创建 `sys_article` 表（文章管理，使用模板 10）

```sql
CREATE TABLE sys_article (
    -- 主键
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    
    -- 业务字段
    title VARCHAR(200) NOT NULL,
    content TEXT,
    author_name VARCHAR(50),
    status VARCHAR(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
    tenant_id UUID NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    
    -- 审计字段：模板 10（IFullAuditedObject）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    
    -- 索引
    INDEX idx_article_tenant (tenant_id),
    INDEX idx_article_status (status)
);

-- 绑定触发器
CREATE TRIGGER trg_article_updated_at
    BEFORE UPDATE ON sys_article
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 启用 RLS
ALTER TABLE sys_article ENABLE ROW LEVEL SECURITY;

CREATE POLICY article_tenant_isolation ON sys_article
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- 注释
COMMENT ON TABLE sys_article IS '文章管理表';
COMMENT ON COLUMN sys_article.deleted_at IS '软删除时间，NULL=未删除';
```

### 9.2 示例：创建 `sys_login_log` 表（登录日志，使用模板 1）

```sql
CREATE TABLE sys_login_log (
    -- 主键
    id BIGSERIAL PRIMARY KEY,
    
    -- 业务字段
    user_id UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    login_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    ip_address VARCHAR(45),
    user_agent TEXT,
    login_result VARCHAR(20) NOT NULL CHECK (login_result IN ('success', 'failed', 'locked')),
    fail_reason VARCHAR(255),
    
    -- 审计字段：模板 1（IHasCreationTime）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    -- 注释：日志表只需记录创建时间，无需修改和软删除
);

-- 日志表不需要 updated_at 触发器
-- 日志表不需要 RLS（或仅允许 SELECT）
```

---

## 10. 总结

| 要点 | 说明 |
|:---|:---|
| **模板用途** | 不建表，仅作为字段参考片段 |
| **推荐模板** | 模板 10（IFullAuditedObject）—— 完整审计 |
| **核心字段** | `created_at`, `updated_at`, `deleted_at` + 可选 `_by` 字段 |
| **触发器** | `updated_at` 必须绑定 `update_updated_at()` |
| **查询规范** | 所有业务查询必须加 `WHERE deleted_at IS NULL` |
| **补全建议** | 现有表可通过 Migration 013 补全 `_by` 字段 |
| **ISoftDelete 实现** | `deleted_at IS NOT NULL` 等价 `IsDeleted = true` |
| **IDataFilter 实现** | 通过 RLS 策略 + 手动过滤实现运行时软删除过滤 |

---

## 11. 修订日志

| 版本 | 日期 | 变更内容 |
|:---|:---|:---|
| v4.0 | 2026-07-21 | 初始版本：审计字段模板参考（基于 ABP.io Auditing Interfaces） |
| v4.1 | 2026-07-21 | 补充完整 10 个接口的独立模板、字段类型对照表、IDataFilter 说明 |
