#!/bin/bash
# =============================================================================
# rotate-credentials.sh — 凭据一键轮换助手（唯一凭据文件：gateway/.env）
# 参数化批（2026-11-20）：三处密码（Logto 管理员 / APISIX admin key / DB 系）
# 的轮换入口统一为 gateway/.env 一个文件——编辑该文件后跑本脚本完成
# 库端同步；容器/外部侧的剩余动作由脚本按序提示。
#
# 用法:
#   1. 编辑 gateway/.env（唯一需要改的文件）：
#      DB_PASSWORD / AUTHENTICATOR_PASSWORD / LOGTO_DB_PASSWORD
#   2. bash scripts/rotate-credentials.sh
#
# 自动完成:
#   * ALTER ROLE app_owner / authenticator / logto（新密码生效于库端）
#   * pgbouncer userlist SCRAM verifier 重生成（scripts/pgbouncer-userlist-scram.sh
#     ——verifier 必须与库端逐字节一致，passthrough 硬要求）
#   * pgbouncer RELOAD（新客户端连接即时生效）
#
# 剩余手动步骤（脚本末尾按序提示，按需执行）:
#   * docker compose -f gateway/docker-compose.yml restart postgrest
#     （authenticator 密码变更后重建连接池）
#   * docker compose -f gateway/docker-compose.yml restart logto
#     （LOGTO_DB_PASSWORD 变更后 Logto 重连，登录中断 ~30s）
#   * 另一项目（Windows 后端，app_owner 连接池）更新连接串并重启
#   * pigsty 重新供应才需要：bash scripts/render-config.sh development 后
#     以 .deploy-render/pigsty.yml 为准（运行中集群无需，ALTER ROLE 已生效）
#   * Logto 管理员密码（E2E_PASSWORD）与 APISIX_ADMIN_KEY：前者须先在
#     Logto Console 修改再同步 .env；后者改 .env 后 restart apisix
#   * CI: GitHub Secrets 同名键（deploy workflows 用）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GW_ENV="$PROJECT_DIR/gateway/.env"

gw_env_val() {
    [ -f "$GW_ENV" ] || { echo "❌ 缺少 $GW_ENV" >&2; exit 1; }
    local v
    v=$(grep -m1 -E "^$1=" "$GW_ENV" | head -1 | cut -d= -f2- | tr -d '\r' || true)
    printf '%s' "$v"
}

# 密码合法性预检：SSH/DSN 内联注入限制——禁单引号与换行（与 render-config.sh 同款）
check_pw() {
    local name="$1" v="$2"
    [ -n "$v" ] || { echo "❌ gateway/.env 缺少 $name" >&2; exit 1; }
    case "$v" in
        *"'"*) echo "❌ $name 含单引号（DSN/内联注入限制），请更换" >&2; exit 1 ;;
        *$'\n'*) echo "❌ $name 含换行符" >&2; exit 1 ;;
    esac
}

DB_PW=$(gw_env_val DB_PASSWORD)
AUTH_PW=$(gw_env_val AUTHENTICATOR_PASSWORD)
LOGTO_PW=$(gw_env_val LOGTO_DB_PASSWORD)
check_pw DB_PASSWORD "$DB_PW"
check_pw AUTHENTICATOR_PASSWORD "$AUTH_PW"
check_pw LOGTO_DB_PASSWORD "$LOGTO_PW"

echo "[rotate] 1/3 ALTER ROLE（app_owner / authenticator / logto）"
sudo -n -u postgres psql -U postgres -d app_db -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE app_owner PASSWORD '$DB_PW'" \
    -c "ALTER ROLE authenticator PASSWORD '$AUTH_PW'" \
    -c "ALTER ROLE logto PASSWORD '$LOGTO_PW'"

echo "[rotate] 2/3 重生成 pgbouncer userlist（SCRAM verifier 与库端一致）"
sudo -n -u postgres psql -U postgres -At \
    -c "SELECT rolname FROM pg_authid WHERE rolname IN ('app_owner','authenticator','logto','dbuser_monitor') ORDER BY 1" \
    | paste -sd, > /tmp/rotate_roles.txt
ROLES=$(cat /tmp/rotate_roles.txt)
sudo -n -u postgres bash "$SCRIPT_DIR/pgbouncer-userlist-scram.sh" "$ROLES" \
    > /etc/pgbouncer/userlist.txt
sudo -n chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo -n chmod 640 /etc/pgbouncer/userlist.txt

echo "[rotate] 3/3 pgbouncer RELOAD"
PGPASSWORD="$DB_PW" psql -h 127.0.0.1 -p 6432 -U app_owner -d pgbouncer -c "RELOAD"

echo ""
echo "✅ 库端轮换完成（ALTER ROLE + userlist SCRAM + RELOAD）"
echo ""
echo "剩余手动步骤（按需执行）："
echo "  1. docker compose -f gateway/docker-compose.yml restart postgrest   # authenticator 变更"
echo "  2. docker compose -f gateway/docker-compose.yml restart logto      # LOGTO_DB_PASSWORD 变更（登录中断 ~30s）"
echo "  3. 另一项目（Windows 后端 app_owner 池）更新连接串并重启"
echo "  4. E2E_PASSWORD（Logto 管理员）：先 Logto Console 修改再同步 gateway/.env"
echo "  5. APISIX_ADMIN_KEY：改 gateway/.env 后 restart apisix"
echo "  6. GitHub Secrets 同步（deploy workflows：DB_PASSWORD / AUTHENTICATOR_PASSWORD / LOGTO_DB_PASSWORD）"
echo "  7. 验收：E2E_USER=<user> E2E_PASSWORD=<pw> bash scripts/e2e-test.sh"
