-- api_v1/public/views/v_dict_list.sql
-- VIEW: api_v1_public.v_dict_list（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_public.v_dict_list AS
SELECT t.id, t.tenant_id, t.dict_name, t.dict_label, t.status, t.sort_no, t.remark,
       COALESCE((
           SELECT json_agg(json_build_object(
               'id', d.id, 'label', d.item_label, 'value', d.item_value,
               'type', d.item_type, 'is_default', d.is_default,
               'sort_no', d.sort_no, 'status', d.status) ORDER BY d.sort_no)
           FROM dict_data d
           WHERE d.dict_name = t.dict_name
             AND d.tenant_id IS NOT DISTINCT FROM t.tenant_id
             AND d.status),
           '[]'::json) AS items
FROM dict_type t;
