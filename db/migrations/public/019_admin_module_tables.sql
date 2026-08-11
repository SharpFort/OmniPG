-- =============================================================================
-- 019_admin_module_tables.sql — admin 管理模块表补全（T8）
-- =============================================================================
-- 背景: 05.1-Admin管理模块表设计分析 决策落地（2026-08-04 用户拍板）
--   D-3  登录日志业务端保留: sys_login_log（webhook PostSignIn 同步 + ip2region 解析）
--   D-4  ip_region_v4: ip2region 数据导入 PG（零后端 IP 归属解析，无经纬度）
--   D-5  audit_log 单表 + log_type + jsonb（扩展既有触发器差异日志为统一审计流）
--   D-7  字典: sys_dict_type + sys_dict_data（与 TEXT+CHECK 约束并存，不用 PG ENUM）
--   岗位: position 树形表 + user_position 关联（用户拍板立即创建）
--   department 树形已满足（001 已含 parent_id + 索引），无需改造
-- 命名规则（备选方案 B）: 无前缀 = 平台基础域（镜像只读 + 系统管理可写）；
--                         iam_ = 授权域（授权判定数据）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 audit_log 扩展为统一审计流（单表 + log_type + jsonb 详情，D-5）
--    user_id uuid → text（对齐 users.id = Logto nanoid，017 已改 tenant_id）
-- ---------------------------------------------------------------------------
ALTER TABLE public.audit_log
    ALTER COLUMN user_id TYPE text USING user_id::text;

ALTER TABLE public.audit_log
    ADD COLUMN IF NOT EXISTS log_type      TEXT NOT NULL DEFAULT 'data_change',
    ADD COLUMN IF NOT EXISTS module        TEXT,
    ADD COLUMN IF NOT EXISTS action        TEXT,
    ADD COLUMN IF NOT EXISTS target_type   TEXT,
    ADD COLUMN IF NOT EXISTS target_id     TEXT,
    ADD COLUMN IF NOT EXISTS result        TEXT,
    ADD COLUMN IF NOT EXISTS ip            INET,
    ADD COLUMN IF NOT EXISTS user_agent    TEXT,
    ADD COLUMN IF NOT EXISTS region        TEXT,
    ADD COLUMN IF NOT EXISTS duration_ms   INT;

COMMENT ON COLUMN public.audit_log.log_type IS
  '日志类型: data_change(触发器差异日志,默认) / operate(业务操作) / login(登录) / exception(异常) / event(事件) / open_api(开放接口)';
COMMENT ON COLUMN public.audit_log.module IS '业务模块（order/user/...）';
COMMENT ON COLUMN public.audit_log.action IS '操作标识（order.approve）';
COMMENT ON COLUMN public.audit_log.target_type IS '操作对象类型';
COMMENT ON COLUMN public.audit_log.target_id IS '操作对象 ID';
COMMENT ON COLUMN public.audit_log.result IS '执行结果: success / fail';
COMMENT ON COLUMN public.audit_log.region IS 'IP 归属地（ip2region: 国家|省|市|ISP）';

CREATE INDEX IF NOT EXISTS idx_audit_logtype ON public.audit_log(log_type, created_at DESC);

-- 重建视图（含新列；幂等）
DROP VIEW IF EXISTS api_v1_sys.sys_audit_log CASCADE;
CREATE VIEW api_v1_sys.sys_audit_log AS
SELECT id, table_name, operation, old_data, new_data, user_id, tenant_id,
       source, description, log_type, module, action, target_type, target_id,
       result, ip, user_agent, region, duration_ms, created_at
FROM audit_log;
COMMENT ON VIEW api_v1_sys.sys_audit_log IS '审计日志视图（统一审计流：差异/操作/登录/异常）';

