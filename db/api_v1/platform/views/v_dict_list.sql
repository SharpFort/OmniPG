DROP VIEW IF EXISTS api_v1_platform.v_dict_list CASCADE;
-- api_v1/platform/views/v_dict_list.sql
-- D27: 字典列表输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.v_dict_list AS
SELECT t.id, t.tenant_id, t.organization_id, t.dict_name, t.dict_label, t.status, t.sort_no, t.remark,
       COALESCE((
           SELECT json_agg(json_build_object(
               'id', d.id, 'label', d.item_label, 'value', d.item_value,
               'type', d.item_type, 'is_default', d.is_default,
               'sort_no', d.sort_no, 'status', d.status) ORDER BY d.sort_no)
           FROM dict_data d
           WHERE d.dict_name = t.dict_name
             AND d.tenant_id = t.tenant_id
             AND d.organization_id IS NOT DISTINCT FROM t.organization_id
             AND d.status),
           '[]'::json) AS items
FROM dict_type t;
