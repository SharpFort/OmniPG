#!/bin/bash
# =============================================================================
# 数据库部署脚本（17 号文档 §3.1 部署链：bootstrap → dbmate up → apply-src 全量）
# 用法: ./scripts/deploy-db.sh <environment> [db_port]
# 示例: ./scripts/deploy-db.sh development          # 宿主 Pigsty PG (5432，默认)
#       ./scripts/deploy-db.sh development 5433     # 备用：指向其他 PG 实例
# 说明: 数据库连接凭据来自 .env.<environment>（DB_USER/DB_PASSWORD），
#       不再在脚本内硬编码密码。
# 流程:
#   [1/4] bootstrap   —— init（扩展/schema/角色）+ src types（枚举）前置
#                        （§3.4 依赖倒置：059/060 迁移引用 src 枚举，必须先建）
#   [2/4] dbmate up   —— 迁移（仅表结构+数据；代码对象归位 src/api_v1）
#   [3/4] apply-src   —— 全量幂等重放（含 §6.3 迁移扫描零容忍 + 迁移幂等重放）
#   [4/4] 验证        —— dbmate status
# 结果一致性: apply-src 全量重放迁移两遍不炸（ddl 均 IF NOT EXISTS/DO 块守卫），
#             再次部署（bootstrap 幂等 + dbmate 跳过已应用 + apply-src 重放）结果一致
# =============================================================================

set -euo pipefail

ENV=${1:-development}
DB_PORT=${2:-${DB_PORT:-5432}}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  数据库部署"
echo "  环境: $ENV    端口: $DB_PORT"
echo "============================================"

# 渲染并加载环境变量（.env / pigsty.yml / userlist.txt 三处一致；CI Secrets 注入）
RENDER_DIR="$PROJECT_DIR/.deploy-render"
bash "$SCRIPT_DIR/render-config.sh" "$ENV" "$RENDER_DIR"
set -a
# shellcheck disable=SC1090
. "$RENDER_DIR/.env"
set +a

DB_USER=${DB_USER:-app_owner}
DB_PASSWORD=${DB_PASSWORD:-admin@password}
DB_NAME=${DB_NAME:-app_db}
DB_HOST=${DB_HOST:-localhost}

# 设置数据库连接（全部来自环境变量，无硬编码密码；@ 等特殊字符须 URL 编码）
DB_PASSWORD_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASSWORD")
DB_URI=${DB_URI:-"postgres://${DB_USER}:${DB_PASSWORD_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"}
DATABASE_URL=${DATABASE_URL:-"$DB_URI"}

cd "$PROJECT_DIR"

# 1. bootstrap（init + src types——扩展/枚举前置，冷启动依赖倒置修复）
echo ""
echo "[1/4] bootstrap（init + src types）..."
bash "$SCRIPT_DIR/apply-src.sh" "$DB_URI" --bootstrap

# 1.5. 业务侧 FK 指向 Logto 基表所需的 REFERENCES 授权（superuser；必须早于 dbmate，D26）
#      幂等：GRANT REPEATABLE；失败仅警告，由 init-logto-reader.sh（3.5）兜底重试
echo ""
echo "[1.5/4] 初始化 Logto FK REFERENCES 授权..."
bash "$SCRIPT_DIR/init-logto-fk-references.sh" || {
  echo "WARN: init-logto-fk-references 失败（可通过 PG_SUPER_CMD 指定超级用户命令重试）；dbmate 068 可能因权限拒绝"
}

# 2. 应用 dbmate 迁移
#   注: 40 号方案合并后 app_db.public 归 Logto（app_owner 无权限），dbmate 自动 dump 全库会
#       因 public.tenants 等权限拒绝而失败，故 --no-dump-schema；db/schema.sql 由业务侧独立快照维护
echo ""
echo "[2/4] 应用数据库迁移（--no-dump-schema）..."
export DATABASE_URL="$DATABASE_URL"
dbmate --no-dump-schema -d db/migrations/platform up

# 3. 刷入幂等源码（含迁移代码对象扫描 + 迁移幂等重放）
echo ""
echo "[3/4] 刷入幂等源码..."
bash "$SCRIPT_DIR/apply-src.sh" "$DB_URI"

# 3.5 创建 Logto 同库只读角色并将投影视图 owner 设为 reader（D25）：
#     BYPASSRLS 需超级用户；必须在 apply-src 之后执行（视图已创建）。
echo ""
echo "[3.5/4] 初始化 Logto 只读角色..."
bash "$SCRIPT_DIR/init-logto-reader.sh" || {
  echo "WARN: init-logto-reader 失败（可通过 PG_SUPER_CMD 指定超级用户命令重试）；视图 owner 可能需要手工修正"
}

# 4. 验证
echo ""
echo "[4/4] 验证部署..."
dbmate -d db/migrations/platform status

echo ""
echo "============================================"
echo "  数据库部署完成!"
echo "============================================"
