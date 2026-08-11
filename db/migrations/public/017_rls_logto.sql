-- =============================================================================
-- 017_rls_logto.sql — T7: RLS 策略 Logto 化（department/audit_log 租户隔离）
-- =============================================================================
-- 背景: 014 重命名表后，department/audit_log 无 RLS 策略（Casdoor 时代策略
--       已在 009 DROP，且当时表名为 sys_*）。现按 Logto 语义补建：
--       - tenant_id 类型统一为 text（与 current_tenant_id() text 返回一致，
--         Logto organization_id 21 位 nanoid；B4 决策延伸）
--       - 镜像表策略已在 009 建立（users/tenants/user_tenants/role/user_profile）
--       - 自主表（iam_api/iam_menu/iam_role_api/iam_role_menu）共享读
--       - audit_log 读策略：超管 + 本租户
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 department.tenant_id uuid → text（先 DROP 依赖视图，改完重建）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_department CASCADE;

ALTER TABLE public.department
    ALTER COLUMN tenant_id TYPE text USING tenant_id::text;

CREATE VIEW api_v1_sys.sys_department AS
SELECT id, dept_name, tenant_id, parent_id, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM department;
COMMENT ON VIEW api_v1_sys.sys_department IS '部门组织架构视图（Logto 语义：tenant_id text）';

-- ---------------------------------------------------------------------------
-- §2 audit_log.tenant_id uuid → text（先 DROP 依赖视图，改完重建）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_audit_log CASCADE;
DROP VIEW IF EXISTS api_v1_sys.v_audit_log_timeline CASCADE;
DROP VIEW IF EXISTS api_v1_sys.v_audit_log_detail CASCADE;

ALTER TABLE public.audit_log
    ALTER COLUMN tenant_id TYPE text USING tenant_id::text;

CREATE VIEW api_v1_sys.sys_audit_log AS
SELECT id, table_name, operation, old_data, new_data, user_id, tenant_id, created_at
FROM audit_log;
COMMENT ON VIEW api_v1_sys.sys_audit_log IS '审计日志视图（Logto 语义：tenant_id text）';

CREATE VIEW api_v1_sys.v_audit_log_timeline AS
SELECT date_trunc('day', created_at) AS log_date,
       table_name, operation,
       count(*) AS change_count,
       count(DISTINCT user_id) AS unique_users
FROM audit_log
GROUP BY date_trunc('day', created_at), table_name, operation
ORDER BY date_trunc('day', created_at) DESC, count(*) DESC;
COMMENT ON VIEW api_v1_sys.v_audit_log_timeline IS '审计日志时间线视图';

-- ---------------------------------------------------------------------------
-- §3 策略（幂等 DROP + CREATE，与 db/src/public/privileges/rls_policies.sql 同步）
-- ---------------------------------------------------------------------------

-- department：租户隔离
ALTER TABLE public.department ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dept_tenant_isolation_policy ON public.department;
CREATE POLICY dept_tenant_isolation_policy ON public.department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- iam_api / iam_menu：系统级共享读
ALTER TABLE public.iam_api ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS api_read_policy ON public.iam_api;
CREATE POLICY api_read_policy ON public.iam_api
FOR SELECT
USING (is_active = TRUE);

ALTER TABLE public.iam_menu ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS menu_read_policy ON public.iam_menu;
CREATE POLICY menu_read_policy ON public.iam_menu
FOR SELECT
USING (is_active = TRUE);

-- iam_role_api / iam_role_menu：绑定数据共享读
ALTER TABLE public.iam_role_api ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_api_read_policy ON public.iam_role_api;
CREATE POLICY role_api_read_policy ON public.iam_role_api
FOR SELECT
USING (true);

ALTER TABLE public.iam_role_menu ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_menu_read_policy ON public.iam_role_menu;
CREATE POLICY role_menu_read_policy ON public.iam_role_menu
FOR SELECT
USING (true);

-- audit_log：超管 + 本租户（写路径经 SECURITY DEFINER 触发器，不受 RLS 限制）
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_log_read_policy ON public.audit_log;
CREATE POLICY audit_log_read_policy ON public.audit_log
FOR SELECT
USING (is_super_admin() OR tenant_id = current_tenant_id());

-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_policies
    WHERE tablename IN ('department','iam_api','iam_menu','iam_role_api','iam_role_menu','audit_log');
    RAISE NOTICE '017: 新增策略数=%（期望 6）', v_cnt;
END $$;
