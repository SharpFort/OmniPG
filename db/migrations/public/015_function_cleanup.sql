-- =============================================================================
-- 015_function_cleanup.sql — T7: 函数清理（退役 Casdoor 时代 + 更新表名引用）
-- =============================================================================
-- 背景: 014 重命名/删除表后，函数 prosrc 文本不会自动更新 → 运行时炸。
--   A. 退役删除（Casdoor 时代，05 §10.2 明确删除/不启用/有 .deprecated 源）:
--      - 会话/黑名单: check_token_blacklist / cleanup_expired_sessions /
--        force_logout_user / get_user_sessions / logout / blacklist_at_on_role_change /
--        cleanup_expired_tokens / kick_user（D12 会话管理交 Logto）
--      - RBAC 时代 RPC: assign_role_to_user / batch_assign_roles / batch_remove_roles /
--        get_role_users / get_user_roles / reject_role_request / remove_role_from_user /
--        submit_role_request / approve_role_request（角色分配移 Logto）
--      - create_user（pg_net→Casdoor 建号，05 明确删除）
--      - webhook_user_upsert / webhook_user_delete（010 已由 webhook_logto 替代）
--      - update_role_permissions（RBAC 时代）
--   B. CREATE OR REPLACE 更新（活跃业务函数，改表名引用）:
--      - get_current_user / get_dept_tree（department）
--      - get_config / get_all_public_configs / update_config（app_config）
--      - get_menu_tree_admin（iam_menu）
--      - get_user_menu（iam_menu + JWT roles 语义）
--      - current_user_dept_id（user_profile）
--      - write_audit_log / audit_trigger_func（audit_log）
--      - sync_membership_delta（app_config）
--      - import_csv（黑名单表名更新）
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 退役删除（DO 块遍历，签名无关）
-- ---------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
    FOR f IN
        SELECT n.nspname AS sch, p.proname AS fn, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('public','api_v1_sys')
          AND p.proname IN (
            'check_token_blacklist','cleanup_expired_sessions','force_logout_user',
            'get_user_sessions','logout','blacklist_at_on_role_change','cleanup_expired_tokens',
            'kick_user','assign_role_to_user','batch_assign_roles','batch_remove_roles',
            'get_role_users','get_user_roles','reject_role_request','remove_role_from_user',
            'submit_role_request','approve_role_request','create_user',
            'webhook_user_upsert','webhook_user_delete','update_role_permissions')
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE', f.sch, f.fn, f.args);
        RAISE NOTICE '015 退役: %.%(%)', f.sch, f.fn, f.args;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- §2 get_current_user — sys_user 视图(自动更新✅) + department 引用修正
--     原引用 public.sys_tenant（已删）→ 改 tenants 镜像（租户名）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.get_current_user()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id text;
    v_user RECORD;
BEGIN
    v_user_id := current_user_id();

    IF v_user_id IS NULL OR v_user_id = '' THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;

    SELECT u.id, u.username, u.primary_email AS email, u.primary_phone AS phone,
           p.tenant_id, p.dept_id, (NOT u.is_suspended) AS is_active,
           u.created_at, u.updated_at,
           t.name AS tenant_name,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM public.users u
    LEFT JOIN public.user_profile p ON p.user_id = u.id
    LEFT JOIN public.tenants t ON p.tenant_id = t.id
    LEFT JOIN public.department d ON p.dept_id = d.id
    WHERE u.id = v_user_id AND u.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;

    RETURN json_build_object(
        'id', v_user.id,
        'username', v_user.username,
        'email', v_user.email,
        'phone', v_user.phone,
        'tenant_id', v_user.tenant_id,
        'tenant_name', v_user.tenant_name,
        'dept_id', v_user.dept_id,
        'dept_name', v_user.dept_name,
        'is_active', v_user.is_active,
        'roles', v_user.roles,
        'created_at', v_user.created_at,
        'updated_at', v_user.updated_at
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_current_user() IS '获取当前登录用户信息（Logto 镜像：users+user_profile+tenants）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_current_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 get_dept_tree — department
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.get_dept_tree(p_tenant_id uuid DEFAULT NULL::uuid)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE dept_tree AS (
        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            1 AS level,
            ARRAY[d.id] AS path_ids,
            ARRAY[d.dept_name] AS path_names
        FROM public.department d
        WHERE d.parent_id IS NULL AND d.deleted_at IS NULL
          AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)

        UNION ALL

        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            dt.level + 1,
            dt.path_ids || d.id,
            dt.path_names || d.dept_name
        FROM public.department d
        JOIN dept_tree dt ON d.parent_id = dt.id
        WHERE d.deleted_at IS NULL AND dt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', id, 'dept_name', dept_name, 'parent_id', parent_id,
        'sort_order', sort_order, 'is_active', is_active, 'level', level
    ) ORDER BY level, sort_order), '[]'::json) INTO v_result
    FROM dept_tree;

    RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_dept_tree(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 get_config / get_all_public_configs / update_config — app_config
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.get_config(p_config_key text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'config_key', config_key,
        'config_value', config_value,
        'config_type', config_type
    ) INTO v_result
    FROM public.app_config
    WHERE config_key = p_config_key AND is_public = TRUE;

    RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_config(text) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.get_all_public_configs()
RETURNS json
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        json_object_agg(config_key, config_value),
        '{}'::json
    )
    FROM public.app_config
    WHERE is_public = TRUE;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_all_public_configs() TO authenticated;

