-- =============================================================================
-- 018_final_cleanup.sql — T7: 残留函数收尾（ensure_user / get_role_permissions）
-- =============================================================================
-- ensure_user: 010 DB 版引用 sys_user_profile → user_profile（JIT 建档）
-- get_role_permissions: Casdoor 时代（sys_role/sys_role_api/sys_api）→ Logto
--   语义（role 镜像 + iam_role_api + iam_api）
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 ensure_user — 更新 user_profile 引用（JIT 兜底建档）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub    text;
    v_org    text;
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO users (id, username, name, avatar, is_suspended)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', ''),
        false
    )
    ON CONFLICT (id) DO UPDATE SET
        username = EXCLUDED.username,
        name     = EXCLUDED.name,
        avatar   = EXCLUDED.avatar,
        updated_at = now();

    -- JIT 兜底：组织 token 携带 organization_id 时补建 profile（租户归属）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;
    END IF;

    RETURN v_sub;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.ensure_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- §2 get_role_permissions — Logto 语义重写
--     入参: p_role_code text（Logto 角色名 = role_code）
--     数据: role 镜像 + iam_role_api→iam_api + iam_role_menu→iam_menu
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_sys.get_role_permissions(uuid);
CREATE FUNCTION api_v1_sys.get_role_permissions(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role RECORD;
    v_apis json;
    v_menus json;
BEGIN
    SELECT id, name AS role_name, role_code, type, is_default INTO v_role
    FROM role WHERE role_code = p_role_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(json_agg(
        json_build_object('id', a.id, 'path', a.path, 'method', a.method, 'api_name', a.name)
        ORDER BY a.path
    ), '[]'::json) INTO v_apis
    FROM iam_role_api ra
    JOIN iam_api a ON ra.api_id = a.id
    WHERE ra.role_code = p_role_code AND a.is_active;

    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.menu_name, 'parent_id', m.parent_id,
                          'path', m.path, 'icon', m.icon)
        ORDER BY m.order_num
    ), '[]'::json) INTO v_menus
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active;

    RETURN json_build_object(
        'role_id', v_role.id,
        'role_code', v_role.role_code,
        'role_name', v_role.role_name,
        'type', v_role.type,
        'apis', v_apis,
        'menus', v_menus,
        'api_count', json_array_length(v_apis),
        'menu_count', json_array_length(v_menus)
    );
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_role_permissions(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 验证：无残留引用旧表名函数
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','api_v1_sys')
      AND p.prosrc ~ 'sys_(api|menu|tenant|secret|token_blacklist|user_session|user_legacy|role|user_role|user_profile|department|config|audit_log|cron_log)';
    RAISE NOTICE '018: 残留引用旧表名函数=%（预期 0）', v_cnt;
END $$;
