#!/usr/bin/env bash
# =============================================================================
# init-logto-reader.sh — 创建 Logto 同库只读角色（D25）
# 角色: omnipg_logto_reader（NOLOGIN + BYPASSRLS + 列级 SELECT）
# 用途: platform 内六个只读投影视图 / v_logto_login_events 的视图 owner，
#       业务 API 永远不会直接授予 public 表权限。
# 前置: 需要超级用户执行（BYPASSRLS 非 superuser/BYPASSRLS 角色不可授予）。
# 用法: PG_SUPER_CMD='sudo -u postgres psql' ./scripts/init-logto-reader.sh
#       或直接 ./scripts/init-logto-reader.sh（默认 sudo; 无 sudo 时回退 runuser）
# 幂等: 角色/授权可重复执行。
# =============================================================================
set -euo pipefail

DB_NAME=${DB_NAME:-app_db}
DB_PORT=${DB_PORT:-5432}
PG_SUPER_CMD=${PG_SUPER_CMD:-}

# 优先 runuser（root 场景更可靠；no-new-privileges 沙箱中 sudo 会失败），
# 无 runuser 时回退 sudo。
if [ -z "$PG_SUPER_CMD" ] && command -v runuser >/dev/null 2>&1; then
  PG_SUPER_CMD="runuser -u postgres -- psql"
elif [ -z "$PG_SUPER_CMD" ] && command -v sudo >/dev/null 2>&1; then
  PG_SUPER_CMD="sudo -u postgres psql"
fi
if [ -z "$PG_SUPER_CMD" ]; then
  echo "ERROR: 无法确定超级用户执行方式，请设置 PG_SUPER_CMD" >&2
  exit 1
fi

echo "[init-logto-reader] create role/grant (db=${DB_NAME})"
$PG_SUPER_CMD -v ON_ERROR_STOP=1 -p "$DB_PORT" -d "$DB_NAME" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'omnipg_logto_reader') THEN
    CREATE ROLE omnipg_logto_reader NOLOGIN BYPASSRLS;
  END IF;
END $$;

GRANT omnipg_logto_reader TO app_owner;

GRANT USAGE ON SCHEMA public TO omnipg_logto_reader;
GRANT USAGE ON SCHEMA platform TO omnipg_logto_reader;

-- Logto 关键表：仅授予投影视图需要的列（敏感列不授）
GRANT SELECT (tenant_id, id, username, primary_email, primary_phone, name, avatar, is_suspended, created_at, updated_at)
  ON public.users TO omnipg_logto_reader;
GRANT SELECT (tenant_id, id, name, description, type, is_default)
  ON public.roles TO omnipg_logto_reader;
GRANT SELECT (tenant_id, id, name, description, custom_data, created_at)
  ON public.organizations TO omnipg_logto_reader;
GRANT SELECT (tenant_id, id, name, description, type)
  ON public.organization_roles TO omnipg_logto_reader;
GRANT SELECT (tenant_id, organization_id, user_id)
  ON public.organization_user_relations TO omnipg_logto_reader;
GRANT SELECT (tenant_id, user_id, role_id)
  ON public.users_roles TO omnipg_logto_reader;
GRANT SELECT (tenant_id, organization_id, user_id, organization_role_id)
  ON public.organization_role_user_relations TO omnipg_logto_reader;
GRANT SELECT (id, name, tag, db_user, created_at, is_suspended)
  ON public.tenants TO omnipg_logto_reader;
GRANT SELECT (tenant_id, key, payload, created_at)
  ON public.logs TO omnipg_logto_reader;

-- 关键：platform 只读投影视图 owner 必须是 reader（BYPASSRLS），否则读取仍受 Logto RLS 拦截。
DO $$ DECLARE v_rel text; BEGIN
  FOREACH v_rel IN ARRAY ARRAY['users','tenants','organizations','role','tenant_role','user_tenants','user_role','v_logto_login_events'] LOOP
    IF to_regclass(format('platform.%I', v_rel)) IS NOT NULL THEN
      EXECUTE format('ALTER VIEW platform.%I OWNER TO omnipg_logto_reader', v_rel);
    END IF;
  END LOOP;
END $$;

-- ALTER OWNER 会清掉旧 owner（app_owner）的授权，重新授给业务 owner
GRANT SELECT ON platform.users, platform.tenants, platform.organizations, platform.role, platform.tenant_role,
              platform.user_tenants, platform.user_role, platform.v_logto_login_events
  TO app_owner;

-- D26: 业务侧 FK 指向 Logto 基表所需的 REFERENCES 权限（仅约束创建所需，非 DML）
GRANT REFERENCES ON public.users, public.organizations, public.roles, public.organization_roles, public.tenants
  TO app_owner;
SQL
echo "[init-logto-reader] done"
