-- =============================================================================
-- 023_admin_p0_naming_perm.sql — sys_ 前缀移除 + P0 三项（has_permission/审计/登录查询）
-- =============================================================================
-- 背景: 2026-08-04 用户拍板
--   ① sys_ 前缀移除（iam_ 保留）: public schema = 平台/系统管理域，无前缀即可
--     sys_dict_type/sys_dict_data/sys_login_log → dict_type/dict_data/login_log
--   ② P0 三项（05.2 §二）:
--     - has_permission(code) 实现（05 文档 §6.3 设计落地，全库此前无实现）
--     - 审计触发器补挂（8 张系统/授权表；镜像表不挂——webhook 可追溯）
--     - rpc_search_login_logs（租户维度登录日志查询，RLS 无法 join 的补位）
--   ③ iam_api 加 api_code 列（权限码，与 iam_menu.perms 对齐——022 注释引用）
-- 联动（RENAME 不自动更新的对象须手动重建）:
--   - 020 sync_login_log_write（plpgsql 函数体文本引用旧表名）
--   - 019 api_v1_sys.sys_dict_type/sys_dict_data/sys_login_log 视图（表名视图改名）
--   - 021 v_sys_login_log（保险重建）
--   RLS 策略/种子数据/其他视图引用表 OID → RENAME 自动跟随 ✅
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 sys_ 前缀移除（数据/RLS/索引随 RENAME 自动跟随）
-- ---------------------------------------------------------------------------
-- 幂等修正（2026-08-14）：019 的 CREATE TABLE IF NOT EXISTS sys_dict_type 在重放
-- 第二遍会重建旧表，RENAME 需同时守卫目标不存在（否则 audit_log/dict_type 等已存在冲突）
DO $$ BEGIN
    IF to_regclass('public.sys_dict_type') IS NOT NULL AND to_regclass('public.dict_type') IS NULL THEN
        ALTER TABLE public.sys_dict_type RENAME TO dict_type;
    END IF;
    IF to_regclass('public.sys_dict_data') IS NOT NULL AND to_regclass('public.dict_data') IS NULL THEN
        ALTER TABLE public.sys_dict_data RENAME TO dict_data;
    END IF;
    IF to_regclass('public.sys_login_log') IS NOT NULL AND to_regclass('public.login_log') IS NULL THEN
        ALTER TABLE public.sys_login_log RENAME TO login_log;
    END IF;
END $$;

-- 表名视图改名（api_v1_sys 暴露层）
DROP VIEW IF EXISTS api_v1_sys.sys_dict_type CASCADE;


DROP VIEW IF EXISTS api_v1_sys.sys_dict_data CASCADE;


DROP VIEW IF EXISTS api_v1_sys.sys_login_log CASCADE;


-- 021 v_sys_login_log 保险重建（引用新表名；geo_locate 返回 jsonb → 键访问）
DROP VIEW IF EXISTS api_v1_sys.v_sys_login_log CASCADE;


-- 020 sync_login_log_write 重建（plpgsql 函数体引用旧表名 sys_login_log → login_log）


-- ---------------------------------------------------------------------------
-- §2 iam_api 加 api_code 列（权限码，与 iam_menu.perms 对齐）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_api
    ADD COLUMN IF NOT EXISTS api_code text;
COMMENT ON COLUMN public.iam_api.api_code IS '权限码（如 sys:user:list；has_permission(code) 判定键，与 iam_menu.perms 同语义）';

CREATE UNIQUE INDEX IF NOT EXISTS idx_iam_api_code ON public.iam_api(api_code)
    WHERE api_code IS NOT NULL;

DROP VIEW IF EXISTS api_v1_sys.sys_api CASCADE;


-- ---------------------------------------------------------------------------
-- §3 has_permission(code) — 授权判定核心（05 §6.3 落地，05.2 §2.1）
--     claims roles ∩ (iam_role_api → iam_api.api_code)；超管短路
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §4 审计触发器补挂（8 张：系统管理 6 + 授权 2；镜像表不挂——webhook 可追溯）
-- ---------------------------------------------------------------------------
-- 字典（新名）


-- 岗位


-- 参数配置 / 用户扩展资料


-- 授权表（菜单/API；role_api/role_menu 已有）


-- ---------------------------------------------------------------------------
-- §5 rpc_search_login_logs — 租户维度登录日志查询（05.2 §2.3）
--     RLS 无法覆盖（login_log.tenant_id 为 NULL）：SECURITY DEFINER +
--     has_permission('sys:login-log:list') + user_tenants 成员过滤
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tables int; v_fn int; v_trg int; v_api_code int;
BEGIN
    SELECT count(*) INTO v_tables FROM pg_tables
      WHERE schemaname='public' AND tablename IN ('dict_type','dict_data','login_log');
    SELECT count(*) INTO v_fn FROM pg_proc WHERE proname IN ('has_permission','rpc_search_login_logs');
    SELECT count(*) INTO v_trg FROM pg_trigger
      WHERE tgname LIKE 'trg_audit_%' AND NOT tgisinternal;
    SELECT count(*) INTO v_api_code FROM information_schema.columns
      WHERE table_schema='public' AND table_name='iam_api' AND column_name='api_code';
    RAISE NOTICE '023: 新表名=%（期望3） 函数=%（期望2） 审计触发器=%（期望11） api_code列=%（期望1）',
        v_tables, v_fn, v_trg, v_api_code;
END $$;
