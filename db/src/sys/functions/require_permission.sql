-- db/src/sys/functions/require_permission.sql
-- 权限门槛统一入口（035）——「权限点档」helper
-- 用法: DEFINER 写/管理 RPC 内一行调用: PERFORM require_permission('sys:xxx');
-- 语义: has_permission(code) 不通过即 RAISE 42501（与 024/025/029 手写门槛等价）
-- 三档模型（05.4）: 无门槛（INVOKER+RLS）/ 权限点（DEFINER+require_permission）/
--                   超管（DEFINER+require_super_admin）

CREATE OR REPLACE FUNCTION require_permission(p_code text) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT has_permission(p_code) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;
COMMENT ON FUNCTION require_permission(text) IS '权限门槛统一入口（035）：has_permission 不通过即 42501；DEFINER 写/管理 RPC 统一调用';
