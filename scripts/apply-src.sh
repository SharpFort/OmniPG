#!/bin/bash
set -e

# =============================================================================
# apply-src.sh — 幂等源码全量重放（17 号文档 §3.1 部署链）
# 用法: ./scripts/apply-src.sh <database_url> [--bootstrap]
#   --bootstrap : 仅执行 bootstrap 子集（init + src/*/types），供 deploy-db.sh
#                 冷启动前置——扩展/枚举必须先于迁移存在（§3.4 依赖倒置陷阱：
#                 059/060 迁移引用 platform.scope_type/iam_gender 等 src 枚举）
# 全量顺序（2026-11-19 批次2d 修订）: §6.3 迁移代码对象扫描（P0-5 零容忍）
#   → init（schema bootstrap，前置——冷库单遍即过）→ src → api_v1
#   （migrations 不再重放：psql 会连 "-- migrate:down" 段一起执行，
#     迁移权威通道 = dbmate / scripts/migrate.sh）
# 模块声明（2026-08-16: net 模块退役——net.request_status 零引用删除；pg_net
#   schema 属扩展所有，项目对象不入驻）:
#   platform（基础/系统层，无前缀函数落 platform schema）
#   依赖方向: 后置模块可依赖前置模块，反之不可；新增模块须在此声明位置
#   api_v1 层前缀 _shared（跨模块共享 API）置首
#   （2026-08-15: inventory/sales 测试模块全链路退役移除，后续按需重建）
# =============================================================================

DB_URL="$1"
if [ -z "$DB_URL" ]; then
    echo "Usage: $0 <database_url> [--bootstrap]"
    exit 1
fi

DB_DIR="$(cd "$(dirname "$0")/../db" && pwd)"

MODULES="platform"
API_MODULES="_shared platform"

BOOTSTRAP_ONLY=false
if [ "$2" = "--bootstrap" ]; then
    BOOTSTRAP_ONLY=true
fi

# ---------------------------------------------------------------------------
# bootstrap 子集：init（扩展/schema/角色）+ src/*/types（枚举）
# ---------------------------------------------------------------------------
if $BOOTSTRAP_ONLY; then
    echo "[bootstrap] 仅执行 bootstrap 子集（init + src types）..."
    FILES="$(find "$DB_DIR/init" -name '*.sql' 2>/dev/null | sort) \
$(for m in $MODULES; do find "$DB_DIR/src/$m/types" -name '*.sql' 2>/dev/null | sort; done)"
    if [ -z "$FILES" ]; then
        echo "ERROR: bootstrap 文件集为空（init/ 或 src/*/types/ 缺失）"
        exit 1
    fi
    for f in $FILES; do
        echo "Applying: $f"
        psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
    done
    echo "Bootstrap applied successfully."
    exit 0
fi

# ---------------------------------------------------------------------------
# §6.3 迁移目录代码对象扫描（P0-5：归位已完成、白名单清零 → 新迁移零容忍）
#   命中即失败：代码型对象（函数/视图/触发器/类型/策略）一律归位 db/src/ 或 db/api_v1/
# ---------------------------------------------------------------------------
echo "[scan] 扫描迁移目录代码对象（§6.3/P0-5 零容忍）..."
MIG_DIRS=""
for m in $MODULES; do
    if [ -d "$DB_DIR/migrations/$m" ]; then
        MIG_DIRS="$MIG_DIRS $DB_DIR/migrations/$m"
    fi
done
if [ -n "$MIG_DIRS" ]; then
    HITS=$(grep -rEn --include="*.sql" \
        -E 'CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?(FUNCTION|VIEW|MATERIALIZED[[:space:]]+VIEW|TRIGGER|TYPE|DOMAIN|POLICY|RULE)|COMMENT[[:space:]]+ON[[:space:]]+(FUNCTION|VIEW|TRIGGER|TYPE|DOMAIN)' \
        $MIG_DIRS | grep -vE ':[0-9]+:[[:space:]]*--' || true)
    if [ -n "$HITS" ]; then
        echo "ERROR: 迁移目录发现代码对象定义（§6.3 扫描失败）——代码型对象一律归位 db/src/ 或 db/api_v1/（17 号文档铁律）："
        echo "$HITS"
        exit 1
    fi
fi
echo "[scan] 迁移目录代码对象扫描通过（零残留）"

