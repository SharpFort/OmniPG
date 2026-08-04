-- ==============================================================================
-- Migration 008: 方案 C 角色镜像改造（04.8-方案C-实施清单 Phase 1）
--   A. sys_role 顺序守卫列（webhook_role_upsert 用，防重试/Replay 乱序陈旧覆盖，H5）
--   B. 停用应用侧角色分配写路径与审批流 RPC（D2/D4：角色分配管理面收敛 Casdoor UI）
--      分配与审批 = Casdoor 唯一真相源，应用侧禁止直接写 sys_user_role 镜像
--      恢复方法: 重新 GRANT（deprecated 文件中的原 GRANT 语句）并移除 .deprecated 后缀
-- 幂等性: 全部 IF NOT EXISTS / DO 块条件判断，重复执行无害（apply-src.sh 会重复应用）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- A. sys_role 顺序守卫列
-- ==============================================================================
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS last_event_id   VARCHAR(64);
ALTER TABLE sys_role ADD COLUMN IF NOT EXISTS last_event_time TIMESTAMPTZ;
COMMENT ON COLUMN sys_role.last_event_id   IS 'webhook 顺序守卫：最后应用事件 ID（防重试/Replay 乱序覆盖）';
COMMENT ON COLUMN sys_role.last_event_time IS 'webhook 顺序守卫：最后应用事件时间（Casdoor createdTime，格式 "2006-01-02 15:04:05"，字典序=时间序）';

-- ==============================================================================
-- B. 停用角色分配写路径与审批流（api_v1 层 RPC 撤销 EXECUTE，PostgREST 即不再暴露）
--    函数签名由 pg_proc 动态获取，函数不存在时跳过（幂等）
-- ==============================================================================
DO $$
DECLARE
    v_rec record;
BEGIN
    FOR v_rec IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api_v1_sys'
          AND p.proname IN (
                -- 分配写 RPC（6 个，D4）
                'assign_role_to_user', 'batch_assign_role_to_users', 'batch_assign_roles',
                'remove_role_from_user', 'batch_remove_role_from_users', 'batch_remove_roles',
                -- 审批流 RPC（4 个，D2）
                'submit_role_request', 'approve_role_request', 'reject_role_request',
                'get_user_role_requests'
              )
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION api_v1_sys.%I(%s) FROM authenticated',
                       v_rec.proname, v_rec.args);
        RAISE NOTICE 'REVOKED api_v1_sys.%(%s) FROM authenticated', v_rec.proname, v_rec.args;
    END LOOP;
END $$;

-- migrate:down
-- 恢复: 对上述函数重新执行 GRANT EXECUTE ... TO authenticated（见各 .deprecated 文件原语句），
--       并 ALTER TABLE sys_role DROP COLUMN last_event_id / last_event_time（如需回退）。
