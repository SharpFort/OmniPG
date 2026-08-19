\restrict dbmate

-- Dumped from database version 18.4 (Ubuntu 18.4-1.pgdg26.04+1)
-- Dumped by pg_dump version 18.4 (Ubuntu 18.4-1.pgdg26.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api_v1; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA api_v1;


--
-- Name: SCHEMA api_v1; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA api_v1 IS 'PostgREST 暴露的业务 API Schema';


--
-- Name: api_v1_public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA api_v1_public;


--
-- Name: SCHEMA api_v1_public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA api_v1_public IS '系统管理 API 暴露层（027 定稿：视图名=底层表名；原 api_v1_sys）';


--
-- Name: api_v1_sys; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA api_v1_sys;


--
-- Name: SCHEMA api_v1_sys; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA api_v1_sys IS '系统管理 API Schema（兼容历史迁移引用；027 迁移统一收敛）';


--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- Name: graphql; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA graphql;


--
-- Name: pg_net; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA public;


--
-- Name: EXTENSION pg_net; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_net IS 'Async HTTP';


--
-- Name: pg_graphql; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_graphql WITH SCHEMA graphql;


--
-- Name: EXTENSION pg_graphql; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_graphql IS 'pg_graphql: GraphQL support';




--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: pgtap; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA public;


--
-- Name: EXTENSION pgtap; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgtap IS 'Unit testing for PostgreSQL';


--
-- Name: audit_operation; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.audit_operation AS ENUM (
    'INSERT',
    'UPDATE',
    'DELETE'
);


--
-- Name: TYPE audit_operation; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.audit_operation IS '审计操作类型';


--
-- Name: gender; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.gender AS ENUM (
    'male',
    'female',
    'other',
    'prefer_not_to_say'
);


--
-- Name: TYPE gender; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.gender IS '用户性别（user_profile.gender）: male=男 / female=女 / other=其他 / prefer_not_to_say=不愿透露（隐私友好，GDPR 惯例）';


--
-- Name: iam_menu_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.iam_menu_type AS ENUM (
    'directory',
    'menu',
    'button',
    'link'
);


--
-- Name: TYPE iam_menu_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.iam_menu_type IS '菜单类型（少变复用枚举）：directory=目录 / menu=菜单 / button=按钮 / link=外链或iframe（path 为 URL，component 留空）';


--
-- Name: request_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.request_status AS ENUM (
    'pending',
    'approved',
    'rejected'
);


--
-- Name: TYPE request_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.request_status IS '审批状态：pending=待审批, approved=已通过, rejected=已拒绝';


--
-- Name: scope_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.scope_type AS ENUM (
    'all',
    'dept_and_child',
    'self',
    'custom'
);


--
-- Name: TYPE scope_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.scope_type IS '角色数据范围: all=全部 / dept_and_child=本部门及以下 / self=仅本人 / custom=自定义部门（059 转原生 ENUM，042 CHECK 移除）';


--
-- Name: ensure_user(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.ensure_user() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_claims     jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub        text;
    v_org        text;
    v_global     text[];
    v_org_roles  text[];
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    -- N7: users 镜像完全由 webhook（User.*）维护，JIT 仅缺失补建（不覆盖权威值）
    INSERT INTO users (id, username, name, avatar)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', '')
    )
    ON CONFLICT (id) DO NOTHING;

    -- N7: profile 仅在无记录时补建（tenant 归属 = 首次观察到的组织上下文）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;

    -- D5/D6（049）: user_role 精确镜像——global/org 分段增量对齐
    --   · 增量对齐：角色不变零写入、created_at 保留首次分配时间；
    --   · 全局段（organization_id=''）：claims 恒有 global_roles（脚本注入，可为空）→ 空则清空；
    --   · 组织段：仅当本次登录携带组织上下文（v_org 非空）时对齐——全局 token 登录
    --     不清组织段（防多组织用户换上下文登录丢失镜像）；
    --   · 兼容：claims 无 global_roles/org_roles（旧 token）→ 跳过（不写不删）；
    --   · role_id 回填：role 镜像存在时按名取 id（LEFT JOIN），缺失为 NULL 等对账。
    IF v_claims ? 'global_roles' THEN
        v_global := ARRAY(SELECT jsonb_array_elements_text(v_claims->'global_roles'));
        INSERT INTO user_role (user_id, organization_id, role_code, role_id)
        SELECT v_sub, '', g, r.id
        FROM unnest(v_global) AS g
        LEFT JOIN role r ON r.name = g
        WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                          WHERE ur.user_id = v_sub
                            AND ur.organization_id = ''
                            AND ur.role_code = g);
        DELETE FROM user_role
        WHERE user_id = v_sub AND organization_id = ''
          AND role_code NOT IN (SELECT unnest(v_global));
    END IF;

    IF v_claims ? 'org_roles' THEN
        v_org_roles := ARRAY(SELECT jsonb_array_elements_text(v_claims->'org_roles'));
        IF v_org IS NOT NULL THEN
            INSERT INTO user_role (user_id, organization_id, role_code, role_id)
            SELECT v_sub, v_org, g, r.id
            FROM unnest(v_org_roles) AS g
            LEFT JOIN role r ON r.name = g
            WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                              WHERE ur.user_id = v_sub
                                AND ur.organization_id = v_org
                                AND ur.role_code = g);
            DELETE FROM user_role
            WHERE user_id = v_sub AND organization_id = v_org
              AND role_code NOT IN (SELECT unnest(v_org_roles));
        END IF;
    END IF;

    RETURN v_sub;
END;
$$;


