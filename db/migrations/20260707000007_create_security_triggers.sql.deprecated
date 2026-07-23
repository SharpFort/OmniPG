-- ==============================================================================
-- Migration 007: 安全触发器（角色变更即时生效）+ 清理函数
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- [修复 P1-3] updated_at 自动更新触发器
-- ==============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN 
        SELECT table_name FROM information_schema.columns 
        WHERE column_name = 'updated_at' AND table_schema = 'public'
    LOOP
        EXECUTE format('CREATE TRIGGER IF NOT EXISTS trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at()', t, t);
    END LOOP;
END;
$$;

-- ==============================================================================
-- blacklist_at_on_role_change：角色变更时即时使旧 Token 失效
-- ==============================================================================
CREATE OR REPLACE FUNCTION blacklist_at_on_role_change()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_session RECORD;
BEGIN
    -- 确定受影响的用户 ID
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        v_user_id := NEW.user_id;
    ELSE
        v_user_id := OLD.user_id;
    END IF;

    -- 将该用户所有活跃会话的 AT 加入黑名单
    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = v_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at, reason, user_id)
        VALUES (v_session.active_jti, v_session.expired_at, 'role_changed', v_user_id)
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION blacklist_at_on_role_change() IS '角色变更触发器：将旧 JWT 的 jti 写入黑名单，迫使客户端无感刷新';

-- 绑定触发器到用户-角色关联表
CREATE TRIGGER trg_blacklist_on_role_change
AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
FOR EACH ROW EXECUTE FUNCTION blacklist_at_on_role_change();

-- ==============================================================================
-- [修复 P1-8] Token 清理机制
-- ==============================================================================
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS void AS $$
BEGIN
    DELETE FROM sys_token_blacklist WHERE expired_at < now();
    DELETE FROM sys_user_session WHERE expired_at < now() - interval '1 day';
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION cleanup_expired_tokens() IS '清理过期的 Token 黑名单和会话（由 pg_cron 定时调用）';

-- migrate:down
DROP FUNCTION IF EXISTS cleanup_expired_tokens();
DROP TRIGGER IF EXISTS trg_blacklist_on_role_change ON sys_user_role;
DROP FUNCTION IF EXISTS blacklist_at_on_role_change();
