-- db/api_v1/sales/rpc/rpc_checkout.sql
-- 销售域 API RPC：结账
-- 包装 sales schema 的 create_order 函数

CREATE OR REPLACE FUNCTION api_v1.checkout(p_items JSONB)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = sales, public, pg_temp
AS $$ SELECT sales.create_order(p_items) $$;

COMMENT ON FUNCTION api_v1.checkout(JSONB) IS '结账 RPC：包装 sales.create_order，创建订单 + 扣减库存';
