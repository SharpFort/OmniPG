-- =============================================================================
-- 051_logto_guard_cleanup.sql — P2 治理：N18 乱序守护 + N21 空转跳过 + N14 RPC
-- =============================================================================
-- 覆盖项（33 号文档 §3/§6 P2 治理）:
--   N18: 镜像表加 logto_updated_at（权威 updatedAt），sync_* 乱序守护——
--        "旧事件不覆盖新状态"（Logto 重试/Replay 可能乱序）；
--   N21: sync_membership_delta 空 delta 早退（无变更事件不空转）；
--        5000 截断的 sys_config 标记移除——D9 对账任务每日全量成员对账兜底（标记冗余）；
--   N14: rpc_get_user_roles（SECURITY DEFINER + sys:tenant-member:list 门槛 + 同租户约束）
--        替代裸视图——租户管理员可查本租户用户角色分配（v_user_roles RLS 仅超管/本人）；
--   N11/N12: 注释固化决策——joined_at=now() 本地近似（Logto 成员 API 不返回加入时间）；
--        角色硬删 + user_role FK CASCADE 显式级联清理绑定（049 已建 FK）。
-- 乱序守护语义:
--   · logto_updated_at = COALESCE(logto_ts(data->>'updatedAt'), now())
--     （webhook 无 updatedAt → 本地时间近似；对账 payload 携带 → 权威时间）；
--   · ON CONFLICT UPDATE 追加 WHERE 旧行 logto_updated_at IS NULL（存量兼容）
--     OR EXCLUDED.logto_updated_at >= 旧行值（>= 允许同时间戳乱序内覆盖）；
--   · 守护只挡"更旧事件"，sync_* 幂等性保持。
-- 依赖: sync_*（047/048/050 版，本迁移重写）；has_permission/current_tenant_id
--       （024/035，rpc_get_user_roles 用）。
-- 幂等: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE 可重放。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 logto_updated_at 列（N18）
-- ---------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE role ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE organization_role ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
COMMENT ON COLUMN users.logto_updated_at IS 'Logto 权威 updatedAt（webhook 无该字段时为本地近似）；乱序守护比较基准（N18）';
COMMENT ON COLUMN tenants.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
COMMENT ON COLUMN role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
COMMENT ON COLUMN organization_role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';

-- N11 决策注释（Logto 成员 API 不返回加入时间——joined_at 为首次观察到成员关系的本地时间）
COMMENT ON COLUMN user_tenants.joined_at IS '加入时间（本地近似）——Logto 成员 API 不返回加入时间；对账全量重建时保持首次观察值（N11 决策）';

-- N12 决策注释（角色硬删 + FK CASCADE 显式级联清理绑定，与用户/组织软删策略区分）
COMMENT ON TABLE role IS 'Logto 全局角色镜像（只读投影）；删除策略=硬删+级联——user_role.role_id FK ON DELETE CASCADE 显式清理分配镜像（N12 决策，049 建立）';

-- ---------------------------------------------------------------------------
-- §2 sync_user_upsert 重写（N18 乱序守护）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §3 sync_role_upsert 重写（N18）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §4 sync_tenant_upsert 重写（N18）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §5 sync_organization_role_upsert 重写（N18）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §6 sync_user_suspension 重写（N18：封禁事件同样受乱序守护）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §7 sync_membership_delta 重写（N21：空 delta 早退；移除 5000 截断标记）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §8 rpc_get_user_roles（N14：管理端角色-成员页查询通道，替代裸视图）
--     门槛: sys:tenant-member:list + 同租户约束（与 rpc_list_tenant_members 一致）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §9 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols int; v_fn int;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('users', 'tenants', 'role', 'organization_role')
      AND column_name = 'logto_updated_at';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('sync_user_upsert', 'sync_role_upsert', 'sync_tenant_upsert',
                      'sync_organization_role_upsert', 'sync_user_suspension',
                      'sync_membership_delta', 'rpc_get_user_roles');
    RAISE NOTICE '051: logto_updated_at列=% 函数=%（dbmate 阶段函数=0，apply-src 后=7）', v_cols, v_fn;
    -- 环境自适应（17 号文档）：sync_* 函数已迁 src，dbmate up 阶段不存在
    IF v_cols <> 4 OR NOT (v_fn IN (0, 7)) THEN
        RAISE EXCEPTION '051 验证失败';
    END IF;
    RAISE NOTICE '051: 全部验证通过';
END $$;