-- update_config — app_config（T7 表名更新；DB 现有返回 boolean，先 DROP 再建）
DROP FUNCTION IF EXISTS api_v1_sys.update_config(text, text);
CREATE FUNCTION api_v1_sys.update_config(p_config_key text, p_config_value text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.app_config
    SET config_value = p_config_value, updated_at = now()
    WHERE config_key = p_config_key;
    RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.update_config(text, text) TO authenticated;

-- import_csv — 白名单黑名单表名更新（T7）
CREATE OR REPLACE FUNCTION api_v1_sys.import_csv(p_table_name text, p_data jsonb, p_dry_run boolean DEFAULT true)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_valid_tables text[];
    v_item jsonb;
    v_inserted int := 0;
    v_errors text[] := '{}';
    v_columns text[];
    v_values text[];
    v_sql text;
    v_key text;
    v_value text;
BEGIN
    -- 白名单校验（镜像表/日志表不可导入）
    SELECT array_agg(table_name) INTO v_valid_tables
    FROM information_schema.tables
    WHERE table_schema = 'api_v1_sys'
      AND table_type IN ('VIEW', 'BASE TABLE')
      AND table_name NOT IN ('app_config', 'audit_log', 'cron_job_log');

    IF NOT (p_table_name = ANY(v_valid_tables)) THEN
        RAISE EXCEPTION 'Table % not found or not importable', p_table_name USING ERRCODE = 'P0001';
    END IF;

    -- 验证数据
    IF jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data is empty' USING ERRCODE = 'P0005';
    END IF;

    -- 遍历每条记录
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            -- 提取列名和值
            SELECT array_agg(k), array_agg(v::text)
            INTO v_columns, v_values
            FROM jsonb_each_text(v_item) AS t(k, v);

            -- 构造 INSERT
            v_sql := format('INSERT INTO api_v1_sys.%I (%s) VALUES (%s)',
                            p_table_name,
                            (SELECT string_agg(quote_ident(c), ',') FROM unnest(v_columns) c),
                            (SELECT string_agg(quote_literal(v), ',') FROM unnest(v_values) v));

            -- 校验列存在
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'api_v1_sys' AND table_name = p_table_name
                  AND column_name = ANY(v_columns)
            ) THEN
                RAISE EXCEPTION 'Column not found in %', p_table_name USING ERRCODE = 'P0001';
            END IF;

            IF NOT p_dry_run THEN
                EXECUTE v_sql;
            END IF;
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors || format('%s: %s', v_item->>'id', SQLERRM);
        END;
    END LOOP;

    RETURN json_build_object(
        'total', jsonb_array_length(p_data),
        'inserted', v_inserted,
        'dry_run', p_dry_run,
        'errors', v_errors
    );
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.import_csv(text, jsonb, boolean) TO authenticated;
-- ---------------------------------------------------------------------------
-- §5 get_menu_tree_admin — iam_menu（列名 menu_name/path/icon/order_num）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.get_menu_tree_admin()
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM public.iam_menu m
        WHERE m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM public.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.is_active AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM menu_tree mt;

    RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_menu_tree_admin() TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 get_user_menu — Logto 语义：JWT roles（字符串数组）→ iam_role_menu → iam_menu
