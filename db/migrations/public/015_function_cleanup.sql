-- =============================================================================
-- 015_function_cleanup.sql — T7: 函数清理（退役 Casdoor 时代 + 更新表名引用）
-- =============================================================================
-- 背景: 014 重命名/删除表后，函数 prosrc 文本不会自动更新 → 运行时炸。
--   A. 退役删除（Casdoor 时代，05 §10.2 明确删除/不启用/有 .deprecated 源）:
--      - 会话/黑名单: check_token_blacklist / cleanup_expired_sessions /
--        force_logout_user / get_user_sessions / logout / blacklist_at_on_role_change /
--        cleanup_expired_tokens / kick_user（D12 会话管理交 Logto）
--      - RBAC 时代 RPC: assign_role_to_user / batch_assign_roles / batch_remove_roles /
--        get_role_users / get_user_roles / reject_role_request / remove_role_from_user /
--        submit_role_request / approve_role_request（角色分配移 Logto）
--      - create_user（pg_net→Casdoor 建号，05 明确删除）
--      - webhook_user_upsert / webhook_user_delete（010 已由 webhook_logto 替代）
--      - update_role_permissions（RBAC 时代）
--   B. CREATE OR REPLACE 更新（活跃业务函数，改表名引用）:
--      - get_current_user / get_dept_tree（department）
--      - get_config / get_all_public_configs / update_config（app_config）
--      - get_menu_tree_admin（iam_menu）
--      - get_user_menu（iam_menu + JWT roles 语义）
--      - current_user_dept_id（user_profile）
--      - write_audit_log / audit_trigger_func（audit_log）
--      - sync_membership_delta（app_config）
--      - import_csv（黑名单表名更新）
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 退役删除（DO 块遍历，签名无关）
-- ---------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
    FOR f IN
        SELECT n.nspname AS sch, p.proname AS fn, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('public','api_v1_sys')
          AND p.proname IN (
            'check_token_blacklist','cleanup_expired_sessions','force_logout_user',
            'get_user_sessions','logout','blacklist_at_on_role_change','cleanup_expired_tokens',
            'kick_user','assign_role_to_user','batch_assign_roles','batch_remove_roles',
            'get_role_users','get_user_roles','reject_role_request','remove_role_from_user',
            'submit_role_request','approve_role_request','create_user',
            'webhook_user_upsert','webhook_user_delete','update_role_permissions')
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE', f.sch, f.fn, f.args);
        RAISE NOTICE '015 退役: %.%(%)', f.sch, f.fn, f.args;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- §2 get_current_user — sys_user 视图(自动更新✅) + department 引用修正
--     原引用 public.sys_tenant（已删）→ 改 tenants 镜像（租户名）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §3 get_dept_tree — department
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §4 get_config / get_all_public_configs / update_config — app_config
-- ---------------------------------------------------------------------------




-- update_config — app_config（T7 表名更新；DB 现有返回 boolean，先 DROP 再建）



-- import_csv — 白名单黑名单表名更新（T7）

-- ---------------------------------------------------------------------------
-- §5 get_menu_tree_admin — iam_menu（列名 menu_name/path/icon/order_num）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §6 get_user_menu — Logto 语义：JWT roles（字符串数组）→ iam_role_menu → iam_menu
--     替代 Casdoor 时代 sys_user_role JOIN（05 §5.3.1：roles claim 直接消费）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §7 current_user_dept_id / write_audit_log / audit_trigger_func — 新表名
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §8 sync_membership_delta — app_config
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §9 验证：无残留引用旧表名的活跃函数
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','api_v1_sys')
      AND p.prosrc ~ 'sys_(api|menu|tenant|secret|token_blacklist|user_session|user_legacy|role|user_role|user_profile|department|config|audit_log|cron_log)';
    RAISE NOTICE '015: 残留引用旧表名函数=%（预期 0）', v_cnt;
END $$;
