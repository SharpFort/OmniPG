CREATE OR REPLACE FUNCTION api_v1.checkout(p_items JSONB)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT sales.create_order(p_items) $$;
COMMENT ON FUNCTION api_v1.checkout(JSONB) IS '结账 RPC：包装 sales.create_order，创建订单 + 扣减库存';
