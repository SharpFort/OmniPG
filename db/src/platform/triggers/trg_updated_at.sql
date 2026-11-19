-- db/src/platform/triggers/trg_updated_at.sql
-- 自动为所有含 updated_at 字段的表创建更新触发器
-- 来源: 20260707000007_create_security_triggers.sql

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        -- pg_catalog 直查（2026-11-19 修复，替代 information_schema）：
        -- information_schema 按当前角色权限过滤，迁移角色无权限的平台表会被静默跳过
        --（无触发器、无告警）；查真实目录不受权限可见性影响
        SELECT c.relname FROM pg_class c
        WHERE c.relnamespace = 'platform'::regnamespace
          -- 含分区表（relkind='p'，2026-11-19 修补：information_schema 的 BASE TABLE
          -- 亦含分区母表，'r' 单条件会漏建）
          AND c.relkind IN ('r', 'p')
          AND EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = c.oid AND a.attname = 'updated_at' AND NOT a.attisdropped)
    LOOP
        -- PG 不支持 CREATE TRIGGER IF NOT EXISTS（17 号文档归位修正：DO 块守卫幂等）
        -- 2026-08-15 修复：仅对 BASE TABLE 建触发器（视图不可有行级触发器）
        -- 2026-11-19 修复两点：
        --   1) 守卫限定目标表：pg_trigger.tgname 仅在表内唯一，跨表同名触发器会让守卫误判跳过；
        --   2) 触发器名 %s → %I：混合大小写表名不再被静默折叠为小写
        IF NOT EXISTS (SELECT 1 FROM pg_trigger tg
                       WHERE tg.tgrelid = format('platform.%I', t)::regclass
                         AND tg.tgname = 'trg_' || t || '_updated_at'
                         AND NOT tg.tgisinternal) THEN
            EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON platform.%I FOR EACH ROW EXECUTE FUNCTION platform.update_updated_at()',
                           'trg_' || t || '_updated_at', t);
        END IF;
    END LOOP;
END;
$$;
