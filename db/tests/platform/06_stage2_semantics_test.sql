-- 06_stage2_semantics_test.sql：阶段 2 新语义回归（四节 1 零覆盖补齐，2026-11-20）
-- 运行: pg_prove -h 127.0.0.1 -U app_owner -d app_db db/tests/platform/06_stage2_semantics_test.sql
-- 覆盖（批次 2a/2b 行为变化）：
--   1) current_logto_tenant_id_strict() 三态（fail-closed；兼容版回退 default 对照）
--   2) audit_created_at() 受控旁路（GUC + session_user 白名单；pg_prove 以 app_owner
--      会话运行 → 白名单天然满足。authenticator 反例需独立会话——SET ROLE 不改
--      session_user，无法在本连接内模拟，见 02 断言注释）
--   3) rpc_create_dict_type 重名预检（23505；dict_type 唯一键 NULLS DISTINCT 缺陷
--      的应用层拦截）+ 无角色会话权限门（42501）
--   4) user_profile WITH CHECK 租户/组织约束（会话内 FORCE RLS；拒绝用例走 INSERT
--      路径——RLS/FK 均先于唯一约束求值，不依赖种子行，fresh DB 兼容；
--      跨组织写入由 validate_user_profile_refs 先于 RLS 拒绝（23503 双层防线））
BEGIN;
SELECT plan(19);

-- ============================================================
-- 1) current_logto_tenant_id_strict() 三态 + 兼容版回退（批次 2a fail-closed）
-- ============================================================
SELECT is(current_logto_tenant_id_strict(), NULL, '无 claim 会话 strict() 返回 NULL（fail-closed）');
SELECT is(current_logto_tenant_id(), 'default', '无 claim 会话兼容版回退 default');

SELECT set_config('request.jwt.claims', '{"sub":"u1","roles":[]}', true);
SELECT is(current_logto_tenant_id_strict(), NULL, '有 claim 无 tenant_id → strict() 返回 NULL');
SELECT is(current_logto_tenant_id(), 'default', '有 claim 无 tenant_id → 兼容版回退 default');

SELECT set_config('request.jwt.claims', '{"sub":"u1","tenant_id":"t_acme","roles":[]}', true);
SELECT is(current_logto_tenant_id_strict(), 't_acme', '有 tenant_id claim → strict() 原样返回');
SELECT is(current_logto_tenant_id(), 't_acme', '有 tenant_id claim → 兼容版同值（不回退）');

SELECT set_config('request.jwt.claims', '{"tenant_id":""}', true);
SELECT is(current_logto_tenant_id_strict(), NULL, '空串 tenant_id → strict() 返回 NULL（NULLIF 双层）');

-- ============================================================
-- 2) audit_created_at() 受控旁路（批次 2b：GUC + session_user 白名单）
-- ============================================================
CREATE TEMP TABLE t_audit_created (id int PRIMARY KEY, created_at timestamptz, payload text);
CREATE TRIGGER trg_t_audit_created
    BEFORE INSERT OR UPDATE ON t_audit_created
    FOR EACH ROW EXECUTE FUNCTION platform.audit_created_at();

INSERT INTO t_audit_created (id, created_at) VALUES (1, '2000-01-01');
SELECT is((SELECT created_at > now() - interval '1 hour' FROM t_audit_created WHERE id = 1), true,
          '默认行为：调用方时间戳被强制覆盖为 now()');

SET app.audit_preserve_timestamps = true;
INSERT INTO t_audit_created (id, created_at) VALUES (2, '2001-02-03');
SELECT is((SELECT created_at::date FROM t_audit_created WHERE id = 2), '2001-02-03'::date,
          'GUC+白名单会话（pg_prove 即 app_owner）：历史时间戳被保留');

INSERT INTO t_audit_created (id, created_at) VALUES (3, NULL);
SELECT is((SELECT created_at > now() - interval '1 hour' FROM t_audit_created WHERE id = 3), true,
          '旁路仅补非 NULL：created_at 为 NULL 仍强制 now()');

UPDATE t_audit_created SET created_at = '1999-12-31' WHERE id = 2;
SELECT is((SELECT created_at::date FROM t_audit_created WHERE id = 2), '2001-02-03'::date,
          'UPDATE 禁止修改 created_at（恢复 OLD 值）');

