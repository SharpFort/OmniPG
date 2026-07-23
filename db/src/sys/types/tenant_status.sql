-- db/src/sys/types/tenant_status.sql
-- 租户状态枚举类型
-- 来源: sys_tenant.status 字段

DO $$ BEGIN
    CREATE TYPE public.tenant_status AS ENUM ('active', 'suspended', 'disabled');
EXCEPTION WHEN duplicate_object THEN null; END $$;

COMMENT ON TYPE public.tenant_status IS '租户状态：active=正常, suspended=暂停, disabled=禁用';