-- ---------------------------------------------------------------------------
-- §2 position 岗位表（树形，租户隔离）— 用户拍板立即创建
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS position (
    id          UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_id   TEXT NOT NULL,                    -- Logto organization_id（text，017 约定）
    pos_name    VARCHAR(100) NOT NULL,
    pos_code    VARCHAR(100),
    parent_id   UUID REFERENCES position(id) ON DELETE CASCADE,  -- NULL = 根岗位
    sort_no     INT NOT NULL DEFAULT 0,
    status      BOOLEAN NOT NULL DEFAULT TRUE,
    remark      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,
    created_by  TEXT,                             -- Logto user id
    updated_by  TEXT,
    deleted_by  TEXT
);
COMMENT ON TABLE position IS '岗位表（树形，租户隔离）。岗位=职级/职务维度，与权限无关（权限用角色）';
COMMENT ON COLUMN position.parent_id IS '上级岗位 ID，NULL 表示根岗位';
CREATE INDEX IF NOT EXISTS idx_position_tenant ON position(tenant_id);
CREATE INDEX IF NOT EXISTS idx_position_parent ON position(parent_id);

DROP VIEW IF EXISTS api_v1_sys.sys_position CASCADE;
CREATE VIEW api_v1_sys.sys_position AS
SELECT id, tenant_id, pos_name, pos_code, parent_id, sort_no, status, remark,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM position;
COMMENT ON VIEW api_v1_sys.sys_position IS '岗位视图';

