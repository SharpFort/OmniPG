-- db/src/platform/functions/resolve_role_ident.sql
-- D26: 角色名（role_code）解析为 Logto 角色标识（role_id / org_role_id）
-- 规则：全局角色（platform.role）优先；仅当全局未命中时才解析组织角色（platform.tenant_role）。
-- 用途：RPC 写路径/查询入参继续保持 p_role_code 字符串契约，内部落库使用两个不可空标识。
-- P-2f（2026-11-20，阶段 4）：全局角色探测原在 role_id 子查询与 org_role_id 的
--   NOT EXISTS 各执行一次（2 次扫描 platform.role）、current_logto_tenant_id
--   解析 3 处——plpgsql 化单次探测 + tenant 局部变量（plpgsql 延迟绑定与
--   2026-08-16 单遍重放契约一致；sql 函数体 CREATE 期即解析绑定才是契约风险方向）。

CREATE OR REPLACE FUNCTION platform.resolve_role_ident(p_role_code text)
RETURNS TABLE(role_id text, org_role_id text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_tenant text := current_logto_tenant_id();
    v_global text;
BEGIN
    -- P-2f：单次全局探测（原 role_id 子查询 + NOT EXISTS 双查 role 表）
    SELECT id INTO v_global FROM platform.role
    WHERE role_code = p_role_code AND tenant_id = v_tenant
    LIMIT 1;

    IF v_global IS NOT NULL THEN
        -- 全局角色命中：org_role_id 恒 NULL（原 NOT EXISTS 语义）
        role_id := v_global;
        org_role_id := NULL;
    ELSE
        role_id := NULL;
        SELECT id INTO org_role_id FROM platform.tenant_role
        WHERE name = p_role_code AND tenant_id = v_tenant
        LIMIT 1;
    END IF;
    -- RETURNS TABLE 语义：RETURN NEXT 积累 (role_id, org_role_id) 单行；
    -- 裸 RETURN; 只结束函数不产出行（plpgsql 手册语义——初版 0 行事故修正）
    RETURN NEXT;
END $$;

COMMENT ON FUNCTION platform.resolve_role_ident(text) IS 'D26: 角色名解析为 Logto 角色标识（全局优先；API 入参仍用角色名；P-2f：单次探测 + tenant 单次解析）';
GRANT EXECUTE ON FUNCTION platform.resolve_role_ident(text) TO authenticated;
