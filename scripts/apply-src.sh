#!/bin/bash
set -e

# =============================================================================
# apply-src.sh — 幂等源码全量重放（17 号文档 §3.1 部署链）
# 用法: ./scripts/apply-src.sh <database_url> [--bootstrap]
#   --bootstrap : 仅执行 bootstrap 子集（init + src/*/types），供 deploy-db.sh
#                 冷启动前置——扩展/枚举必须先于迁移存在（§3.4 依赖倒置陷阱：
#                 059/060 迁移引用 public.scope_type/iam_gender 等 src 枚举）
# 全量顺序: §6.3 迁移代码对象扫描（P0-5 零容忍）→ src → api_v1 → init → migrations
# 模块顺序显式声明（2026-08-11，sys→public 重命名）:
#   public（基础/系统层，无前缀函数落 public schema）→ net
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

MODULES="public net"
API_MODULES="_shared public"

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
# 全量幂等重放（src types → src 其余 → api_v1 → init → migrations）
#   types 前置：枚举必须先于函数/视图存在（无 bootstrap 直接全量也安全）
#   api_v1 分类排序（rpc → views → 其余）：privileges/zz_grant_all.sql 引用视图，
#     按字母序 privileges < views 会先执行而炸（2026-08-14 实测）——显式排后
#   migrations 重放 = 幂等性验证（ddl 均 IF NOT EXISTS / DO 块守卫，两遍不炸）
# ---------------------------------------------------------------------------
for f in \
    $(for m in $MODULES; do find "$DB_DIR/src/$m/types" -name "*.sql" 2>/dev/null | sort; done) \
    $(for m in $MODULES; do find "$DB_DIR/src/$m" -name "*.sql" -not -path "*/types/*" 2>/dev/null | sort; done) \
    $(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m/rpc" -name "*.sql" 2>/dev/null | sort; done) \
    $(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m/views" -name "*.sql" 2>/dev/null | sort; done) \
    $(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m" -name "*.sql" -not -path "*/rpc/*" -not -path "*/views/*" 2>/dev/null | sort; done) \
    $(find "$DB_DIR/init" -name "*.sql" 2>/dev/null | sort) \
    $(for m in $MODULES; do find "$DB_DIR/migrations/$m" -name "*.sql" 2>/dev/null | sort; done); do
    echo "Applying: "$f""
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "All SQL files applied successfully."
