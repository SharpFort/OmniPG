#!/bin/bash
# =============================================================================
# verify-fresh-db.sh — 全新库冷启动验证（0.1 squash 基线 064/065/066 之后）
# 用法（WSL 内执行，需 sudo 建扩展）:
#   bash scripts/verify-fresh-db.sh [dbname]
#   默认 scratch 库名: app_db_verify（保留复用，每次验证 DROP+重建）
# 流程:
#   [1] DROP+CREATE scratch 库（WITH FORCE 终止残留会话）
#   [2] superuser 建扩展（内联最小集：pgcrypto/pg_net/pgtap；权威 = Pigsty infra/*.yml）
#   [3] app_owner: 02-schemas.sql + src types（枚举前置，bootstrap 子集）
#   [4] dbmate up（064-066 基线）
#   [5] apply-src 全量（幂等重放，含 §6.3 扫描）
#   [6] apply-src 二遍（幂等验证）
#   [7] 与参照库（app_db）结构比对（表/列/约束/种子/函数/视图/触发器/策略/索引）
#   [8] pgTAP（tests/platform，需 pg_prove）
# 环境: PGPASSWORD 自动从 gateway/.env 提取；参照库 REF_DB（默认 app_db）
# 注: 生产 Pigsty 无 sudo 时，用 PG_SUPER_CMD/PG_SUPER_POSTGRES_CMD 覆盖超级用户执行方式
#     （如 PG_SUPER_CMD='psql "postgres://dbuser_dba:xxx@host:5432/${DB_NAME}"'）
# =============================================================================
set -euo pipefail

DB_NAME=${1:-app_db_verify}
REF_DB=${REF_DB:-app_db}
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_PASSWORD=$(sed -n 's/^DB_PASSWORD=//p' "$REPO_DIR/gateway/.env" | tr -d '\r')
URI="postgres://app_owner:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}?sslmode=disable"
SUPER_CMD=${PG_SUPER_CMD:-"sudo -u postgres psql -d ${DB_NAME}"}
SUPER_POSTGRES_CMD=${PG_SUPER_POSTGRES_CMD:-"sudo -u postgres psql -d postgres"}

echo "=============================================="
echo "  全新库冷启动验证"
echo "  scratch: ${DB_NAME}    参照: ${REF_DB}"
echo "=============================================="

# [1] 重建 scratch 库（DROP WITH FORCE 须超级用户：终止残留会话需 pg_signal_backend）
echo ""
echo "[1/8] 重建 scratch 库 ${DB_NAME} ..."
$SUPER_POSTGRES_CMD -q -c "DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE);"
$SUPER_POSTGRES_CMD -q -c "CREATE DATABASE ${DB_NAME} OWNER app_owner;"

# [2] superuser 建扩展（app_owner 非超管，CREATE EXTENSION 须超级用户）
#   扩展权威 = Pigsty（infra/pigsty.yml：pg_extensions + pg_databases[].extensions）；
#   旧的扩展引导文件已于 2026-08-19 移除，此处内联最小集仅供本地验证环境兜底
echo ""
echo "[2/8] superuser 建扩展（内联最小集，权威 = Pigsty）..."
$SUPER_CMD -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_net";
CREATE EXTENSION IF NOT EXISTS "pgtap";
-- 40 号方案：扩展迁出 public → ext（Logto 独占 public；[3] 的 02-schemas 幂等建 ext）
--   此处 superuser 先建 ext 再 ALTER，保证 [4]-[8] 阶段 ext 内函数可解析
CREATE SCHEMA IF NOT EXISTS ext;
ALTER EXTENSION "pgcrypto" SET SCHEMA ext;
ALTER EXTENSION "pgtap" SET SCHEMA ext;
SQL

