-- db/src/sys/migrations/20260707013_audit_by_backfill.sql
-- =============================================================================
-- 注意：本 migration 仅适用于 v3.0 之前的版本升级
-- v3.1 已补全所有 _by 字段，无需执行本 migration
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §8
-- =============================================================================

-- migrate:up

-- 为所有业务表补全 created_by / updated_by / deleted_by
-- 注意：这些字段允许 NULL，避免影响现有数据
-- 注意：不强制外键约束，避免循环引用

ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_tenant ADD COLUMN IF NOT EXISTS deleted_by UUID;

ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_department ADD COLUMN IF NOT EXISTS deleted_by UUID;

ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_user ADD COLUMN IF NOT EXISTS deleted_by UUID;

ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS deleted_by UUID;

ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_api ADD COLUMN IF NOT EXISTS deleted_by UUID;

ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS updated_by UUID;
ALTER TABLE sys_menu ADD COLUMN IF NOT EXISTS deleted_by UUID;

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
