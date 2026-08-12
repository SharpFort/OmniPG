-- =============================================================================
-- 023_admin_p0_naming_perm.sql — sys_ 前缀移除 + P0 三项（has_permission/审计/登录查询）
-- =============================================================================
-- 背景: 2026-08-04 用户拍板
--   ① sys_ 前缀移除（iam_ 保留）: public schema = 平台/系统管理域，无前缀即可
--     sys_dict_type/sys_dict_data/sys_login_log → dict_type/dict_data/login_log
--   ② P0 三项（05.2 §二）:
--     - has_permission(code) 实现（05 文档 §6.3 设计落地，全库此前无实现）
--     - 审计触发器补挂（8 张系统/授权表；镜像表不挂——webhook 可追溯）
--     - rpc_search_login_logs（租户维度登录日志查询，RLS 无法 join 的补位）
--   ③ iam_api 加 api_code 列（权限码，与 iam_menu.perms 对齐——022 注释引用）
-- 联动（RENAME 不自动更新的对象须手动重建）:
--   - 020 sync_login_log_write（plpgsql 函数体文本引用旧表名）
--   - 019 api_v1_sys.sys_dict_type/sys_dict_data/sys_login_log 视图（表名视图改名）
--   - 021 v_sys_login_log（保险重建）
--   RLS 策略/种子数据/其他视图引用表 OID → RENAME 自动跟随 ✅
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 sys_ 前缀移除（数据/RLS/索引随 RENAME 自动跟随）
-- ---------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.sys_dict_type  RENAME TO dict_type;
ALTER TABLE IF EXISTS public.sys_dict_data  RENAME TO dict_data;
ALTER TABLE IF EXISTS public.sys_login_log  RENAME TO login_log;

-- 表名视图改名（api_v1_sys 暴露层）
DROP VIEW IF EXISTS api_v1_sys.sys_dict_type CASCADE;
CREATE VIEW api_v1_sys.dict_type AS
SELECT id, tenant_id, dict_name, dict_label, status, sort_no, remark,
       created_at, updated_at, created_by, updated_by
FROM dict_type;
COMMENT ON VIEW api_v1_sys.dict_type IS '字典类型视图（sys_ 前缀移除，023）';

DROP VIEW IF EXISTS api_v1_sys.sys_dict_data CASCADE;
CREATE VIEW api_v1_sys.dict_data AS
SELECT id, tenant_id, dict_name, item_label, item_value, item_type, is_default,
       sort_no, status, remark, created_at, updated_at, created_by, updated_by
FROM dict_data;
COMMENT ON VIEW api_v1_sys.dict_data IS '字典数据视图（sys_ 前缀移除，023）';

DROP VIEW IF EXISTS api_v1_sys.sys_login_log CASCADE;
CREATE VIEW api_v1_sys.login_log AS
SELECT id, tenant_id, user_id, username, login_type, result, fail_reason,
       ip, user_agent, region, logto_event, created_at
FROM login_log;
COMMENT ON VIEW api_v1_sys.login_log IS '登录日志视图（sys_ 前缀移除，023）';

-- 021 v_sys_login_log 保险重建（引用新表名；geo_locate 返回 jsonb → 键访问）
DROP VIEW IF EXISTS api_v1_sys.v_sys_login_log CASCADE;
CREATE VIEW api_v1_sys.v_sys_login_log AS
SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type, l.result,
       l.fail_reason, l.ip, l.user_agent,
       l.region                 AS region_snapshot,
       g->>'region'             AS region_live,
       g->>'source'             AS geo_source,
       (g->>'latitude')::float8 AS latitude,
       (g->>'longitude')::float8 AS longitude,
       g->>'timezone'           AS timezone,
       l.logto_event, l.created_at
FROM login_log l
LEFT JOIN LATERAL geo_locate(l.ip) g ON true;
COMMENT ON VIEW api_v1_sys.v_sys_login_log IS '登录日志视图：login_log + geo_locate 实时地理（023 重建）';

