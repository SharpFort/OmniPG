-- db/src/public/functions/current_user_roles.sql
-- 当前用户角色 code 列表（Logto 语义，030 重建）
-- 数据源: PostgREST 注入的 request.jwt.claims -> roles（Logto 字符串数组，05 §5.1 定稿）
-- 语义:   Logto roles = ["role_super_admin", "tenant_admin", ...]（纯字符串数组）
--         旧版按 Casdoor 对象数组（[{name,isEnabled}]）解析 → e->>'name' 恒 NULL
--         → current_user_roles() 恒空 → is_super_admin() 恒 false（030 修复根因）
-- 性能:   纯 claims 解析，零查询；STABLE 每条语句只评估一次
-- 用途:   is_super_admin() / RLS 策略 / RPC 权限检查，与用户数无关
-- 依赖:   JWT roles 字符串数组（Logto Custom Token Claims 脚本输出，05 §5.1.1）

CREATE OR REPLACE FUNCTION current_user_roles() RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(current_setting('request.jwt.claims', true)::jsonb -> 'roles', '[]'::jsonb)
        )
    );
$$;

COMMENT ON FUNCTION current_user_roles() IS '当前用户角色 code 列表（JWT claims roles 字符串数组，零查询；030 修复 Logto 语义）';
