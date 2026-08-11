-- db/src/public/functions/require_super_admin.sql
-- 超管门槛统一入口（035）——「超管档」helper
-- 用法: 平台级 RPC（pg_cron 任务查看/会话清理等）内一行调用: PERFORM require_super_admin();
-- 语义: is_super_admin() 不通过即 RAISE 42501

CREATE OR REPLACE FUNCTION require_super_admin() RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;
COMMENT ON FUNCTION require_super_admin() IS '超管门槛统一入口（035）：平台级 RPC（pg_cron/会话清理等）统一调用';
