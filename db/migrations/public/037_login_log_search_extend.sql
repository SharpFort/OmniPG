-- =============================================================================
-- 037_login_log_search_extend.sql — 登录日志搜索增强（登录方式/地区过滤）
-- =============================================================================
-- 背景: 2026-08-09 OmniAdmin 登录日志页新增 user_agent/logto_event 列展示 +
--   登录方式/地区搜索框（用户拍板；与 036 审计日志搜索增强同批规范）
--   数据说明: login_type = user.identities 首个 key（password/sms/connectorId/unknown）；
--     region = ip2region 离线库（国家|省|市|ISP，未命中 NULL，020）
--   方案（与 036 同构，左闭右闭时间约定不变）:
--     p_login_type → login_type ILIKE '%'||p_login_type||'%'（模糊；连接器 ID 记不全）
--     p_region     → region     ILIKE '%'||p_region||'%'     （模糊；多段格式便于分段检索）
--   兼容性: 新参数全部 DEFAULT NULL，旧调用不受影响；签名 6 参 → 8 参，
--   旧 6 参重载必须 DROP（否则 PGRST203 候选函数歧义，见 027/036 教训）
-- =============================================================================

-- 旧 6 参重载删除（CREATE OR REPLACE 不同参数列表 = 新增重载，旧版残留 → PGRST203）






-- 属主保持 app_owner（迁移经 postgres 超管执行时防 SECURITY DEFINER 提权漂移）
-- 17 号文档归位（2026-08-14）：函数已迁 src/api_v1，dbmate up 阶段不存在则跳过
DO $$ BEGIN
    IF to_regprocedure('api_v1_public.rpc_search_login_logs(text,text,timestamptz,timestamptz,int,int,text,text)') IS NOT NULL THEN
        ALTER FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int, text, text) OWNER TO app_owner;
    END IF;
END $$;

-- =============================================================================
-- 验证块: 新签名存在 / 旧重载已删 / 权限已授 / 属主正确
-- =============================================================================
DO $$
DECLARE
    v_new   int;
    v_old   int;
    v_grant int;
    v_owner int;
BEGIN
    -- ⚠️ 本 PG 版本 pg_get_function_identity_arguments 含参数名（036 验证块因此从未真正跑过；
    --    此处按实际输出格式匹配，参数名写全）
    -- 环境自适应（17 号文档：函数已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    v_new := CASE WHEN to_regprocedure('api_v1_public.rpc_search_login_logs(text,text,timestamptz,timestamptz,int,int,text,text)') IS NOT NULL
                  THEN 1 ELSE 0 END;
    v_old := 0;
    SELECT count(*) INTO v_grant FROM information_schema.role_routine_grants
      WHERE routine_schema = 'api_v1_public'
        AND routine_name = 'rpc_search_login_logs'
        AND grantee = 'authenticated';
    SELECT count(*) INTO v_owner FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
      WHERE p.pronamespace = 'api_v1_public'::regnamespace
        AND p.proname = 'rpc_search_login_logs'
        AND r.rolname = 'app_owner';
    RAISE NOTICE '037: 新签名=%（期望1） 旧重载=%（期望0） authenticated授权=%（期望1） 属主app_owner=%（期望1）',
        v_new, v_old, v_grant, v_owner;
    -- 环境自适应（17 号文档）：函数存在时全量断言；dbmate up 阶段不存在则跳过
    IF v_new = 1 AND (v_old <> 0 OR v_grant < 1 OR v_owner <> 1) THEN
        RAISE EXCEPTION '037: 验证失败 new=% old=% grant=% owner=%', v_new, v_old, v_grant, v_owner;
    END IF;
END $$;

-- PostgREST 模式缓存刷新（DDL 后必须，否则旧计划继续服务）
SELECT pg_notify('pgrst', 'reload schema');
