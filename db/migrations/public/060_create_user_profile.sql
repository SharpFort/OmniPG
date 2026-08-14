-- =============================================================================
-- 060_create_user_profile.sql — 用户个人资料表（补建 T7 遗留缺口，17 号文档 §14.2 #5）
-- =============================================================================
-- 背景: user_profile 表在迁移链中无 CREATE TABLE（014 仅 RENAME 自 T7 时代已删迁移
--       创建的 sys_user_profile），空库冷启动缺失——src 的 current_user_dept_id /
--       sys_user 视图 / trg_audit_user_profile / rpc_get_user_profile 均依赖它。
--       2026-08-14 用户拍板补建（P0-7 剩余项）。
-- 设计（业界最佳实践对齐）:
--   - 1:1 关联 users 镜像表（主键即外键，Supabase public.profiles 模式）：
--     users 为 Logto 认证镜像（只读权威），user_profile 为应用自有"用户可编辑个人信息"
--   - 结构化核心列（高频/校验友好，ASP.NET ABP 用户资料惯例）：
--     nickname/avatar_url/gender/birthday/bio/location/hobbies/website
--   - JSONB 扩展（低频偏好，Auth0 user_metadata / Logto customData 模式）：
--     preferences（language/timezone/theme/通知开关等，前端自定义键）
--   - 组织关联：tenant_id（017 约定 organization_id，可空=全局）、dept_id
--     （current_user_dept_id 依赖，部门归属）
--   - 审计列：012 的 text 化约定（created_by/updated_by/deleted_by text）
--   - 软删除：deleted_at/deleted_by（全表惯例）
-- 联动（同提交）:
--   - src 新增 db/src/public/types/gender.sql（bootstrap 前置建，幂等 DO 块）
--   - rls_policies.sql: profile_tenant_policy 补 WITH CHECK（本人/超管可写——
--     原 017 时代仅 USING 只读；用户可编辑语义）
--   - trg_audit_user_profile（src）与 trg_updated_at（自动）随表存在自动生效
--   - rpc_update_user_profile 为动态列白名单（information_schema 驱动）→ 新列自动纳入
-- 幂等: CREATE TABLE IF NOT EXISTS；索引 IF NOT EXISTS；重放两遍安全
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- migrate:up

CREATE TABLE IF NOT EXISTS user_profile (
    user_id     text PRIMARY KEY
                REFERENCES users(id) ON DELETE CASCADE,   -- Logto 用户 id（nanoid 21）；1:1 主键即外键
    nickname    varchar(64),                              -- 昵称（应用自定义显示名；users.name 为 Logto 权威，不重复存储）
    avatar_url  text,                                     -- 头像 URL（Supabase profiles.avatar_url 惯例）
    gender      public.gender,                            -- 性别（原生枚举四值，隐私友好）
    birthday    date,                                     -- 生日（date；隐私字段，前端按需脱敏展示）
    bio         varchar(500),                             -- 个人简介（业界常见 varchar 限长）
    location    varchar(200),                             -- 所在地/住址（自由文本）
    hobbies     text[] NOT NULL DEFAULT '{}',             -- 爱好（标签数组，PG 原生数组类型）
    website     text,                                     -- 个人主页（可选）
    preferences jsonb NOT NULL DEFAULT '{}',              -- 偏好扩展（language/timezone/theme/通知开关等；Auth0 user_metadata 模式）
    dept_id     uuid REFERENCES department(id) ON DELETE SET NULL,  -- 部门归属（current_user_dept_id 依赖）
    tenant_id   text REFERENCES tenants(id) ON DELETE RESTRICT,     -- 租户（017 约定 organization_id；NULL=全局个人资料）
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text,                                     -- 012 text 化约定（Logto user id）
    updated_by  text,
    deleted_at  timestamptz,                              -- 软删除（全表惯例）
    deleted_by  text
);

COMMENT ON TABLE user_profile IS '用户个人资料（应用自有扩展，用户可编辑）：users 为 Logto 认证镜像只读，user_profile 承载 nickname/头像/生日/爱好/住址等个人信息；RLS 本人/超管可写（rls_policies.sql profile_tenant_policy）';
COMMENT ON COLUMN user_profile.user_id IS 'Logto 用户 id（users.id 1:1；主键即外键，ON DELETE CASCADE）';
COMMENT ON COLUMN user_profile.nickname IS '昵称（应用自定义显示名；users.name 为 Logto 权威显示名，不重复）';
COMMENT ON COLUMN user_profile.avatar_url IS '头像 URL（空=默认头像，前端兜底）';
COMMENT ON COLUMN user_profile.gender IS '性别（gender 枚举：male/female/other/prefer_not_to_say）';
COMMENT ON COLUMN user_profile.birthday IS '生日（隐私字段；前端按需脱敏）';
COMMENT ON COLUMN user_profile.bio IS '个人简介（≤500 字）';
COMMENT ON COLUMN user_profile.location IS '所在地/住址（自由文本）';
COMMENT ON COLUMN user_profile.hobbies IS '爱好（标签数组，如 {"篮球","摄影"}）';
COMMENT ON COLUMN user_profile.website IS '个人主页 URL';
COMMENT ON COLUMN user_profile.preferences IS '偏好扩展 JSONB（language/timezone/theme/通知开关等；前端自定义键，Auth0 user_metadata 模式）';
COMMENT ON COLUMN user_profile.dept_id IS '部门归属（current_user_dept_id 依赖；department 表）';
COMMENT ON COLUMN user_profile.tenant_id IS '租户 organization_id（017 约定；NULL=全局个人资料）';

-- 租户维度查询索引（RLS 同租户列表 + 管理端）
CREATE INDEX IF NOT EXISTS idx_user_profile_tenant ON user_profile(tenant_id);

-- 审计触发器由 apply-src 统一挂载：
--   trg_audit_user_profile（src/public/triggers/）——审计日志
--   trg_updated_at（src 自动 DO 块）——updated_at 维护
-- RLS 启用与策略由 rls_policies.sql 集中管理（profile_tenant_policy：读=超管/本人/同租户；写=本人/超管）

-- =============================================================================
-- migrate:down
-- =============================================================================
-- 回滚: DROP TABLE IF EXISTS user_profile CASCADE;
