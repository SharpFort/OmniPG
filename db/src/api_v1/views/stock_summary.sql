CREATE OR REPLACE VIEW api_v1.stock_summary AS
SELECT s.product_id, p.product_name, s.warehouse_id, s.quantity, s.last_updated
FROM public.inventory_stock s
JOIN public.products p ON s.product_id = p.id;
