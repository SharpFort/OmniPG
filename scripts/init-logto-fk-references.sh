#!/usr/bin/env bash
# =============================================================================
# init-logto-fk-references.sh — 业务侧 FK 指向 Logto 基表所需的 REFERENCES 授权（D26）
# 角色: app_owner 获得 public.users / public.organizations / public.roles /
#       public.organization_roles 的 REFERENCES 权限（仅约束创建所需，非 DML）
# 前置: 需要超级用户执行（表属主为 logto，非 superuser 无 GRANT REFERENCES 权限）
# 用法: PG_SUPER_CMD='sudo -u postgres psql' ./scripts/init-logto-fk-references.sh
#       或直接 ./scripts/init-logto-fk-references.sh（默认 sudo; 无 sudo 时回退 runuser）
# 幂等: GRANT 可重复执行。
# =============================================================================
set -euo pipefail

DB_NAME=${DB_NAME:-app_db}
DB_PORT=${DB_PORT:-5432}
PG_SUPER_CMD=${PG_SUPER_CMD:-}

if [ -z "$PG_SUPER_CMD" ] && command -v sudo >/dev/null 2>&1; then
  PG_SUPER_CMD="sudo -u postgres psql"
elif [ -z "$PG_SUPER_CMD" ] && command -v runuser >/dev/null 2>&1; then
  PG_SUPER_CMD="runuser -u postgres -- psql"
fi
if [ -z "$PG_SUPER_CMD" ]; then
  echo "ERROR: 无法确定超级用户执行方式，请设置 PG_SUPER_CMD" >&2
  exit 1
fi

echo "[init-logto-fk-references] GRANT REFERENCES (db=${DB_NAME})"
$PG_SUPER_CMD -v ON_ERROR_STOP=1 -p "$DB_PORT" -d "$DB_NAME" <<'SQL'
GRANT REFERENCES ON public.users, public.organizations, public.roles, public.organization_roles, public.tenants TO app_owner;
SQL
echo "[init-logto-fk-references] done"
