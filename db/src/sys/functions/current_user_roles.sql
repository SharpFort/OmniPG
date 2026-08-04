-- db/src/sys/functions/current_user_roles.sql
-- 当前用户有效业务角色 code 列表（方案 C，04.8 §5.5）
-- 数据源: PostgREST 注入的 request.jwt.claims -> roles 数组（Casdoor JWT，tokenFormat=JWT-Custom）
-- 语义:   过滤 isEnabled=false 的角色（H9：禁用角色仍会进入 JWT，C11）
--         缺失 isEnabled 时视为启用（COALESCE 兜底）
-- 性能:   纯 claims 解析，零查询；STABLE 每条语句只评估一次（C6）
-- 用途:   RLS 策略 / RPC 权限检查 / 前端菜单渲染，与用户数无关
-- 依赖:   JWT roles 数组元素为对象（owner/name/displayName/isEnabled/...，C11）

CREATE OR REPLACE FUNCTION current_user_roles() RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT ARRAY(
        SELECT e->>'name'
        FROM jsonb_array_elements(
            COALESCE(current_setting('request.jwt.claims', true)::jsonb -> 'roles', '[]'::jsonb)
        ) e
        WHERE COALESCE((e->>'isEnabled')::boolean, TRUE) = TRUE
    );
$$;

COMMENT ON FUNCTION current_user_roles() IS '当前用户有效业务角色 code 列表（JWT claims roles，过滤 isEnabled=false，零查询）';
