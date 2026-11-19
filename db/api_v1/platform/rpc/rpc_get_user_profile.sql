-- api_v1/platform/rpc/rpc_get_user_profile.sql
-- D27: 档案查询按 organization_id 成员约束，输出双列。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_get_user_profile(p_user_id text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_row json; v_org text := current_organization_id();
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'user_id required' USING ERRCODE = '22023';
    END IF;
    -- 无用户上下文（缺 sub claim）一律拒绝：原 `p_user_id <> current_user_id()` 对 NULL 恒为 NULL，
    -- 下方鉴权分支会被静默跳过（fail-open）
    IF current_user_id() IS NULL THEN
        RAISE EXCEPTION 'unauthorized: missing user context' USING ERRCODE = '42501';
    END IF;
    IF p_user_id <> current_user_id() AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = p_user_id AND organization_id = v_org
                         AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 列白名单输出：不再 SELECT */row_to_json(p) 序列化 deleted_*/created_by 等审计与内部列
    SELECT json_build_object(
        'user_id', p.user_id,
        'organization_id', p.organization_id,
        'tenant_id', p.tenant_id,
        'dept_id', p.dept_id,
        'nickname', p.nickname,
        'avatar_url', p.avatar_url,
        'gender', p.gender,
        'birthday', p.birthday,
        'bio', p.bio,
        'location', p.location,
        'hobbies', to_jsonb(p.hobbies),
        'website', p.website,
        'preferences', p.preferences,
        'created_at', p.created_at,
        'updated_at', p.updated_at
    ) INTO v_row
    FROM user_profile p
    WHERE p.user_id = p_user_id AND p.deleted_at IS NULL; -- 软删档案不再返回
    RETURN COALESCE(v_row, '{}'::json);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_get_user_profile(text) TO authenticated;
