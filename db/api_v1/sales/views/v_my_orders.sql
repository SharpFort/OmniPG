-- db/api_v1/sales/views/v_my_orders.sql
-- 销售域 API 视图：我的订单
-- 注意：此视图在 api_v1 schema 中，引用 sales schema 的内部表

CREATE OR REPLACE VIEW api_v1.v_my_orders AS
SELECT o.id, o.order_no, o.user_id, o.total_amount, o.status, o.created_at
FROM sales.orders o
WHERE o.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::UUID;

COMMENT ON VIEW api_v1.v_my_orders IS '我的订单视图：仅显示当前登录用户的订单';
