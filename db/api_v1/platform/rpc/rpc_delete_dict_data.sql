-- api_v1/platform/rpc/rpc_delete_dict_data.sql
-- D27: 字典数据删除按 organization_id + tenant_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_delete_dict_data(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_org text;
BEGIN
    IF NOT has_permission('platform:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    -- 严格按当前租户查找目标数据
    SELECT organization_id
      INTO v_org
      FROM dict_data
     WHERE id = p_id AND tenant_id = current_logto_tenant_id();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
    END IF;

    -- 全局字典（organization_id IS NULL）仅超管可删除
    IF v_org IS NULL THEN
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_org IS DISTINCT FROM current_organization_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    -- 严格限定租户范围删除，杜绝跨租户误删
    DELETE FROM dict_data
     WHERE id = p_id AND tenant_id = current_logto_tenant_id();

    PERFORM log_operate('dict', 'delete', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_delete_dict_data(uuid) TO authenticated;
