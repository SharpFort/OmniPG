-- =============================================================================
-- 049_user_role_refine.sql — D5+D6 user_role 精确镜像（33 号文档 §9 D5/D6）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板（方案 A）——
--   ① user_role 加 organization_id 维度（'' = 全局角色；非空 = 该组织内角色），
--      结构对齐 Logto users_roles（user_id/role_id 形状），复合主键；
--   ② claims 脚本拆 global_roles / org_roles 注入（init-logto.py 同步修改）；
--   ③ JIT 改增量对齐：角色不变零写入、保留 created_at 首次分配时间；
--   ④ 全局 token 登录（无 organization_id）不清组织角色段（防多组织用户丢镜像）。
-- 键设计:
--   PK (user_id, organization_id, role_code)——role_code 为业务键（JWT roles 元素名，
--   恒可用）；role_id 为 Logto 对齐冗余列（可空：镜像缺失时 NULL，对账/后续登录回填），
--   FK → role(id) ON DELETE CASCADE（角色删除级联清理分配镜像，N12 关联项）。
-- 兼容: claims 无 global_roles/org_roles（旧 token 过渡期，claims 脚本未更新前）→
--   跳过角色镜像更新（不写不删），避免把用户角色误清空。
-- 幂等: ADD COLUMN IF NOT EXISTS / DROP CONSTRAINT IF EXISTS / CREATE OR REPLACE。
-- 依赖: role 镜像表（009）、user_profile（012）、ensure_user（035 §7 N7 版，本迁移重写）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 user_role 结构改造
-- ---------------------------------------------------------------------------
ALTER TABLE user_role ADD COLUMN IF NOT EXISTS organization_id text NOT NULL DEFAULT '';
ALTER TABLE user_role ADD COLUMN IF NOT EXISTS role_id text;
COMMENT ON COLUMN user_role.organization_id IS '角色归属维度：'''' = 全局角色（Logto 全局 roles）；非空 = Logto organization id（组织角色）';
COMMENT ON COLUMN user_role.role_id IS 'Logto 角色 id（对齐 users_roles 形状；镜像缺失时 NULL，对账/后续登录回填）';

-- PK 重建: (user_id, role_code) → (user_id, organization_id, role_code)
-- 存量行 organization_id=''，一一对应无冲突
ALTER TABLE user_role DROP CONSTRAINT IF EXISTS user_role_pkey;
ALTER TABLE user_role ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, organization_id, role_code);

-- role_id 对齐 FK（角色删除级联清理分配镜像）
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_role_id_fk') THEN
        ALTER TABLE user_role
        ADD CONSTRAINT user_role_role_id_fk
        FOREIGN KEY (role_id) REFERENCES role(id) ON DELETE CASCADE;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §2 ensure_user 重写（N7 保持 + D5/D6 增量对齐）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols int; v_pk int; v_fk int; v_fn int;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_role'
      AND column_name IN ('organization_id', 'role_id');
    -- PK 三列完整性由 DROP+ADD PRIMARY KEY DDL 保证（失败即报错）；此处仅查约束存在
    SELECT count(*) INTO v_pk FROM pg_constraint WHERE conname = 'user_role_pkey';
    SELECT count(*) INTO v_fk FROM pg_constraint WHERE conname = 'user_role_role_id_fk';
    SELECT count(*) INTO v_fn FROM pg_proc WHERE proname = 'ensure_user';
    RAISE NOTICE '049: 新增列=% PK=% FK=% ensure_user=%（dbmate 阶段 ensure_user=0，apply-src 后=1）', v_cols, v_pk, v_fk, v_fn;
    -- 环境自适应（17 号文档）：ensure_user 已迁 src，dbmate up 阶段不存在
    IF v_cols <> 2 OR v_pk <> 1 OR v_fk <> 1 OR NOT (v_fn IN (0, 1)) THEN
        RAISE EXCEPTION '049 验证失败';
    END IF;
    RAISE NOTICE '049: 全部验证通过';
END $$;
