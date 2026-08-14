-- api_v1/public/rpc/rpc_list_cron_job_runs.sql
-- FUNCTION: api_v1_public.rpc_list_cron_job_runs（17 号文档归位：迁移 021_cron_rpc_geolite2.sql 删定义段，本文件为唯一权威）
-- 回放终态: 021_cron_rpc_geolite2.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_cron_job_runs(p_limit int DEFAULT 100)
RETURNS TABLE(runid bigint, jobid bigint, status text, return_message text,
              start_time timestamptz, end_time timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
    FROM cron.job_run_details d
    ORDER BY d.runid DESC
    LIMIT GREATEST(1, LEAST(p_limit, 1000));
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_cron_job_runs(int) TO authenticated;