--
-- Name: FUNCTION ensure_user(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像精确对齐（035: user_role 随 claims 全量覆盖；049 D5/D6: global/org 分段增量对齐，角色不变零写入，保留 created_at，全局 token 不清 org 段）';


--
-- Name: get_all_public_configs(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_all_public_configs() RETURNS json
    LANGUAGE sql
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT COALESCE(
        json_object_agg(config_key, config_value),
        '{}'::json
    )
    FROM public.app_config
    WHERE is_public = TRUE;
$$;


--
-- Name: FUNCTION get_all_public_configs(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_all_public_configs() IS '获取所有公开配置（前端初始化）';


--
-- Name: get_audit_log_timeline(timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_audit_log_timeline(p_start_date timestamp without time zone DEFAULT (now() - '7 days'::interval), p_end_date timestamp without time zone DEFAULT now()) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'start_date', p_start_date,
        'end_date', p_end_date,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(t.*) ORDER BY t.log_date DESC)
             FROM (
                 SELECT * FROM api_v1_public.v_audit_log_timeline
                 WHERE log_date >= p_start_date AND log_date <= p_end_date
             ) t),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION get_audit_log_timeline(p_start_date timestamp without time zone, p_end_date timestamp without time zone); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_audit_log_timeline(p_start_date timestamp without time zone, p_end_date timestamp without time zone) IS '获取审计时间线（按天聚合）';


--
-- Name: get_config(text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_config(p_config_key text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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


--
-- Name: FUNCTION get_config(p_config_key text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_config(p_config_key text) IS '获取单个公开配置';


--
-- Name: get_current_user(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_current_user() RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
           u.created_at, u.logto_updated_at AS updated_at,
           t.name AS tenant_name,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM public.users u
    LEFT JOIN public.user_profile p ON p.user_id = u.id
    LEFT JOIN public.tenants t ON p.tenant_id = t.id
    LEFT JOIN public.department d ON p.dept_id = d.id
    WHERE u.id = v_user_id;

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


--
-- Name: FUNCTION get_current_user(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_current_user() IS '获取当前登录用户信息（Logto 镜像：users+user_profile+tenants）';


--
-- Name: get_dept_tree(text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_dept_tree(p_tenant_id text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE dept_tree AS (
        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            1 AS level,
            ARRAY[d.id] AS path_ids,
            ARRAY[d.dept_name::text] AS path_names
        FROM public.department d
        WHERE d.parent_id IS NULL AND d.deleted_at IS NULL
          AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)

        UNION ALL

        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            dt.level + 1,
            dt.path_ids || d.id,
            dt.path_names || d.dept_name::text
        FROM public.department d
        JOIN dept_tree dt ON d.parent_id = dt.id
        WHERE d.deleted_at IS NULL AND dt.level < 10
    )
    SELECT COALESCE(json_agg(
        json_build_object(
            'id', dt.id,
            'dept_name', dt.dept_name,
            'parent_id', dt.parent_id,
            'sort_order', dt.sort_order,
            'is_active', dt.is_active,
            'level', dt.level,
            'path', array_to_string(dt.path_names, ' > ')
        ) ORDER BY dt.path_ids
    ), '[]'::json) INTO v_result
    FROM dept_tree dt;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION get_dept_tree(p_tenant_id text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_dept_tree(p_tenant_id text) IS '获取部门树形结构（035: p_tenant_id 改 text，对齐 department.tenant_id text 化）';


--
-- Name: get_menu_tree_admin(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_menu_tree_admin() RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM public.iam_menu m
        WHERE m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM public.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.is_active AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'menu_type', mt.menu_type, 'api_code', mt.api_code,
        'api_url', mt.api_url, 'api_method', mt.api_method, 'is_affix', mt.is_affix,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM menu_tree mt;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION get_menu_tree_admin(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_menu_tree_admin() IS '获取完整菜单树形结构（管理用），按层级和排序（055: +menu_type/api_code/api_url/api_method/is_affix——授权弹窗数据源）';


--
-- Name: get_role_permissions(text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_role_permissions(p_role_code text) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
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

    -- 055 单表化：API 授权 = 角色绑定按钮行中带端点的行
    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'path', m.api_url, 'method', m.api_method, 'api_name', m.menu_name)
        ORDER BY m.api_url
    ), '[]'::json) INTO v_apis
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active AND m.api_url IS NOT NULL;

    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.menu_name, 'parent_id', m.parent_id,
                          'path', m.router, 'icon', m.icon)
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


--
-- Name: FUNCTION get_role_permissions(p_role_code text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_role_permissions(p_role_code text) IS '获取角色权限（055 单表化: apis 段 = 角色菜单下挂接口，输出键 path/method/api_name 保持）';


--
-- Name: get_user_menu(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.get_user_menu() RETURNS json
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$ SELECT public.get_user_menu() $$;


--
-- Name: FUNCTION get_user_menu(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.get_user_menu() IS '获取用户菜单树：委托 public.get_user_menu';


--
-- Name: import_csv(text, jsonb, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.import_csv(p_table_name text, p_data jsonb, p_dry_run boolean DEFAULT true) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_allow    text[] := ARRAY['department','position','user_position',
                               'dict_type','dict_data','iam_menu'];
    v_item     jsonb;
    v_inserted int := 0;
    v_errors   text[] := '{}';
    v_cols     text;
    v_sql      text;
BEGIN
    PERFORM require_permission('public:import');

    IF NOT (p_table_name = ANY(v_allow)) THEN
        RAISE EXCEPTION 'Table % not importable. Allowed: %',
            p_table_name, array_to_string(v_allow, ', ') USING ERRCODE = 'P0001';
    END IF;

    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'array'
       OR jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data must be a non-empty JSON array' USING ERRCODE = 'P0005';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            IF jsonb_typeof(v_item) <> 'object'
               OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_item)) THEN
                RAISE EXCEPTION 'row must be a non-empty JSON object';
            END IF;

            -- 列子集插入：仅 JSON 提供的键（quote_ident 防注入），
            -- 缺失列（id/created_at 等）走表 DEFAULT——jsonb_populate_record
            -- 全列填充会把 NULL 显式传入导致 NOT NULL 冲突（PGlite 验证发现）
            v_cols := (SELECT string_agg(quote_ident(k), ', ')
                       FROM jsonb_object_keys(v_item) AS k);
            v_sql := format('INSERT INTO api_v1_public.%I (%s) ' ||
                            'SELECT %s FROM jsonb_populate_record(NULL::api_v1_public.%I, $1)',
                            p_table_name, v_cols, v_cols, p_table_name);

            IF NOT p_dry_run THEN
                EXECUTE v_sql USING v_item;
                v_inserted := v_inserted + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_errors := array_append(v_errors, format('Row %s: %s', v_item::text, SQLERRM));
        END;
    END LOOP;

    PERFORM log_operate('import', 'import', p_table_name, NULL::text, 'success',
                        jsonb_build_object('total', jsonb_array_length(p_data),
                                           'inserted', v_inserted));
    RETURN json_build_object('table', p_table_name,
                             'total', jsonb_array_length(p_data),
                             'inserted', v_inserted,
                             'errors', v_errors,
                             'dry_run', p_dry_run);
END;
$_$;


--
-- Name: FUNCTION import_csv(p_table_name text, p_data jsonb, p_dry_run boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.import_csv(p_table_name text, p_data jsonb, p_dry_run boolean) IS '通用导入（035 重写：显式业务表白名单 + jsonb_populate_record 参数化列子集；public:import）';


--
-- Name: rpc_assign_user_positions(text, uuid[], uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_assign_user_positions(p_user_id text, p_position_ids uuid[], p_primary_position_id uuid DEFAULT NULL::uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tenant text := current_tenant_id();
BEGIN
    IF NOT has_permission('public:position:assign') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 目标用户必须是本租户成员
    IF NOT EXISTS (SELECT 1 FROM user_tenants
                   WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
    END IF;
    -- 全量覆盖分配
    DELETE FROM user_position
    WHERE user_id = p_user_id AND tenant_id = v_tenant;
    IF p_position_ids IS NOT NULL THEN
        INSERT INTO user_position (user_id, position_id, tenant_id, is_primary, created_by)
        SELECT p_user_id, g, v_tenant,
               (g = p_primary_position_id), current_user_id()
        FROM unnest(p_position_ids) AS g;
    END IF;
    PERFORM log_operate('position', 'assign', 'user_position', p_user_id,
                        'success', jsonb_build_object('positions', p_position_ids));
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_assign_user_positions(p_user_id text, p_position_ids uuid[], p_primary_position_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_assign_user_positions(p_user_id text, p_position_ids uuid[], p_primary_position_id uuid) IS '用户岗位分配（全量覆盖；sys:position:assign；目标用户须为本租户成员）';


--
-- Name: rpc_create_department(text, uuid, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_create_department(p_dept_name text, p_parent_id uuid DEFAULT NULL::uuid, p_sort_order integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:dept:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dept_name IS NULL OR trim(p_dept_name) = '' THEN
        RAISE EXCEPTION 'dept_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO department (tenant_id, dept_name, parent_id, sort_order, created_by)
    VALUES (current_tenant_id(), p_dept_name, p_parent_id, p_sort_order, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dept', 'create', 'department', v_id::text,
                        'success', jsonb_build_object('name', p_dept_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;


--
-- Name: FUNCTION rpc_create_department(p_dept_name text, p_parent_id uuid, p_sort_order integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_create_department(p_dept_name text, p_parent_id uuid, p_sort_order integer) IS '部门新增（sys:dept:create）';


--
-- Name: rpc_create_dict_data(text, text, text, text, boolean, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_create_dict_data(p_dict_name text, p_item_label text, p_item_value text, p_item_type text DEFAULT 'default'::text, p_is_default boolean DEFAULT false, p_sort_no integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 字典类型必须存在，且作用域匹配当前租户（或全局超管）
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE dict_name = p_dict_name;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE dict_name = p_dict_name) THEN
            RAISE EXCEPTION 'dict type not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_data (tenant_id, dict_name, item_label, item_value,
                           item_type, is_default, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_item_label, p_item_value,
            p_item_type, p_is_default, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_data', v_id::text,
                        'success', jsonb_build_object('dict', p_dict_name, 'value', p_item_value));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;


--
-- Name: FUNCTION rpc_create_dict_data(p_dict_name text, p_item_label text, p_item_value text, p_item_type text, p_is_default boolean, p_sort_no integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_create_dict_data(p_dict_name text, p_item_label text, p_item_value text, p_item_type text, p_is_default boolean, p_sort_no integer) IS '字典数据新增（sys:dict:create；类型存在性与作用域校验）';


--
-- Name: rpc_create_dict_type(text, text, boolean, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_create_dict_type(p_dict_name text, p_dict_label text, p_tenant_scoped boolean DEFAULT false, p_sort_no integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dict_name IS NULL OR trim(p_dict_name) = '' THEN
        RAISE EXCEPTION 'dict_name required' USING ERRCODE = '22023';
    END IF;
    v_tenant := CASE WHEN p_tenant_scoped THEN current_tenant_id() ELSE NULL END;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_type (tenant_id, dict_name, dict_label, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_dict_label, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_type', v_id::text,
                        'success', jsonb_build_object('name', p_dict_name, 'tenant_scoped', p_tenant_scoped));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;


--
-- Name: FUNCTION rpc_create_dict_type(p_dict_name text, p_dict_label text, p_tenant_scoped boolean, p_sort_no integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_create_dict_type(p_dict_name text, p_dict_label text, p_tenant_scoped boolean, p_sort_no integer) IS '字典类型新增（sys:dict:create；全局字典仅超管）';


--
-- Name: rpc_create_menu(text, uuid, text, text, text, text, text, integer, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_create_menu(p_menu_name text, p_parent_id uuid DEFAULT NULL::uuid, p_menu_type text DEFAULT 'menu'::text, p_api_code text DEFAULT NULL::text, p_router text DEFAULT NULL::text, p_component text DEFAULT NULL::text, p_icon text DEFAULT NULL::text, p_order_num integer DEFAULT 0, p_is_visible boolean DEFAULT true, p_remark text DEFAULT NULL::text, p_route_name text DEFAULT NULL::text, p_is_link boolean DEFAULT NULL::boolean, p_is_iframe boolean DEFAULT NULL::boolean, p_redirect text DEFAULT NULL::text, p_is_cache boolean DEFAULT NULL::boolean, p_api_url text DEFAULT NULL::text, p_api_method text DEFAULT NULL::text, p_is_affix boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:menu:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_name IS NULL OR trim(p_menu_name) = '' THEN
        RAISE EXCEPTION 'menu_name required' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：button 必须 api_code
    IF p_menu_type = 'button' AND (p_api_code IS NULL OR trim(p_api_code) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：button 行禁传导航字段（RPC 友好报错 + 表级 CHECK 兜底）
    IF p_menu_type = 'button' AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    -- 端点仅 button 行使用（Admin.NET CheckMenuParam 语义：非 Btn 行不落端点）
    IF p_menu_type <> 'button' AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, api_code, router, component,
                          icon, order_num, is_visible,
                          remark, route_name,
                          is_link, is_iframe, redirect, is_cache,
                          api_url, api_method, is_affix, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type,
            CASE WHEN p_menu_type = 'button' THEN p_api_code ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_router END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_component END,
            p_icon, p_order_num, p_is_visible,
            p_remark,
            -- 056 B2：手填优先；否则 directory/menu 行按 router 末段推导
            -- （button 行 router 恒 NULL、link 行 router 为外链 URL，均不推导）
            COALESCE(p_route_name,
                     CASE WHEN p_menu_type IN ('directory','menu')
                          THEN public.derive_route_name(p_router) END),
            COALESCE(p_is_link, p_menu_type = 'link'), COALESCE(p_is_iframe, false),
            p_redirect, COALESCE(p_is_cache, true),
            CASE WHEN p_menu_type = 'button' THEN p_api_url ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN p_api_method ELSE NULL END,
            COALESCE(p_is_affix, false), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;


--
-- Name: FUNCTION rpc_create_menu(p_menu_name text, p_parent_id uuid, p_menu_type text, p_api_code text, p_router text, p_component text, p_icon text, p_order_num integer, p_is_visible boolean, p_remark text, p_route_name text, p_is_link boolean, p_is_iframe boolean, p_redirect text, p_is_cache boolean, p_api_url text, p_api_method text, p_is_affix boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_create_menu(p_menu_name text, p_parent_id uuid, p_menu_type text, p_api_code text, p_router text, p_component text, p_icon text, p_order_num integer, p_is_visible boolean, p_remark text, p_route_name text, p_is_link boolean, p_is_iframe boolean, p_redirect text, p_is_cache boolean, p_api_url text, p_api_method text, p_is_affix boolean) IS '菜单新增（public:menu:create；057: p_keep_alive→p_is_cache；056: -p_query +route_name 推导兜底；055: +api_url/api_method/is_affix）';


--
-- Name: rpc_create_position(text, uuid, text, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_create_position(p_pos_name text, p_parent_id uuid DEFAULT NULL::uuid, p_pos_code text DEFAULT NULL::text, p_sort_no integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:position:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_pos_name IS NULL OR trim(p_pos_name) = '' THEN
        RAISE EXCEPTION 'pos_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO position (tenant_id, pos_name, pos_code, parent_id, sort_no, created_by)
    VALUES (current_tenant_id(), p_pos_name, p_pos_code, p_parent_id, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('position', 'create', 'position', v_id::text,
                        'success', jsonb_build_object('name', p_pos_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;


--
-- Name: FUNCTION rpc_create_position(p_pos_name text, p_parent_id uuid, p_pos_code text, p_sort_no integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_create_position(p_pos_name text, p_parent_id uuid, p_pos_code text, p_sort_no integer) IS '岗位新增（sys:position:create）';


--
-- Name: rpc_delete_department(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_delete_department(p_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:dept:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM department
               WHERE parent_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_profile
               WHERE dept_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM department WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('dept', 'delete', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_delete_department(p_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_delete_department(p_id uuid) IS '部门删除（sys:dept:delete；有子部门/关联用户拒绝）';


--
-- Name: rpc_delete_dict_data(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_delete_dict_data(p_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_data WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    DELETE FROM dict_data WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_delete_dict_data(p_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_delete_dict_data(p_id uuid) IS '字典数据删除（sys:dict:delete）';


--
-- Name: rpc_delete_dict_type(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_delete_dict_type(p_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tenant text; v_name text;
BEGIN
    IF NOT has_permission('public:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id, dict_name INTO v_tenant, v_name FROM dict_type WHERE id = p_id;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    IF v_tenant IS NOT NULL AND v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 级联删除同作用域的数据项（dict_data 无 FK，手动清理）
    DELETE FROM dict_data WHERE dict_name = v_name
        AND tenant_id IS NOT DISTINCT FROM v_tenant;
    DELETE FROM dict_type WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_type', p_id::text,
                        'success', jsonb_build_object('name', v_name));
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_delete_dict_type(p_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_delete_dict_type(p_id uuid) IS '字典类型删除（sys:dict:delete；级联清理同作用域数据项）';


--
-- Name: rpc_delete_menu(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_delete_menu(p_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:menu:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM iam_menu WHERE parent_id = p_id) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM iam_role_menu WHERE menu_id = p_id;
    DELETE FROM iam_menu WHERE id = p_id;
    PERFORM log_operate('menu', 'delete', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_delete_menu(p_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_delete_menu(p_id uuid) IS '菜单删除（sys:menu:delete；有子菜单拒绝；级联清绑定）';


--
-- Name: rpc_delete_position(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_delete_position(p_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:position:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM position
               WHERE parent_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_position
               WHERE position_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM position WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'delete', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_delete_position(p_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_delete_position(p_id uuid) IS '岗位删除（sys:position:delete；有子岗位/关联用户拒绝）';


--
-- Name: rpc_get_position_tree(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_get_position_tree() RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('public:position:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    WITH RECURSIVE tree AS (
        SELECT id, parent_id, pos_name, pos_code, sort_no, status,
               1 AS depth, pos_name::text AS path_name
        FROM position
        WHERE parent_id IS NULL AND tenant_id = current_tenant_id()
        UNION ALL
        SELECT p.id, p.parent_id, p.pos_name, p.pos_code, p.sort_no, p.status,
               t.depth + 1, t.path_name::text || ' / ' || p.pos_name::text
        FROM position p JOIN tree t ON p.parent_id = t.id
        WHERE p.tenant_id = current_tenant_id()
    )
    SELECT json_agg(row_to_json(x) ORDER BY x.path_name)
      INTO v_result
    FROM (SELECT id, parent_id, pos_name, pos_code, sort_no, status, depth, path_name
          FROM tree) x;
    RETURN COALESCE(v_result, '[]'::json);
END $$;


--
-- Name: FUNCTION rpc_get_position_tree(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_get_position_tree() IS '岗位树（递归 CTE + 层级路径；sys:position:list；替代 v_position_tree 视图方案）';


--
-- Name: rpc_get_role_data_scope(text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_get_role_data_scope(p_role_code text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_scope_type text;
    v_depts      json;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT min(scope_type) INTO v_scope_type
    FROM iam_role_data_scope WHERE role_code = p_role_code;
    -- custom 可多行，取任意非 NULL 类型即该角色类型（约束保证同角色类型一致）

    SELECT COALESCE(json_agg(json_build_object('id', d.id, 'name', d.dept_name)
                             ORDER BY d.dept_name), '[]'::json) INTO v_depts
    FROM iam_role_data_scope rs
    JOIN department d ON d.id = rs.dept_id
    WHERE rs.role_code = p_role_code AND rs.dept_id IS NOT NULL;

    RETURN json_build_object(
        'role_code', p_role_code,
        'scope_type', COALESCE(v_scope_type, 'self'),
        'depts', v_depts);
END;
$$;


--
-- Name: FUNCTION rpc_get_role_data_scope(p_role_code text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_get_role_data_scope(p_role_code text) IS '角色数据范围查询（sys:data-scope:bind；默认 self）';


--
-- Name: rpc_get_user_profile(text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_get_user_profile(p_user_id text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_row json; v_tenant text := current_tenant_id();
BEGIN
    -- 本人 / 超管 / 本租户成员（管理端查看）
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'user_id required' USING ERRCODE = '22023';
    END IF;
    IF p_user_id <> current_user_id() AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT COALESCE(row_to_json(p), '{}'::json) INTO v_row
    FROM user_profile p WHERE p.user_id = p_user_id;
    RETURN COALESCE(v_row, '{}'::json);
END $$;


--
-- Name: FUNCTION rpc_get_user_profile(p_user_id text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_get_user_profile(p_user_id text) IS '用户资料查询（本人/超管/本租户成员）';


--
-- Name: rpc_get_user_roles(text, text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_get_user_roles(p_user_id text, p_org_id text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_org        text;
    v_global     json;
    v_org_roles  json;
BEGIN
    IF NOT has_permission('public:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    -- 同租户约束：跨租户查询仅超管可越权
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_global
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = '') x;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_org_roles
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = v_org) x;

    RETURN json_build_object(
        'user_id',  p_user_id,
        'org_id',   v_org,
        'global_roles', v_global,
        'org_roles',    v_org_roles
    );
END $$;


--
-- Name: FUNCTION rpc_get_user_roles(p_user_id text, p_org_id text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_get_user_roles(p_user_id text, p_org_id text) IS '用户角色分配查询（N14: SECURITY DEFINER + sys:tenant-member:list + 同租户约束；global 段 + 当前 org 段）';


--
-- Name: rpc_list_cron_job_runs(integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_list_cron_job_runs(p_limit integer DEFAULT 100) RETURNS TABLE(runid bigint, jobid bigint, status text, return_message text, start_time timestamp with time zone, end_time timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
    FROM cron.job_run_details d
    ORDER BY d.runid DESC
    LIMIT GREATEST(1, LEAST(p_limit, 1000));
END;
$$;


--
-- Name: FUNCTION rpc_list_cron_job_runs(p_limit integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_list_cron_job_runs(p_limit integer) IS 'pg_cron 运行历史只读查询（超管，默认最近 100 条，上限 1000）';


--
-- Name: rpc_list_cron_jobs(); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_list_cron_jobs() RETURNS TABLE(jobid bigint, jobname text, schedule text, command text, nodename text, nodeport integer, database text, username text, active boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    -- 仅超管可查看任务定义（平台级运维信息，非租户级）
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT c.jobid, c.jobname, c.schedule, c.command, c.nodename, c.nodeport,
           c.database, c.username, c.active
    FROM cron.job c
    ORDER BY c.jobid;
END;
$$;


--
-- Name: FUNCTION rpc_list_cron_jobs(); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_list_cron_jobs() IS 'pg_cron 任务定义只读查询（超管）；管理端"查看已设置任务"用';


--
-- Name: rpc_list_tenant_members(text, text, integer, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_list_tenant_members(p_org_id text DEFAULT NULL::text, p_query text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result json; v_org text;
BEGIN
    IF NOT has_permission('public:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM user_tenants ut
                  WHERE ut.organization_id = v_org
                    AND (p_query IS NULL OR EXISTS (
                        SELECT 1 FROM users u WHERE u.id = ut.user_id
                        AND (u.username ILIKE '%' || p_query || '%'
                          OR u.primary_email ILIKE '%' || p_query || '%')))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.joined_at DESC)
            FROM (
                SELECT u.id AS user_id, u.username, u.primary_email AS email,
                       u.primary_phone AS phone, u.name, u.avatar,
                       (NOT u.is_suspended) AS is_active,
                       ut.joined_at
                FROM user_tenants ut
                JOIN users u ON u.id = ut.user_id
                WHERE ut.organization_id = v_org
                  AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%')
                ORDER BY ut.joined_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;


--
-- Name: FUNCTION rpc_list_tenant_members(p_org_id text, p_query text, p_limit integer, p_offset integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_list_tenant_members(p_org_id text, p_query text, p_limit integer, p_offset integer) IS '租户成员列表（035: 上限统一 100；sys:tenant-member:list）';


--
-- Name: rpc_list_tenants(text, integer, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_list_tenants(p_query text DEFAULT NULL::text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('public:tenant:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT json_build_object(
        'total', (SELECT count(*) FROM tenants t
                  WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT t.id, t.name, t.description, t.created_at,
                       (SELECT count(*) FROM user_tenants ut
                        WHERE ut.organization_id = t.id) AS member_count
                FROM tenants t
                WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'
                ORDER BY t.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;


--
-- Name: FUNCTION rpc_list_tenants(p_query text, p_limit integer, p_offset integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_list_tenants(p_query text, p_limit integer, p_offset integer) IS '租户列表（035: 上限统一 100；sys:tenant:list）';


--
-- Name: rpc_list_webhook_events(text, integer, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_list_webhook_events(p_result text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_rows  json;
    v_total int;
BEGIN
    PERFORM require_super_admin();
    IF p_result IS NOT NULL AND p_result NOT IN ('received','success','error','ignored') THEN
        RAISE EXCEPTION 'invalid result filter' USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO v_total
    FROM webhook_event_log
    WHERE p_result IS NULL OR result = p_result;

    SELECT COALESCE(json_agg(x ORDER BY x.created_at DESC), '[]'::json) INTO v_rows
    FROM (
        SELECT id, hook_id, event, logto_created, result, error, created_at, payload
        FROM webhook_event_log
        WHERE p_result IS NULL OR result = p_result
        ORDER BY created_at DESC
        LIMIT GREATEST(1, LEAST(p_limit, 100))
        OFFSET GREATEST(0, p_offset)
    ) x;

    RETURN json_build_object('total', v_total, 'rows', v_rows);
END;
$$;


--
-- Name: FUNCTION rpc_list_webhook_events(p_result text, p_limit integer, p_offset integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_list_webhook_events(p_result text, p_limit integer, p_offset integer) IS 'webhook 事件日志列表（超管专属；result 过滤 + 分页上限 100）';


--
-- Name: rpc_replay_webhook_event(uuid); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_replay_webhook_event(p_event_id uuid) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_payload jsonb;
    v_event   text;
    v_res     jsonb;
BEGIN
    PERFORM require_super_admin();
    SELECT payload, event INTO v_payload, v_event
    FROM webhook_event_log WHERE id = p_event_id;
    IF v_payload IS NULL THEN
        RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
    END IF;

    v_res := api_v1_public.webhook_logto(v_payload);
    PERFORM log_operate('webhook', 'replay', 'webhook_event_log', p_event_id::text,
                        'success', jsonb_build_object('event', v_event, 'result', v_res));
    RETURN json_build_object('ok', true, 'event', v_event, 'replay', v_res);
END;
$$;


--
-- Name: FUNCTION rpc_replay_webhook_event(p_event_id uuid); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_replay_webhook_event(p_event_id uuid) IS '重放指定 webhook 事件（超管专属；payload 重喂 webhook_logto，sync_* 幂等；重放结果新落一行）';


--
-- Name: rpc_search_login_logs(text, text, timestamp with time zone, timestamp with time zone, integer, integer, text, text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_search_login_logs(p_user_id text DEFAULT NULL::text, p_result text DEFAULT NULL::text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_login_type text DEFAULT NULL::text, p_region text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
    v_tenant text := current_tenant_id();
BEGIN
    -- 权限门槛：超管或具备登录日志查询权限点（023 原逻辑）
    IF NOT has_permission('public:login-log:list') THEN
        RAISE EXCEPTION 'permission denied'
            USING ERRCODE = '42501';
    END IF;

    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RETURN json_build_object('total', 0, 'limit', p_limit, 'offset', p_offset, 'items', '[]'::json);
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM login_log l
                  WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                    AND (p_result   IS NULL OR l.result = p_result)
                    AND (p_login_type IS NULL OR l.login_type ILIKE '%' || p_login_type || '%')
                    AND (p_region     IS NULL OR l.region ILIKE '%' || p_region || '%')
                    AND (p_from     IS NULL OR l.created_at >= p_from)
                    AND (p_to       IS NULL OR l.created_at <= p_to)
                    AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
            FROM (
                SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type,
                       l.result, l.fail_reason, l.ip, l.user_agent, l.region,
                       l.logto_event, l.created_at
                FROM login_log l
                WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                  AND (p_result   IS NULL OR l.result = p_result)
                  AND (p_login_type IS NULL OR l.login_type ILIKE '%' || p_login_type || '%')
                  AND (p_region     IS NULL OR l.region ILIKE '%' || p_region || '%')
                  AND (p_from     IS NULL OR l.created_at >= p_from)
                  AND (p_to       IS NULL OR l.created_at <= p_to)
                  AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))
                ORDER BY l.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) u),
            '[]'::json)
    ) INTO v_result;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION rpc_search_login_logs(p_user_id text, p_result text, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer, p_login_type text, p_region text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_search_login_logs(p_user_id text, p_result text, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer, p_login_type text, p_region text) IS '登录日志分页查询（037: 新增登录方式/地区模糊过滤；035: 上限统一 100；sys:login-log:list；租户成员过滤）';


--
-- Name: rpc_set_role_data_scope(text, text, uuid[]); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_set_role_data_scope(p_role_code text, p_scope_type text, p_dept_ids uuid[] DEFAULT NULL::uuid[]) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_dept uuid;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 角色校验同 041（镜像表 OR 已有绑定——镜像同步缺口兜底）
    IF p_role_code IS NULL OR NOT (
        EXISTS (SELECT 1 FROM role WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_api WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_menu WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_data_scope WHERE role_code = p_role_code)
    ) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_scope_type IS NULL OR p_scope_type NOT IN ('all','dept_and_child','self','custom') THEN
        RAISE EXCEPTION 'invalid scope_type' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type = 'custom' AND (p_dept_ids IS NULL OR cardinality(p_dept_ids) = 0) THEN
        RAISE EXCEPTION 'custom scope requires dept_ids' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type <> 'custom' AND p_dept_ids IS NOT NULL AND cardinality(p_dept_ids) > 0 THEN
        RAISE EXCEPTION 'non-custom scope cannot carry dept_ids' USING ERRCODE = '22023';
    END IF;

    -- 全量覆盖（单事务）
    DELETE FROM iam_role_data_scope WHERE role_code = p_role_code;
    IF p_scope_type = 'custom' THEN
        FOREACH v_dept IN ARRAY p_dept_ids LOOP
            IF NOT EXISTS (SELECT 1 FROM department WHERE id = v_dept AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'dept not found: %', v_dept USING ERRCODE = 'P0002';
            END IF;
            INSERT INTO iam_role_data_scope (role_code, scope_type, dept_id, created_by)
            VALUES (p_role_code, 'custom', v_dept, current_user_id());
        END LOOP;
    ELSE
        INSERT INTO iam_role_data_scope (role_code, scope_type, created_by)
        VALUES (p_role_code, p_scope_type, current_user_id());
    END IF;

    PERFORM log_operate('role', 'set-data-scope', 'iam_role_data_scope',
                        p_role_code, 'success',
                        jsonb_build_object('scope_type', p_scope_type, 'dept_count', coalesce(cardinality(p_dept_ids), 0)));
    RETURN json_build_object('ok', true);
END;
$$;


--
-- Name: FUNCTION rpc_set_role_data_scope(p_role_code text, p_scope_type text, p_dept_ids uuid[]); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_set_role_data_scope(p_role_code text, p_scope_type text, p_dept_ids uuid[]) IS '角色数据范围设置（全量覆盖；sys:data-scope:bind；custom 须 dept_ids 且部门存在）';


--
-- Name: rpc_set_role_menus(text, uuid[]); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_set_role_menus(p_role_code text, p_menu_ids uuid[]) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:role-menu:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_role_code IS NULL OR NOT EXISTS (SELECT 1 FROM role WHERE name = p_role_code) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM iam_role_menu WHERE role_code = p_role_code;
    IF p_menu_ids IS NOT NULL THEN
        INSERT INTO iam_role_menu (role_code, menu_id, created_by)
        SELECT p_role_code, g, current_user_id()
        FROM unnest(p_menu_ids) AS g
        ON CONFLICT (role_code, menu_id) DO NOTHING;
    END IF;
    PERFORM log_operate('role', 'bind-menus', 'role', p_role_code,
                        'success', jsonb_build_object('menu_ids', p_menu_ids));
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_set_role_menus(p_role_code text, p_menu_ids uuid[]); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_set_role_menus(p_role_code text, p_menu_ids uuid[]) IS '角色→菜单绑定（全量覆盖；sys:role-menu:bind）';


--
-- Name: rpc_update_department(uuid, uuid, text, integer, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_department(p_id uuid, p_parent_id uuid DEFAULT NULL::uuid, p_dept_name text DEFAULT NULL::text, p_sort_order integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:dept:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM department
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'dept not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE department SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        dept_name   = COALESCE(p_dept_name, dept_name),
        sort_order  = COALESCE(p_sort_order, sort_order),
        is_active   = COALESCE(p_is_active, is_active),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('dept', 'update', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_update_department(p_id uuid, p_parent_id uuid, p_dept_name text, p_sort_order integer, p_is_active boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_department(p_id uuid, p_parent_id uuid, p_dept_name text, p_sort_order integer, p_is_active boolean) IS '部门修改（sys:dept:update）';


--
-- Name: rpc_update_dict_data(uuid, text, text, text, boolean, integer, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_dict_data(p_id uuid, p_item_label text DEFAULT NULL::text, p_item_value text DEFAULT NULL::text, p_item_type text DEFAULT NULL::text, p_is_default boolean DEFAULT NULL::boolean, p_sort_no integer DEFAULT NULL::integer, p_status boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_data WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_data SET
        item_label = COALESCE(p_item_label, item_label),
        item_value = COALESCE(p_item_value, item_value),
        item_type  = COALESCE(p_item_type, item_type),
        is_default = COALESCE(p_is_default, is_default),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_update_dict_data(p_id uuid, p_item_label text, p_item_value text, p_item_type text, p_is_default boolean, p_sort_no integer, p_status boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_dict_data(p_id uuid, p_item_label text, p_item_value text, p_item_type text, p_is_default boolean, p_sort_no integer, p_status boolean) IS '字典数据修改（sys:dict:update）';


--
-- Name: rpc_update_dict_type(uuid, text, integer, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_dict_type(p_id uuid, p_dict_label text DEFAULT NULL::text, p_sort_no integer DEFAULT NULL::integer, p_status boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_type SET
        dict_label = COALESCE(p_dict_label, dict_label),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_type', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_update_dict_type(p_id uuid, p_dict_label text, p_sort_no integer, p_status boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_dict_type(p_id uuid, p_dict_label text, p_sort_no integer, p_status boolean) IS '字典类型修改（sys:dict:update；租户/全局作用域校验）';


--
-- Name: rpc_update_menu(uuid, uuid, text, text, text, text, text, text, integer, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_menu(p_id uuid, p_parent_id uuid DEFAULT NULL::uuid, p_menu_name text DEFAULT NULL::text, p_menu_type text DEFAULT NULL::text, p_api_code text DEFAULT NULL::text, p_router text DEFAULT NULL::text, p_component text DEFAULT NULL::text, p_icon text DEFAULT NULL::text, p_order_num integer DEFAULT NULL::integer, p_is_active boolean DEFAULT NULL::boolean, p_is_visible boolean DEFAULT NULL::boolean, p_remark text DEFAULT NULL::text, p_route_name text DEFAULT NULL::text, p_is_link boolean DEFAULT NULL::boolean, p_is_iframe boolean DEFAULT NULL::boolean, p_redirect text DEFAULT NULL::text, p_is_cache boolean DEFAULT NULL::boolean, p_api_url text DEFAULT NULL::text, p_api_method text DEFAULT NULL::text, p_is_affix boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_api_code  text;
BEGIN
    IF NOT has_permission('public:menu:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam_menu WHERE id = p_id) THEN
        RAISE EXCEPTION 'menu not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type IS NOT NULL AND p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    SELECT menu_type, api_code INTO v_menu_type, v_api_code FROM iam_menu WHERE id = p_id;
    -- 040 单码制：最终类型为 button 必须 api_code
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (COALESCE(p_api_code, v_api_code) IS NULL OR trim(COALESCE(p_api_code, v_api_code)) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：最终类型为 button 禁传导航字段
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) <> 'button'::iam_menu_type)
       AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type::iam_menu_type, menu_type),
        -- 055：字段归属按最终类型（Admin.NET CheckMenuParam 语义）
        api_code    = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_code, api_code) ELSE NULL END,
        router      = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_router, router) END,
        component   = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_component, component) END,
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        remark      = COALESCE(p_remark, remark),
        -- 056 B2：button 行清空（导航字段族同 D8）；手填值优先；
        --         directory/menu 行改 router 未传 route_name 时按新 router 重新推导
        route_name  = CASE
            WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                THEN NULL
            WHEN p_route_name IS NOT NULL
                THEN p_route_name
            WHEN p_router IS NOT NULL
             AND COALESCE(p_menu_type::iam_menu_type, v_menu_type) IN ('directory'::iam_menu_type, 'menu'::iam_menu_type)
                THEN public.derive_route_name(p_router)
            ELSE route_name
        END,
        is_link     = COALESCE(p_is_link, p_menu_type = 'link', is_link),
        is_iframe   = COALESCE(p_is_iframe, is_iframe),
        redirect    = COALESCE(p_redirect, redirect),
        is_cache    = COALESCE(p_is_cache, is_cache),
        api_url     = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_url, api_url) ELSE NULL END,
        api_method  = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_method, api_method) ELSE NULL END,
        is_affix    = COALESCE(p_is_affix, is_affix),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_update_menu(p_id uuid, p_parent_id uuid, p_menu_name text, p_menu_type text, p_api_code text, p_router text, p_component text, p_icon text, p_order_num integer, p_is_active boolean, p_is_visible boolean, p_remark text, p_route_name text, p_is_link boolean, p_is_iframe boolean, p_redirect text, p_is_cache boolean, p_api_url text, p_api_method text, p_is_affix boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_menu(p_id uuid, p_parent_id uuid, p_menu_name text, p_menu_type text, p_api_code text, p_router text, p_component text, p_icon text, p_order_num integer, p_is_active boolean, p_is_visible boolean, p_remark text, p_route_name text, p_is_link boolean, p_is_iframe boolean, p_redirect text, p_is_cache boolean, p_api_url text, p_api_method text, p_is_affix boolean) IS '菜单修改（public:menu:update；057: p_keep_alive→p_is_cache；056: -p_query +route_name 推导兜底/button 清空；055: 字段归属按最终类型）';


--
-- Name: rpc_update_position(uuid, uuid, text, text, integer, boolean); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_position(p_id uuid, p_parent_id uuid DEFAULT NULL::uuid, p_pos_name text DEFAULT NULL::text, p_pos_code text DEFAULT NULL::text, p_sort_no integer DEFAULT NULL::integer, p_status boolean DEFAULT NULL::boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:position:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM position
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'position not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE position SET
        parent_id  = COALESCE(p_parent_id, parent_id),
        pos_name   = COALESCE(p_pos_name, pos_name),
        pos_code   = COALESCE(p_pos_code, pos_code),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'update', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;


--
-- Name: FUNCTION rpc_update_position(p_id uuid, p_parent_id uuid, p_pos_name text, p_pos_code text, p_sort_no integer, p_status boolean); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_position(p_id uuid, p_parent_id uuid, p_pos_name text, p_pos_code text, p_sort_no integer, p_status boolean) IS '岗位修改（sys:position:update）';


--
-- Name: rpc_update_user_profile(text, jsonb); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.rpc_update_user_profile(p_user_id text, p_updates jsonb) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_tenant text := current_tenant_id();
    v_self   boolean;
    v_sql    text;
    v_col    text;
BEGIN
    IF p_user_id IS NULL OR p_updates IS NULL THEN
        RAISE EXCEPTION 'user_id and updates required' USING ERRCODE = '22023';
    END IF;
    -- 权限：本人改自己（免权限点）或超管/本租户管理成员（需权限点）
    v_self := (p_user_id = current_user_id());
    IF NOT v_self THEN
        IF NOT has_permission('public:profile:update') THEN
            RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
        END IF;
        IF NOT is_super_admin()
           AND NOT EXISTS (SELECT 1 FROM user_tenants
                           WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
            RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- 动态列白名单：仅允许 user_profile 的业务列（排除主键/租户/审计列）
    FOR v_col IN
        SELECT c.column_name
        FROM information_schema.columns c
        WHERE c.table_schema = 'public' AND c.table_name = 'user_profile'
          AND c.column_name NOT IN
              ('user_id','tenant_id','dept_id','created_at','updated_at',
               'deleted_at','created_by','updated_by','deleted_by')
          AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
    LOOP
        v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L, updated_at = now(), updated_by = %L WHERE user_id = %L',
                        v_col, v_col, current_user_id(), p_user_id);
        EXECUTE v_sql USING p_updates;
    END LOOP;
    -- 档案行不存在则建档（JIT 语义）
    IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM user_profile WHERE user_id = p_user_id) THEN
        INSERT INTO user_profile (user_id, tenant_id, created_by)
        VALUES (p_user_id, v_tenant, current_user_id());
        -- 再执行一次白名单更新（简化：仅重放首轮）
        FOR v_col IN
            SELECT c.column_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'public' AND c.table_name = 'user_profile'
              AND c.column_name NOT IN
                  ('user_id','tenant_id','dept_id','created_at','updated_at',
                   'deleted_at','created_by','updated_by','deleted_by')
              AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
        LOOP
            v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L WHERE user_id = %L',
                            v_col, v_col, p_user_id);
            EXECUTE v_sql USING p_updates;
        END LOOP;
    END IF;
    PERFORM log_operate('profile', 'update', 'user_profile', p_user_id,
                        'success', p_updates);
    RETURN json_build_object('ok', true);
END $_$;


--
-- Name: FUNCTION rpc_update_user_profile(p_user_id text, p_updates jsonb); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.rpc_update_user_profile(p_user_id text, p_updates jsonb) IS '用户资料更新（本人免权限点；管理他人需 sys:profile:update；动态列白名单）';


--
-- Name: search_audit_log(text, text, text, timestamp with time zone, timestamp with time zone, integer, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.search_audit_log(p_query text DEFAULT NULL::text, p_table_name text DEFAULT NULL::text, p_operation text DEFAULT NULL::text, p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_public.v_audit_log_detail
                  WHERE (p_table_name IS NULL OR table_name ILIKE '%' || p_table_name || '%')
                    AND (p_operation IS NULL OR operation = p_operation)
                    AND (p_start_date IS NULL OR created_at >= p_start_date)
                    AND (p_end_date IS NULL OR created_at <= p_end_date)
                    AND (p_query IS NULL OR username ILIKE '%' || p_query || '%'
                         OR old_data::text ILIKE '%' || p_query || '%'
                         OR new_data::text ILIKE '%' || p_query || '%')),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(a.*) ORDER BY a.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_public.v_audit_log_detail
                 WHERE (p_table_name IS NULL OR table_name ILIKE '%' || p_table_name || '%')
                   AND (p_operation IS NULL OR operation = p_operation)
                   AND (p_start_date IS NULL OR created_at >= p_start_date)
                   AND (p_end_date IS NULL OR created_at <= p_end_date)
                   AND (p_query IS NULL OR username ILIKE '%' || p_query || '%'
                         OR old_data::text ILIKE '%' || p_query || '%'
                         OR new_data::text ILIKE '%' || p_query || '%')
                 ORDER BY created_at DESC
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) a),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION search_audit_log(p_query text, p_table_name text, p_operation text, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_limit integer, p_offset integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.search_audit_log(p_query text, p_table_name text, p_operation text, p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_limit integer, p_offset integer) IS '搜索审计日志（036: 时间范围/操作人/表名模糊；035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';


--
-- Name: search_users(text, text, uuid, integer, integer); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.search_users(p_query text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_dept_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_public.v_user_list u2
                  WHERE (p_query IS NULL OR u2.username ILIKE '%' || p_query || '%' OR u2.email ILIKE '%' || p_query || '%')
                    AND (p_status IS NULL OR (p_status = 'active' AND u2.is_active = TRUE) OR (p_status = 'inactive' AND u2.is_active = FALSE))
                    AND (p_dept_id IS NULL OR u2.dept_id = p_dept_id)),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_public.v_user_list u2
                 WHERE (p_query IS NULL OR u2.username ILIKE '%' || p_query || '%' OR u2.email ILIKE '%' || p_query || '%')
                   AND (p_status IS NULL OR (p_status = 'active' AND u2.is_active = TRUE) OR (p_status = 'inactive' AND u2.is_active = FALSE))
                   AND (p_dept_id IS NULL OR u2.dept_id = p_dept_id)
                 ORDER BY u2.created_at DESC
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) u),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;


--
-- Name: FUNCTION search_users(p_query text, p_status text, p_dept_id uuid, p_limit integer, p_offset integer); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.search_users(p_query text, p_status text, p_dept_id uuid, p_limit integer, p_offset integer) IS '分页搜索用户（035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';


--
-- Name: update_config(text, text); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.update_config(p_config_key text, p_config_value text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission('public:config:write') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    UPDATE public.app_config
    SET config_value = p_config_value, updated_at = now()
    WHERE config_key = p_config_key;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Config key not found: %', p_config_key USING ERRCODE = 'P0001';
    END IF;

    PERFORM log_operate('config', 'update', 'app_config', p_config_key);
    RETURN TRUE;
END;
$$;


--
-- Name: FUNCTION update_config(p_config_key text, p_config_value text); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.update_config(p_config_key text, p_config_value text) IS '更新系统配置（public:config:write；029 补门槛，035 源文件同步）';


--
-- Name: webhook_logto(jsonb); Type: FUNCTION; Schema: api_v1_public; Owner: -
--

CREATE FUNCTION api_v1_public.webhook_logto(jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_event  text := $1->>'event';
    v_data   jsonb := $1->'data';
    v_log_id uuid;
    v_failed boolean := false;
BEGIN
    -- N6: 事件落库（received；日志写入失败不阻断处理）
    BEGIN
        INSERT INTO webhook_event_log (hook_id, event, logto_created, payload)
        VALUES ($1->>'hookId', v_event, logto_ts($1->>'createdAt'), $1)
        RETURNING id INTO v_log_id;
    EXCEPTION WHEN OTHERS THEN
        v_log_id := NULL;
    END;

    CASE v_event
        -- ═══ 用户事件 ═══
        WHEN 'User.Created' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Data.Updated' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Deleted' THEN
            -- N1: data=null，删除 ID 在 params；三键兜底
            PERFORM sync_user_delete(
                COALESCE($1->'params'->>'userId', $1->'params'->>'id', v_data->>'id'));
        WHEN 'User.SuspensionStatus.Updated' THEN
            -- D7: 封禁/解封（PATCH /users/:id/is-suspended 独立事件；data 含 isSuspended）
            PERFORM sync_user_suspension(
                v_data->>'id',
                COALESCE((v_data->>'isSuspended')::boolean, false));

        -- ═══ 组织（租户）事件 ═══
        WHEN 'Organization.Created' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Data.Updated' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Deleted' THEN
            -- N1: DELETE /organizations/:id → params.id
            PERFORM sync_tenant_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 成员关系事件（增量 diff）═══
        WHEN 'Organization.Membership.Updated' THEN
            PERFORM sync_membership_delta(
                $1->>'organizationId',
                COALESCE($1->'addedUserIds', '[]'::jsonb),
                COALESCE($1->'removedUserIds', '[]'::jsonb));

        -- ═══ 组织角色事件（D4）═══
        WHEN 'OrganizationRole.Created' THEN
            PERFORM sync_organization_role_upsert(v_data);
        WHEN 'OrganizationRole.Data.Updated' THEN
            PERFORM sync_organization_role_upsert(v_data);
        WHEN 'OrganizationRole.Deleted' THEN
            -- N1: DELETE /organization-roles/:id → params.id
            PERFORM sync_organization_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 角色目录事件 ═══
        WHEN 'Role.Created' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Data.Updated' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Deleted' THEN
            -- N1: DELETE /roles/:id → params.id
            PERFORM sync_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 登录事件（D-C：interaction payload 顶层平铺，无 data 包装）═══
        WHEN 'PostSignIn' THEN
            -- N6: 登录日志独立容错——失败仅落 error 不阻断（避免重试双写）
            BEGIN
                PERFORM sync_login_log_write($1);
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                IF v_log_id IS NOT NULL THEN
                    UPDATE webhook_event_log
                       SET result = 'error', error = SQLERRM
                     WHERE id = v_log_id;
                END IF;
            END;

        -- ═══ 未知事件 — 落 ignored（测试负载/未来新事件可观测）═══
        ELSE
            IF v_log_id IS NOT NULL THEN
                UPDATE webhook_event_log SET result = 'ignored' WHERE id = v_log_id;
            END IF;
    END CASE;

    -- N6: 成功落库（PostSignIn 失败/未知事件已单独标记，不覆盖）
    IF v_log_id IS NOT NULL AND NOT v_failed
       AND NOT EXISTS (SELECT 1 FROM webhook_event_log WHERE id = v_log_id AND result <> 'received') THEN
        UPDATE webhook_event_log SET result = 'success' WHERE id = v_log_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    -- N6: 失败落库（error）并返回 ok:false；参数 $1 不回滚，用于匹配 received 行
    BEGIN
        UPDATE webhook_event_log
           SET result = 'error', error = SQLERRM
         WHERE id = (SELECT id FROM webhook_event_log
                     WHERE payload = $1 AND result = 'received'
                     ORDER BY created_at DESC LIMIT 1);
        IF NOT FOUND THEN
            INSERT INTO webhook_event_log (hook_id, event, logto_created, payload, result, error)
            VALUES ($1->>'hookId', $1->>'event', logto_ts($1->>'createdAt'), $1, 'error', SQLERRM);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$_$;


--
-- Name: FUNCTION webhook_logto(jsonb); Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON FUNCTION api_v1_public.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；N6 事件落库；N1 删除 ID 三键兜底；D4 OrganizationRole.*；D7 SuspensionStatus.Updated；PostSignIn 失败容忍';


--
-- Name: audit_created_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_created_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        NEW.created_at := now();
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.created_at := OLD.created_at;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION audit_created_at(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.audit_created_at() IS '强制保护 created_at 字段：INSERT 时强制设为 now()，UPDATE 时禁止修改。作为最后一道防线防止应用层篡改。';


--
-- Name: audit_deletion_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_deletion_user() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
        NEW.deleted_by := current_user_id();
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION audit_deletion_user(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.audit_deletion_user() IS '自动填充删除审计字段：deleted_at 从 NULL 变为非 NULL 时填充 deleted_by。无 JWT 上下文时设为 NULL。';


--
-- Name: audit_trigger_func(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_trigger_func() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_old_data jsonb;
    v_new_data jsonb;
BEGIN
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

    -- 使用通用审计函数写入
    PERFORM public.write_audit_log(
        p_table_name := TG_TABLE_NAME,
        p_operation := TG_OP,
        p_old_data := v_old_data,
        p_new_data := v_new_data,
        p_source := 'trigger'
    );

    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;


--
-- Name: FUNCTION audit_trigger_func(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.audit_trigger_func() IS '审计触发器函数：使用 write_audit_log() 标准化写入';


--
-- Name: audit_user_fields(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_user_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        NEW.created_by := current_user_id();
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.updated_by := current_user_id();
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION audit_user_fields(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.audit_user_fields() IS '自动填充审计用户字段：INSERT 时填充 created_by，UPDATE 时填充 updated_by。无 JWT 上下文时设为 NULL（Logto 用户 id，text）。';


--
-- Name: current_data_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_data_scope() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_roles text[];
    v_scope jsonb;
BEGIN
    -- 超管短路
    IF is_super_admin() THEN
        RETURN jsonb_build_object('scope_type', 'all', 'dept_ids', '[]'::jsonb);
    END IF;

    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;

    -- 多角色取最宽: all > dept_and_child > custom > self（RuoYi 同语义）
    SELECT jsonb_build_object(
        'scope_type', CASE
            WHEN bool_or(scope_type = 'all')           THEN 'all'
            WHEN bool_or(scope_type = 'dept_and_child') THEN 'dept_and_child'
            WHEN bool_or(scope_type = 'custom')         THEN 'custom'
            ELSE 'self' END,
        'dept_ids', COALESCE(jsonb_agg(dept_id) FILTER (WHERE dept_id IS NOT NULL), '[]'::jsonb)
    ) INTO v_scope
    FROM iam_role_data_scope
    WHERE role_code = ANY(v_roles);

    IF v_scope IS NULL THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;
    RETURN v_scope;
END;
$$;


--
-- Name: FUNCTION current_data_scope(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_data_scope() IS '当前用户数据范围（超管=all；多角色取最宽 all>dept_and_child>custom>self；RLS 部门维度过滤的判定源）';


--
-- Name: current_tenant_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_tenant_id() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'organization_id', '')
$$;


--
-- Name: FUNCTION current_tenant_id(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_tenant_id() IS '当前租户 ID（Logto 组织 token: organization_id claim，text）';


--
-- Name: current_user_dept_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_dept_id() RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL SAFE
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN (
        SELECT p.dept_id
        FROM user_profile p
        WHERE p.user_id = current_user_id()
          AND p.deleted_at IS NULL
        LIMIT 1
    );
END;
$$;


--
-- Name: FUNCTION current_user_dept_id(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_user_dept_id() IS '当前用户部门 ID（查询 user_profile；SECURITY DEFINER 防 RLS 递归）';


--
-- Name: current_user_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_id() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER PARALLEL SAFE
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'sub', '')
$$;


--
-- Name: FUNCTION current_user_id(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_user_id() IS '当前用户 ID（Logto JWT sub claim，text）';


--
-- Name: current_user_roles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_roles() RETURNS text[]
    LANGUAGE sql STABLE
    AS $$
    SELECT ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(current_setting('request.jwt.claims', true)::jsonb -> 'roles', '[]'::jsonb)
        )
    );
$$;


--
-- Name: FUNCTION current_user_roles(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_user_roles() IS '当前用户角色 code 列表（JWT claims roles 字符串数组，零查询；030 修复 Logto 语义）';


--
-- Name: current_visible_dept_ids(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_visible_dept_ids() RETURNS SETOF uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH scope AS (
        SELECT scope_type, dept_ids
        FROM jsonb_to_record(current_data_scope()) AS x(scope_type text, dept_ids jsonb)
    )
    -- all: 全部部门
    SELECT d.id FROM department d JOIN scope s ON true WHERE s.scope_type = 'all'
    UNION
    -- custom: 指定部门
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'custom'
      AND d.id IN (SELECT (jsonb_array_elements_text(s.dept_ids))::uuid)
    UNION
    -- dept_and_child: 用户部门及其后代（无部门 → 空集）
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'dept_and_child'
      AND (d.id = current_user_dept_id() OR d.id IN (
          WITH RECURSIVE subtree AS (
              SELECT id FROM department WHERE id = current_user_dept_id()
              UNION ALL
              SELECT c.id FROM department c
              JOIN subtree p ON c.parent_id = p.id
          )
          SELECT id FROM subtree));
END;
$$;


--
-- Name: FUNCTION current_visible_dept_ids(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.current_visible_dept_ids() IS '当前用户可见部门 id 集合（RLS USING dept_id IN (SELECT current_visible_dept_ids())；SECURITY DEFINER 防 RLS 递归）';


--
-- Name: derive_route_name(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.derive_route_name(p_router text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
SELECT upper(left(s, 1)) || substring(s FROM 2)
FROM (
    SELECT (string_to_array(btrim(p_router, '/'), '/'))
           [array_length(string_to_array(btrim(p_router, '/'), '/'), 1)] AS s
) t
WHERE s IS NOT NULL AND s <> '';
$$;


--
-- Name: FUNCTION derive_route_name(p_router text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.derive_route_name(p_router text) IS '路由名称推导（056 B2：router 末段首字母大写，如 /system/user→User；仿 SharpFort/vue-element-admin 惯例；p_router 为 NULL 或末段为空返回 NULL）';




--
-- Name: geo_locate(inet); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geo_locate(ip inet) RETURNS jsonb
    LANGUAGE plpgsql STABLE STRICT
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_region   text;
    v_cidr     cidr;
    v_row      record;
    v_lat      float8;
    v_lon      float8;
    v_tz       text;
    v_country  text;
    v_city     text;
BEGIN
    -- ① ip2region 优先（仅 IPv4，国内精度高）
    v_region := ip2region(ip);

    -- ② GeoLite2 兜底（IPv4 未命中 或 IPv6）
    BEGIN
        v_cidr := ip::cidr;   -- inet → cidr（/32 或 /128）
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    SELECT g.latitude, g.longitude, g.timezone, g.country_name, g.city_name
      INTO v_lat, v_lon, v_tz, v_country, v_city
    FROM ip_geolite2_city g
    WHERE g.network >>= v_cidr
    ORDER BY masklen(g.network) DESC
    LIMIT 1;

    IF v_region IS NOT NULL THEN
        RETURN jsonb_build_object(
            'source', 'ip2region', 'region', v_region,
            'latitude', v_lat, 'longitude', v_lon,
            'timezone', v_tz, 'country', v_country, 'city', v_city);
    ELSIF v_city IS NOT NULL OR v_country IS NOT NULL OR v_lat IS NOT NULL THEN
        RETURN jsonb_build_object(
            'source', 'geolite2', 'region', NULL,
            'latitude', v_lat, 'longitude', v_lon,
            'timezone', v_tz, 'country', v_country, 'city', v_city);
    ELSE
        RETURN NULL;
    END IF;
END;
$$;


--
-- Name: FUNCTION geo_locate(ip inet); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.geo_locate(ip inet) IS 'IP 地理定位：ip2region 优先（国家|省|市|ISP）→ GeoLite2 兜底（全球+经纬度+时区）；返回 {source, region, latitude, longitude, timezone, country, city}';


--
-- Name: get_user_menu(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_menu() RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_roles)) THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
            m.is_affix
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
            m.is_affix
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
            c.menu_type, c.perms, c.is_visible, c.component,
            c.is_link, c.is_iframe, c.is_cache, c.redirect, c.route_name,
            c.is_affix,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;


--
-- Name: FUNCTION get_user_menu(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_menu() IS '获取用户菜单树（057: keep_alive→is_cache 输出键——前端 MenuProcessor 映射同步，Vue meta.keepAlive 不改；056: -query B1 清理；055: +is_affix）';


--
-- Name: has_permission(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_permission(p_code text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    -- 单通道（055 D3）：权限点 = button 行 api_code（非 button 行 api_code 已收敛置空）
    RETURN EXISTS (
        SELECT 1
        FROM iam_role_menu rm
        JOIN iam_menu m ON m.id = rm.menu_id
        WHERE rm.role_code = ANY(v_roles)
          AND m.api_code = p_code
          AND m.is_active
    );
END;
$$;


--
-- Name: FUNCTION has_permission(p_code text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.has_permission(p_code text) IS '权限点判定（055 单通道 D3: role_menu→menu.api_code；超管短路；一码多端点 EXISTS 语义）';


--
-- Name: import_geolite2_city(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_geolite2_city() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_cnt int;
BEGIN
    TRUNCATE ip_geolite2_city;
    INSERT INTO ip_geolite2_city
        (network, geoname_id, latitude, longitude, accuracy_radius,
         timezone, country_name, city_name)
    SELECT b.network, b.geoname_id, b.latitude, b.longitude, b.accuracy_radius,
           l.time_zone, l.country_name, l.city_name
    FROM ip_geolite2_blocks b
    LEFT JOIN ip_geolite2_locations l
           ON l.geoname_id = b.geoname_id AND l.locale_code = 'zh-CN';
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    RETURN v_cnt;
END;
$$;


--
-- Name: FUNCTION import_geolite2_city(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.import_geolite2_city() IS 'GeoLite2 staging → ip_geolite2_city 全量替换（幂等）；返回导入行数；调用前须已 COPY 两 staging 表';


--
-- Name: ip2region(inet); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ip2region(ip inet) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT country
           || CASE WHEN province IS NOT NULL AND province <> '' THEN '|' || province ELSE '' END
           || CASE WHEN city     IS NOT NULL AND city     <> '' THEN '|' || city     ELSE '' END
           || CASE WHEN isp      IS NOT NULL AND isp      <> '' THEN '|' || isp      ELSE '' END
    FROM ip_region_v4
    WHERE family(ip) = 4
      AND start_ip <= ip AND end_ip >= ip
    ORDER BY start_ip DESC
    LIMIT 1;
$$;


--
-- Name: FUNCTION ip2region(ip inet); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.ip2region(ip inet) IS 'ip2region 离线库查询：返回 国家|省|市|ISP（未命中 NULL）；数据由 import-ip2region.sh 导入';


--
-- Name: is_super_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_super_admin() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
    SELECT current_user_roles() @> ARRAY['role_super_admin'];
$$;


--
-- Name: FUNCTION is_super_admin(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_super_admin() IS '检查当前用户是否为超级管理员（Logto: roles 含 role_super_admin；035 重建——030 声称修复但漏改 is_super_admin 本身）';


--
-- Name: is_uuid_v7(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_uuid_v7(p_uuid uuid) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $_$
BEGIN
    RETURN p_uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
END;
$_$;


--
-- Name: FUNCTION is_uuid_v7(p_uuid uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_uuid_v7(p_uuid uuid) IS '验证 UUID 是否为 v7 版本（时间有序 UUID）。用于 CHECK 约束或数据质量检查。';


--
-- Name: log_operate(text, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_operate(p_module text, p_action text, p_target_type text DEFAULT NULL::text, p_target_id text DEFAULT NULL::text, p_result text DEFAULT 'success'::text, p_detail jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    INSERT INTO audit_log
        (log_type, operation, module, action, target_type, target_id, result,
         new_data, user_id, tenant_id, created_at)
    VALUES
        ('operate', COALESCE(p_action, 'operate'), p_module, p_action,
         p_target_type, p_target_id, p_result,
         p_detail, current_user_id(), current_tenant_id(), now());
END;
$$;


--
-- Name: FUNCTION log_operate(p_module text, p_action text, p_target_type text, p_target_id text, p_result text, p_detail jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.log_operate(p_module text, p_action text, p_target_type text, p_target_id text, p_result text, p_detail jsonb) IS '业务操作审计写入（038 修复: +operation 列——audit_log.operation NOT NULL，024 起缺失导致写 RPC 23502）';


--
-- Name: logto_ts(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.logto_ts(v text) RETURNS timestamp with time zone
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]+$' THEN
        -- 毫秒时间戳（13 位）或秒（10 位）
        IF length(v) >= 13 THEN
            RETURN to_timestamp(v::bigint / 1000.0);
        ELSE
            RETURN to_timestamp(v::bigint);
        END IF;
    END IF;
    RETURN v::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END $_$;


--
-- Name: require_permission(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_permission(p_code text) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT has_permission(p_code) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;


--
-- Name: FUNCTION require_permission(p_code text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.require_permission(p_code text) IS '权限门槛统一入口（035）：has_permission 不通过即 42501；DEFINER 写/管理 RPC 统一调用';


--
-- Name: require_super_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_super_admin() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;


--
-- Name: FUNCTION require_super_admin(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.require_super_admin() IS '超管门槛统一入口（035）：平台级 RPC（pg_cron/会话清理等）统一调用';


--
-- Name: sha256(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sha256(data bytea) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$;


--
-- Name: FUNCTION sha256(data bytea); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sha256(data bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值（仅用于非密码场景）；public. 限定——PG18 内置 sha256(bytea) 在 pg_catalog，无限定会解析到内置（返回 bytea 且属主 postgres 不可 REPLACE）';


--
-- Name: sync_login_log_write(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_login_log_write(payload jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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


--
-- Name: FUNCTION sync_login_log_write(payload jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_login_log_write(payload jsonb) IS 'PostSignIn → login_log（023 重建：表名随 sys_ 前缀移除更新）';


--
-- Name: sync_membership_delta(text, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_membership_delta(org_id text, added jsonb, removed jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_user_id text;
BEGIN
    -- N21: 缺失字段视为无变更（Logto 无变更事件也可能推送 Membership.Updated）
    IF added IS NULL OR jsonb_typeof(added) <> 'array' THEN
        added := '[]'::jsonb;
    END IF;
    IF removed IS NULL OR jsonb_typeof(removed) <> 'array' THEN
        removed := '[]'::jsonb;
    END IF;

    -- N21: 空 delta 早退（无变更不空转）
    IF jsonb_array_length(added) = 0 AND jsonb_array_length(removed) = 0 THEN
        RETURN;
    END IF;

    -- 新增成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(added)
    LOOP
        INSERT INTO user_tenants (organization_id, user_id)
        VALUES (org_id, v_user_id)
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- 移除成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(removed)
    LOOP
        DELETE FROM user_tenants
        WHERE organization_id = org_id AND user_id = v_user_id;
    END LOOP;
END $$;


--
-- Name: FUNCTION sync_membership_delta(org_id text, added jsonb, removed jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_membership_delta(org_id text, added jsonb, removed jsonb) IS '成员关系增量同步（051 N21: 空 delta 早退；5000 截断由 D9 对账每日全量兜底，sys_config 标记已移除）';


--
-- Name: sync_organization_role_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_organization_role_delete(p_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    DELETE FROM organization_role WHERE id = p_id;
END $$;


--
-- Name: FUNCTION sync_organization_role_delete(p_id text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_organization_role_delete(p_id text) IS '组织角色镜像删除（data=null，ID 取 params.id——N1 同款）';


--
-- Name: sync_organization_role_upsert(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_organization_role_upsert(data jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO organization_role (id, name, description, created_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        now(),
        v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE organization_role.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= organization_role.logto_updated_at;
END $$;


--
-- Name: FUNCTION sync_organization_role_upsert(data jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_organization_role_upsert(data jsonb) IS '组织角色镜像 upsert（051 N18: 乱序守护）';


--
-- Name: sync_role_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_role_delete(role_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    DELETE FROM role WHERE id = role_id;
END $$;


--
-- Name: sync_role_upsert(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_role_upsert(data jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO role (id, name, description, type, is_default, created_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now(),
        v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        type             = EXCLUDED.type,
        is_default       = EXCLUDED.is_default,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE role.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= role.logto_updated_at;
END $$;


--
-- Name: FUNCTION sync_role_upsert(data jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_role_upsert(data jsonb) IS 'Logto 角色目录镜像 upsert（051 N18: 乱序守护）';


--
-- Name: sync_tenant_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_tenant_delete(org_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    UPDATE user_profile SET tenant_id = NULL WHERE tenant_id = org_id;
    DELETE FROM tenants WHERE id = org_id;
END $$;


--
-- Name: sync_tenant_upsert(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_tenant_upsert(data jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO tenants (id, name, description, custom_data, created_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        custom_data      = EXCLUDED.custom_data,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE tenants.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= tenants.logto_updated_at;
END $$;


--
-- Name: FUNCTION sync_tenant_upsert(data jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_tenant_upsert(data jsonb) IS 'Logto 组织镜像 upsert（051 N18: 乱序守护）';


--
-- Name: sync_user_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_user_delete(user_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    DELETE FROM users WHERE id = user_id;
END $$;


--
-- Name: sync_user_suspension(text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_user_suspension(p_user_id text, p_suspended boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    UPDATE users
       SET is_suspended   = COALESCE(p_suspended, false),
           logto_updated_at = now()
     WHERE id = p_user_id
       AND (logto_updated_at IS NULL OR now() >= logto_updated_at);
END $$;


--
-- Name: FUNCTION sync_user_suspension(p_user_id text, p_suspended boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_user_suspension(p_user_id text, p_suspended boolean) IS '封禁状态镜像同步（051 N18: 乱序守护）';


--
-- Name: sync_user_upsert(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_user_upsert(data jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO users (id, username, primary_email, primary_phone, name, avatar,
                       custom_data, identities, last_sign_in_at, created_at, application_id,
                       is_suspended, profile, sso_identities, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'username', ''),
        COALESCE(data->>'primaryEmail', ''),
        COALESCE(data->>'primaryPhone', ''),
        COALESCE(data->>'name', ''),
        COALESCE(data->>'avatar', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(data->'identities', '{}'),
        logto_ts(data->>'lastSignInAt'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        COALESCE(data->>'applicationId', ''),
        COALESCE((data->>'isSuspended')::boolean, false),
        COALESCE(data->'profile', '{}'),
        COALESCE(data->'ssoIdentities', '{}'),
        v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        username        = EXCLUDED.username,
        primary_email   = EXCLUDED.primary_email,
        primary_phone   = EXCLUDED.primary_phone,
        name            = EXCLUDED.name,
        avatar          = EXCLUDED.avatar,
        custom_data     = EXCLUDED.custom_data,
        identities      = EXCLUDED.identities,
        last_sign_in_at = EXCLUDED.last_sign_in_at,
        application_id  = EXCLUDED.application_id,
        is_suspended    = EXCLUDED.is_suspended,
        profile         = EXCLUDED.profile,
        sso_identities  = EXCLUDED.sso_identities,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE users.logto_updated_at IS NULL                       -- 存量兼容（首次同步）
       OR EXCLUDED.logto_updated_at >= users.logto_updated_at; -- 乱序守护（N18）
END $$;


--
-- Name: FUNCTION sync_user_upsert(data jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sync_user_upsert(data jsonb) IS 'Logto 用户镜像 upsert（051 N18: logto_updated_at 乱序守护——旧事件不覆盖新状态）';


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


--
-- Name: FUNCTION update_updated_at(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.update_updated_at() IS '自动更新 updated_at 字段为当前时间';


--
-- Name: write_audit_log(text, text, jsonb, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.write_audit_log(p_table_name text, p_operation text, p_old_data jsonb DEFAULT NULL::jsonb, p_new_data jsonb DEFAULT NULL::jsonb, p_source text DEFAULT 'trigger'::text, p_description text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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


--
-- Name: FUNCTION write_audit_log(p_table_name text, p_operation text, p_old_data jsonb, p_new_data jsonb, p_source text, p_description text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.write_audit_log(p_table_name text, p_operation text, p_old_data jsonb, p_new_data jsonb, p_source text, p_description text) IS '通用审计日志写入函数：标准化数据变更和业务事件的审计记录。
触发器场景：自动记录表数据变更（source=trigger）
业务场景：记录登录/登出/密码修改等事件（source=rpc/business）';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_config (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_config_id_not_null NOT NULL,
    config_key character varying(100) CONSTRAINT sys_config_config_key_not_null NOT NULL,
    config_value text,
    config_type character varying(20) DEFAULT 'string'::character varying CONSTRAINT sys_config_config_type_not_null NOT NULL,
    description character varying(255),
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_config_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT sys_config_updated_at_not_null NOT NULL
);


--
-- Name: app_config; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.app_config AS
 SELECT id,
    config_key,
    config_value,
    config_type,
    is_public,
    created_at,
    updated_at
   FROM public.app_config;


--
-- Name: VIEW app_config; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.app_config IS '系统配置视图（公开配置，不含敏感描述）';


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_audit_log_id_not_null NOT NULL,
    tenant_id text,
    user_id text,
    username character varying(100),
    operation character varying(50) CONSTRAINT sys_audit_log_operation_not_null NOT NULL,
    table_name character varying(100),
    record_id uuid,
    old_data jsonb,
    new_data jsonb,
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_audit_log_created_at_not_null NOT NULL,
    log_type text DEFAULT 'data_change'::text NOT NULL,
    module text,
    action text,
    target_type text,
    target_id text,
    result text,
    ip inet,
    region text,
    duration_ms integer,
    source character varying(20) DEFAULT 'trigger'::character varying NOT NULL,
    description text
);


--
-- Name: COLUMN audit_log.log_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.log_type IS '日志类型: data_change(触发器差异日志,默认) / operate(业务操作) / login(登录) / exception(异常) / event(事件) / open_api(开放接口)';


--
-- Name: COLUMN audit_log.module; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.module IS '业务模块（order/user/...）';


--
-- Name: COLUMN audit_log.action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.action IS '操作标识（order.approve）';


--
-- Name: COLUMN audit_log.target_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.target_type IS '操作对象类型';


--
-- Name: COLUMN audit_log.target_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.target_id IS '操作对象 ID';


--
-- Name: COLUMN audit_log.result; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.result IS '执行结果: success / fail';


--
-- Name: COLUMN audit_log.region; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.audit_log.region IS 'IP 归属地（ip2region: 国家|省|市|ISP）';


--
-- Name: audit_log; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.audit_log AS
 SELECT id,
    table_name,
    operation,
    old_data,
    new_data,
    user_id,
    tenant_id,
    created_at
   FROM public.audit_log;


--
-- Name: VIEW audit_log; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.audit_log IS '审计日志视图（只读）';


--
-- Name: config_admin; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.config_admin AS
 SELECT id,
    config_key,
    config_value,
    config_type,
    description,
    is_public,
    created_at,
    updated_at
   FROM public.app_config;


--
-- Name: VIEW config_admin; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.config_admin IS '系统配置管理视图（含描述，仅管理员使用）';


--
-- Name: cron_job_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cron_job_log (
    id bigint CONSTRAINT sys_cron_log_id_not_null NOT NULL,
    job_name character varying(100) CONSTRAINT sys_cron_log_job_name_not_null NOT NULL,
    execution_time timestamp with time zone DEFAULT now() CONSTRAINT sys_cron_log_execution_time_not_null NOT NULL,
    result jsonb,
    duration_ms integer
);


--
-- Name: TABLE cron_job_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cron_job_log IS 'pg_cron 任务执行日志';


--
-- Name: cron_job_log; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.cron_job_log AS
 SELECT id,
    job_name,
    execution_time,
    result,
    duration_ms
   FROM public.cron_job_log;


--
-- Name: VIEW cron_job_log; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.cron_job_log IS 'Cron 执行日志视图（只读）';


--
-- Name: department; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.department (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_department_id_not_null NOT NULL,
    dept_name character varying(100) CONSTRAINT sys_department_dept_name_not_null NOT NULL,
    tenant_id text CONSTRAINT sys_department_tenant_id_not_null NOT NULL,
    parent_id uuid,
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true CONSTRAINT sys_department_is_active_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_department_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT sys_department_updated_at_not_null NOT NULL,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text,
    deleted_by text
);


--
-- Name: TABLE department; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.department IS '部门组织架构表，按租户隔离';


--
-- Name: COLUMN department.tenant_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.department.tenant_id IS '所属租户，租户间部门数据隔离';


--
-- Name: COLUMN department.parent_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.department.parent_id IS '上级部门 ID，NULL 表示根部门';


--
-- Name: COLUMN department.created_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.department.created_by IS '创建者用户 ID';


--
-- Name: COLUMN department.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.department.updated_by IS '最后修改者用户 ID';


--
-- Name: COLUMN department.deleted_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.department.deleted_by IS '删除者用户 ID';


--
-- Name: department; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.department AS
 SELECT id,
    dept_name,
    tenant_id,
    parent_id,
    sort_order,
    is_active,
    created_at,
    updated_at,
    deleted_at,
    created_by,
    updated_by,
    deleted_by
   FROM public.department;


--
-- Name: VIEW department; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.department IS '部门树视图';


--
-- Name: dict_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dict_data (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_dict_data_id_not_null NOT NULL,
    tenant_id text,
    dict_name text CONSTRAINT sys_dict_data_dict_name_not_null NOT NULL,
    item_label text CONSTRAINT sys_dict_data_item_label_not_null NOT NULL,
    item_value text CONSTRAINT sys_dict_data_item_value_not_null NOT NULL,
    item_type text DEFAULT 'default'::text CONSTRAINT sys_dict_data_item_type_not_null NOT NULL,
    is_default boolean DEFAULT false CONSTRAINT sys_dict_data_is_default_not_null NOT NULL,
    sort_no integer DEFAULT 0 CONSTRAINT sys_dict_data_sort_no_not_null NOT NULL,
    status boolean DEFAULT true CONSTRAINT sys_dict_data_status_not_null NOT NULL,
    remark text,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_dict_data_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT sys_dict_data_updated_at_not_null NOT NULL,
    created_by text,
    updated_by text
);


--
-- Name: TABLE dict_data; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.dict_data IS '字典数据项';


--
-- Name: dict_data; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.dict_data AS
 SELECT id,
    tenant_id,
    dict_name,
    item_label,
    item_value,
    item_type,
    is_default,
    sort_no,
    status,
    remark,
    created_at,
    updated_at,
    created_by,
    updated_by
   FROM public.dict_data;


--
-- Name: VIEW dict_data; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.dict_data IS '字典数据视图（sys_ 前缀移除，023）';


--
-- Name: dict_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dict_type (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_dict_type_id_not_null NOT NULL,
    tenant_id text,
    dict_name text CONSTRAINT sys_dict_type_dict_name_not_null NOT NULL,
    dict_label text CONSTRAINT sys_dict_type_dict_label_not_null NOT NULL,
    status boolean DEFAULT true CONSTRAINT sys_dict_type_status_not_null NOT NULL,
    sort_no integer DEFAULT 0 CONSTRAINT sys_dict_type_sort_no_not_null NOT NULL,
    remark text,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_dict_type_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT sys_dict_type_updated_at_not_null NOT NULL,
    created_by text,
    updated_by text
);


--
-- Name: TABLE dict_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.dict_type IS '字典类型（全局 + 租户两级）';


--
-- Name: COLUMN dict_type.tenant_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.dict_type.tenant_id IS 'NULL=全局字典（所有租户共享）；非 NULL=租户字典（RLS 按 claims 过滤）';


--
-- Name: dict_type; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.dict_type AS
 SELECT id,
    tenant_id,
    dict_name,
    dict_label,
    status,
    sort_no,
    remark,
    created_at,
    updated_at,
    created_by,
    updated_by
   FROM public.dict_type;


--
-- Name: VIEW dict_type; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.dict_type IS '字典类型视图（sys_ 前缀移除，023）';


--
-- Name: iam_menu; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_menu (
    id uuid DEFAULT uuidv7() NOT NULL,
    parent_id uuid,
    menu_name character varying(100) NOT NULL,
    router character varying(200),
    icon character varying(100),
    order_num integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    updated_by text,
    menu_type public.iam_menu_type DEFAULT 'menu'::public.iam_menu_type NOT NULL,
    api_code text,
    component text,
    is_visible boolean DEFAULT true NOT NULL,
    remark text,
    route_name text,
    is_link boolean DEFAULT false NOT NULL,
    is_iframe boolean DEFAULT false NOT NULL,
    redirect text,
    is_cache boolean DEFAULT true CONSTRAINT iam_menu_keep_alive_not_null NOT NULL,
    api_url character varying(255),
    api_method character varying(10),
    is_affix boolean DEFAULT false NOT NULL,
    CONSTRAINT iam_menu_api_method_check CHECK (((api_method IS NULL) OR ((api_method)::text = ANY ((ARRAY['GET'::character varying, 'POST'::character varying, 'PUT'::character varying, 'PATCH'::character varying, 'DELETE'::character varying, 'HEAD'::character varying, 'OPTIONS'::character varying, '*'::character varying])::text[])))),
    CONSTRAINT iam_menu_api_pair_check CHECK (((api_url IS NULL) OR (api_method IS NOT NULL))),
    CONSTRAINT iam_menu_button_nav_null_check CHECK (((menu_type <> 'button'::public.iam_menu_type) OR ((router IS NULL) AND (component IS NULL)))),
    CONSTRAINT iam_menu_button_perms_check CHECK (((menu_type <> 'button'::public.iam_menu_type) OR ((api_code IS NOT NULL) AND (TRIM(BOTH FROM api_code) <> ''::text)))),
    CONSTRAINT iam_menu_is_link_path_check CHECK (((NOT is_link) OR ((router)::text ~~ 'http://%'::text) OR ((router)::text ~~ 'https://%'::text))),
    CONSTRAINT iam_menu_link_path_check CHECK (((menu_type <> 'link'::public.iam_menu_type) OR ((router)::text ~~ 'http://%'::text) OR ((router)::text ~~ 'https://%'::text)))
);


--
-- Name: TABLE iam_menu; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.iam_menu IS '菜单树（PG 自主数据）；role_code 经 iam_role_menu 绑定角色';


--
-- Name: COLUMN iam_menu.router; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.router IS '路由地址（前端 vue-router path；link 类型为 http(s):// 外链 URL；原 path）';


--
-- Name: COLUMN iam_menu.menu_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.menu_type IS '菜单类型: directory(目录) / menu(菜单) / button(按钮) / link(外链或iframe，032)';


--
-- Name: COLUMN iam_menu.api_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.api_code IS '权限码（单码制：与 iam_api.api_code 同码；button 必填，has_permission 双通道判定键；原 perms）';


--
-- Name: COLUMN iam_menu.component; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.component IS '前端组件路径（路由渲染，仅 menu 类型使用）';


--
-- Name: COLUMN iam_menu.is_visible; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.is_visible IS '是否显示（目录/菜单显隐控制）';


--
-- Name: COLUMN iam_menu.remark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.remark IS '备注（管理端展示）';


--
-- Name: COLUMN iam_menu.route_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.route_name IS '路由名称（Vue Router name，英文唯一；前端 addRoute 用）';


--
-- Name: COLUMN iam_menu.is_link; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.is_link IS '是否外链（新窗口打开；menu_type=link 时自动置 true）';


--
-- Name: COLUMN iam_menu.is_iframe; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.is_iframe IS '是否 iframe 内嵌（path 为内嵌 URL）';


--
-- Name: COLUMN iam_menu.redirect; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.redirect IS '目录重定向路径（noRedirect 表示不重定向）';


--
-- Name: COLUMN iam_menu.is_cache; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.is_cache IS '是否缓存页面（keep-alive，默认 true；057 由 keep_alive 改名——语义对标 SharpFort IsCache/RuoYi is_cache + iam_menu 布尔列 is_ 前缀命名统一）';


--
-- Name: COLUMN iam_menu.api_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.api_url IS 'API 端点路径（原 iam_api.path，055 单表化 D1；仅 button 行使用；SharpFort ApiUrl 借鉴；约定以 / 开头不含 {}，RPC 层软校验 P2）';


--
-- Name: COLUMN iam_menu.api_method; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.api_method IS 'API 端点方法（原 iam_api.method，055 单表化 D1；api_url 非空时必填，值域 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*；SharpFort ApiMethod 借鉴）';


--
-- Name: COLUMN iam_menu.is_affix; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_menu.is_affix IS '是否固定标签页（Admin.NET IsAffix 借鉴；多页签前端布局使用，默认 false）';


--
-- Name: iam_menu; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.iam_menu AS
 SELECT id,
    parent_id,
    menu_name,
    menu_type,
    api_code,
    router,
    component,
    icon,
    order_num,
    is_visible,
    is_active,
    remark,
    route_name,
    is_link,
    is_iframe,
    redirect,
    is_cache,
    api_url,
    api_method,
    is_affix,
    created_at,
    updated_at,
    created_by,
    updated_by
   FROM public.iam_menu;


--
-- Name: VIEW iam_menu; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（057: keep_alive→is_cache 改名——SharpFort IsCache 语义 + is_ 前缀统一；056: -query B1 清理）';


--
-- Name: iam_role_menu; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_role_menu (
    id uuid DEFAULT uuidv7() NOT NULL,
    role_code text NOT NULL,
    menu_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text
);


--
-- Name: TABLE iam_role_menu; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.iam_role_menu IS '角色→菜单绑定（PG 自主数据）';


--
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    id text CONSTRAINT iam_role_id_not_null NOT NULL,
    name character varying(128) CONSTRAINT iam_role_name_not_null NOT NULL,
    role_code text GENERATED ALWAYS AS (name) STORED,
    type character varying(32) DEFAULT 'User'::character varying CONSTRAINT iam_role_type_not_null NOT NULL,
    is_default boolean DEFAULT false CONSTRAINT iam_role_is_default_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT iam_role_created_at_not_null NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    logto_updated_at timestamp with time zone
);


--
-- Name: TABLE role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.role IS 'Logto 全局角色镜像（只读投影）；删除策略=硬删+级联——user_role.role_id FK ON DELETE CASCADE 显式清理分配镜像（N12 决策，049 建立）';


--
-- Name: COLUMN role.role_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.role.role_code IS '生成列 = name（E5），与 iam_role_api.role_code / 网关 required_roles 对齐';


--
-- Name: COLUMN role.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.role.description IS 'Logto Role.description（webhook/对账推送）';


--
-- Name: COLUMN role.logto_updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';


--
-- Name: iam_role_menu; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.iam_role_menu AS
 SELECT r.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.created_by
   FROM (public.iam_role_menu rm
     JOIN public.role r ON ((r.role_code = rm.role_code)));


--
-- Name: VIEW iam_role_menu; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.iam_role_menu IS '角色-菜单关联视图（Logto 镜像：iam_role_menu）';


--
-- Name: login_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login_log (
    id bigint CONSTRAINT sys_login_log_id_not_null NOT NULL,
    tenant_id text,
    user_id text,
    username text,
    login_type text CONSTRAINT sys_login_log_login_type_not_null NOT NULL,
    result text CONSTRAINT sys_login_log_result_not_null NOT NULL,
    fail_reason text,
    ip inet,
    user_agent text,
    region text,
    logto_event text,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_login_log_created_at_not_null NOT NULL
);


--
-- Name: TABLE login_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.login_log IS '登录日志（业务端安全审计镜像：Logto 审计日志无租户隔离/会被清理，业务端保留长期记录）';


--
-- Name: login_log; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.login_log AS
 SELECT id,
    tenant_id,
    user_id,
    username,
    login_type,
    result,
    fail_reason,
    ip,
    user_agent,
    region,
    logto_event,
    created_at
   FROM public.login_log;


--
-- Name: VIEW login_log; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.login_log IS '登录日志视图（sys_ 前缀移除，023）';


--
-- Name: organization_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_role (
    id text NOT NULL,
    name character varying(128) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    logto_updated_at timestamp with time zone
);


--
-- Name: TABLE organization_role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.organization_role IS 'Logto 组织角色镜像表（独立于 role 全局角色；只读投影，写入通道 = sync_organization_role_*）';


--
-- Name: COLUMN organization_role.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.organization_role.id IS 'Logto organization role id（21 位 nanoid）';


--
-- Name: COLUMN organization_role.logto_updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.organization_role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';


--
-- Name: organization_role; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.organization_role AS
 SELECT id,
    name,
    description,
    created_at,
    logto_updated_at AS updated_at
   FROM public.organization_role;


--
-- Name: VIEW organization_role; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.organization_role IS '组织角色镜像视图（D4 展示接口；只读）';


--
-- Name: position; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."position" (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id text NOT NULL,
    pos_name character varying(100) NOT NULL,
    pos_code character varying(100),
    parent_id uuid,
    sort_no integer DEFAULT 0 NOT NULL,
    status boolean DEFAULT true NOT NULL,
    remark text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text,
    deleted_by text
);


--
-- Name: TABLE "position"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."position" IS '岗位表（树形，租户隔离）。岗位=职级/职务维度，与权限无关（权限用角色）';


--
-- Name: COLUMN "position".parent_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."position".parent_id IS '上级岗位 ID，NULL 表示根岗位';


--
-- Name: position; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public."position" AS
 SELECT id,
    tenant_id,
    pos_name,
    pos_code,
    parent_id,
    sort_no,
    status,
    remark,
    created_at,
    updated_at,
    deleted_at,
    created_by,
    updated_by,
    deleted_by
   FROM public."position";


--
-- Name: VIEW "position"; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public."position" IS '岗位视图（026：sys_position 去前缀）';


--
-- Name: role; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.role AS
 SELECT id,
    role_code,
    COALESCE(name, (role_code)::character varying) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    true AS is_active,
    created_at,
    logto_updated_at AS updated_at,
    NULL::timestamp with time zone AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by
   FROM public.role r;


--
-- Name: VIEW role; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.role IS '角色表视图（Logto 镜像：role 投影，全局角色；is_active 恒 true——Logto 无角色停用概念，034；061 updated_at=同步水位）';


--
-- Name: user_position; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_position (
    user_id text NOT NULL,
    position_id uuid NOT NULL,
    tenant_id text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text
);


--
-- Name: TABLE user_position; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_position IS '用户-岗位关联（多对多，租户隔离）';


--
-- Name: user_position; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.user_position AS
 SELECT user_id,
    position_id,
    tenant_id,
    is_primary,
    created_at,
    created_by
   FROM public.user_position;


--
-- Name: VIEW user_position; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.user_position IS '用户岗位关联视图（026：sys_user_position 去前缀）';


--
-- Name: user_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_tenants (
    organization_id text NOT NULL,
    user_id text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE user_tenants; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_tenants IS 'Logto 组织成员关系镜像（来源: Organization.Membership.Updated webhook）';


--
-- Name: COLUMN user_tenants.joined_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_tenants.joined_at IS '加入时间（本地近似）——Logto 成员 API 不返回加入时间；对账全量重建时保持首次观察值（N11 决策）';


--
-- Name: user_tenants; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.user_tenants AS
 SELECT user_id,
    organization_id,
    joined_at
   FROM public.user_tenants ut;


--
-- Name: VIEW user_tenants; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.user_tenants IS '用户-组织成员关系视图（Logto 镜像：user_tenants；034 由 user_role 更名，消除与 public.user_role 表同名冲突）';


--
-- Name: user_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profile (
    user_id text NOT NULL,
    tenant_id text,
    dept_id uuid,
    nickname character varying(64),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text,
    deleted_by text,
    avatar_url text,
    gender public.gender,
    birthday date,
    bio character varying(500),
    location character varying(200),
    hobbies text[] DEFAULT '{}'::text[] NOT NULL,
    website text,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: TABLE user_profile; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_profile IS '用户个人资料（应用自有扩展，用户可编辑）：users 为 Logto 认证镜像只读，user_profile 承载 nickname/头像/生日/爱好/住址等个人信息；RLS 本人/超管可写（rls_policies.sql profile_tenant_policy）';


--
-- Name: COLUMN user_profile.user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.user_id IS 'Logto 用户 id（users.id 1:1；主键即外键，ON DELETE CASCADE）';


--
-- Name: COLUMN user_profile.tenant_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.tenant_id IS '租户 organization_id（017 约定；NULL=全局个人资料）';


--
-- Name: COLUMN user_profile.dept_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.dept_id IS '部门归属（current_user_dept_id 依赖；department 表）';


--
-- Name: COLUMN user_profile.nickname; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.nickname IS '昵称（应用自定义显示名；users.name 为 Logto 权威显示名，不重复）';


--
-- Name: COLUMN user_profile.avatar_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.avatar_url IS '头像 URL（空=默认头像，前端兜底）';


--
-- Name: COLUMN user_profile.gender; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.gender IS '性别（gender 枚举：male/female/other/prefer_not_to_say）';


--
-- Name: COLUMN user_profile.birthday; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.birthday IS '生日（隐私字段；前端按需脱敏）';


--
-- Name: COLUMN user_profile.bio; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.bio IS '个人简介（≤500 字）';


--
-- Name: COLUMN user_profile.location; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.location IS '所在地/住址（自由文本）';


--
-- Name: COLUMN user_profile.hobbies; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.hobbies IS '爱好（标签数组，如 {"篮球","摄影"}）';


--
-- Name: COLUMN user_profile.website; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.website IS '个人主页 URL';


--
-- Name: COLUMN user_profile.preferences; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_profile.preferences IS '偏好扩展 JSONB（language/timezone/theme/通知开关等；前端自定义键，Auth0 user_metadata 模式）';


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id text NOT NULL,
    username character varying(128) DEFAULT ''::character varying NOT NULL,
    primary_email character varying(255) DEFAULT ''::character varying NOT NULL,
    primary_phone character varying(32) DEFAULT ''::character varying NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    avatar character varying(500) DEFAULT ''::character varying NOT NULL,
    custom_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    identities jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_sign_in_at timestamp with time zone,
    is_suspended boolean DEFAULT false NOT NULL,
    application_id character varying(64) DEFAULT ''::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    profile jsonb DEFAULT '{}'::jsonb NOT NULL,
    sso_identities jsonb DEFAULT '{}'::jsonb NOT NULL,
    logto_updated_at timestamp with time zone
);


--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.users IS 'Logto 用户镜像表（Logto 权威，PG 只读；不进授权判定路径）';


--
-- Name: COLUMN users.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.id IS 'Logto 用户 id（21 位 nanoid 字符串，与服务端 JWT sub 一致）';


--
-- Name: COLUMN users.primary_email; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.primary_email IS 'Logto primaryEmail — 用户主邮箱';


--
-- Name: COLUMN users.primary_phone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.primary_phone IS 'Logto primaryPhone — 用户主电话';


--
-- Name: COLUMN users.profile; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.profile IS 'Logto User.profile（OIDC 标准 claims；仅 Management API 返回，对账任务 D9 注入）';


--
-- Name: COLUMN users.sso_identities; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.sso_identities IS 'Logto User.ssoIdentities（企业 SSO 身份；仅 Management API 返回，对账任务 D9 注入）';


--
-- Name: COLUMN users.logto_updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.logto_updated_at IS 'Logto 权威 updatedAt（webhook 无该字段时为本地近似）；乱序守护比较基准（N18）';


--
-- Name: sys_user; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.sys_user WITH (security_invoker='true') AS
 SELECT u.id,
    u.username,
    NULL::text AS password_hash,
    p.tenant_id,
    p.dept_id,
    u.primary_email AS email,
    u.primary_phone AS phone,
    (NOT u.is_suspended) AS is_active,
    u.created_at,
    u.logto_updated_at AS updated_at,
    NULL::timestamp with time zone AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by
   FROM (public.users u
     LEFT JOIN public.user_profile p ON ((p.user_id = u.id)));


--
-- Name: VIEW sys_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.sys_user IS 'Logto 用户兼容视图（替代 Casdoor 版 casdoor_user_mirror 投影）；security_invoker=true';


--
-- Name: users; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.users AS
 SELECT id,
    username,
    email,
    phone,
    tenant_id,
    dept_id,
    is_active,
    created_at,
    updated_at,
    deleted_at,
    created_by,
    updated_by,
    deleted_by,
    password_hash
   FROM public.sys_user;


--
-- Name: VIEW users; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.users IS '用户表视图（password_hash 仅通过 RPC 访问）';


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id text NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    custom_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    logto_updated_at timestamp with time zone
);


--
-- Name: TABLE tenants; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tenants IS 'Logto 组织镜像表（租户容器；id = Logto organization id，与业务 tenant_id 同键）';


--
-- Name: COLUMN tenants.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenants.id IS 'Logto organization id（21 位 nanoid）—— 业务表 tenant_id 的直接 FK 目标';


--
-- Name: COLUMN tenants.logto_updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenants.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';


--
-- Name: v_audit_log_detail; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_audit_log_detail AS
 SELECT a.id,
    a.table_name,
    a.operation,
    a.old_data,
    a.new_data,
    a.user_id,
    u.username,
    a.tenant_id,
    t.name AS tenant_name,
    a.created_at
   FROM ((public.audit_log a
     LEFT JOIN public.sys_user u ON ((a.user_id = u.id)))
     LEFT JOIN public.tenants t ON ((a.tenant_id = t.id)));


--
-- Name: VIEW v_audit_log_detail; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_audit_log_detail IS '审计日志视图：含用户名、租户名';


--
-- Name: v_audit_log_timeline; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_audit_log_timeline AS
 SELECT date_trunc('day'::text, created_at) AS log_date,
    table_name,
    operation,
    count(*) AS change_count,
    count(DISTINCT user_id) AS unique_users
   FROM public.audit_log
  GROUP BY (date_trunc('day'::text, created_at)), table_name, operation
  ORDER BY (date_trunc('day'::text, created_at)) DESC, (count(*)) DESC;


--
-- Name: VIEW v_audit_log_timeline; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_audit_log_timeline IS '审计时间线（按天聚合）';


--
-- Name: v_dept_list; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_dept_list AS
 SELECT d.id,
    d.dept_name,
    d.tenant_id,
    d.parent_id,
    t.name AS tenant_name,
    d.sort_order,
    d.is_active,
    d.created_at,
    d.updated_at,
    d.deleted_at,
    ( SELECT count(*) AS count
           FROM public.sys_user u
          WHERE ((u.dept_id = d.id) AND (u.deleted_at IS NULL))) AS user_count
   FROM (public.department d
     LEFT JOIN public.tenants t ON ((d.tenant_id = t.id)));


--
-- Name: VIEW v_dept_list; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_dept_list IS '部门列表视图：含用户数量统计';


--
-- Name: v_dict_list; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_dict_list AS
 SELECT id,
    tenant_id,
    dict_name,
    dict_label,
    status,
    sort_no,
    remark,
    COALESCE(( SELECT json_agg(json_build_object('id', d.id, 'label', d.item_label, 'value', d.item_value, 'type', d.item_type, 'is_default', d.is_default, 'sort_no', d.sort_no, 'status', d.status) ORDER BY d.sort_no) AS json_agg
           FROM public.dict_data d
          WHERE ((d.dict_name = t.dict_name) AND (NOT (d.tenant_id IS DISTINCT FROM t.tenant_id)) AND d.status)), '[]'::json) AS items
   FROM public.dict_type t;


--
-- Name: VIEW v_dict_list; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_dict_list IS '字典组合视图（类型 + 数据项聚合）';


--
-- Name: v_login_log; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_login_log AS
 SELECT l.id,
    l.tenant_id,
    l.user_id,
    l.username,
    l.login_type,
    l.result,
    l.fail_reason,
    l.ip,
    l.user_agent,
    l.region AS region_snapshot,
    (g.g ->> 'region'::text) AS region_live,
    (g.g ->> 'source'::text) AS geo_source,
    ((g.g ->> 'latitude'::text))::double precision AS latitude,
    ((g.g ->> 'longitude'::text))::double precision AS longitude,
    (g.g ->> 'timezone'::text) AS timezone,
    l.logto_event,
    l.created_at
   FROM (public.login_log l
     LEFT JOIN LATERAL public.geo_locate(l.ip) g(g) ON (true));


--
-- Name: VIEW v_login_log; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_login_log IS '登录日志视图：login_log + geo_locate 实时地理（026：v_sys_login_log 去前缀）';


--
-- Name: user_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_role (
    user_id text NOT NULL,
    role_code text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    organization_id text DEFAULT ''::text NOT NULL,
    role_id text
);


--
-- Name: TABLE user_role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_role IS '用户↔角色分配镜像（Logto 权威；JIT 覆盖+主动同步+对账，05 §6.5；仅管理端展示）';


--
-- Name: COLUMN user_role.organization_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_role.organization_id IS '角色归属维度：'''' = 全局角色（Logto 全局 roles）；非空 = Logto organization id（组织角色）';


--
-- Name: COLUMN user_role.role_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_role.role_id IS 'Logto 角色 id（对齐 users_roles 形状；镜像缺失时 NULL，对账/后续登录回填）';


--
-- Name: v_role_list; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_role_list AS
 SELECT id,
    role_code,
    COALESCE(name, (role_code)::character varying) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    true AS is_active,
    created_at,
    logto_updated_at AS updated_at,
    NULL::timestamp with time zone AS deleted_at,
    '全局'::character varying AS tenant_name,
    ( SELECT count(*) AS count
           FROM (public.iam_role_menu rm
             JOIN public.iam_menu m ON ((m.id = rm.menu_id)))
          WHERE ((rm.role_code = r.role_code) AND (m.api_url IS NOT NULL))) AS api_count,
    ( SELECT count(*) AS count
           FROM public.iam_role_menu rm
          WHERE (rm.role_code = r.role_code)) AS menu_count,
    ( SELECT count(*) AS count
           FROM public.user_role ur
          WHERE (ur.role_code = r.role_code)) AS users_count
   FROM public.role r;


--
-- Name: VIEW v_role_list; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数；034 users_count 真实计数；055 api_count 口径=带端点按钮绑定数；061 updated_at=同步水位）';


--
-- Name: v_role_menu_detail; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_role_menu_detail AS
 SELECT rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, (rm.role_code)::character varying) AS role_name,
    m.menu_name,
    m.menu_type,
    m.api_code AS permission_code,
    m.router AS menu_path,
    m.icon AS menu_icon,
    m.parent_id AS menu_parent_id,
    m.api_url,
    m.api_method,
    m.is_affix
   FROM ((public.iam_role_menu rm
     JOIN public.role r ON ((r.role_code = rm.role_code)))
     JOIN public.iam_menu m ON ((m.id = rm.menu_id)));


--
-- Name: VIEW v_role_menu_detail; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu；055: +端点/固定标签列）';


--
-- Name: v_role_users; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_role_users AS
 SELECT r.name AS role_code,
    r.id AS role_id,
    r.type AS role_type,
    ur.user_id,
    u.username
   FROM ((public.role r
     LEFT JOIN public.user_role ur ON ((ur.role_code = r.role_code)))
     LEFT JOIN public.users u ON ((u.id = ur.user_id)));


--
-- Name: VIEW v_role_users; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_role_users IS '角色→用户镜像视图（管理端角色详情-成员标签页；035: JOIN 键改 r.role_code 清晰化——生成列恒等于 name，原写法碰巧正确）';


--
-- Name: v_system_stats; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_system_stats AS
 SELECT ( SELECT count(*) AS count
           FROM public.tenants) AS total_tenants,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE (users.is_suspended = false)) AS active_users,
    ( SELECT count(*) AS count
           FROM public.users) AS total_users,
    ( SELECT count(*) AS count
           FROM public.role) AS total_roles,
    ( SELECT count(*) AS count
           FROM public.department
          WHERE (department.deleted_at IS NULL)) AS total_departments,
    ( SELECT count(*) AS count
           FROM public.iam_menu
          WHERE iam_menu.is_active) AS total_menus,
    ( SELECT count(*) AS count
           FROM public.iam_menu
          WHERE (iam_menu.is_active AND (iam_menu.api_url IS NOT NULL))) AS total_apis,
    now() AS stats_time;


--
-- Name: VIEW v_system_stats; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_system_stats IS '系统统计面板视图（单行汇总，Logto 镜像表；055: total_apis 口径=button 行带端点；061 tenants 直计）';


--
-- Name: v_system_stats_realtime; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_system_stats_realtime AS
 SELECT NULL::bigint AS online_users,
    NULL::bigint AS blacklisted_tokens,
    ( SELECT max(cron_job_log.execution_time) AS max
           FROM public.cron_job_log
          WHERE ((cron_job_log.job_name)::text = 'cleanup-old-audit-logs'::text)) AS last_cleanup_time,
    ( SELECT count(*) AS count
           FROM public.audit_log
          WHERE (audit_log.created_at > (now() - '24:00:00'::interval))) AS audit_24h,
    now() AS stats_time;


--
-- Name: VIEW v_system_stats_realtime; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_system_stats_realtime IS '实时系统统计视图（T9: 会话/黑名单计数置 NULL，Logto 接管；035: last_cleanup_time 改指 cleanup-old-audit-logs）';


--
-- Name: v_user_list; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_user_list AS
 SELECT u.id,
    u.username,
    u.primary_email AS email,
    u.primary_phone AS phone,
    u.name,
    p.tenant_id,
    p.dept_id,
    t.name AS tenant_name,
    d.dept_name,
    (NOT u.is_suspended) AS is_active,
    u.created_at,
    u.logto_updated_at AS updated_at,
    NULL::timestamp with time zone AS deleted_at,
    COALESCE(( SELECT json_agg(ut.organization_id ORDER BY ut.organization_id) AS json_agg
           FROM public.user_tenants ut
          WHERE (ut.user_id = u.id)), '[]'::json) AS organizations
   FROM (((public.users u
     LEFT JOIN public.user_profile p ON ((p.user_id = u.id)))
     LEFT JOIN public.tenants t ON ((p.tenant_id = t.id)))
     LEFT JOIN public.department d ON ((p.dept_id = d.id)));


--
-- Name: VIEW v_user_list; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_user_list IS '用户列表视图（058 +name 列：前端关键词搜索姓名匹配；061 updated_at=同步水位、deleted_at 恒 NULL；含租户名、部门名、组织成员关系）';


--
-- Name: v_user_role_detail; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_user_role_detail AS
 SELECT ut.user_id,
    ut.organization_id AS role_id,
    ut.organization_id AS tenant_id,
    ut.joined_at AS created_at,
    u.username,
    u.primary_email AS email,
    t.name AS role_name,
    t.name AS tenant_name
   FROM ((public.user_tenants ut
     JOIN public.users u ON ((ut.user_id = u.id)))
     JOIN public.tenants t ON ((ut.organization_id = t.id)))
  WHERE (u.is_suspended = false);


--
-- Name: VIEW v_user_role_detail; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_user_role_detail IS '用户-组织成员详情视图（Logto 镜像）';


--
-- Name: v_user_roles; Type: VIEW; Schema: api_v1_public; Owner: -
--

CREATE VIEW api_v1_public.v_user_roles AS
 SELECT u.id AS user_id,
    u.username,
    u.primary_email AS email,
    ur.role_code,
    ur.created_at AS assigned_at
   FROM (public.users u
     LEFT JOIN public.user_role ur ON ((ur.user_id = u.id)));


--
-- Name: VIEW v_user_roles; Type: COMMENT; Schema: api_v1_public; Owner: -
--

COMMENT ON VIEW api_v1_public.v_user_roles IS '用户→角色镜像视图（user_role 分配镜像，管理端详情页）';


--
-- Name: casbin_rule; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.casbin_rule AS
 SELECT NULL::integer AS id,
    'p'::character varying AS ptype,
    (rm.role_code)::character varying AS v0,
    (m.api_url)::character varying AS v1,
    (m.api_method)::character varying AS v2,
    NULL::character varying AS v3,
    NULL::character varying AS v4,
    NULL::character varying AS v5
   FROM (public.iam_role_menu rm
     JOIN public.iam_menu m ON ((rm.menu_id = m.id)))
  WHERE (m.is_active AND (m.api_url IS NOT NULL))
UNION ALL
 SELECT NULL::integer AS id,
    'p'::character varying AS ptype,
    (rm.role_code)::character varying AS v0,
    (m.router)::character varying AS v1,
    'menu'::character varying AS v2,
    NULL::character varying AS v3,
    NULL::character varying AS v4,
    NULL::character varying AS v5
   FROM (public.iam_role_menu rm
     JOIN public.iam_menu m ON ((rm.menu_id = m.id)))
  WHERE m.is_active;


--
-- Name: VIEW casbin_rule; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.casbin_rule IS 'Casbin 策略运行视图（055 双段）：API 段 = role_menu→button 行端点（v1=api_url, v2=api_method）+ 菜单段 = role_menu→router（v2=menu）原样保留';


--
-- Name: COLUMN casbin_rule.v0; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.casbin_rule.v0 IS '策略主体：角色代码（role_code）';


--
-- Name: COLUMN casbin_rule.v1; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.casbin_rule.v1 IS '策略对象：API 路径 / 菜单路径';


--
-- Name: COLUMN casbin_rule.v2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.casbin_rule.v2 IS '策略动作：HTTP 方法 / menu';


--
-- Name: iam_role_data_scope; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.iam_role_data_scope (
    id uuid DEFAULT uuidv7() NOT NULL,
    role_code text NOT NULL,
    scope_type public.scope_type DEFAULT 'self'::public.scope_type NOT NULL,
    dept_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    CONSTRAINT iam_role_data_scope_dept_consistency CHECK ((((scope_type = 'custom'::public.scope_type) AND (dept_id IS NOT NULL)) OR ((scope_type <> 'custom'::public.scope_type) AND (dept_id IS NULL))))
);


--
-- Name: TABLE iam_role_data_scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.iam_role_data_scope IS '角色数据范围（授权判定数据；RLS 部门维度过滤的依据）';


--
-- Name: COLUMN iam_role_data_scope.scope_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_role_data_scope.scope_type IS '数据范围: all=全部 / dept_and_child=本部门及以下 / self=仅本人 / custom=自定义部门';


--
-- Name: COLUMN iam_role_data_scope.dept_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.iam_role_data_scope.dept_id IS 'custom 时指定部门（一个角色可多行）；其余类型恒 NULL（约束保证）';


--
-- Name: ip_geolite2_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_geolite2_blocks (
    network cidr NOT NULL,
    geoname_id bigint,
    registered_country_geoname_id bigint,
    represented_country_geoname_id bigint,
    is_anonymous_proxy boolean,
    is_satellite_provider boolean,
    postal_code text,
    latitude double precision,
    longitude double precision,
    accuracy_radius integer
);


--
-- Name: TABLE ip_geolite2_blocks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ip_geolite2_blocks IS 'GeoLite2-City-Blocks-IPv4.csv staging（导入管道）';


--
-- Name: ip_geolite2_city; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_geolite2_city (
    network cidr NOT NULL,
    geoname_id bigint,
    latitude double precision,
    longitude double precision,
    accuracy_radius integer,
    timezone text,
    country_name text,
    city_name text
);


--
-- Name: TABLE ip_geolite2_city; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ip_geolite2_city IS 'GeoLite2-City 离线库（Blocks×Locations join 导入，只读）；全球覆盖含经纬度/时区；ip2region 未命中或 IPv6 时兜底';


--
-- Name: ip_geolite2_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_geolite2_locations (
    geoname_id bigint NOT NULL,
    locale_code text NOT NULL,
    continent_code text,
    continent_name text,
    country_iso_code text,
    country_name text,
    subdivision_1_iso_code text,
    subdivision_1_name text,
    subdivision_2_iso_code text,
    subdivision_2_name text,
    city_name text,
    metro_code integer,
    time_zone text,
    is_in_european_union boolean
);


--
-- Name: TABLE ip_geolite2_locations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ip_geolite2_locations IS 'GeoLite2-City-Locations-zh-CN.csv staging（导入管道）';


--
-- Name: ip_region_v4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ip_region_v4 (
    start_ip inet NOT NULL,
    end_ip inet NOT NULL,
    country text NOT NULL,
    province text,
    city text,
    isp text,
    iso_code text,
    CONSTRAINT ip_region_v4_check CHECK ((start_ip <= end_ip))
);


--
-- Name: TABLE ip_region_v4; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.ip_region_v4 IS 'IP 归属地离线库（ip2region v4 数据导入，只读）';


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sys_cron_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sys_cron_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sys_cron_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sys_cron_log_id_seq OWNED BY public.cron_job_log.id;


--
-- Name: sys_login_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sys_login_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sys_login_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sys_login_log_id_seq OWNED BY public.login_log.id;


--
-- Name: webhook_event_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_event_log (
    id uuid DEFAULT uuidv7() NOT NULL,
    hook_id text,
    event text NOT NULL,
    logto_created timestamp with time zone,
    payload jsonb NOT NULL,
    result text DEFAULT 'received'::text NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE webhook_event_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.webhook_event_log IS 'Logto webhook 事件日志（N6：同步链路可观测；payload 留存供审计/重放；保留 90 天）';


--
-- Name: COLUMN webhook_event_log.result; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.webhook_event_log.result IS '处理结果：received（落库未完成）/ success / error（同步失败）/ ignored（未知事件）';


--
-- Name: cron_job_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cron_job_log ALTER COLUMN id SET DEFAULT nextval('public.sys_cron_log_id_seq'::regclass);


--
-- Name: login_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_log ALTER COLUMN id SET DEFAULT nextval('public.sys_login_log_id_seq'::regclass);


--
-- Name: iam_menu iam_menu_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_menu
    ADD CONSTRAINT iam_menu_pkey PRIMARY KEY (id);


--
-- Name: iam_role_data_scope iam_role_data_scope_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_data_scope
    ADD CONSTRAINT iam_role_data_scope_pkey PRIMARY KEY (id);


--
-- Name: iam_role_data_scope iam_role_data_scope_role_code_scope_type_dept_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_data_scope
    ADD CONSTRAINT iam_role_data_scope_role_code_scope_type_dept_id_key UNIQUE (role_code, scope_type, dept_id);


--
-- Name: iam_role_menu iam_role_menu_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_menu
    ADD CONSTRAINT iam_role_menu_pkey PRIMARY KEY (id);


--
-- Name: iam_role_menu iam_role_menu_role_code_menu_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_menu
    ADD CONSTRAINT iam_role_menu_role_code_menu_id_key UNIQUE (role_code, menu_id);


--
-- Name: role iam_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT iam_role_pkey PRIMARY KEY (id);


--
-- Name: ip_geolite2_city ip_geolite2_city_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ip_geolite2_city
    ADD CONSTRAINT ip_geolite2_city_pkey PRIMARY KEY (network);


--
-- Name: organization_role organization_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_role
    ADD CONSTRAINT organization_role_pkey PRIMARY KEY (id);


--
-- Name: position position_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT position_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: audit_log sys_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT sys_audit_log_pkey PRIMARY KEY (id);


--
-- Name: app_config sys_config_config_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_config
    ADD CONSTRAINT sys_config_config_key_key UNIQUE (config_key);


--
-- Name: app_config sys_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_config
    ADD CONSTRAINT sys_config_pkey PRIMARY KEY (id);


--
-- Name: cron_job_log sys_cron_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cron_job_log
    ADD CONSTRAINT sys_cron_log_pkey PRIMARY KEY (id);


--
-- Name: department sys_department_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT sys_department_pkey PRIMARY KEY (id);


--
-- Name: dict_data sys_dict_data_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dict_data
    ADD CONSTRAINT sys_dict_data_pkey PRIMARY KEY (id);


--
-- Name: dict_type sys_dict_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dict_type
    ADD CONSTRAINT sys_dict_type_pkey PRIMARY KEY (id);


--
-- Name: dict_type sys_dict_type_tenant_id_dict_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dict_type
    ADD CONSTRAINT sys_dict_type_tenant_id_dict_name_key UNIQUE (tenant_id, dict_name);


--
-- Name: login_log sys_login_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_log
    ADD CONSTRAINT sys_login_log_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: user_position user_position_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_position
    ADD CONSTRAINT user_position_pkey PRIMARY KEY (user_id, position_id);


--
-- Name: user_profile user_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT user_profile_pkey PRIMARY KEY (user_id);


--
-- Name: user_role user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, organization_id, role_code);


--
-- Name: user_tenants user_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenants
    ADD CONSTRAINT user_tenants_pkey PRIMARY KEY (organization_id, user_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: webhook_event_log webhook_event_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_event_log
    ADD CONSTRAINT webhook_event_log_pkey PRIMARY KEY (id);


--
-- Name: idx_audit_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_created ON public.audit_log USING btree (created_at);


--
-- Name: idx_audit_logtype; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logtype ON public.audit_log USING btree (log_type, created_at DESC);


--
-- Name: idx_audit_operation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_operation ON public.audit_log USING btree (operation);


--
-- Name: idx_audit_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_tenant ON public.audit_log USING btree (tenant_id);


--
-- Name: idx_audit_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_user ON public.audit_log USING btree (user_id);


--
-- Name: idx_config_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_key ON public.app_config USING btree (config_key);


--
-- Name: idx_config_public; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_public ON public.app_config USING btree (is_public) WHERE (is_public = true);


--
-- Name: idx_dept_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dept_parent ON public.department USING btree (parent_id);


--
-- Name: idx_dept_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dept_tenant ON public.department USING btree (tenant_id);


--
-- Name: idx_dict_data_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dict_data_name ON public.dict_data USING btree (dict_name, sort_no);


--
-- Name: idx_iam_menu_api_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_menu_api_code ON public.iam_menu USING btree (api_code);


--
-- Name: idx_iam_menu_api_url_method; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_iam_menu_api_url_method ON public.iam_menu USING btree (api_url, api_method) WHERE (api_url IS NOT NULL);


--
-- Name: idx_iam_menu_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_menu_parent ON public.iam_menu USING btree (parent_id);


--
-- Name: idx_iam_menu_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_menu_type ON public.iam_menu USING btree (menu_type);


--
-- Name: idx_iam_role_data_scope_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_role_data_scope_dept ON public.iam_role_data_scope USING btree (dept_id);


--
-- Name: idx_iam_role_data_scope_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_role_data_scope_role ON public.iam_role_data_scope USING btree (role_code);


--
-- Name: idx_iam_role_menu_menu; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_role_menu_menu ON public.iam_role_menu USING btree (menu_id);


--
-- Name: idx_iam_role_menu_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iam_role_menu_role ON public.iam_role_menu USING btree (role_code);


--
-- Name: idx_ip_region_end; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ip_region_end ON public.ip_region_v4 USING btree (end_ip);


--
-- Name: idx_ip_region_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ip_region_start ON public.ip_region_v4 USING btree (start_ip);


--
-- Name: idx_login_log_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_log_created ON public.login_log USING btree (created_at DESC);


--
-- Name: idx_login_log_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_log_user ON public.login_log USING btree (user_id, created_at DESC);


--
-- Name: idx_org_role_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_org_role_name ON public.organization_role USING btree (name);


--
-- Name: idx_position_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_position_parent ON public."position" USING btree (parent_id);


--
-- Name: idx_position_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_position_tenant ON public."position" USING btree (tenant_id);


--
-- Name: idx_role_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_role_name ON public.role USING btree (name);


--
-- Name: idx_role_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_type ON public.role USING btree (type);


--
-- Name: idx_tenants_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_name ON public.tenants USING btree (name);


--
-- Name: idx_user_position_pos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_position_pos ON public.user_position USING btree (position_id);


--
-- Name: idx_user_position_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_position_tenant ON public.user_position USING btree (tenant_id);


--
-- Name: idx_user_profile_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_profile_tenant ON public.user_profile USING btree (tenant_id);


--
-- Name: idx_users_is_suspended; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_is_suspended ON public.users USING btree (is_suspended);


--
-- Name: idx_users_primary_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_primary_email ON public.users USING btree (primary_email);


--
-- Name: idx_users_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_username ON public.users USING btree (username);


--
-- Name: idx_ut_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ut_org ON public.user_tenants USING btree (organization_id);


--
-- Name: idx_ut_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ut_user ON public.user_tenants USING btree (user_id);


--
-- Name: idx_wev_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wev_created ON public.webhook_event_log USING btree (created_at DESC);


--
-- Name: idx_wev_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wev_event ON public.webhook_event_log USING btree (event);


--
-- Name: idx_wev_hook; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wev_hook ON public.webhook_event_log USING btree (hook_id);


--
-- Name: idx_wev_result; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wev_result ON public.webhook_event_log USING btree (result);


--
-- Name: app_config trg_app_config_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_app_config_updated_at BEFORE UPDATE ON public.app_config FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: app_config trg_audit_app_config; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_app_config AFTER INSERT OR DELETE OR UPDATE ON public.app_config FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: department trg_audit_department; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_department AFTER INSERT OR DELETE OR UPDATE ON public.department FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: dict_data trg_audit_dict_data; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_dict_data AFTER INSERT OR DELETE OR UPDATE ON public.dict_data FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: dict_type trg_audit_dict_type; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_dict_type AFTER INSERT OR DELETE OR UPDATE ON public.dict_type FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: iam_menu trg_audit_iam_menu; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_iam_menu AFTER INSERT OR DELETE OR UPDATE ON public.iam_menu FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: position trg_audit_position; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_position AFTER INSERT OR DELETE OR UPDATE ON public."position" FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: iam_role_menu trg_audit_role_menu; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_role_menu AFTER INSERT OR DELETE OR UPDATE ON public.iam_role_menu FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();


--
-- Name: user_position trg_audit_user_position; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_user_position AFTER INSERT OR DELETE OR UPDATE ON public.user_position FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: user_profile trg_audit_user_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_user_profile AFTER INSERT OR DELETE OR UPDATE ON public.user_profile FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func('tenant_aware');


--
-- Name: department trg_department_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_department_updated_at BEFORE UPDATE ON public.department FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: dict_data trg_dict_data_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_dict_data_updated_at BEFORE UPDATE ON public.dict_data FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: dict_type trg_dict_type_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_dict_type_updated_at BEFORE UPDATE ON public.dict_type FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: iam_menu trg_iam_menu_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_iam_menu_updated_at BEFORE UPDATE ON public.iam_menu FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: position trg_position_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_position_updated_at BEFORE UPDATE ON public."position" FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: user_profile trg_user_profile_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_user_profile_updated_at BEFORE UPDATE ON public.user_profile FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: iam_menu iam_menu_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_menu
    ADD CONSTRAINT iam_menu_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.iam_menu(id) ON DELETE SET NULL;


--
-- Name: iam_role_data_scope iam_role_data_scope_dept_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_data_scope
    ADD CONSTRAINT iam_role_data_scope_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.department(id) ON DELETE CASCADE;


--
-- Name: iam_role_menu iam_role_menu_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.iam_role_menu
    ADD CONSTRAINT iam_role_menu_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES public.iam_menu(id) ON DELETE CASCADE;


--
-- Name: position position_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT position_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public."position"(id) ON DELETE CASCADE;


--
-- Name: department sys_department_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT sys_department_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.department(id) ON DELETE CASCADE;


--
-- Name: user_position user_position_position_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_position
    ADD CONSTRAINT user_position_position_id_fkey FOREIGN KEY (position_id) REFERENCES public."position"(id) ON DELETE CASCADE;


--
-- Name: user_position user_position_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_position
    ADD CONSTRAINT user_position_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_profile user_profile_dept_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT user_profile_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.department(id) ON DELETE SET NULL;


--
-- Name: user_profile user_profile_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT user_profile_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE RESTRICT;


--
-- Name: user_profile user_profile_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT user_profile_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_role user_role_role_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_role_id_fk FOREIGN KEY (role_id) REFERENCES public.role(id) ON DELETE CASCADE;


--
-- Name: user_role user_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_tenants user_tenants_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenants
    ADD CONSTRAINT user_tenants_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: user_tenants user_tenants_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenants
    ADD CONSTRAINT user_tenants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log audit_log_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY audit_log_read_policy ON public.audit_log FOR SELECT USING ((public.is_super_admin() OR (tenant_id = public.current_tenant_id())));


--
-- Name: department; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.department ENABLE ROW LEVEL SECURITY;

--
-- Name: department dept_tenant_isolation_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dept_tenant_isolation_policy ON public.department AS RESTRICTIVE USING ((tenant_id = public.current_tenant_id())) WITH CHECK ((tenant_id = public.current_tenant_id()));


--
-- Name: dict_data; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dict_data ENABLE ROW LEVEL SECURITY;

--
-- Name: dict_data dict_data_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dict_data_read_policy ON public.dict_data FOR SELECT USING ((public.is_super_admin() OR (tenant_id IS NULL) OR (tenant_id = public.current_tenant_id())));


--
-- Name: dict_type; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dict_type ENABLE ROW LEVEL SECURITY;

--
-- Name: dict_type dict_type_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dict_type_read_policy ON public.dict_type FOR SELECT USING ((public.is_super_admin() OR (tenant_id IS NULL) OR (tenant_id = public.current_tenant_id())));


--
-- Name: ip_geolite2_city geolite2_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY geolite2_read_policy ON public.ip_geolite2_city FOR SELECT USING (true);


--
-- Name: iam_menu; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.iam_menu ENABLE ROW LEVEL SECURITY;

--
-- Name: iam_role_data_scope; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.iam_role_data_scope ENABLE ROW LEVEL SECURITY;

--
-- Name: iam_role_menu; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.iam_role_menu ENABLE ROW LEVEL SECURITY;

--
-- Name: ip_geolite2_city; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ip_geolite2_city ENABLE ROW LEVEL SECURITY;

--
-- Name: ip_region_v4 ip_region_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ip_region_read_policy ON public.ip_region_v4 FOR SELECT USING (true);


--
-- Name: ip_region_v4; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ip_region_v4 ENABLE ROW LEVEL SECURITY;

--
-- Name: login_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.login_log ENABLE ROW LEVEL SECURITY;

--
-- Name: login_log login_log_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY login_log_read_policy ON public.login_log FOR SELECT USING ((public.is_super_admin() OR (tenant_id = public.current_tenant_id()) OR (user_id = public.current_user_id())));


--
-- Name: iam_menu menu_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_read_policy ON public.iam_menu FOR SELECT USING ((is_active = true));


--
-- Name: organization_role org_role_select_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY org_role_select_policy ON public.organization_role FOR SELECT USING (true);


--
-- Name: organization_role; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_role ENABLE ROW LEVEL SECURITY;

--
-- Name: position; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."position" ENABLE ROW LEVEL SECURITY;

--
-- Name: position position_tenant_isolation_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY position_tenant_isolation_policy ON public."position" AS RESTRICTIVE USING ((tenant_id = public.current_tenant_id())) WITH CHECK ((tenant_id = public.current_tenant_id()));


--
-- Name: user_profile profile_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profile_tenant_policy ON public.user_profile USING ((public.is_super_admin() OR (user_id = public.current_user_id()) OR (tenant_id = public.current_tenant_id()))) WITH CHECK ((public.is_super_admin() OR (user_id = public.current_user_id())));


--
-- Name: role; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role ENABLE ROW LEVEL SECURITY;

--
-- Name: iam_role_data_scope role_data_scope_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_data_scope_read_policy ON public.iam_role_data_scope FOR SELECT USING (true);


--
-- Name: iam_role_menu role_menu_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_menu_read_policy ON public.iam_role_menu FOR SELECT USING (true);


--
-- Name: role role_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_read_policy ON public.role FOR SELECT USING (true);


--
-- Name: tenants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

--
-- Name: tenants tenants_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenants_read_policy ON public.tenants FOR SELECT USING ((public.is_super_admin() OR (id = public.current_tenant_id()) OR (EXISTS ( SELECT 1
   FROM public.user_tenants ut
  WHERE ((ut.organization_id = tenants.id) AND (ut.user_id = public.current_user_id()))))));


--
-- Name: user_position; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_position ENABLE ROW LEVEL SECURITY;

--
-- Name: user_position user_position_tenant_isolation_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_position_tenant_isolation_policy ON public.user_position AS RESTRICTIVE USING ((tenant_id = public.current_tenant_id())) WITH CHECK ((tenant_id = public.current_tenant_id()));


--
-- Name: user_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: user_role; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_role ENABLE ROW LEVEL SECURITY;

--
-- Name: user_role user_role_read_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_role_read_policy ON public.user_role FOR SELECT USING ((public.is_super_admin() OR (user_id = public.current_user_id())));


--
-- Name: user_tenants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_tenants ENABLE ROW LEVEL SECURITY;

--
-- Name: user_tenants user_tenants_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_tenants_policy ON public.user_tenants USING ((public.is_super_admin() OR (user_id = public.current_user_id()) OR (organization_id = public.current_tenant_id())));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_tenant_policy ON public.users USING ((public.is_super_admin() OR (id = public.current_user_id()) OR (EXISTS ( SELECT 1
   FROM public.user_profile p
  WHERE ((p.user_id = users.id) AND (p.tenant_id = public.current_tenant_id()) AND (p.deleted_at IS NULL))))));


--
-- Name: webhook_event_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.webhook_event_log ENABLE ROW LEVEL SECURITY;

--
-- Name: webhook_event_log webhook_event_log_select_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webhook_event_log_select_policy ON public.webhook_event_log FOR SELECT USING (public.is_super_admin());


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('064'),
    ('065'),
    ('066');
