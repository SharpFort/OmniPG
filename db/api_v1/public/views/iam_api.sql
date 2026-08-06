-- db/api_v1/public/views/iam_api.sql（T9: 列对齐当前 iam_api 表）
-- 来源: 20260707000013_postgrest_api_v1.sql（T9 改造）

CREATE OR REPLACE VIEW api_v1_public.iam_api AS
SELECT id, path, method, name, description, api_code, is_active,
       created_at, updated_at, created_by, updated_by
FROM public.iam_api;
COMMENT ON VIEW api_v1_public.iam_api IS 'API 资源表视图（含 api_code）';