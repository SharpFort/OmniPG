#!/bin/bash
# =============================================================================
# 数据库迁移快捷入口
# 用法: ./scripts/migrate.sh <command> <environment>
# 示例: ./scripts/migrate.sh up development
# 2026-11-19 批次2d 修复（含验收修补）：
#   * 硬编码凭据 DSN 移除：连接串按契约解析（优先级 DATABASE_URL > DB_URI >
#     DB_USER/DB_PASSWORD/DB_HOST/DB_PORT/DB_NAME），缺失 fail-fast
#   * 环境加载：不再通用 source/逐行 export（.env 内含行内注释与 ${VAR} 占位符，
#     通用解析必错）——改为按键名定向提取（本脚本仅需要 DB_* 与 DATABASE_URL）
#   * up/rollback 追加 --no-dump-schema（dbmate 默认迁移后 dump db/schema.sql，
#     deploy-db.sh:64-70 已注明该 dump 在本仓库会失败/写坏基线文件）
#   * create 子命令不触库，不再要求凭据
#   * 密码经环境变量传给 python（不进 argv/ps 可见面）
# =============================================================================
set -euo pipefail

COMMAND=${1:-status}
ENV=${2:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env.$ENV"

# 按键名定向提取（不做行内注释剥离——密码含 # 是合法值；兼容 CRLF）
env_val() {
    [ -f "$ENV_FILE" ] || return 0
    local v
    v=$(grep -m1 -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)
    printf '%s' "$v"
}

# 唯一凭据文件回退（2026-11-20 参数化批）：DB_PASSWORD 等凭据键的权威源
# 为 gateway/.env（轮换只改该文件）；.env.$ENV 的同名键降级为惰性备份
gw_env_val() {
    local f="$PROJECT_DIR/gateway/.env"
    [ -f "$f" ] || return 0
    local v
    v=$(grep -m1 -E "^$1=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)
    printf '%s' "$v"
}

# 本地写文件类命令无需凭据（验收修补）
if [ "$COMMAND" = "create" ]; then
    if [ -z "${3:-}" ]; then
        echo "用法: $0 create <migration_name>"
        exit 1
    fi
    echo "创建迁移: $3"
    cd "$PROJECT_DIR/db"
    dbmate new "$3"
    exit 0
fi

# 连接串契约（优先级：DATABASE_URL > DB_URI > 分项）
DATABASE_URL="${DATABASE_URL:-$(env_val DATABASE_URL)}"
if [ -z "$DATABASE_URL" ]; then
    DB_URI="$(env_val DB_URI)"
    DB_PASSWORD="${DB_PASSWORD:-$(gw_env_val DB_PASSWORD)}"
    DB_PASSWORD="${DB_PASSWORD:-$(env_val DB_PASSWORD)}"
    if [ -n "$DB_URI" ]; then
        DATABASE_URL="$DB_URI"
    elif [ -n "$DB_PASSWORD" ]; then
        DB_USER="${DB_USER:-$(env_val DB_USER)}"; DB_USER="${DB_USER:-app_owner}"
        DB_HOST="${DB_HOST:-$(env_val DB_HOST)}"; DB_HOST="${DB_HOST:-127.0.0.1}"
        DB_PORT="${DB_PORT:-$(env_val DB_PORT)}"; DB_PORT="${DB_PORT:-5432}"
        DB_NAME="${DB_NAME:-$(env_val DB_NAME)}"; DB_NAME="${DB_NAME:-app_db}"
        # 密码经环境变量传给 python（不进 argv——ps/审计日志不可见）
        DB_PASSWORD_ENC=$(env DB_PASSWORD="$DB_PASSWORD" python3 -c \
            'import os,urllib.parse; print(urllib.parse.quote(os.environ["DB_PASSWORD"], safe=""))')
        DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
    else
        echo "❌ 缺少数据库凭据：请提供 DATABASE_URL / DB_URI / DB_PASSWORD（.env.$ENV 或环境变量，契约见 wiki/03-部署指南/环境配置.md）" >&2
        exit 2
    fi
fi

cd "$PROJECT_DIR/db"
# 显式 --url（验收修补）：dbmate 环境变量优先级 DBMATE_DATABASE_URL > DATABASE_URL，
# 环境里残留的 DBMATE_DATABASE_URL 会静默覆盖——显式旗标最稳
MIGRATE_ARGS=(-d migrations/platform --url "$DATABASE_URL")

case "$COMMAND" in
    up)
        echo "应用数据库迁移..."
        dbmate "${MIGRATE_ARGS[@]}" --no-dump-schema up
        ;;
    down|rollback)
        echo "回滚最近一次迁移..."
        dbmate "${MIGRATE_ARGS[@]}" --no-dump-schema rollback
        ;;
    status)
        echo "迁移状态:"
        dbmate "${MIGRATE_ARGS[@]}" status
        ;;
    *)
        echo "用法: $0 {up|down|status|create} <environment>"
        exit 1
        ;;
esac
