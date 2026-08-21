-- db/src/platform/types/request_status.sql
-- 审批状态枚举类型
-- 来源: sys_user_role_request.status 字段

DO $$ BEGIN
    CREATE TYPE platform.request_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN null; END $$;

COMMENT ON TYPE platform.request_status IS '审批状态：pending=待审批, approved=已通过, rejected=已拒绝';
