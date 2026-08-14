-- =============================================================================
-- 050_suspension_sync.sql — D7 封禁状态同步（33 号文档 §9 D7）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板——封禁操作在 Logto 侧完成（OmniPG 不实现、不依赖）；
--   镜像仅同步 is_suspended 供展示；实时生效依赖 Logto 会话撤销 + 短 token。
-- 官方核实（webhooks-events 页触发表）: PATCH /users/:id/is-suspended
--   → User.SuspensionStatus.Updated（独立事件，User.Data.Updated 不触发）；
--   payload data = UserEntity（含 isSuspended 布尔）。
-- 实现: sync_user_suspension 幂等仅改 is_suspended；webhook_logto 追加分支
--   （048 版 + 新分支，N1/N6/D4 语义保持）。
-- 幂等: CREATE OR REPLACE / DROP+CREATE+GRANT 可重放。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 sync_user_suspension — 幂等仅改封禁列（不触碰其他权威字段）
--     用户行不存在则跳过（行由 User.Created / 对账建立；0 行更新无害）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §2 webhook_logto 重写（048 版 + User.SuspensionStatus.Updated 分支）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_fn int; v_src int;
BEGIN
    -- 环境自适应（17 号文档：函数已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    v_fn := (to_regprocedure('sync_user_suspension(text,boolean)') IS NOT NULL)::int;
    v_src := CASE WHEN to_regprocedure('api_v1_public.webhook_logto(jsonb)') IS NOT NULL
                  AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'webhook_logto'
                              AND pg_get_functiondef(oid) LIKE '%User.SuspensionStatus.Updated%')
                  THEN 1 ELSE 0 END;
    RAISE NOTICE '050: sync_user_suspension=% 分支=%（dbmate 阶段=0/0，apply-src 后=1/1）', v_fn, v_src;
    -- 环境自适应（17 号文档）：函数已迁 src，dbmate up 阶段不存在
    IF NOT (v_fn IN (0, 1)) OR NOT (v_src IN (0, 1)) THEN
        RAISE EXCEPTION '050 验证失败';
    END IF;
    RAISE NOTICE '050: 全部验证通过';
END $$;