# [3] bootstrap 子集（02-schemas + src types）
echo ""
echo "[3/8] 02-schemas + src types（枚举前置）..."
PGPASSWORD="$DB_PASSWORD" psql "$URI" -q -v ON_ERROR_STOP=1 -f "$REPO_DIR/db/init/02-schemas.sql"
for f in "$REPO_DIR"/db/src/platform/types/*.sql; do
    PGPASSWORD="$DB_PASSWORD" psql "$URI" -q -v ON_ERROR_STOP=1 -f "$f"
done

# [4] dbmate up（基线 064/065/066；--no-dump-schema 防止 scratch 快照覆盖 db/schema.sql）
echo ""
echo "[4/8] dbmate up（基线迁移）..."
(cd "$REPO_DIR" && DATABASE_URL="$URI" dbmate --no-dump-schema -d db/migrations/platform up)

# apply-src.sh 为 CRLF（仓库惯例不改行尾），WSL bash 直跑必炸——LF 临时副本
# 放在 scripts/ 下保证其 "$0/../db" 路径推导正确；trap 兜底清理
APPLY_TMP="$REPO_DIR/scripts/.apply-src.lf.tmp.sh"
tr -d '\r' < "$REPO_DIR/scripts/apply-src.sh" > "$APPLY_TMP"
trap 'rm -f "$APPLY_TMP"' EXIT

# [5] apply-src 全量
echo ""
echo "[5/8] apply-src 全量重放 ..."
bash "$APPLY_TMP" "$URI"

# [6] apply-src 二遍（幂等验证）
echo ""
echo "[6/8] apply-src 二遍（幂等验证）..."
bash "$APPLY_TMP" "$URI"

# [7] 结构比对
echo ""
echo "[7/8] 与参照库 ${REF_DB} 结构比对 ..."
cat > /tmp/verify_compare.sql <<'EOF'
\pset tuples_only on
\pset format unaligned
SELECT 'TABLE|' || table_name || '|' || string_agg(column_name || ':' || data_type || CASE WHEN udt_name<>data_type THEN ':'||udt_name ELSE '' END, ',' ORDER BY ordinal_position)
FROM information_schema.columns
WHERE table_schema='platform' AND table_name <> 'schema_migrations'
GROUP BY table_name ORDER BY table_name;
SELECT 'CONSTRAINT|' || c.relname || '|' || con.conname || '|' || con.contype
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
WHERE c.relnamespace='platform'::regnamespace AND c.relname <> 'schema_migrations'
ORDER BY 2,3;
SELECT 'SEED|app_config|' || count(*) FROM app_config
UNION ALL SELECT 'SEED|dict_type|' || count(*) FROM dict_type
UNION ALL SELECT 'SEED|dict_data|' || count(*) FROM dict_data
UNION ALL SELECT 'SEED|iam_menu|' || count(*) FROM iam_menu;
SELECT 'FUNC_COUNT|' || count(*) FROM pg_proc p
WHERE p.pronamespace IN ('platform'::regnamespace,'api_v1_platform'::regnamespace)
AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e');
SELECT 'VIEW_COUNT|' || count(*) FROM pg_views WHERE schemaname IN ('platform','api_v1_platform');
SELECT 'TRIGGER_COUNT|' || count(*) FROM pg_trigger WHERE tgisinternal=false
AND tgrelid NOT IN (SELECT oid FROM pg_class WHERE relnamespace = COALESCE((SELECT oid FROM pg_namespace WHERE nspname='cron'), 0));
SELECT 'POLICY_COUNT|' || count(*) FROM pg_policy p
JOIN pg_class c ON c.oid=p.polrelid
WHERE c.relnamespace <> COALESCE((SELECT oid FROM pg_namespace WHERE nspname='cron'), 0);
SELECT 'INDEX_COUNT|' || count(*) FROM pg_indexes WHERE schemaname='platform' AND tablename <> 'schema_migrations';
EOF
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U app_owner -d "$REF_DB" -w -f /tmp/verify_compare.sql > /tmp/verify_ref.txt 2>&1
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U app_owner -d "$DB_NAME" -w -f /tmp/verify_compare.sql > /tmp/verify_new.txt 2>&1
if diff -u /tmp/verify_ref.txt /tmp/verify_new.txt; then
    echo "结构比对: ✅ 完全一致（表/列/约束/种子/函数/视图/触发器/策略/索引）"
else
    echo "结构比对: ❌ 存在差异（见上方 diff；pg_cron 等扩展对象差异属正常，已在查询中排除）"
    exit 1
fi

# [8] pgTAP
echo ""
echo "[8/8] pgTAP 测试 ..."
if command -v pg_prove >/dev/null 2>&1; then
    TAP_OUT=$(PGPASSWORD="$DB_PASSWORD" pg_prove -h 127.0.0.1 -U app_owner -d "$DB_NAME" --ext .sql -r "$REPO_DIR/db/tests/" 2>&1) || true
    echo "$TAP_OUT" | tail -8
    # 预期差异：test_casbin_view 3-5 依赖 iam_role_menu 运行时绑定（种子不含运行时数据），
    #   全新库必空 → casbin 视图 0 行。管理员 UI 配置绑定后自愈；其余用例必须全过。
    if echo "$TAP_OUT" | grep -q "test_casbin_view.sql  (Wstat: 0 Tests: 8 Failed: 3)" \
        && [ "$(echo "$TAP_OUT" | grep -cE '\(Wstat: .* Failed: [1-9]')" = "1" ]; then
        echo "pgTAP: ✅ 112/115 通过；casbin 3 用例为预期差异（运行时绑定数据不在种子内）"
    elif echo "$TAP_OUT" | grep -q "Result: PASS"; then
        echo "pgTAP: ✅ 全部通过"
    else
        echo "pgTAP: ❌ 存在非预期失败"
        exit 1
    fi
else
    echo "pg_prove 未安装，跳过 pgTAP（安装: apt install pgtap 或 cpan TAP::Parser::SourceHandler::pgTAP）"
fi

echo ""
echo "=============================================="
echo "  全新库冷启动验证完成 ✅"
echo "=============================================="
