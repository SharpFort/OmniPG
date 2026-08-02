-- db/api_v1/sys/rpc/rpc_create_user.sql
-- 创建用户 RPC（Phase 1, D8: 一律调用 Casdoor API，pg_net http_post）
-- 流程: Casdoor /api/add-user（Basic Auth，凭据存 sys_secret）→ Casdoor 触发
--       new-user webhook → webhook_user_upsert 回流 mirror/profile（异步）
-- 返回值: 触发结果（true = 已提交 Casdoor;用户数据经 webhook 回流）
-- 注意: 返回类型由 uuid 变更为 boolean（D8 语义变更），需先 DROP 旧签名
DROP FUNCTION IF EXISTS api_v1_sys.create_user(text, text, uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION api_v1_sys.create_user(
    p_username text,
    p_password text,
    p_tenant_id uuid,
    p_dept_id uuid DEFAULT NULL,
    p_email text DEFAULT NULL,
    p_phone text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_casdoor_url text;
    v_admin_user  text;
    v_admin_pass  text;
    v_org         text;
    v_auth        text;
    v_body        jsonb;
    v_headers     jsonb;
    v_req_id      bigint;
    v_resp        record;
BEGIN
    -- 1. 读取 Casdoor 集成配置（sys_secret）
    SELECT key_value INTO v_casdoor_url FROM sys_secret WHERE key_name = 'casdoor_admin_api';
    SELECT key_value INTO v_admin_user  FROM sys_secret WHERE key_name = 'casdoor_admin_user';
    SELECT key_value INTO v_admin_pass  FROM sys_secret WHERE key_name = 'casdoor_admin_password';
    SELECT key_value INTO v_org         FROM sys_secret WHERE key_name = 'casdoor_org';
    IF v_casdoor_url IS NULL OR v_admin_user IS NULL OR v_admin_pass IS NULL OR v_org IS NULL THEN
        RAISE EXCEPTION 'Casdoor admin API 未配置（sys_secret）' USING ERRCODE = 'P0098';
    END IF;

    -- 2. Basic Auth 头（base64(user:pass)）
    v_auth := 'Basic ' || encode(convert_to(v_admin_user || ':' || v_admin_pass, 'UTF8'), 'base64');
    v_headers := jsonb_build_object('Authorization', v_auth);

    -- 3. 调用 Casdoor add-user（owner = 业务组织）
    v_body := jsonb_build_object(
        'owner', v_org,
        'name', p_username,
        'password', p_password,
        'email', COALESCE(p_email, ''),
        'phone', COALESCE(p_phone, ''),
        'type', 'normal-user'
    );

    SELECT request_id INTO v_req_id
    FROM net.http_post(
        v_casdoor_url || '/api/add-user',
        v_body,
        '{}'::jsonb,
        v_headers
    );

    -- 4. 收集响应（同步等待，确认 Casdoor 受理）
    SELECT status_code, content INTO v_resp
    FROM net.http_collect_response(v_req_id, async := false);

    IF v_resp.status_code <> 200 THEN
        RAISE EXCEPTION 'Casdoor add-user 失败: HTTP %', v_resp.status_code USING ERRCODE = 'P0098';
    END IF;

    -- 5. 业务档案预占位（tenant/dept 归属;mirror 行由 webhook 回流）
    --    注意: 此处不写 mirror（id 由 Casdoor 生成），webhook_user_upsert 到达后
    --    由 ensure 逻辑补全 profile（默认租户）。若需立即绑定指定租户，
    --    可在 webhook 回流后由前端调用 profile 更新 RPC（Phase 3）。
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.create_user(text, text, uuid, uuid, text, text) IS '创建用户（D8: 调用 Casdoor API，webhook 回流镜像）';
GRANT EXECUTE ON FUNCTION api_v1_sys.create_user(text, text, uuid, uuid, text, text) TO authenticated;
