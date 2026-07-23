-- db/src/sys/types/audit_operation.sql
-- 审计操作类型枚举
-- 来源: sys_audit_log.operation 字段

DO $$ BEGIN
    CREATE TYPE public.audit_operation AS ENUM ('INSERT', 'UPDATE', 'DELETE');
EXCEPTION WHEN duplicate_object THEN null; END $$;

COMMENT ON TYPE public.audit_operation IS '审计操作类型';
