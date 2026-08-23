DROP VIEW IF EXISTS api_v1_platform.user_position CASCADE;
-- api_v1/platform/views/user_position.sql
-- D27: user_position API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.user_position AS
SELECT user_id, position_id, tenant_id, organization_id, is_primary, created_at, created_by
FROM user_position;
