-- db/src/platform/templates/audit_fields.sql
-- =============================================================================
-- 审计字段模板参考（基于 ABP.io Auditing Interfaces）
-- 来源: 02-数据库建模-审计接口与字段模板完整参考-v4.2.md
--
-- 定位：本文档提供 10 个审计接口的字段模板，作为新建表时的字段参考。
-- 使用说明：建表时按需复制对应模板的字段代码块。
--
-- 重要提示：
--   1. 模板中的 _by 字段（created_by/updated_by/deleted_by）定义为普通 UUID，
--       不强制外键约束（避免循环引用问题，特别是 tenants 镜像表（T7））
--   2. 如需外键约束，建议在表创建后通过 ALTER TABLE 单独添加
--   3. 所有模板中的索引使用 PostgreSQL 标准写法（CREATE INDEX），非内联索引
--   4. _by 字段推荐使用 UUID v7（时间有序），可通过 is_uuid_v7() 函数验证
--       如需严格验证，请取消注释对应的 CHECK 约束行
-- =============================================================================

-- =============================================================================
-- 【模板 1】接口 IHasCreationTime
-- 性质：CreationTime
-- 适用：仅需记录创建时间，如日志表、配置表
-- PostgreSQL 字段：created_at
-- =============================================================================

/*
    -- 审计字段：创建时间（由数据库默认值填充，应用层不应修改）
    -- 如需强制保护，请绑定 audit_created_at() 触发器
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
*/

-- =============================================================================
-- 【模板 2】接口 IMayHaveCreator
-- 性质：CreatorId
-- 适用：仅需知道创建者，如自动采集的数据
-- PostgreSQL 字段：created_by
-- =============================================================================

/*
    -- 审计字段：创建者用户 ID（NULL 表示系统/匿名创建）
    -- 注意：不强制外键约束，避免循环引用
    -- 可选：如需强制 UUID v7 格式，请取消注释下一行
    -- CHECK (created_by IS NULL OR is_uuid_v7(created_by)),
    created_by UUID,
*/

-- =============================================================================
-- 【模板 3】接口 ICreationAuditedObject
-- 性质：CreationTime, CreatorId（继承 1 + 2）
-- 适用：需要完整创建审计的实体
-- PostgreSQL 字段：created_at, created_by
-- =============================================================================

/*
    -- 审计字段：创建者 + 创建时间
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,  -- 可选: CHECK (created_by IS NULL OR is_uuid_v7(created_by)),
*/

-- =============================================================================
-- 【模板 4】接口 IHasModificationTime
-- 性质：LastModificationTime
-- 适用：仅需记录最后修改时间，如无需追踪修改者的实体
-- PostgreSQL 字段：updated_at
-- =============================================================================

/*
    -- 审计字段：最后修改时间（由 update_updated_at() 触发器自动维护，应用层不应修改）
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
*/

-- =============================================================================
-- 【模板 5】接口 IModificationAuditedObject
-- 性质：LastModificationTime, LastModifierId（继承 4 + 新增）
-- 适用：需要完整修改审计的实体（不关心创建信息）
-- PostgreSQL 字段：updated_at, updated_by
-- =============================================================================

/*
    -- 审计字段：最后修改时间 + 最后修改者
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,  -- 可选: CHECK (updated_by IS NULL OR is_uuid_v7(updated_by)),
    -- 注释：updated_at 由 update_updated_at() 触发器自动维护
    -- 注释：updated_by 由应用层或 audit_user_fields() 触发器填充
*/

-- =============================================================================
-- 【模板 6】接口 IAuditedObject ⭐
-- 性质：CreationTime, CreatorId, LastModificationTime, LastModifierId（继承 3 + 5）
-- 适用：需要完整生命周期追踪（创建+修改），但不需要软删除的实体
-- PostgreSQL 字段：created_at, created_by, updated_at, updated_by
-- =============================================================================

/*
    -- 审计字段：创建 + 修改
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,  -- 可选: CHECK (created_by IS NULL OR is_uuid_v7(created_by)),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,  -- 可选: CHECK (updated_by IS NULL OR is_uuid_v7(updated_by)),
    -- 注释：updated_at 由 update_updated_at() 触发器自动维护
    -- 注释：updated_by 由应用层或 audit_user_fields() 触发器填充
*/

-- =============================================================================
-- 【模板 7】接口 ISoftDelete
-- 性质：IsDeleted (BOOLEAN true/false)
-- PostgreSQL 实现：deleted_at TIMESTAMPTZ（NULL=未删除, NOT NULL=已删除）
-- 适用：仅需软删除能力的实体（不关心删除者和删除时间）
-- PostgreSQL 字段：deleted_at
-- =============================================================================

