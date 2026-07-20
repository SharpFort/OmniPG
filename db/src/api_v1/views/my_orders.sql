CREATE OR REPLACE VIEW api_v1.my_orders AS
SELECT o.id, o.order_no, o.user_id, o.total_amount, o.status, o.created_at
FROM public.sales_orders o
WHERE o.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::UUID;
