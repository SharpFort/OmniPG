-- api_v1/public/rpc/rpc_list_cron_jobs.sql
-- FUNCTION: api_v1_public.rpc_list_cron_jobs（17 号文档归位：迁移 021_cron_rpc_geolite2.sql 删定义段，本文件为唯一权威）
-- 回放终态: 021_cron_rpc_geolite2.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_cron_jobs()
RETURNS TABLE(jobid bigint, jobname text, schedule text, command text,
              nodename text, nodeport integer, database text, username text, active boolean)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    -- 仅超管可查看任务定义（平台级运维信息，非租户级）
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT c.jobid, c.jobname, c.schedule, c.command, c.nodename, c.nodeport,
           c.database, c.username, c.active
    FROM cron.job c
    ORDER BY c.jobid;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_cron_jobs() TO authenticated;
