-- db/src/public/functions/write_audit_log.sql
-- 通用审计日志写入函数（供触发器和业务 RPC 调用）
-- T7: sys_audit_log → audit_log；user_id 类型 text（Logto sub）
--
-- 调用场景：
--   1. 触发器自动调用（数据变更审计）
--   2. RPC 手动调用（业务事件审计：登录/登出/密码修改等）
--
-- 参数说明：
--   p_table_name : 操作的表名
--   p_operation  : INSERT/UPDATE/DELETE
--   p_old_data   : 变更前的数据（DELETE/UPDATE 时）
--   p_new_data   : 变更后的数据（INSERT/UPDATE 时）
--   p_source     : 来源标识（trigger/manual/rpc/business）
--   p_description: 可选的业务描述

CREATE OR REPLACE FUNCTION public.write_audit_log(
    p_table_name    text,
    p_operation     text,
    p_old_data      jsonb DEFAULT NULL,
    p_new_data      jsonb DEFAULT NULL,
    p_source        text DEFAULT 'trigger',
    p_description   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant_id text;
    v_user_id text;
BEGIN
    -- 提取 tenant_id（优先从 new_data，其次 old_data；Logto organization_id）
    v_tenant_id := COALESCE(
        p_new_data->>'tenant_id',
        p_old_data->>'tenant_id'
    );

    -- 提取 user_id（从 JWT 上下文）
    v_user_id := current_user_id();

    INSERT INTO public.audit_log (
        table_name,
        operation,
        old_data,
        new_data,
        user_id,
        tenant_id,
        source,
        description,
        created_at
    ) VALUES (
        p_table_name,
        p_operation,
        p_old_data,
        p_new_data,
        v_user_id,
        v_tenant_id,
        p_source,
        p_description,
        now()
    );
END;
$$;

COMMENT ON FUNCTION public.write_audit_log(text, text, jsonb, jsonb, text, text) IS
'通用审计日志写入函数：标准化数据变更和业务事件的审计记录。
触发器场景：自动记录表数据变更（source=trigger）
业务场景：记录登录/登出/密码修改等事件（source=rpc/business）';
