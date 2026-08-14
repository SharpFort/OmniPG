-- =============================================================================
-- 020_login_log_webhook.sql — 登录日志 webhook 链路落地（D-C）
-- =============================================================================
-- 背景: 2026-08-04 用户确认"webhook PostSignIn 主通道"方案
-- 源码核实（logto-io/logto master）: Interaction hooks（PostSignIn 等）payload
--   顶层平铺、无 data 包装（packages/core/src/libraries/hook/index.ts L130-176）：
--   { event, interactionEvent, sessionId, applicationId, userIp, userAgent,
--     userId, user, hookId, createdAt }
--   ⚠️ 与实体事件（User.Created 等 data 包装）结构不同 → 分支内直接读顶层字段
-- 失败登录: Identifier.Lockout + Management API 对账 → P1（019 注释已说明）
--
-- 2026-08-11 重写（P0 修复 N1 + N25，33 号审查文档 §9 决策 D8）：
--   N1: 删除类事件兜底恢复——User.Deleted / Organization.Deleted / Role.Deleted
--       的 data 为 null（官方 webhooks-request 页: 删除类事件 data=null），
--       删除 ID 在 Management API context 的 params（koa path params）中：
--       DELETE /users/:userId        → params.userId（010/020 旧写法取 params.id 同样取不到）
--       DELETE /organizations/:id    → params.id
--       DELETE /roles/:id            → params.id
--       统一恢复 COALESCE(params->>'userId', params->>'id', data->>'id') 三键兜底
--       （020 初版误删兜底改 v_data->>'id' 恒 NULL → 镜像软删/硬删永不执行）
--   N25: sync_login_log_write 函数体仍引用旧表名 sys_login_log——023 已将
--        public.sys_login_log RENAME TO login_log，函数体表名运行时解析，
--        改名后 PostSignIn 一触发即 relation does not exist，且被异常分支
--        静默吞掉（N6）→ 登录日志链路实际断开。本轮改为 login_log，
--        并对 020→023 执行顺序做双表兼容（to_regclass 运行时判断）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 ip2region 查询函数（public 底层）
--     数据表 ip_region_v4（019）由 scripts/import-ip2region.sh 导入 ipv4_source.txt
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §2 登录日志写入函数（webhook_logto 内部调用，不对外暴露）
--     tenant_id 留 NULL：PostSignIn 事件无组织上下文（用户登录后可属多组织）；
--     租户维度查询走 P1 管理端 RPC（按 user_tenants join）
--     N25（2026-08-11）: 表名 sys_login_log → login_log（023 RENAME 后旧名失效）；
--     双表兼容：函数体运行时按 to_regclass 选择，兼容 020→023 未衔接的极端顺序
-- ---------------------------------------------------------------------------

-- REVOKE EXECUTE ON FUNCTION sync_login_log_write(jsonb) FROM PUBLIC; -- 已随函数归位（17 号文档）：函数迁 src/public/functions/sync_login_log_write.sql，REVOKE 随迁

-- ---------------------------------------------------------------------------
-- §3 webhook_logto 重定义（N1 删除事件兜底恢复；其余分支与 010 一致）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §4 login_log RLS 更新（+ 本人可见自己的登录记录）
--     17 号文档归位（2026-08-14）：策略定义迁 db/src/public/privileges/rls_policies.sql
--     （login_log_read_policy 已含 020 语义：超管 OR 本租户 OR 本人可见）
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §5 验证（N1/N25 防复发断言）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_fn1  int;  -- ip2region 函数
    v_fn2  int;  -- sync_login_log_write 函数
    v_pol  int;  -- login_log_read_policy（login_log 或 sys_login_log 上）
    v_new  int;  -- sync_login_log_write 定义含 INSERT INTO login_log（N25 防复发）
    v_del  int;  -- webhook_logto 定义含 params 兜底（N1 防复发）
BEGIN
    SELECT count(*) INTO v_fn1 FROM pg_proc WHERE proname = 'ip2region';
    SELECT count(*) INTO v_fn2 FROM pg_proc WHERE proname = 'sync_login_log_write';
    SELECT count(*) INTO v_pol FROM pg_policies
      WHERE policyname = 'login_log_read_policy'
        AND tablename IN ('login_log', 'sys_login_log');
    SELECT count(*) INTO v_new FROM pg_proc
      WHERE proname = 'sync_login_log_write'
        AND pg_get_functiondef(oid) LIKE '%INSERT INTO login_log%';
    SELECT count(*) INTO v_del FROM pg_proc
      WHERE proname = 'webhook_logto'
        AND pg_get_functiondef(oid) LIKE '%params%';
    RAISE NOTICE '020: ip2region=% sync_login_log_write=% 策略=% N25表名=% N1参数兜底=%（期望 1/1/1/1/1）',
        v_fn1, v_fn2, v_pol, v_new, v_del;
END $$;