--     替代 Casdoor 时代 sys_user_role JOIN（05 §5.3.1：roles claim 直接消费）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_menu()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR jsonb_array_length(v_roles) = 0 THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon, m.order_num
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon, m.order_num
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.is_active
    )
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_menu_tree
    FROM (
        SELECT
            c.id, c.parent_id, c.name, c.path,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION public.get_user_menu() IS '获取用户菜单树（Logto：JWT roles → iam_role_menu → iam_menu）';

-- ---------------------------------------------------------------------------
-- §7 current_user_dept_id / write_audit_log / audit_trigger_func — 新表名
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_dept_id()
RETURNS uuid
LANGUAGE sql
STABLE PARALLEL SAFE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.dept_id
    FROM user_profile p
    WHERE p.user_id = current_user_id()
      AND p.deleted_at IS NULL
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.write_audit_log(
    p_table_name text, p_operation text,
    p_old_data jsonb DEFAULT NULL::jsonb,
    p_new_data jsonb DEFAULT NULL::jsonb,
    p_source text DEFAULT 'trigger'::text,
    p_description text DEFAULT NULL::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_tenant_id uuid;
    v_user_id text;
BEGIN
    v_tenant_id := COALESCE(
        (p_new_data->>'tenant_id')::uuid,
        (p_old_data->>'tenant_id')::uuid
    );

    v_user_id := current_user_id();

    INSERT INTO public.audit_log (
        table_name, operation, old_data, new_data, user_id, tenant_id,
        source, description, created_at
    ) VALUES (
        p_table_name, p_operation, p_old_data, p_new_data, v_user_id,
        v_tenant_id, p_source, p_description, now()
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_trigger_func()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_data jsonb;
    v_new_data jsonb;
    v_tenant_id uuid;
BEGIN
    IF TG_NARGS > 0 AND TG_ARGV[0] = 'tenant_aware' THEN
        IF (TG_OP = 'DELETE') THEN
            v_tenant_id := OLD.tenant_id;
        ELSE
            v_tenant_id := NEW.tenant_id;
        END IF;
    END IF;

    IF (TG_OP = 'DELETE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
    ELSIF (TG_OP = 'INSERT') THEN
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
    ELSIF (TG_OP = 'UPDATE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
    END IF;

    INSERT INTO audit_log (
        table_name, operation, old_data, new_data, user_id, tenant_id, created_at
    ) VALUES (
        TG_TABLE_NAME, TG_OP, v_old_data, v_new_data, current_user_id(), v_tenant_id, now()
    );

    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- §8 sync_membership_delta — app_config
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_membership_delta(org_id text, added jsonb, removed jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id text;
BEGIN
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(added)
    LOOP
        INSERT INTO user_tenants (organization_id, user_id)
        VALUES (org_id, v_user_id)
        ON CONFLICT DO NOTHING;
    END LOOP;

    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(removed)
    LOOP
        DELETE FROM user_tenants
        WHERE organization_id = org_id AND user_id = v_user_id;
    END LOOP;

    IF jsonb_array_length(added) = 5000 OR jsonb_array_length(removed) = 5000 THEN
        INSERT INTO app_config (config_key, config_value, config_type, description, is_public)
        VALUES ('reconciliation.pending_org', org_id, 'string',
                format('Membership delta capped at 5000 for org %s; full reconciliation needed', org_id),
                false)
        ON CONFLICT (config_key) DO UPDATE
        SET config_value = org_id, updated_at = now();
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §9 验证：无残留引用旧表名的活跃函数
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','api_v1_sys')
      AND p.prosrc ~ 'sys_(api|menu|tenant|secret|token_blacklist|user_session|user_legacy|role|user_role|user_profile|department|config|audit_log|cron_log)';
    RAISE NOTICE '015: 残留引用旧表名函数=%（预期 0）', v_cnt;
END $$;
