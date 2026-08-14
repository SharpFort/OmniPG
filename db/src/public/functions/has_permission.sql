-- src/public/functions/has_permission.sql
-- FUNCTION: public.has_permission（17 号文档归位：迁移 055_iam_menu_permission_unify.sql 删定义段，本文件为唯一权威）
-- 回放终态: 055_iam_menu_permission_unify.sql；幂等写法（§9 模板）

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
