-- 065_v010_baseline.sql
-- v0.1.0 squash baseline（2026-08-16 用户拍板，方案 36-迁移基线合并）
--   业务表结构：department、position、user_profile、user_position、iam_menu、iam_role_menu、iam_role_data_scope、dict_type、dict_data、app_config、audit_log、login_log、cron_job_log、webhook_event_log、ip_geolite2_city/blocks/locations、ip_region_v4（18 张）。依赖 064 镜像表。
--   来源：现库 pg_dump 反写（2026-08-15 审计追平终态，含 059-063 全部变更）。
--   17 号铁律：本文件仅承载表结构；RLS 策略/触发器/枚举/函数/视图归 src（apply-src 部署）。
--   幂等：CREATE IF NOT EXISTS / 约束 DO 守卫 / COMMENT 覆盖——apply-src 全量重放安全。
--   回滚：无 down 语义（squash baseline）；历史 62 个迁移见 git tag v0.1.0。
-- migrate:up
CREATE TABLE IF NOT EXISTS public.app_config (
    id uuid DEFAULT uuidv7() CONSTRAINT sys_config_id_not_null NOT NULL,
    config_key character varying(100) CONSTRAINT sys_config_config_key_not_null NOT NULL,
    config_value text,
    config_type character varying(20) DEFAULT 'string'::character varying CONSTRAINT sys_config_config_type_not_null NOT NULL,
    description character varying(255),
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT sys_config_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT sys_config_updated_at_not_null NOT NULL
);
CREATE TABLE IF NOT EXISTS public.audit_log (
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
COMMENT ON COLUMN public.audit_log.log_type IS '日志类型: data_change(触发器差异日志,默认) / operate(业务操作) / login(登录) / exception(异常) / event(事件) / open_api(开放接口)';
COMMENT ON COLUMN public.audit_log.module IS '业务模块（order/user/...）';
COMMENT ON COLUMN public.audit_log.action IS '操作标识（order.approve）';
COMMENT ON COLUMN public.audit_log.target_type IS '操作对象类型';
COMMENT ON COLUMN public.audit_log.target_id IS '操作对象 ID';
COMMENT ON COLUMN public.audit_log.result IS '执行结果: success / fail';
COMMENT ON COLUMN public.audit_log.region IS 'IP 归属地（ip2region: 国家|省|市|ISP）';
CREATE TABLE IF NOT EXISTS public.cron_job_log (
    id bigint CONSTRAINT sys_cron_log_id_not_null NOT NULL,
    job_name character varying(100) CONSTRAINT sys_cron_log_job_name_not_null NOT NULL,
    execution_time timestamp with time zone DEFAULT now() CONSTRAINT sys_cron_log_execution_time_not_null NOT NULL,
    result jsonb,
    duration_ms integer
);
COMMENT ON TABLE public.cron_job_log IS 'pg_cron 任务执行日志';
CREATE TABLE IF NOT EXISTS public.department (
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
COMMENT ON TABLE public.department IS '部门组织架构表，按租户隔离';
COMMENT ON COLUMN public.department.tenant_id IS '所属租户，租户间部门数据隔离';
COMMENT ON COLUMN public.department.parent_id IS '上级部门 ID，NULL 表示根部门';
COMMENT ON COLUMN public.department.created_by IS '创建者用户 ID';
COMMENT ON COLUMN public.department.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN public.department.deleted_by IS '删除者用户 ID';
CREATE TABLE IF NOT EXISTS public.dict_data (
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
COMMENT ON TABLE public.dict_data IS '字典数据项';
CREATE TABLE IF NOT EXISTS public.dict_type (
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
COMMENT ON TABLE public.dict_type IS '字典类型（全局 + 租户两级）';
COMMENT ON COLUMN public.dict_type.tenant_id IS 'NULL=全局字典（所有租户共享）；非 NULL=租户字典（RLS 按 claims 过滤）';
CREATE TABLE IF NOT EXISTS public.iam_menu (
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
COMMENT ON TABLE public.iam_menu IS '菜单树（PG 自主数据）；role_code 经 iam_role_menu 绑定角色';
COMMENT ON COLUMN public.iam_menu.router IS '路由地址（前端 vue-router path；link 类型为 http(s):// 外链 URL；原 path）';
COMMENT ON COLUMN public.iam_menu.menu_type IS '菜单类型: directory(目录) / menu(菜单) / button(按钮) / link(外链或iframe，032)';
COMMENT ON COLUMN public.iam_menu.api_code IS '权限码（单码制：与 iam_api.api_code 同码；button 必填，has_permission 双通道判定键；原 perms）';
COMMENT ON COLUMN public.iam_menu.component IS '前端组件路径（路由渲染，仅 menu 类型使用）';
COMMENT ON COLUMN public.iam_menu.is_visible IS '是否显示（目录/菜单显隐控制）';
COMMENT ON COLUMN public.iam_menu.remark IS '备注（管理端展示）';
COMMENT ON COLUMN public.iam_menu.route_name IS '路由名称（Vue Router name，英文唯一；前端 addRoute 用）';
COMMENT ON COLUMN public.iam_menu.is_link IS '是否外链（新窗口打开；menu_type=link 时自动置 true）';
COMMENT ON COLUMN public.iam_menu.is_iframe IS '是否 iframe 内嵌（path 为内嵌 URL）';
COMMENT ON COLUMN public.iam_menu.redirect IS '目录重定向路径（noRedirect 表示不重定向）';
COMMENT ON COLUMN public.iam_menu.is_cache IS '是否缓存页面（keep-alive，默认 true；057 由 keep_alive 改名——语义对标 SharpFort IsCache/RuoYi is_cache + iam_menu 布尔列 is_ 前缀命名统一）';
COMMENT ON COLUMN public.iam_menu.api_url IS 'API 端点路径（原 iam_api.path，055 单表化 D1；仅 button 行使用；SharpFort ApiUrl 借鉴；约定以 / 开头不含 {}，RPC 层软校验 P2）';
COMMENT ON COLUMN public.iam_menu.api_method IS 'API 端点方法（原 iam_api.method，055 单表化 D1；api_url 非空时必填，值域 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*；SharpFort ApiMethod 借鉴）';
COMMENT ON COLUMN public.iam_menu.is_affix IS '是否固定标签页（Admin.NET IsAffix 借鉴；多页签前端布局使用，默认 false）';
CREATE TABLE IF NOT EXISTS public.iam_role_menu (
    id uuid DEFAULT uuidv7() NOT NULL,
    role_code text NOT NULL,
    menu_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text
);
COMMENT ON TABLE public.iam_role_menu IS '角色→菜单绑定（PG 自主数据）';
CREATE TABLE IF NOT EXISTS public.login_log (
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
COMMENT ON TABLE public.login_log IS '登录日志（业务端安全审计镜像：Logto 审计日志无租户隔离/会被清理，业务端保留长期记录）';
CREATE TABLE IF NOT EXISTS public."position" (
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
COMMENT ON TABLE public."position" IS '岗位表（树形，租户隔离）。岗位=职级/职务维度，与权限无关（权限用角色）';
COMMENT ON COLUMN public."position".parent_id IS '上级岗位 ID，NULL 表示根岗位';
CREATE TABLE IF NOT EXISTS public.user_position (
    user_id text NOT NULL,
    position_id uuid NOT NULL,
    tenant_id text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text
);
COMMENT ON TABLE public.user_position IS '用户-岗位关联（多对多，租户隔离）';
CREATE TABLE IF NOT EXISTS public.user_profile (
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
COMMENT ON TABLE public.user_profile IS '用户个人资料（应用自有扩展，用户可编辑）：users 为 Logto 认证镜像只读，user_profile 承载 nickname/头像/生日/爱好/住址等个人信息；RLS 本人/超管可写（rls_policies.sql profile_tenant_policy）';
COMMENT ON COLUMN public.user_profile.user_id IS 'Logto 用户 id（users.id 1:1；主键即外键，ON DELETE CASCADE）';
COMMENT ON COLUMN public.user_profile.tenant_id IS '租户 organization_id（017 约定；NULL=全局个人资料）';
COMMENT ON COLUMN public.user_profile.dept_id IS '部门归属（current_user_dept_id 依赖；department 表）';
COMMENT ON COLUMN public.user_profile.nickname IS '昵称（应用自定义显示名；users.name 为 Logto 权威显示名，不重复）';
COMMENT ON COLUMN public.user_profile.avatar_url IS '头像 URL（空=默认头像，前端兜底）';
COMMENT ON COLUMN public.user_profile.gender IS '性别（gender 枚举：male/female/other/prefer_not_to_say）';
COMMENT ON COLUMN public.user_profile.birthday IS '生日（隐私字段；前端按需脱敏）';
COMMENT ON COLUMN public.user_profile.bio IS '个人简介（≤500 字）';
COMMENT ON COLUMN public.user_profile.location IS '所在地/住址（自由文本）';
COMMENT ON COLUMN public.user_profile.hobbies IS '爱好（标签数组，如 {"篮球","摄影"}）';
COMMENT ON COLUMN public.user_profile.website IS '个人主页 URL';
COMMENT ON COLUMN public.user_profile.preferences IS '偏好扩展 JSONB（language/timezone/theme/通知开关等；前端自定义键，Auth0 user_metadata 模式）';
CREATE TABLE IF NOT EXISTS public.iam_role_data_scope (
    id uuid DEFAULT uuidv7() NOT NULL,
    role_code text NOT NULL,
    scope_type public.scope_type DEFAULT 'self'::public.scope_type NOT NULL,
    dept_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    CONSTRAINT iam_role_data_scope_dept_consistency CHECK ((((scope_type = 'custom'::public.scope_type) AND (dept_id IS NOT NULL)) OR ((scope_type <> 'custom'::public.scope_type) AND (dept_id IS NULL))))
);
COMMENT ON TABLE public.iam_role_data_scope IS '角色数据范围（授权判定数据；RLS 部门维度过滤的依据）';
COMMENT ON COLUMN public.iam_role_data_scope.scope_type IS '数据范围: all=全部 / dept_and_child=本部门及以下 / self=仅本人 / custom=自定义部门';
COMMENT ON COLUMN public.iam_role_data_scope.dept_id IS 'custom 时指定部门（一个角色可多行）；其余类型恒 NULL（约束保证）';
CREATE TABLE IF NOT EXISTS public.ip_geolite2_blocks (
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
COMMENT ON TABLE public.ip_geolite2_blocks IS 'GeoLite2-City-Blocks-IPv4.csv staging（导入管道）';
CREATE TABLE IF NOT EXISTS public.ip_geolite2_city (
    network cidr NOT NULL,
    geoname_id bigint,
    latitude double precision,
    longitude double precision,
    accuracy_radius integer,
    timezone text,
    country_name text,
    city_name text
);
COMMENT ON TABLE public.ip_geolite2_city IS 'GeoLite2-City 离线库（Blocks×Locations join 导入，只读）；全球覆盖含经纬度/时区；ip2region 未命中或 IPv6 时兜底';
CREATE TABLE IF NOT EXISTS public.ip_geolite2_locations (
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
COMMENT ON TABLE public.ip_geolite2_locations IS 'GeoLite2-City-Locations-zh-CN.csv staging（导入管道）';
CREATE TABLE IF NOT EXISTS public.ip_region_v4 (
    start_ip inet NOT NULL,
    end_ip inet NOT NULL,
    country text NOT NULL,
    province text,
    city text,
    isp text,
    iso_code text,
    CONSTRAINT ip_region_v4_check CHECK ((start_ip <= end_ip))
);
COMMENT ON TABLE public.ip_region_v4 IS 'IP 归属地离线库（ip2region v4 数据导入，只读）';
CREATE SEQUENCE IF NOT EXISTS public.sys_cron_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.sys_cron_log_id_seq OWNED BY public.cron_job_log.id;
CREATE SEQUENCE IF NOT EXISTS public.sys_login_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.sys_login_log_id_seq OWNED BY public.login_log.id;
CREATE TABLE IF NOT EXISTS public.webhook_event_log (
    id uuid DEFAULT uuidv7() NOT NULL,
    hook_id text,
    event text NOT NULL,
    logto_created timestamp with time zone,
    payload jsonb NOT NULL,
    result text DEFAULT 'received'::text NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE public.webhook_event_log IS 'Logto webhook 事件日志（N6：同步链路可观测；payload 留存供审计/重放；保留 90 天）';
COMMENT ON COLUMN public.webhook_event_log.result IS '处理结果：received（落库未完成）/ success / error（同步失败）/ ignored（未知事件）';
ALTER TABLE ONLY public.cron_job_log ALTER COLUMN id SET DEFAULT nextval('public.sys_cron_log_id_seq'::regclass);
ALTER TABLE ONLY public.login_log ALTER COLUMN id SET DEFAULT nextval('public.sys_login_log_id_seq'::regclass);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_pkey') THEN
        ALTER TABLE ONLY public.iam_menu ADD CONSTRAINT iam_menu_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_pkey') THEN
        ALTER TABLE ONLY public.iam_role_data_scope ADD CONSTRAINT iam_role_data_scope_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_role_code_scope_type_dept_id_key') THEN
        ALTER TABLE ONLY public.iam_role_data_scope ADD CONSTRAINT iam_role_data_scope_role_code_scope_type_dept_id_key UNIQUE (role_code, scope_type, dept_id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_pkey') THEN
        ALTER TABLE ONLY public.iam_role_menu ADD CONSTRAINT iam_role_menu_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_role_code_menu_id_key') THEN
        ALTER TABLE ONLY public.iam_role_menu ADD CONSTRAINT iam_role_menu_role_code_menu_id_key UNIQUE (role_code, menu_id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ip_geolite2_city_pkey') THEN
        ALTER TABLE ONLY public.ip_geolite2_city ADD CONSTRAINT ip_geolite2_city_pkey PRIMARY KEY (network);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'position_pkey') THEN
        ALTER TABLE ONLY public."position" ADD CONSTRAINT position_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_audit_log_pkey') THEN
        ALTER TABLE ONLY public.audit_log ADD CONSTRAINT sys_audit_log_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_config_config_key_key') THEN
        ALTER TABLE ONLY public.app_config ADD CONSTRAINT sys_config_config_key_key UNIQUE (config_key);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_config_pkey') THEN
        ALTER TABLE ONLY public.app_config ADD CONSTRAINT sys_config_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_cron_log_pkey') THEN
        ALTER TABLE ONLY public.cron_job_log ADD CONSTRAINT sys_cron_log_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_department_pkey') THEN
        ALTER TABLE ONLY public.department ADD CONSTRAINT sys_department_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_dict_data_pkey') THEN
        ALTER TABLE ONLY public.dict_data ADD CONSTRAINT sys_dict_data_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_dict_type_pkey') THEN
        ALTER TABLE ONLY public.dict_type ADD CONSTRAINT sys_dict_type_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_dict_type_tenant_id_dict_name_key') THEN
        ALTER TABLE ONLY public.dict_type ADD CONSTRAINT sys_dict_type_tenant_id_dict_name_key UNIQUE (tenant_id, dict_name);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_login_log_pkey') THEN
        ALTER TABLE ONLY public.login_log ADD CONSTRAINT sys_login_log_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_pkey') THEN
        ALTER TABLE ONLY public.user_position ADD CONSTRAINT user_position_pkey PRIMARY KEY (user_id, position_id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_pkey') THEN
        ALTER TABLE ONLY public.user_profile ADD CONSTRAINT user_profile_pkey PRIMARY KEY (user_id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'webhook_event_log_pkey') THEN
        ALTER TABLE ONLY public.webhook_event_log ADD CONSTRAINT webhook_event_log_pkey PRIMARY KEY (id);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_audit_created ON public.audit_log USING btree (created_at);
CREATE INDEX IF NOT EXISTS idx_audit_logtype ON public.audit_log USING btree (log_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_operation ON public.audit_log USING btree (operation);
CREATE INDEX IF NOT EXISTS idx_audit_tenant ON public.audit_log USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_user ON public.audit_log USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_config_key ON public.app_config USING btree (config_key);
CREATE INDEX IF NOT EXISTS idx_config_public ON public.app_config USING btree (is_public) WHERE (is_public = true);
CREATE INDEX IF NOT EXISTS idx_dept_parent ON public.department USING btree (parent_id);
CREATE INDEX IF NOT EXISTS idx_dept_tenant ON public.department USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_dict_data_name ON public.dict_data USING btree (dict_name, sort_no);
CREATE INDEX IF NOT EXISTS idx_iam_menu_api_code ON public.iam_menu USING btree (api_code);
CREATE UNIQUE INDEX IF NOT EXISTS idx_iam_menu_api_url_method ON public.iam_menu USING btree (api_url, api_method) WHERE (api_url IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_iam_menu_parent ON public.iam_menu USING btree (parent_id);
CREATE INDEX IF NOT EXISTS idx_iam_menu_type ON public.iam_menu USING btree (menu_type);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_dept ON public.iam_role_data_scope USING btree (dept_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_role ON public.iam_role_data_scope USING btree (role_code);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_menu ON public.iam_role_menu USING btree (menu_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_role ON public.iam_role_menu USING btree (role_code);
CREATE INDEX IF NOT EXISTS idx_ip_region_end ON public.ip_region_v4 USING btree (end_ip);
CREATE INDEX IF NOT EXISTS idx_ip_region_start ON public.ip_region_v4 USING btree (start_ip);
CREATE INDEX IF NOT EXISTS idx_login_log_created ON public.login_log USING btree (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_login_log_user ON public.login_log USING btree (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_position_parent ON public."position" USING btree (parent_id);
CREATE INDEX IF NOT EXISTS idx_position_tenant ON public."position" USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_position_pos ON public.user_position USING btree (position_id);
CREATE INDEX IF NOT EXISTS idx_user_position_tenant ON public.user_position USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_profile_tenant ON public.user_profile USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_wev_created ON public.webhook_event_log USING btree (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wev_event ON public.webhook_event_log USING btree (event);
CREATE INDEX IF NOT EXISTS idx_wev_hook ON public.webhook_event_log USING btree (hook_id);
CREATE INDEX IF NOT EXISTS idx_wev_result ON public.webhook_event_log USING btree (result);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_parent_id_fkey') THEN
        ALTER TABLE ONLY public.iam_menu ADD CONSTRAINT iam_menu_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.iam_menu(id) ON DELETE SET NULL;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_dept_id_fkey') THEN
        ALTER TABLE ONLY public.iam_role_data_scope ADD CONSTRAINT iam_role_data_scope_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.department(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_menu_id_fkey') THEN
        ALTER TABLE ONLY public.iam_role_menu ADD CONSTRAINT iam_role_menu_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES public.iam_menu(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'position_parent_id_fkey') THEN
        ALTER TABLE ONLY public."position" ADD CONSTRAINT position_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public."position"(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sys_department_parent_id_fkey') THEN
        ALTER TABLE ONLY public.department ADD CONSTRAINT sys_department_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.department(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_position_id_fkey') THEN
        ALTER TABLE ONLY public.user_position ADD CONSTRAINT user_position_position_id_fkey FOREIGN KEY (position_id) REFERENCES public."position"(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_user_id_fkey') THEN
        ALTER TABLE ONLY public.user_position ADD CONSTRAINT user_position_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_dept_id_fkey') THEN
        ALTER TABLE ONLY public.user_profile ADD CONSTRAINT user_profile_dept_id_fkey FOREIGN KEY (dept_id) REFERENCES public.department(id) ON DELETE SET NULL;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_tenant_id_fkey') THEN
        ALTER TABLE ONLY public.user_profile ADD CONSTRAINT user_profile_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE RESTRICT;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_user_id_fkey') THEN
        ALTER TABLE ONLY public.user_profile ADD CONSTRAINT user_profile_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
    END IF;
END $$;

-- migrate:down
-- （无回滚：squash baseline。历史迁移与回滚路径见 git tag v0.1.0 / 全库快照）