-- 020 sync_login_log_write 重建（plpgsql 函数体引用旧表名 sys_login_log → login_log）
CREATE OR REPLACE FUNCTION sync_login_log_write(payload jsonb) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id    text := payload->>'userId';
    v_username   text;
    v_ip         inet;
    v_agent      text := payload->>'userAgent';
    v_ts         timestamptz := logto_ts(payload->>'createdAt');
    v_login_type text;
BEGIN
    IF v_user_id IS NULL THEN RETURN; END IF;

    SELECT username INTO v_username FROM users WHERE id = v_user_id;

    BEGIN
        v_ip := (payload->>'userIp')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    SELECT key INTO v_login_type
    FROM jsonb_each_text(COALESCE(payload->'user'->'identities', '{}'::jsonb))
    LIMIT 1;

    INSERT INTO login_log
        (tenant_id, user_id, username, login_type, result, ip, user_agent,
         region, logto_event, created_at)
    VALUES
        (NULL, v_user_id, v_username, COALESCE(v_login_type, 'unknown'), 'success',
         v_ip, v_agent, ip2region(v_ip), 'PostSignIn', COALESCE(v_ts, now()));
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;
COMMENT ON FUNCTION sync_login_log_write(jsonb) IS 'PostSignIn → login_log（023 重建：表名随 sys_ 前缀移除更新）';

-- ---------------------------------------------------------------------------
-- §2 iam_api 加 api_code 列（权限码，与 iam_menu.perms 对齐）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_api
    ADD COLUMN IF NOT EXISTS api_code text;
COMMENT ON COLUMN public.iam_api.api_code IS '权限码（如 sys:user:list；has_permission(code) 判定键，与 iam_menu.perms 同语义）';

CREATE UNIQUE INDEX IF NOT EXISTS idx_iam_api_code ON public.iam_api(api_code)
    WHERE api_code IS NOT NULL;

DROP VIEW IF EXISTS api_v1_sys.sys_api CASCADE;
CREATE VIEW api_v1_sys.sys_api AS
SELECT id, api_code, path, method, name, description, is_active,
       created_at, updated_at, created_by, updated_by
FROM iam_api;
COMMENT ON VIEW api_v1_sys.sys_api IS 'API 权限点目录视图（含 api_code）';

-- ---------------------------------------------------------------------------
-- §3 has_permission(code) — 授权判定核心（05 §6.3 落地，05.2 §2.1）
--     claims roles ∩ (iam_role_api → iam_api.api_code)；超管短路
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION has_permission(p_code text) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles text[];
BEGIN
    IF p_code IS NULL OR p_code = '' THEN
        RETURN false;
    END IF;

    -- 超管短路（RLS 例外同款语义）
    IF is_super_admin() THEN
        RETURN true;
    END IF;

    -- 从 JWT claims 提取角色（零查询原则：角色在 claims，绑定查小表）
    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN false;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM iam_role_api ra
        JOIN iam_api a ON a.id = ra.api_id
        WHERE ra.role_code = ANY (v_roles)
          AND a.api_code = p_code
          AND a.is_active
    );
END;
$$;
COMMENT ON FUNCTION has_permission(text) IS '权限判定：当前用户 claims roles ∩ iam_role_api → iam_api.api_code；超管短路；授权判定零查询（claims）+ 小表索引';