RESET app.audit_preserve_timestamps;
INSERT INTO t_audit_created (id, created_at) VALUES (4, '2002-03-04');
SELECT is((SELECT created_at > now() - interval '1 hour' FROM t_audit_created WHERE id = 4), true,
          'GUC 失效后旁路关闭（恢复强制 now()）');

-- ============================================================
-- 3) rpc_create_dict_type 重名预检（23505）+ 权限门（42501）
--    全局字典路径（p_tenant_scoped=false → org NULL）：不依赖 Logto 组织数据
--    （fresh DB 安全），且正中唯一键 NULLS DISTINCT 缺口本体（068 遗留：
--    organization_id=NULL 不受约束，重名仅靠本预检的应用层拦截）
-- ============================================================
SELECT set_config('request.jwt.claims',
    '{"sub":"u_pgtap","tenant_id":"default","roles":["role_super_admin"]}', true);
SELECT lives_ok($$ SELECT api_v1_platform.rpc_create_dict_type('pgtap_dup_dict', 'pgtap重复预检', false, 0) $$,
    '超管首次创建全局字典成功（重名预检放行）');
SELECT throws_ok($$ SELECT api_v1_platform.rpc_create_dict_type('pgtap_dup_dict', 'pgtap重复预检', false, 0) $$,
    '23505', 'dict name already exists', '重名预检：全局重名字典返回 23505（NULLS DISTINCT 缺口的应用层拦截）');

SELECT set_config('request.jwt.claims', '{"sub":"u_pgtap","roles":[]}', true);
SELECT throws_ok($$ SELECT api_v1_platform.rpc_create_dict_type('pgtap_noperm', '无权限', true, 0) $$,
    '42501', 'permission denied', '无角色会话被权限门拒绝（has_permission fail-closed）');

-- ============================================================
-- 4) user_profile WITH CHECK 租户/组织约束（跨租户写入须拒）
--    会话内 FORCE RLS 使表 owner 同受策略约束（事务回滚无残留）；
--    claims 取自既有档案行（无行时回退虚拟值——4.1/4.2 的 RLS 拒绝先于 FK 求值，
--    4.3 的 guard 拒绝先于 RLS 与 FK，均不依赖行/用户真实存在）
-- ============================================================
SELECT set_config('request.jwt.claims', (SELECT jsonb_build_object(
        'sub', COALESCE(p.user_id, 'u_pgtap_virtual'),
        'tenant_id', COALESCE(p.tenant_id, 'default'),
        'organization_id', COALESCE(p.organization_id, 'o_none'),
        'roles', '[]'::jsonb)::text
    FROM platform.user_profile p
    ORDER BY p.user_id LIMIT 1), true);

ALTER TABLE platform.user_profile FORCE ROW LEVEL SECURITY;

SELECT throws_ok($$ INSERT INTO platform.user_profile (user_id, tenant_id, organization_id)
    SELECT current_setting('request.jwt.claims', true)::jsonb->>'sub', 't_pgtap_other', NULL $$,
    '42501', $q$new row violates row-level security policy for table "user_profile"$q$,
    'INSERT 跨租户档案行被 WITH CHECK 拒绝');

SELECT throws_ok($$ INSERT INTO platform.user_profile (user_id, tenant_id, organization_id)
    VALUES ('u_pgtap_somebody_else', 'default', NULL) $$,
    '42501', $q$new row violates row-level security policy for table "user_profile"$q$,
    'INSERT 他人档案行被 WITH CHECK 拒绝（user_id ≠ 当前用户）');

SELECT throws_ok($$ INSERT INTO platform.user_profile (user_id, tenant_id, organization_id)
    SELECT current_setting('request.jwt.claims', true)::jsonb->>'sub', 'default', 'o_pgtap_other' $$,
    '23503',
    'user ' || (current_setting('request.jwt.claims', true)::jsonb->>'sub')
        || ' is not a member of organization o_pgtap_other',
    'INSERT 跨组织档案行被成员关系校验拒绝（locker FOR KEY SHARE / 冷库 EXISTS 回退）');

SELECT is(
    (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'platform' AND tablename = 'user_profile'
       AND policyname = 'profile_tenant_policy'
       AND with_check IS NOT NULL
       AND position('current_user_id()' in with_check) > 0
       AND position('current_logto_tenant_id()' in with_check) > 0
       AND position('current_organization_id()' in with_check) > 0),
    1::bigint, 'WITH CHECK 谓词含 user/tenant/org 三重绑定（introspection 兜底）');

SELECT * FROM finish();
ROLLBACK;
