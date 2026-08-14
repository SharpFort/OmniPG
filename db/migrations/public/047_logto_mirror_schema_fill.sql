-- =============================================================================
-- 047_logto_mirror_schema_fill.sql — D2 镜像表结构补齐（33 号文档 §9 D2）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板——role 补 description；users 补 profile/ssoIdentities；
--   webhook 推送字段入库阶段全部接收；updated_at 映射进 sync_*。
-- 字段来源核实（官方 webhooks-request 页 + 源码 userInfoSelectFields）:
--   - webhook UserEntity 13 字段不含 profile/ssoIdentities/updatedAt
--     → 两列默认 '{}'（webhook 阶段恒空），唯一数据来源 = 对账任务（D9）注入；
--   - updatedAt 仅在 Management API 返回 → COALESCE(logto_ts(data->>'updatedAt'), now())
--     （webhook 推送时落本地时间，对账 payload 携带时落权威时间）
-- 幂等: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / GRANT 可重放
-- 依赖: logto_ts（010）、sync_user_upsert/sync_role_upsert/sync_tenant_upsert（010 初版，本迁移重写）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 列补齐
-- ---------------------------------------------------------------------------
ALTER TABLE public.role ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
COMMENT ON COLUMN public.role.description IS 'Logto Role.description（webhook/对账推送）';

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS profile jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS sso_identities jsonb NOT NULL DEFAULT '{}';
COMMENT ON COLUMN public.users.profile IS 'Logto User.profile（OIDC 标准 claims；仅 Management API 返回，对账任务 D9 注入）';
COMMENT ON COLUMN public.users.sso_identities IS 'Logto User.ssoIdentities（企业 SSO 身份；仅 Management API 返回，对账任务 D9 注入）';

-- ---------------------------------------------------------------------------
-- §2 sync_user_upsert 重写（D2: +profile/sso_identities 列 + updatedAt 映射）
--     data 字段 = Logto User entity（webhook 13 字段；对账 payload 可含 profile/
--     ssoIdentities/updatedAt——Management API 返回）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §3 sync_role_upsert 重写（D2: +description 列 + updatedAt 映射）
--     data: id, name, description, type, isDefault（webhook/对账；updatedAt 可选）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §4 sync_tenant_upsert 重写（D2: updatedAt 映射）
--     data: id, name, description, customData, createdAt, updatedAt（可选）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ucols int; v_rcol int; v_fn int;
BEGIN
    SELECT count(*) INTO v_ucols FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users'
      AND column_name IN ('profile', 'sso_identities');
    SELECT count(*) INTO v_rcol FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'role'
      AND column_name = 'description';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('sync_user_upsert', 'sync_role_upsert', 'sync_tenant_upsert');
    RAISE NOTICE '047: users新增列=% role.description=% sync函数=%（dbmate 阶段 sync=0，apply-src 后=3）', v_ucols, v_rcol, v_fn;
    -- 环境自适应（17 号文档）：sync_* 函数已迁 src，dbmate up 阶段不存在
    IF v_ucols <> 2 OR v_rcol <> 1 OR NOT (v_fn IN (0, 3)) THEN
        RAISE EXCEPTION '047 验证失败';
    END IF;
    RAISE NOTICE '047: 全部验证通过';
END $$;
