-- db/api_v1/sys/rpc/rpc_health_check.sql
-- 健康检查 RPC
-- 来源: 20260707000014_auth_rpc_functions.sql

CREATE OR REPLACE FUNCTION api_v1_sys.health_check()
RETURNS json
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT json_build_object(
        'status', 'ok',
        'timestamp', now(),
        'database', current_database(),
        'version', current_setting('server_version')
    );
$$;
COMMENT ON FUNCTION api_v1_sys.health_check() IS '健康检查接口（无认证要求，PostgREST 匿名访问也可用）';
GRANT EXECUTE ON FUNCTION api_v1_sys.health_check() TO web_anon;
