-- 063_retire_inventory_sales.sql
-- 退役模块全链路移除（2026-08-15 用户拍板）
--   inventory / sales 测试模块整体退役，后续按需重建。
--   库内 4 个 schema 均为空壳（0 对象，app_owner 属主，跨 schema 依赖为 0）。
--   配套（同批提交，非本文件）：
--     仓库: git rm db/src/{inventory,sales}、db/api_v1/{inventory,sales}、
--           db/tests/{inventory,sales} 共 7 文件
--     脚本: apply-src.sh MODULES/API_MODULES 去 inventory sales
--           init-apisix-routes.sh 去 /api/v1/sales|inventory 两条路由
--     网关: gateway/docker-compose.yml PGRST_DB_SCHEMAS / EXTRA_SEARCH_PATH 收敛
-- 本文件仅承载结构变更；幂等（重放安全）。

DROP SCHEMA IF EXISTS api_v1_inventory;
DROP SCHEMA IF EXISTS api_v1_sales;
DROP SCHEMA IF EXISTS inventory;
DROP SCHEMA IF EXISTS sales;

-- 验证段
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(nspname, ', ')
      INTO v_bad
      FROM pg_namespace
     WHERE nspname IN ('inventory','sales','api_v1_inventory','api_v1_sales');

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '063 验证失败：退役 schema 残留 %', v_bad;
    END IF;

    RAISE NOTICE '063 验证通过：inventory/sales 退役 schema 已全部移除';
END $$;
