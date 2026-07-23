-- db/api_v1/inventory/views/v_stock_summary.sql
-- 库存域 API 视图：库存汇总
-- 注意：此视图在 api_v1 schema 中，引用 inventory schema 的内部表

CREATE OR REPLACE VIEW api_v1_inventory.v_stock_summary AS
SELECT s.product_id, p.product_name, s.warehouse_id, s.quantity, s.last_updated
FROM inventory.stock s
JOIN inventory.products p ON s.product_id = p.id;

COMMENT ON VIEW api_v1_inventory.v_stock_summary IS '库存汇总视图：显示各仓库的商品库存';
