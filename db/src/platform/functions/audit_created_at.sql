-- db/src/platform/functions/audit_created_at.sql
-- 强制保护 created_at 字段：INSERT 时强制设为 now()，UPDATE 时禁止修改
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §5（P2 修复）
--
-- 使用说明：
--   CREATE TRIGGER trg_<表名>_audit_created_at
--       BEFORE INSERT OR UPDATE ON <表名>
--       FOR EACH ROW EXECUTE FUNCTION audit_created_at();
--
-- 注意：
--   - INSERT 时：默认强制 now()；pg_restore/历史回填等场景可经会话级 GUC + 白名单登录身份
--     受控旁路：SET app.audit_preserve_timestamps = true;（须以 app_owner/postgres 会话执行；
--     此时仅补 NULL，不覆盖既有值）
--   - UPDATE 时：无论应用层传入什么值，都强制恢复为 OLD.created_at
--   - 这是"最后一道防线"，确保 created_at 不可被应用层篡改

CREATE OR REPLACE FUNCTION audit_created_at()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        -- 受控旁路（2026-11-19 修复）：原实现无条件覆盖 created_at，pg_restore/数据回填
        -- 会把全部历史时间戳改写为恢复时刻（不可逆数据丢失）。
        -- 旁路需同时满足：会话级 GUC + 会话登录身份为 app_owner/postgres——
        -- session_user 不可经 SET 伪造，PostgREST 连接（authenticator）无法启用旁路
        -- 使用方式（恢复会话内执行，非 SET LOCAL——独立会话不共享事务外设置）：
        --   SET app.audit_preserve_timestamps = true;
        IF COALESCE(current_setting('app.audit_preserve_timestamps', true), '') = 'true'
           AND session_user IN ('app_owner', 'postgres')
           AND NEW.created_at IS NOT NULL THEN
            NULL;  -- 保留调用方提供的历史值
        ELSE
            NEW.created_at := now();
        END IF;
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.created_at := OLD.created_at;
    ELSE
        -- 防御（2026-11-19）：误绑 DELETE/TRUNCATE 时 NEW 为 NULL，隐式返回 NULL 会
        -- 静默取消整条 DML——显式报错暴露误用
        RAISE EXCEPTION 'audit_created_at() only supports INSERT/UPDATE, got %', TG_OP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit_created_at() IS '强制保护 created_at 字段：INSERT 默认 now()（app.audit_preserve_timestamps=true 时保留调用方值），UPDATE 禁止修改。作为最后一道防线防止应用层篡改。';
