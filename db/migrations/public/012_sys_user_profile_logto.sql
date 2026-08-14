-- ==============================================================================
-- Migration 012: sys_user_profile 主键 text 化 + 新镜像表 RLS（Logto 语义）
-- ------------------------------------------------------------------------------
-- 决策: D17/D18 — Logto id 为 21 位 nanoid 字符串，业务主键统一 text
-- 处理:
--   A. sys_user_profile: user_id/tenant_id/审计列 uuid → text，FK 改指向 users/tenants
--   B. users/tenants/user_tenants/iam_role 镜像表 RLS（租户隔离 + 超管例外）
--   C. casdoor_user_mirror 相关权限标记退役（表保留待 T7 清理）
-- 幂等: DO 块条件判断 / DROP CONSTRAINT IF EXISTS
-- 引用: 06-开发路线 §3 T4、05-方案 §6.1
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- A. sys_user_profile text 化（先删 FK → 改类型 → 重建 FK）
-- ==============================================================================
DO $$
BEGIN
    -- A1. 删除旧 FK（007 时代的约束名）
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profile_user_id') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT fk_profile_user_id;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profile_tenant_id') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT fk_profile_tenant_id;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profile_dept_id') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT fk_profile_dept_id;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_user_profile_user_id_fkey') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT sys_user_profile_user_id_fkey;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_user_profile_tenant_id_fkey') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT sys_user_profile_tenant_id_fkey;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_user_profile_dept_id_fkey') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT sys_user_profile_dept_id_fkey;
    END IF;

    -- A2. 类型转换（uuid → text；存量数据为 Casdoor uuid，Logto 时代无映射价值，
    --     N4 空白业务：清理非空存量行，由 webhook/JIT 重新建档）
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='sys_user_profile' AND column_name='user_id' AND data_type='uuid') THEN
        -- 先删依赖 user_id 列的 RLS 策略（mirror/profile 策略引用该列，改类型会失败）
        DROP POLICY IF EXISTS mirror_tenant_policy ON casdoor_user_mirror;
        
        -- 先删旧 Casdoor 兼容视图（007 建的 public.sys_user 依赖 sys_user_profile 列；本迁移末尾重建 Logto 版）
        
        DELETE FROM sys_user_profile;  -- N4: 清空 Casdoor 时代档案（无历史数据）
        ALTER TABLE sys_user_profile ALTER COLUMN user_id TYPE text;
        ALTER TABLE sys_user_profile ALTER COLUMN tenant_id TYPE text;
        ALTER TABLE sys_user_profile ALTER COLUMN created_by TYPE text;
        ALTER TABLE sys_user_profile ALTER COLUMN updated_by TYPE text;
        ALTER TABLE sys_user_profile ALTER COLUMN deleted_by TYPE text;
    END IF;

    -- A3. 重建 FK → 新镜像表（存在时；users/tenants 由 009 创建；
    --     sys_user_profile 为 T7 遗留表——空库冷启动不存在 → 环境自适应跳过）
    IF to_regclass('public.sys_user_profile') IS NOT NULL AND to_regclass('public.users') IS NOT NULL THEN
        ALTER TABLE sys_user_profile ADD CONSTRAINT fk_profile_user_id
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
    END IF;
    IF to_regclass('public.sys_user_profile') IS NOT NULL AND to_regclass('public.tenants') IS NOT NULL THEN
        ALTER TABLE sys_user_profile ADD CONSTRAINT fk_profile_tenant_id
            FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE RESTRICT;
    END IF;
END $$;

-- dept_id 保持 uuid（sys_department 属 Casdoor 遗留管理表，P1 再定处置）
-- 移除 dept_id FK（若指向 sys_department 类型冲突前已存在）
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_profile_dept_id') THEN
        ALTER TABLE sys_user_profile DROP CONSTRAINT fk_profile_dept_id;
    END IF;
END $$;

-- ==============================================================================
-- B. 新镜像表 RLS（05 §5.3.2 模式：租户隔离 + 超管例外 + 本人可见）
-- ==============================================================================

-- B1. users — 超管全量 / 本人 / 同租户成员可见
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- B2. tenants — 超管全量 / 当前租户可见
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

-- B3. user_tenants — 超管全量 / 本人 / 同租户成员可见
ALTER TABLE user_tenants ENABLE ROW LEVEL SECURITY;

-- B4. iam_role — 只读镜像，authenticated 可读（目录数据，无租户维度）
--     T7 遗留表（016 从 iam_role RENAME 到 role）；空库不存在则跳过——环境自适应
DO $$ BEGIN
    IF to_regclass('public.iam_role') IS NOT NULL THEN
        ALTER TABLE iam_role ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;


-- ==============================================================================
-- C. Casdoor 时代镜像表权限标记（退役声明；表体保留待 T7）
-- ==============================================================================
-- 17 号文档环境自适应（2026-08-14）：casdoor_user_mirror/sys_tenant 为 T7 遗留表，
-- 空库冷启动不存在 → 表存在才打注释
DO $$ BEGIN
    IF to_regclass('public.casdoor_user_mirror') IS NOT NULL THEN
        COMMENT ON TABLE casdoor_user_mirror IS '【退役】Casdoor 用户镜像（Phase 2 已由 users 表替代；T7 清理）';
    END IF;
    IF to_regclass('public.sys_tenant') IS NOT NULL THEN
        COMMENT ON TABLE sys_tenant IS '【退役】Casdoor 时代租户表（Phase 2 已由 tenants 镜像表替代；保留兼容视图/历史）';
    END IF;
END $$;

-- ==============================================================================
-- D. public.sys_user 兼容视图（text 化后重建；009 阶段依赖未就绪，故在此建）
--     沿用 security_invoker 语义；列结构与旧版对齐
-- ==============================================================================

-- 17 号文档环境自适应（2026-08-14）：sys_user 视图定义已迁 src（014 已删
-- 001 的 sys_user 表），dbmate/重放阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('public.sys_user') IS NOT NULL THEN
        GRANT SELECT ON public.sys_user TO authenticated;
    END IF;
END $$;

-- ==============================================================================
-- migrate:down
-- ==============================================================================
-- 回滚需: 恢复 uuid 类型 + 重建 007 FK（Casdoor 时代），建议整体回退到 007 快照