-- ---------------------------------------------------------------------------
-- §3 user_position 用户岗位关联（多对多）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_position (
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,  -- Logto user id
    position_id UUID NOT NULL REFERENCES position(id) ON DELETE CASCADE,
    tenant_id   TEXT NOT NULL,
    is_primary  BOOLEAN NOT NULL DEFAULT FALSE,   -- 主岗位
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT,
    PRIMARY KEY (user_id, position_id)
);
COMMENT ON TABLE user_position IS '用户-岗位关联（多对多，租户隔离）';
CREATE INDEX IF NOT EXISTS idx_user_position_tenant ON user_position(tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_position_pos ON user_position(position_id);

DROP VIEW IF EXISTS api_v1_sys.sys_user_position CASCADE;
CREATE VIEW api_v1_sys.sys_user_position AS
SELECT user_id, position_id, tenant_id, is_primary, created_at, created_by
FROM user_position;
COMMENT ON VIEW api_v1_sys.sys_user_position IS '用户岗位关联视图';

-- ---------------------------------------------------------------------------
-- §4 字典 sys_dict_type / sys_dict_data（D-7）
--    与 TEXT+CHECK 约束并存：约束管数据完整性，字典管展示/可配置
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_dict_type (
    id          UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_id   TEXT,                             -- NULL = 全局字典；非 NULL = 租户字典
    dict_name   TEXT NOT NULL,                    -- 业务名（如 user_status）
    dict_label  TEXT NOT NULL,                    -- 展示名（如 用户状态）
    status      BOOLEAN NOT NULL DEFAULT TRUE,
    sort_no     INT NOT NULL DEFAULT 0,
    remark      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT,
    updated_by  TEXT,
    UNIQUE (tenant_id, dict_name)
);
COMMENT ON TABLE sys_dict_type IS '字典类型（全局 + 租户两级）';
COMMENT ON COLUMN sys_dict_type.tenant_id IS 'NULL=全局字典（所有租户共享）；非 NULL=租户字典（RLS 按 claims 过滤）';

CREATE TABLE IF NOT EXISTS sys_dict_data (
    id          UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_id   TEXT,                             -- 与 dict_type 一致（NULL=全局）
    dict_name   TEXT NOT NULL,
    item_label  TEXT NOT NULL,                    -- 显示文本（如 启用）
    item_value  TEXT NOT NULL,                    -- 存储值（如 1）
    item_type   TEXT NOT NULL DEFAULT 'default',  -- default/success/warning/danger（前端样式）
    is_default  BOOLEAN NOT NULL DEFAULT FALSE,
    sort_no     INT NOT NULL DEFAULT 0,
    status      BOOLEAN NOT NULL DEFAULT TRUE,
    remark      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT,
    updated_by  TEXT
);
COMMENT ON TABLE sys_dict_data IS '字典数据项';
CREATE INDEX IF NOT EXISTS idx_dict_data_name ON sys_dict_data(dict_name, sort_no);

DROP VIEW IF EXISTS api_v1_sys.sys_dict_type CASCADE;
CREATE VIEW api_v1_sys.sys_dict_type AS
SELECT id, tenant_id, dict_name, dict_label, status, sort_no, remark,
       created_at, updated_at, created_by, updated_by
FROM sys_dict_type;
COMMENT ON VIEW api_v1_sys.sys_dict_type IS '字典类型视图';

DROP VIEW IF EXISTS api_v1_sys.sys_dict_data CASCADE;
CREATE VIEW api_v1_sys.sys_dict_data AS
SELECT id, tenant_id, dict_name, item_label, item_value, item_type, is_default,
       sort_no, status, remark, created_at, updated_at, created_by, updated_by
FROM sys_dict_data;
COMMENT ON VIEW api_v1_sys.sys_dict_data IS '字典数据视图';

-- ---------------------------------------------------------------------------
-- §5 sys_login_log 登录日志（D-3）
--    数据来源: Logto webhook PostSignIn（payload 含 userIp/userAgent，成功登录主通道）
--              + Identifier.Lockout（锁定）；失败登录对账经 Management API（P1）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_login_log (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   TEXT,                             -- 登录时所属组织（可能 NULL=全局登录）
    user_id     TEXT,                             -- Logto user id
    username    TEXT,
    login_type  TEXT NOT NULL,                    -- password/sms/wechat/social/...
    result      TEXT NOT NULL,                    -- success / fail / locked / mfa_required
    fail_reason TEXT,
    ip          INET,
    user_agent  TEXT,
    region      TEXT,                             -- ip2region 解析（国家|省|市|ISP），写入时同步解析
    logto_event TEXT,                             -- PostSignIn / Identifier.Lockout 等
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys_login_log IS '登录日志（业务端安全审计镜像：Logto 审计日志无租户隔离/会被清理，业务端保留长期记录）';
CREATE INDEX IF NOT EXISTS idx_login_log_user ON sys_login_log(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_login_log_created ON sys_login_log(created_at DESC);

DROP VIEW IF EXISTS api_v1_sys.sys_login_log CASCADE;
CREATE VIEW api_v1_sys.sys_login_log AS
SELECT id, tenant_id, user_id, username, login_type, result, fail_reason,
       ip, user_agent, region, logto_event, created_at
FROM sys_login_log;
COMMENT ON VIEW api_v1_sys.sys_login_log IS '登录日志视图';

-- ---------------------------------------------------------------------------
-- §6 ip_region_v4: ip2region 数据表（D-4，零后端 IP 归属解析）
--    数据来源: ip2region v2.0 data/ipv4_source.txt（起始IP|结束IP|国家|省|市|ISP|iso）
--    P1 导入: COPY ip_region_v4 FROM '...ipv4_source.txt'（或脚本导入）
--    查询: SELECT country, province, city, isp FROM ip_region_v4
--          WHERE start_ip <= $1 AND end_ip >= $1 ORDER BY start_ip DESC LIMIT 1;
--    注: ip2region 不含经纬度；经纬度 P2 另接（GeoLite2-CSV 同法导入或高德 IP 定位 API）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ip_region_v4 (
    start_ip    INET NOT NULL,
    end_ip      INET NOT NULL,
    country     TEXT NOT NULL,
    province    TEXT,
    city        TEXT,
    isp         TEXT,
    iso_code    TEXT,
    CHECK (start_ip <= end_ip)
);
COMMENT ON TABLE ip_region_v4 IS 'IP 归属地离线库（ip2region v4 数据导入，只读）';
CREATE INDEX IF NOT EXISTS idx_ip_region_start ON ip_region_v4(start_ip);
CREATE INDEX IF NOT EXISTS idx_ip_region_end ON ip_region_v4(end_ip);

-- ---------------------------------------------------------------------------
-- §7 种子字典数据（示例：全局字典，幂等）
-- ---------------------------------------------------------------------------
INSERT INTO sys_dict_type (tenant_id, dict_name, dict_label, sort_no, remark)
VALUES (NULL, 'user_status', '用户状态', 1, '全局字典示例：用户状态展示')
ON CONFLICT (tenant_id, dict_name) DO NOTHING;

INSERT INTO sys_dict_data (tenant_id, dict_name, item_label, item_value, item_type, is_default, sort_no)
VALUES
    (NULL, 'user_status', '正常', 'active',   'success', TRUE,  1),
    (NULL, 'user_status', '已禁用', 'suspended', 'danger', FALSE, 2),
    (NULL, 'user_status', '待验证', 'pending',  'warning', FALSE, 3)
ON CONFLICT DO NOTHING;

INSERT INTO sys_dict_type (tenant_id, dict_name, dict_label, sort_no, remark)
VALUES (NULL, 'log_type', '审计日志类型', 2, '全局字典示例：audit_log.log_type 展示')
ON CONFLICT (tenant_id, dict_name) DO NOTHING;

INSERT INTO sys_dict_data (tenant_id, dict_name, item_label, item_value, item_type, sort_no)
VALUES
    (NULL, 'log_type', '数据变更', 'data_change', 'default', 1),
    (NULL, 'log_type', '业务操作', 'operate',     'default', 2),
    (NULL, 'log_type', '登录',     'login',       'success', 3),
    (NULL, 'log_type', '异常',     'exception',   'danger',  4),
    (NULL, 'log_type', '事件',     'event',       'warning', 5),
    (NULL, 'log_type', '开放接口', 'open_api',    'default', 6)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- §8 RLS 策略（幂等，与 017 风格一致）
-- ---------------------------------------------------------------------------

-- position: 租户隔离
ALTER TABLE public.position ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS position_tenant_isolation_policy ON public.position;
CREATE POLICY position_tenant_isolation_policy ON public.position
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- user_position: 租户隔离
ALTER TABLE public.user_position ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_position_tenant_isolation_policy ON public.user_position;
CREATE POLICY user_position_tenant_isolation_policy ON public.user_position
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- sys_dict_type: 全局公共读 + 本租户 + 超管
ALTER TABLE public.sys_dict_type ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dict_type_read_policy ON public.sys_dict_type;
CREATE POLICY dict_type_read_policy ON public.sys_dict_type
FOR SELECT
USING (is_super_admin() OR tenant_id IS NULL OR tenant_id = current_tenant_id());

-- sys_dict_data: 全局公共读 + 本租户 + 超管
ALTER TABLE public.sys_dict_data ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dict_data_read_policy ON public.sys_dict_data;
CREATE POLICY dict_data_read_policy ON public.sys_dict_data
FOR SELECT
USING (is_super_admin() OR tenant_id IS NULL OR tenant_id = current_tenant_id());

-- sys_login_log: 超管 + 本租户（写经 SECURITY DEFINER webhook RPC，不受 RLS 限制）
ALTER TABLE public.sys_login_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS login_log_read_policy ON public.sys_login_log;
CREATE POLICY login_log_read_policy ON public.sys_login_log
FOR SELECT
USING (is_super_admin() OR tenant_id = current_tenant_id());

-- ip_region_v4: 共享读（离线库，无租户维度）
ALTER TABLE public.ip_region_v4 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ip_region_read_policy ON public.ip_region_v4;
CREATE POLICY ip_region_read_policy ON public.ip_region_v4
FOR SELECT
USING (true);

-- ---------------------------------------------------------------------------
-- §9 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_tables int; v_policies int;
BEGIN
    SELECT count(*) INTO v_tables FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename IN ('position','user_position','sys_dict_type','sys_dict_data','sys_login_log','ip_region_v4');
    SELECT count(*) INTO v_policies FROM pg_policies
    WHERE tablename IN ('position','user_position','sys_dict_type','sys_dict_data','sys_login_log','ip_region_v4');
    RAISE NOTICE '019: 新建表=%（期望 6），策略=%（期望 6）', v_tables, v_policies;
END $$;
