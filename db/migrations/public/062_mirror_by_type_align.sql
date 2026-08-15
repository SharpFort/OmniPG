-- 062_mirror_by_type_align.sql
-- _by 类型追平 + 死列清理（2026-08-15 用户拍板）
--   department.created_by/updated_by/deleted_by: uuid → text
--     （其余业务表 _by 已全部 text；存量三列全 NULL，无数据转换风险；
--      text 对齐 Logto 用户 id，未来可安全绑定 audit_user_fields()）
--   audit_log.created_by: 死列直接删除
--     （417 行全 NULL；生产审计链 write_audit_log 写 user_id(text)，从不写它）
-- 视图说明：api_v1_public.department 投影 _by 三列，阻塞 ALTER TYPE——解锁用
--   条件式 DROP（仅当列仍为 uuid 时才执行），与 ALTER 同处单 DO 块（事务原子）。
--   重放（apply-src 二遍演练/双跑幂等）时条件为假 → 不再 DROP → 视图存活；
--   重建由源文件 db/api_v1/public/views/department.sql 重放承担（铁律：迁移不含视图定义）。
--   C2 实测该视图零下游依赖，CASCADE 无级联。
-- 本文件仅承载表结构变更；幂等（apply-src 重放安全）。

-- §1 department._by uuid→text（条件解锁 + ALTER，单 DO 块原子执行）
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'department'
                  AND column_name IN ('created_by','updated_by','deleted_by')
                  AND data_type = 'uuid') THEN
        EXECUTE 'DROP VIEW IF EXISTS api_v1_public.department CASCADE';
        EXECUTE 'ALTER TABLE department ALTER COLUMN created_by TYPE text';
        EXECUTE 'ALTER TABLE department ALTER COLUMN updated_by TYPE text';
        EXECUTE 'ALTER TABLE department ALTER COLUMN deleted_by TYPE text';
    END IF;
END $$;

-- §2 audit_log.created_by 死列删除
ALTER TABLE audit_log DROP COLUMN IF EXISTS created_by;

-- §3 验证段（幂等重放自适应）
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(column_name, ', ')
      INTO v_bad
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'department'
       AND column_name IN ('created_by','updated_by','deleted_by')
       AND data_type <> 'text';

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '062 验证失败：department._by 残留非 text 列 %', v_bad;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'audit_log'
                  AND column_name = 'created_by') THEN
        RAISE EXCEPTION '062 验证失败：audit_log.created_by 仍存在';
    END IF;

    RAISE NOTICE '062 验证通过：department._by 已 text 化、audit_log.created_by 已删除';
END $$;
