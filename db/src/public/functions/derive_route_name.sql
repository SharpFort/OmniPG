-- src/public/functions/derive_route_name.sql
-- FUNCTION: public.derive_route_name（17 号文档归位：迁移 056_iam_menu_query_drop_route_name_fallback.sql 删定义段，本文件为唯一权威）
-- 回放终态: 056_iam_menu_query_drop_route_name_fallback.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION public.derive_route_name(p_router text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
SELECT upper(left(s, 1)) || substring(s FROM 2)
FROM (
    SELECT (string_to_array(btrim(p_router, '/'), '/'))
           [array_length(string_to_array(btrim(p_router, '/'), '/'), 1)] AS s
) t
WHERE s IS NOT NULL AND s <> '';
$$;
