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
CREATE OR REPLACE FUNCTION ip2region(ip inet) RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = public, pg_temp
AS $$
    SELECT country
           || CASE WHEN province IS NOT NULL AND province <> '' THEN '|' || province ELSE '' END
           || CASE WHEN city     IS NOT NULL AND city     <> '' THEN '|' || city     ELSE '' END
           || CASE WHEN isp      IS NOT NULL AND isp      <> '' THEN '|' || isp      ELSE '' END
    FROM ip_region_v4
    WHERE start_ip <= ip AND end_ip >= ip
    ORDER BY start_ip DESC
    LIMIT 1;
$$;
COMMENT ON FUNCTION ip2region(inet) IS 'ip2region 离线库查询：返回 国家|省|市|ISP（未命中 NULL）；数据由 import-ip2region.sh 导入';

-- ---------------------------------------------------------------------------
-- §2 登录日志写入函数（webhook_logto 内部调用，不对外暴露）
--     tenant_id 留 NULL：PostSignIn 事件无组织上下文（用户登录后可属多组织）；
--     租户维度查询走 P1 管理端 RPC（按 user_tenants join）
--     N25（2026-08-11）: 表名 sys_login_log → login_log（023 RENAME 后旧名失效）；
--     双表兼容：函数体运行时按 to_regclass 选择，兼容 020→023 未衔接的极端顺序
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_login_log_write(payload jsonb) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id    text := payload->>'userId';
    v_username   text;
    v_ip         inet;
    v_agent      text := payload->>'userAgent';
    v_ts         timestamptz := logto_ts(payload->>'createdAt');
    v_login_type text;
BEGIN
    IF v_user_id IS NULL THEN RETURN; END IF;

    SELECT username INTO v_username FROM users WHERE id = v_user_id;

    BEGIN
        v_ip := (payload->>'userIp')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;                     -- 非法 IP 不阻断写入
    END;

    -- 登录方式: user.identities 的第一个 provider（password/sms/wechat/...）
    SELECT key INTO v_login_type
    FROM jsonb_each_text(COALESCE(payload->'user'->'identities', '{}'::jsonb))
    LIMIT 1;

    -- N25: 023 已 RENAME public.sys_login_log → public.login_log；
    --      函数体表名运行时解析，此处双表兼容（正常环境恒走 login_log 分支）
    IF to_regclass('public.login_log') IS NOT NULL THEN
        INSERT INTO login_log
            (tenant_id, user_id, username, login_type, result, ip, user_agent,
             region, logto_event, created_at)
        VALUES
            (NULL, v_user_id, v_username, COALESCE(v_login_type, 'unknown'), 'success',
             v_ip, v_agent, ip2region(v_ip), 'PostSignIn', COALESCE(v_ts, now()));
    ELSE
        INSERT INTO sys_login_log
            (tenant_id, user_id, username, login_type, result, ip, user_agent,
             region, logto_event, created_at)
        VALUES
            (NULL, v_user_id, v_username, COALESCE(v_login_type, 'unknown'), 'success',
             v_ip, v_agent, ip2region(v_ip), 'PostSignIn', COALESCE(v_ts, now()));
    END IF;
EXCEPTION WHEN OTHERS THEN
    NULL;  -- 登录日志失败不阻断 webhook（镜像数据，容忍丢失，P1 告警）
END;
$$;
COMMENT ON FUNCTION sync_login_log_write(jsonb) IS 'PostSignIn → login_log（interaction payload 平铺读取；region 经 ip2region 解析；N25 表名修复）';
REVOKE EXECUTE ON FUNCTION sync_login_log_write(jsonb) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- §3 webhook_logto 重定义（N1 删除事件兜底恢复；其余分支与 010 一致）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_sys.webhook_logto(jsonb);
CREATE FUNCTION api_v1_sys.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_event text := $1->>'event';
    v_data  jsonb := $1->'data';
BEGIN
    CASE v_event
        -- ═══ 用户事件 ═══
        WHEN 'User.Created' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Data.Updated' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Deleted' THEN
            -- N1: data=null，删除 ID 在 params（DELETE /users/:userId → params.userId）；
            --     三键兜底：userId 优先 → id 次之 → data 最后
            PERFORM sync_user_delete(
                COALESCE($1->'params'->>'userId', $1->'params'->>'id', v_data->>'id'));

        -- ═══ 组织（租户）事件 ═══
        WHEN 'Organization.Created' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Data.Updated' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Deleted' THEN
            -- N1: DELETE /organizations/:id → params.id
            PERFORM sync_tenant_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 成员关系事件（增量 diff）═══
        WHEN 'Organization.Membership.Updated' THEN
            PERFORM sync_membership_delta(
                $1->>'organizationId',
                COALESCE($1->'addedUserIds', '[]'::jsonb),
                COALESCE($1->'removedUserIds', '[]'::jsonb));

        -- ═══ 角色目录事件 ═══
        WHEN 'Role.Created' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Data.Updated' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Deleted' THEN
            -- N1: DELETE /roles/:id → params.id
            PERFORM sync_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 登录事件（D-C：interaction payload 顶层平铺，无 data 包装）═══
        WHEN 'PostSignIn' THEN
            PERFORM sync_login_log_write($1);

        -- ═══ 未知事件 — 静默忽略（SuspensionStatus/OrganizationRole.* 等 P1 订阅）═══
        ELSE NULL;
    END CASE;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    -- 幂等失败不阻断 webhook 响应（Logto 投递 fire-and-forget + 重试 3 次）
    RETURN jsonb_build_object('ok', true, 'warn', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api_v1_sys.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；按 event 分发：User.*/Organization.*/Membership/Role.*（data 包装）+ PostSignIn（interaction 平铺）；N1 删除事件 ID 取 params 兜底';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_logto(jsonb) TO web_anon;

-- ---------------------------------------------------------------------------
-- §4 login_log RLS 更新（+ 本人可见自己的登录记录）
--     租户维度：tenant_id 为 NULL（事件无组织上下文），租户管理员经 P1 管理端 RPC 查询
--     表名兼容：023 RENAME 前后策略目标表不同，DDL 立即执行 → 按 to_regclass 分支
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.login_log') IS NOT NULL THEN
        EXECUTE 'DROP POLICY IF EXISTS login_log_read_policy ON public.login_log';
        EXECUTE 'CREATE POLICY login_log_read_policy ON public.login_log
                 FOR SELECT
                 USING (is_super_admin() OR tenant_id = current_tenant_id() OR user_id = current_user_id())';
    ELSIF to_regclass('public.sys_login_log') IS NOT NULL THEN
        EXECUTE 'DROP POLICY IF EXISTS login_log_read_policy ON public.sys_login_log';
        EXECUTE 'CREATE POLICY login_log_read_policy ON public.sys_login_log
                 FOR SELECT
                 USING (is_super_admin() OR tenant_id = current_tenant_id() OR user_id = current_user_id())';
    END IF;
END $$;

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
