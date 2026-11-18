-- =============================================================================
-- api_v1_platform: 回收 PUBLIC EXECUTE（44 号文档 P0-3）
-- 背景: Postgres 函数默认 EXECUTE TO PUBLIC——web_anon 绕过网关 jwt-auth 直打
--       PostgREST :3100 即可调用全部 api_v1_* 函数（含全量聚合）。
-- 姿势: PUBLIC 的 EXECUTE 先逐函数转授全部登录角色再回收（PostgREST 按 pg_role
--       切到 super_admin/role_admin/role_editor/role_guest，它们不继承 authenticated；
--       原本就不对 PUBLIC 开放的管理端函数不转授，保持原显式授权）；登录基线另授
--       authenticated；本模块前序文件声明的「仅管理员」REVOKE 在批量授权后重放；
--       新增函数经 ALTER DEFAULT PRIVILEGES 兜底。
-- =============================================================================

DO $$
DECLARE f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
             WHERE p.pronamespace = 'api_v1_platform'::regnamespace
               AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                    WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
    LOOP
        EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO role_guest, role_editor, role_admin, tenant_admin, super_admin', f);
    END LOOP;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_platform FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_platform TO authenticated;

-- 将来新建函数：不落 PUBLIC，默认 authenticated + 全部登录角色（app_owner 所建）
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA api_v1_platform
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA api_v1_platform
    GRANT EXECUTE ON FUNCTIONS TO authenticated, role_guest, role_editor, role_admin, tenant_admin, super_admin;

-- 登录引导函数保持 web_anon 可用（无 JWT 阶段兜底；单对象返回无放大面）
GRANT EXECUTE ON FUNCTION api_v1_platform.get_config(p_config_key text) TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.get_all_public_configs() TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.get_current_user() TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.ensure_user() TO web_anon;