/*
    -- 审计字段：软删除标记
    deleted_at TIMESTAMPTZ,
    -- 注释：NULL = 未删除，有值 = 已软删除（删除时间）
    -- 注释：等效于 ABP 的 IsDeleted（deleted_at IS NOT NULL = true）
*/

-- =============================================================================
-- 【模板 8】接口 IHasDeletionTime
-- 性质：IsDeleted, DeletionTime（继承 7 + 新增）
-- PostgreSQL 实现：deleted_at TIMESTAMPTZ（取代表示）
-- 适用：需要软删除+删除时间，但不需要删除者的实体
-- PostgreSQL 字段：deleted_at
-- =============================================================================

/*
    -- 审计字段：软删除 + 删除时间
    deleted_at TIMESTAMPTZ,
    -- 注释：NULL = 未删除，有值 = 已软删除（记录删除时间）
    -- 注释：deleted_at 同时承载 IsDeleted 和 DeletionTime 两个语义
*/

-- =============================================================================
-- 【模板 9】接口 IDeletionAuditedObject
-- 性质：IsDeleted, DeletionTime, DeleterId（继承 8 + 新增）
-- PostgreSQL 实现：deleted_at TIMESTAMPTZ, deleted_by UUID
-- 适用：需要完整删除审计的实体（删除标记+时间+删除者）
-- PostgreSQL 字段：deleted_at, deleted_by
-- =============================================================================

/*
    -- 审计字段：完整删除审计
    deleted_at TIMESTAMPTZ,
    deleted_by UUID,  -- 可选: CHECK (deleted_by IS NULL OR is_uuid_v7(deleted_by)),
    -- 注释：deleted_at = 删除时间（NULL=未删除）
    -- 注释：deleted_by = 执行删除操作的用户 ID
    -- 注释：deleted_by 由应用层或 audit_deletion_user() 触发器填充
*/

-- =============================================================================
-- 【模板 10】接口 IFullAuditedObject ⭐⭐
-- 性质：CreationTime, CreatorId, LastModificationTime, LastModifierId,
--        IsDeleted, DeletionTime, DeleterId（继承 6 + 9）
-- PostgreSQL 实现：6 个字段（deleted_at 取代表示 IsDeleted + DeletionTime）
-- 适用：核心业务实体，需要完整生命周期追踪（创建+修改+删除）
-- PostgreSQL 字段：created_at, created_by, updated_at, updated_by, deleted_at, deleted_by
-- =============================================================================

/*
    -- 审计字段：完整审计（创建 + 修改 + 软删除）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,  -- 可选: CHECK (created_by IS NULL OR is_uuid_v7(created_by)),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID,  -- 可选: CHECK (updated_by IS NULL OR is_uuid_v7(updated_by)),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID,  -- 可选: CHECK (deleted_by IS NULL OR is_uuid_v7(deleted_by)),
    -- 注释：created_at = 创建时间，不可变
    -- 注释：created_by = 创建者（NULL=系统创建）
    -- 注释：updated_at = 最后修改时间（触发器自动维护）
    -- 注释：updated_by = 最后修改者（应用层/触发器填充）
    -- 注释：deleted_at = 软删除时间（NULL=未删除）
    -- 注释：deleted_by = 删除者（应用层/触发器填充）
*/

-- =============================================================================
-- 触发器绑定示例（配合审计字段）
-- =============================================================================

-- 1. updated_at 自动维护（必需）
/*
CREATE TRIGGER trg_<表名>_updated_at
    BEFORE UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
*/

-- 2. created_by / updated_by 自动填充（可选，推荐）
/*
CREATE TRIGGER trg_<表名>_audit_user
    BEFORE INSERT OR UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION audit_user_fields();
*/

-- 3. deleted_by 自动填充（可选，推荐）
/*
CREATE TRIGGER trg_<表名>_audit_deletion
    BEFORE UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION audit_deletion_user();
*/

-- 4. created_at 强制保护（可选，推荐）
/*
CREATE TRIGGER trg_<表名>_audit_created_at
    BEFORE INSERT OR UPDATE ON <表名>
    FOR EACH ROW EXECUTE FUNCTION audit_created_at();
*/

-- 5. UUID v7 严格验证（可选，按需启用）
/*
ALTER TABLE <表名> ADD CONSTRAINT chk_<表名>_created_by_uuid7
    CHECK (created_by IS NULL OR is_uuid_v7(created_by));
ALTER TABLE <表名> ADD CONSTRAINT chk_<表名>_updated_by_uuid7
    CHECK (updated_by IS NULL OR is_uuid_v7(updated_by));
ALTER TABLE <表名> ADD CONSTRAINT chk_<表名>_deleted_by_uuid7
    CHECK (deleted_by IS NULL OR is_uuid_v7(deleted_by));
*/