-- ---------------------------------------------------------------------------
-- §4 审计触发器补挂（8 张：系统管理 6 + 授权 2；镜像表不挂——webhook 可追溯）
-- ---------------------------------------------------------------------------
-- 字典（新名）
DROP TRIGGER IF EXISTS trg_audit_dict_type ON dict_type;
CREATE TRIGGER trg_audit_dict_type
    AFTER INSERT OR UPDATE OR DELETE ON dict_type
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_dict_data ON dict_data;
CREATE TRIGGER trg_audit_dict_data
    AFTER INSERT OR UPDATE OR DELETE ON dict_data
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- 岗位
DROP TRIGGER IF EXISTS trg_audit_position ON position;
CREATE TRIGGER trg_audit_position
    AFTER INSERT OR UPDATE OR DELETE ON position
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_user_position ON user_position;
CREATE TRIGGER trg_audit_user_position
    AFTER INSERT OR UPDATE OR DELETE ON user_position
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- 参数配置 / 用户扩展资料
DROP TRIGGER IF EXISTS trg_audit_app_config ON app_config;
CREATE TRIGGER trg_audit_app_config
    AFTER INSERT OR UPDATE OR DELETE ON app_config
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_user_profile ON user_profile;
CREATE TRIGGER trg_audit_user_profile
    AFTER INSERT OR UPDATE OR DELETE ON user_profile
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- 授权表（菜单/API；role_api/role_menu 已有）
DROP TRIGGER IF EXISTS trg_audit_iam_menu ON iam_menu;
CREATE TRIGGER trg_audit_iam_menu
    AFTER INSERT OR UPDATE OR DELETE ON iam_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_iam_api ON iam_api;
CREATE TRIGGER trg_audit_iam_api
    AFTER INSERT OR UPDATE OR DELETE ON iam_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- ---------------------------------------------------------------------------
-- §5 rpc_search_login_logs — 租户维度登录日志查询（05.2 §2.3）
--     RLS 无法覆盖（login_log.tenant_id 为 NULL）：SECURITY DEFINER +
--     has_permission('sys:login-log:list') + user_tenants 成员过滤
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_search_login_logs(
    p_user_id  text DEFAULT NULL,
    p_result   text DEFAULT NULL,
    p_from     timestamptz DEFAULT NULL,
    p_to       timestamptz DEFAULT NULL,
    p_limit    int DEFAULT 50,
    p_offset   int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
    v_tenant text := current_tenant_id();
BEGIN
    -- 权限门槛：超管或具备登录日志查询权限点
    IF NOT has_permission('public:login-log:list') THEN
        RAISE EXCEPTION 'permission denied'
            USING ERRCODE = '42501';
    END IF;

    IF v_tenant IS NULL THEN
        -- 无租户上下文（全局 token）：仅超管可用，此处已过 has_permission
        -- 超管查全部；否则空
        IF NOT is_super_admin() THEN
            RETURN json_build_object('total', 0, 'limit', p_limit, 'offset', p_offset, 'items', '[]'::json);
        END IF;
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM login_log l
                  WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                    AND (p_result   IS NULL OR l.result = p_result)
                    AND (p_from     IS NULL OR l.created_at >= p_from)
                    AND (p_to       IS NULL OR l.created_at <= p_to)
                    AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE((
            SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
            FROM (
                SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type,
                       l.result, l.fail_reason, l.ip, l.user_agent, l.region,
                       l.logto_event, l.created_at
                FROM login_log l
                WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                  AND (p_result   IS NULL OR l.result = p_result)
                  AND (p_from     IS NULL OR l.created_at >= p_from)
                  AND (p_to       IS NULL OR l.created_at <= p_to)
                  AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))
                ORDER BY l.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 1000)) OFFSET GREATEST(0, p_offset)
            ) u),
            '[]'::json)
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int) IS '登录日志分页查询（租户维度：本租户成员过滤；超管全量；需 sys:login-log:list 权限点）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tables int; v_fn int; v_trg int; v_api_code int;
BEGIN
    SELECT count(*) INTO v_tables FROM pg_tables
      WHERE schemaname='public' AND tablename IN ('dict_type','dict_data','login_log');
    SELECT count(*) INTO v_fn FROM pg_proc WHERE proname IN ('has_permission','rpc_search_login_logs');
    SELECT count(*) INTO v_trg FROM pg_trigger
      WHERE tgname LIKE 'trg_audit_%' AND NOT tgisinternal;
    SELECT count(*) INTO v_api_code FROM information_schema.columns
      WHERE table_schema='public' AND table_name='iam_api' AND column_name='api_code';
    RAISE NOTICE '023: 新表名=%（期望3） 函数=%（期望2） 审计触发器=%（期望11） api_code列=%（期望1）',
        v_tables, v_fn, v_trg, v_api_code;
END $$;
