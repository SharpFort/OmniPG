-- src/platform/functions/has_permission.sql
-- FUNCTION: platform.has_permission（17 号文档归位：迁移 055_iam_menu_permission_unify.sql 删定义段，本文件为唯一权威）
-- 回放终态: 055_iam_menu_permission_unify.sql；幂等写法（§9 模板）
-- D26: iam_role_menu 改 role_id/org_role_id 双列 FK，JWT 角色名先解析为 Logto 角色标识。
-- P-2d（2026-11-20，阶段 4 函数级优化）：claims 单遍解析——原版每次调用重复解析
--   claims 6 处（is_super_admin→current_user_roles 1、current_user_roles 1、
--   current_logto_tenant_id 4：两条角色解析各 1 + EXISTS 双表谓词 2）且 3 条独立
--   语句；现版一次读取 jsonb 全程局部变量 + 双角色解析合并为单条语句。
--   超管短路改 jsonb 包含判定（'["role_super_admin"]'，非数组场景 fail-closed
--   而非报错）；角色非字符串数组场景仍在展开处报错（与原版一致）。

CREATE OR REPLACE FUNCTION has_permission(p_code text) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_claims       jsonb;
    v_roles        text[];
    v_tenant       text;
    v_role_ids     text[];
    v_org_role_ids text[];
BEGIN
    IF p_code IS NULL OR p_code = '' THEN
        RETURN false;
    END IF;
    -- P-2d：claims 单遍读取，全程局部变量
    v_claims := NULLIF(current_setting('request.jwt.claims', true), '')::jsonb;

    -- 超管短路（RLS 例外同款语义；jsonb 包含判定，不经数组展开）
    IF COALESCE(v_claims -> 'roles', '[]'::jsonb) @> '["role_super_admin"]'::jsonb THEN
        RETURN true;
    END IF;

    v_roles := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_claims -> 'roles', '[]'::jsonb)));
    IF cardinality(v_roles) = 0 THEN
        RETURN false;
    END IF;
    v_tenant := COALESCE(NULLIF(v_claims ->> 'tenant_id', ''), 'default');

    -- D26: 角色名 → Logto 角色标识（强制锁定当前租户范围，消除跨租户角色 ID 碰撞；
    -- P-2d：原两条独立语句合并为单条双数组）
    SELECT ARRAY(SELECT r.id FROM platform.role r
                  WHERE r.name = ANY(v_roles) AND r.tenant_id = v_tenant),
           ARRAY(SELECT tr.id FROM platform.tenant_role tr
                  WHERE tr.name = ANY(v_roles) AND tr.tenant_id = v_tenant)
      INTO v_role_ids, v_org_role_ids;

    -- 单通道（055 D3）：权限点 = button 行 api_code（非 button 行 api_code 已收敛置空）
    RETURN EXISTS (
        SELECT 1
        FROM iam_role_menu rm
        JOIN iam_menu m ON m.id = rm.menu_id
        WHERE (rm.role_id = ANY(v_role_ids) OR rm.org_role_id = ANY(v_org_role_ids))
          AND rm.tenant_id = v_tenant
          AND m.tenant_id = v_tenant
          AND m.api_code = p_code
          AND m.is_active
    );
END;
$$;
COMMENT ON FUNCTION has_permission(text) IS '权限点校验（055 单通道：button 行 api_code；D26 双列 FK；P-2d：claims 单遍解析 + 超管 jsonb 包含短路）';