# ---------------------------------------------------------------------------
# 全量幂等重放（init → src types → src 其余 → api_v1 → migrations）
#   init 前置（2026-11-19 批次2d 修复）：02-schemas.sql 创建 platform/api_v1_platform/ext
#   schema，原先排在全部 src/api_v1 之后——冷库首遍必失败，依赖"三遍收敛"兜底
#   才能通过（浪费一整遍且掩盖真实错误）；schema 先行后冷库单遍即过
#   types 前置：枚举必须先于函数/视图存在（无 bootstrap 直接全量也安全）
#   api_v1 分类排序（rpc → views → 其余）：privileges/zz_grant_all.sql 引用视图，
#     按字母序 privileges < views 会先执行而炸（2026-08-14 实测）——显式排后
# ---------------------------------------------------------------------------
# 多遍收敛重放（2026-08-16 拍板）：LANGUAGE sql 函数体在 CREATE 时即解析绑定，
#   单遍 find|sort 无法保证依赖顺序；失败文件重试至多 3 遍（幂等文件重放安全），
#   三遍仍失败 = 真错误（依赖缺失/语法错），终止并列出。
# 2026-11-19 批次2d 修复：重试收敛仅适用于 src/api_v1 幂等源码；init 与 migrations
#   单遍失败即终止——迁移文件可能非整文件幂等（部分应用后盲目重放有风险，dbmate
#   才是迁移的权威执行通道，apply-src 的迁移段仅作结构比对前的一致性重放）
apply_files_converge() {
    local pending="$1"
    local pass retry f
    for pass in 1 2 3; do
        [ -z "$pending" ] && break
        retry=""
        for f in $pending; do
            echo "Applying: "$f""
            if ! psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"; then
                echo "WARN: $f 第 $pass 遍失败，进入重试队列"
                retry="$retry $f"
            fi
        done
        pending="$retry"
    done
    if [ -n "$pending" ]; then
        echo "ERROR: 连续 3 遍仍失败的文件：$pending"
        return 1
    fi
}

apply_files_single_pass() {
    local f
    for f in $1; do
        echo "Applying: "$f""
        psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f" || { echo "ERROR: $f 失败（init/migrations 不重试）"; return 1; }
    done
}

INIT_FILES="$(find "$DB_DIR/init" -name "*.sql" 2>/dev/null | sort)"
if [ -z "$INIT_FILES" ]; then
    echo "ERROR: db/init 下未发现 SQL 文件（schema bootstrap 缺失）" >&2
    exit 1
fi
apply_files_single_pass "$INIT_FILES" || exit 1

FILES="$(for m in $MODULES; do find "$DB_DIR/src/$m/types" -name "*.sql" 2>/dev/null | sort; done) \
$(for m in $MODULES; do find "$DB_DIR/src/$m" -name "*.sql" -not -path "*/types/*" 2>/dev/null | sort; done) \
$(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m/rpc" -name "*.sql" 2>/dev/null | sort; done) \
$(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m/views" -name "*.sql" 2>/dev/null | sort; done) \
$(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m" -name "*.sql" -not -path "*/rpc/*" -not -path "*/views/*" 2>/dev/null | sort; done)"
if [ -z "$FILES" ]; then
    echo "ERROR: src/api_v1 下未发现 SQL 文件" >&2
    exit 1
fi

apply_files_converge "$FILES" || exit 1

# ---------------------------------------------------------------------------
# 迁移重放段（2026-11-19 批次2d 验收修复：整体移除）
#   psql -f 会执行迁移文件的全部内容——"-- migrate:down" 对 psql 仅为注释，
#   原来的"幂等重放"每跑一遍就把 up 段建的对象再按 down 段删一遍（074 的索引
#   由此在每次 apply-src 后消失）。迁移的唯一权威执行通道是 dbmate
#   （scripts/migrate.sh up，含事务边界与执行记录）；apply-src 不再触碰
#   migrations/（§6.3 的零容忍扫描仍然保留，只读不执行）。
#   verify-fresh-db.sh 的冷启动流程亦不受影响：[4] dbmate up 负责迁移。
# ---------------------------------------------------------------------------

echo "All SQL files applied successfully."

# ---------------------------------------------------------------------------
# 重放后必须恢复 Logto 只读投影视图 owner（BYPASSRLS），否则 Logto RLS 会把
# platform.users/role 等过滤为 0 行 → get_current_user 'User not found'（前端 500）。
# 设置了 PG_SUPER_CMD 时自动重跑；否则打印醒目警告（deploy-db.sh 3.5 会兜底重跑）。
# ---------------------------------------------------------------------------
if [ -n "${PG_SUPER_CMD:-}" ]; then
    echo "[apply-src] PG_SUPER_CMD 已设置，自动重跑 init-logto-reader 恢复投影视图 owner..."
    DB_NAME="${DB_NAME:-app_db}" DB_PORT="${DB_PORT:-5432}" bash "$(dirname "$0")/init-logto-reader.sh"
else
    echo ""
    echo "⚠️  [apply-src] 全量重放已重建 platform.* 只读投影视图（owner 变回当前执行角色，"
    echo "    BYPASSRLS 丢失）。若该库使用 Logto RLS 同库直读，请立即重跑："
    echo "      PG_SUPER_CMD='sudo -u postgres psql' ./scripts/init-logto-reader.sh"
    echo "    否则 get_current_user/ensure_user 会报 'User not found'，前端登录后跳 500。"
    echo ""
fi
