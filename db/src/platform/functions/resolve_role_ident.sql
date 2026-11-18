-- db/src/platform/functions/resolve_role_ident.sql
-- D26: 角色名（role_code）解析为 Logto 角色标识（role_id / org_role_id）
-- 规则：全局角色（platform.role）优先；仅当全局未命中时才解析组织角色（platform.tenant_role）。
-- 用途：RPC 写路径/查询入参继续保持 p_role_code 字符串契约，内部落库使用两个不可空标识。

CREATE OR REPLACE FUNCTION platform.resolve_role_ident(p_role_code text)
RETURNS TABLE(role_id text, org_role_id text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
    SELECT
        (SELECT id FROM platform.role WHERE role_code = p_role_code AND tenant_id = current_logto_tenant_id() LIMIT 1) AS role_id,
        (SELECT id FROM platform.tenant_role WHERE name = p_role_code AND tenant_id = current_logto_tenant_id()
           AND NOT EXISTS (SELECT 1 FROM platform.role WHERE role_code = p_role_code AND tenant_id = current_logto_tenant_id())
         LIMIT 1) AS org_role_id;
$$;

COMMENT ON FUNCTION platform.resolve_role_ident(text) IS 'D26: 角色名解析为 Logto 角色标识（全局优先；API 入参仍用角色名）';
GRANT EXECUTE ON FUNCTION platform.resolve_role_ident(text) TO authenticated;
