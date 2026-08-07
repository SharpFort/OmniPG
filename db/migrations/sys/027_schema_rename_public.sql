-- =============================================================================
-- 027_schema_rename_public.sql — api_v1_sys → api_v1_public（用户拍板）
-- =============================================================================
-- 背景: 2026-08-05 用户巡检："还需要将 api_v1_sys 重命名为 api_v1_public，
--       这也是可以直接替换的对吧？"
-- 方案（顺序无关、重放安全）:
--   - db/init/02-schemas.sql 已建 api_v1_sys（历史迁移引用承载）+ api_v1_public
--   - 本迁移（migrations 层，最后执行）:
--     ① api_v1_sys 存在 且 api_v1_public 不存在 → ALTER SCHEMA RENAME（首次迁移）
--     ② 双 schema 并存（重放场景）→ 034 修复：迁移层对象（023-026 建于 api_v1_sys
--        的 dict_type/dict_data/login_log/v_dict_list/v_user_roles/v_role_users/
--        position/user_position/v_login_log、024/025 CRUD RPC、check_token_blacklist）
--        搬迁到 api_v1_public；同名冲突对象（api_v1/public 目录源文件权威副本，
--        如 v_role_list/v_role_api_detail/v_role_menu_detail/v_audit_log_timeline/
--        v_system_stats_realtime 等）删除 api_v1_sys 残留
--        ⚠️ 旧版直接 DROP SCHEMA api_v1_sys CASCADE 会摧毁上述全部迁移层对象
--           （前端联调 030-033 未暴露：024/025 CRUD 页面尚未开发）
--     ③ api_v1_sys 不存在 → 跳过（已完成）
-- 最终态: 仅 api_v1_public，对象 = api_v1/public 目录文件（视图名=底层表名）+ 027 前各迁移
-- =============================================================================

DO $$
DECLARE
    v_obj   record;
    v_kind  text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api_v1_sys') THEN
        IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api_v1_public') THEN
            ALTER SCHEMA api_v1_sys RENAME TO api_v1_public;
            RAISE NOTICE '027: api_v1_sys → api_v1_public（RENAME 完成）';
        ELSE
            -- 034 修复：双 schema 并存 → 搬迁迁移层对象（替代旧版 DROP SCHEMA CASCADE）
            -- ① 关系对象（视图/表/序列/物化视图/外部表）
            FOR v_obj IN
                SELECT c.oid, c.relname, c.relkind
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'api_v1_sys'
                  AND c.relkind IN ('v','r','m','S','f','p')
            LOOP
                v_kind := CASE v_obj.relkind
                              WHEN 'v' THEN 'VIEW'
                              WHEN 'r' THEN 'TABLE'
                              WHEN 'm' THEN 'MATERIALIZED VIEW'
                              WHEN 'S' THEN 'SEQUENCE'
                              WHEN 'f' THEN 'FOREIGN TABLE'
                              ELSE 'TABLE' END;  -- 'p' 分区表
                IF to_regclass(format('api_v1_public.%I', v_obj.relname)) IS NOT NULL THEN
                    -- 同名冲突：api_v1/public 源文件已建权威版，删迁移层残留
                    EXECUTE format('DROP %s api_v1_sys.%I CASCADE', v_kind, v_obj.relname);
                ELSE
                    EXECUTE format('ALTER %s api_v1_sys.%I SET SCHEMA api_v1_public',
                                   v_kind, v_obj.relname);
                END IF;
            END LOOP;

            -- ② 函数/过程（同名同参冲突 → 删 api_v1_sys 版，否则搬迁）
            --    注: oidvectortypes 不加别名限定（pg_catalog 隐式 search_path；
            --        限定形式在部分嵌入式 PG 兼容层解析为 schema 限定而失败）
            FOR v_obj IN
                SELECT p.proname, oidvectortypes(p.proargtypes) AS args
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'api_v1_sys'
            LOOP
                IF EXISTS (
                    SELECT 1 FROM pg_proc p2
                    JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
                    WHERE n2.nspname = 'api_v1_public'
                      AND p2.proname = v_obj.proname
                      AND oidvectortypes(p2.proargtypes) = v_obj.args
                ) THEN
                    EXECUTE format('DROP FUNCTION api_v1_sys.%I(%s) CASCADE',
                                   v_obj.proname, v_obj.args);
                ELSE
                    EXECUTE format('ALTER FUNCTION api_v1_sys.%I(%s) SET SCHEMA api_v1_public',
                                   v_obj.proname, v_obj.args);
                END IF;
            END LOOP;

            DROP SCHEMA api_v1_sys;
            RAISE NOTICE '027(034修复): 迁移层对象已搬迁至 api_v1_public，残留 api_v1_sys 已清理';
        END IF;
    ELSE
        RAISE NOTICE '027: api_v1_sys 不存在，跳过（已收敛）';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_sys int; v_public int; v_objs int;
BEGIN
    SELECT count(*) INTO v_sys FROM pg_namespace WHERE nspname = 'api_v1_sys';
    SELECT count(*) INTO v_public FROM pg_namespace WHERE nspname = 'api_v1_public';
    SELECT count(*) INTO v_objs FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'api_v1_public' AND c.relkind IN ('v','r');
    RAISE NOTICE '027: api_v1_sys=%（期望0） api_v1_public=%（期望1） 对象数=%', v_sys, v_public, v_objs;
END $$;
