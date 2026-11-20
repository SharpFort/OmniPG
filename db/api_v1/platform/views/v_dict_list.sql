DROP VIEW IF EXISTS api_v1_platform.v_dict_list CASCADE;
-- api_v1/platform/views/v_dict_list.sql
-- D27: 字典列表输出 tenant_id/organization_id 双列。
-- P-3l（2026-11-20，阶段 4）：相关 json_agg 子查询逐行求值 → 预聚合 + LEFT JOIN——
--   原版对 dict_type 每行执行一次 dict_data 聚合扫描；预聚合版一次性
--   GROUP BY (dict_name, tenant_id, organization_id) 后连接，语义保持：
--   status 过滤在聚合前、ORDER BY sort_no 在聚合内、无条目行 COALESCE '[]'、
--   organization_id NULL 经 GROUP 分组与 IS NOT DISTINCT FROM 连接匹配。

CREATE OR REPLACE VIEW api_v1_platform.v_dict_list AS
SELECT t.id, t.tenant_id, t.organization_id, t.dict_name, t.dict_label, t.status, t.sort_no, t.remark,
       COALESCE(dd.items, '[]'::json) AS items
FROM dict_type t
LEFT JOIN (
    SELECT dict_name, tenant_id, organization_id,
           json_agg(json_build_object(
               'id', d.id, 'label', d.item_label, 'value', d.item_value,
               'type', d.item_type, 'is_default', d.is_default,
               'sort_no', d.sort_no, 'status', d.status) ORDER BY d.sort_no) AS items
    FROM dict_data d
    WHERE d.status
    GROUP BY dict_name, tenant_id, organization_id
) dd ON dd.dict_name = t.dict_name
    AND dd.tenant_id = t.tenant_id
    AND dd.organization_id IS NOT DISTINCT FROM t.organization_id;
