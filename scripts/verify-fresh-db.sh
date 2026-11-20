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

# 标识符白名单校验（2026-11-19 批次2d 修复 C-14）：DB_NAME 被内插进
# DROP DATABASE ... WITH (FORCE)、CREATE DATABASE 与连接 URI——
# 未校验时误传生产库名可摧毁数据库、构造串可注入 SQL/破坏 URI
DB_NAME=${1:-app_db_verify}
if [[ ! "$DB_NAME" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "❌ 非法库名: ${DB_NAME}（仅小写字母/数字/下划线，≤63 字符，字母或下划线开头）" >&2
    exit 1
fi
# 非默认 scratch 名需显式确认（denylist 无法枚举所有真实库名——2026-11-19 验收修补）
if [ "$DB_NAME" != "app_db_verify" ] && [ "${CONFIRM_DESTRUCTIVE:-}" != "1" ]; then
    echo "❌ 非默认 scratch 库名需 CONFIRM_DESTRUCTIVE=1 确认（将 DROP DATABASE \"${DB_NAME}\" WITH (FORCE)）" >&2
    exit 1
fi
REF_DB=${REF_DB:-app_db}
if [ "$DB_NAME" == "$REF_DB" ]; then
    echo "❌ 拒绝对参照库执行 DROP: ${DB_NAME}" >&2
    exit 1
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_PASSWORD=$(sed -n 's/^DB_PASSWORD=//p' "$REPO_DIR/gateway/.env" | tr -d '\r')
DB_PASSWORD_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASSWORD")
URI="postgres://app_owner:${DB_PASSWORD_ENC}@127.0.0.1:5432/${DB_NAME}?sslmode=disable"
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
-- 02-schemas 由 app_owner 执行（COMMENT ON SCHEMA ext 需要 owner），把 ext 所有权交给 app_owner
ALTER SCHEMA ext OWNER TO app_owner;
SQL

# [3] bootstrap 子集（02-schemas + src types）
echo ""
echo "[3/8] 02-schemas + src types（枚举前置）..."
PGPASSWORD="$DB_PASSWORD" psql "$URI" -q -v ON_ERROR_STOP=1 -f "$REPO_DIR/db/init/02-schemas.sql"
for f in "$REPO_DIR"/db/src/platform/types/*.sql; do
    PGPASSWORD="$DB_PASSWORD" psql "$URI" -q -v ON_ERROR_STOP=1 -f "$f"
done

# [3.5] 参照库 public 形状同步（2026-11-20 收尾批，verify-fresh 覆盖 068+ 的前置）
#   迁移链 068+ 的 FK 直挂 Logto public 基表（users/roles/organizations/tenants...）、
#   src 的 identity guards 冷库回退亦查询其表——scratch 库无 Logto 运行时，
#   以 pg_dump schema-only 从参照库同步精确形状（自动跟随参照库演进、零手工维护；
#   schema-only 零数据——FK 与回退 EXISTS 仅需形状）。
#   067/068 的 cron 调度段自带 undefined_table 容错（集群 cron.database_name
#   仅指向主库），scratch 上优雅跳过。
echo ""
echo "[3.5/8] 参照库 public 形状同步（Logto 基表骨架，pg_dump schema-only）..."
PG_DUMP_CMD=${PG_DUMP_CMD:-"sudo -n -u postgres pg_dump"}
# 全 schema dump（表+类型+约束——--table 限定会漏掉列上的自定义类型如
# public.role_type），剥事务包裹（逐句 autocommit）与 CREATE SCHEMA 行
# （scratch 自带 public）；执行不用 ON_ERROR_STOP——环境性失败（引用
# search 等未同步 schema 的函数/视图残留）跳过继续，基表形状是唯一目标；
# 末尾以关键表就位断言防"全部静默失败"的假绿
$PG_DUMP_CMD --schema-only --no-owner --no-privileges --schema=public "$REF_DB" \
    | grep -vE '^(BEGIN;|COMMIT;|CREATE SCHEMA public;)$' > /tmp/verify_public_schema.sql
sudo -n -u postgres psql -d "$DB_NAME" -q -f /tmp/verify_public_schema.sql > /dev/null 2>&1 || true
rm -f /tmp/verify_public_schema.sql
# Logto RLS 关闭（scratch 模拟库无 Logto 租户流量）：dump 会把 Logto 的租户
# 隔离 RLS 策略一并带入——apply-src 时刻投影视图 owner=app_owner（尾部
# init-logto-reader 才 ALTER 到 BYPASSRLS reader），经视图读基表会被
# Logto 策略过滤为 0 行（主库语义由 reader 的 BYPASSRLS 承担，scratch
# 上直接关闭以等价该语义）
sudo -n -u postgres psql -d "$DB_NAME" -q -c "DO \$\$ DECLARE t text; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
        EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', t);
    END LOOP;
END \$\$;"
sudo -n -u postgres psql -d "$DB_NAME" -At -c "SELECT to_regclass('public.users') IS NOT NULL AND to_regclass('public.organizations') IS NOT NULL" \
    | grep -q t || { echo "❌ [3.5] Logto 基表骨架未就位（public.users/organizations 缺失）" >&2; exit 1; }
# 068 前置（与 init-logto-fk-references.sh 同款）：app_owner 建 FK 所需
# REFERENCES 权限（仅约束创建所需，非 DML）
sudo -n -u postgres psql -d "$DB_NAME" -q -c \
    "GRANT REFERENCES ON public.users, public.organizations, public.roles, public.organization_roles, public.tenants TO app_owner;"
# SELECT 补授（对齐主库实态——演进库的 app_owner 历史授权含六表表级 SELECT，
# 见主库 information_schema.role_table_grants；apply-src 二遍重放会把投影
# 视图 owner 重置回 app_owner（init-logto-reader 的 ALTER 仅尾部跑），
# zz_role_bindings 等段内以 app_owner 身份经视图读基表时需要此授权）
sudo -n -u postgres psql -d "$DB_NAME" -q -c \
    "GRANT SELECT ON public.users, public.organizations, public.roles, public.organization_roles, public.tenants TO app_owner;"
# 查找表数据同步（迁移链 DML 的 FK/绑定目标行）：tenants（069 回填 tenant_id=
# 'default' 的 FK 目标）+ roles（zz_role_bindings 的超管/租户管理员绑定按
# name 解析角色 id）；--inserts 避免序列依赖
$PG_DUMP_CMD --data-only --no-owner --no-privileges --inserts \
    --table=public.tenants --table=public.roles "$REF_DB" \
    | grep -vE '^(BEGIN;|COMMIT;)$' > /tmp/verify_lookup_data.sql
sudo -n -u postgres psql -d "$DB_NAME" -q -f /tmp/verify_lookup_data.sql
rm -f /tmp/verify_lookup_data.sql
echo "  Logto 基表骨架就位（public.users/organizations 断言 + REFERENCES 授权 + tenants 查找数据通过）"

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

# [7] 结构比对（口径 2026-11-20 收尾批修订）
#   验证目标 = "从零重建的库结构正确"，而非"与演进库逐字节一致"：
#   - TABLE 列集按 column_name 排序串接（列序无关——主库历史演进的 ALTER ADD
#     顺序与干净链天然不同，ordinal_position 比对必假红）
#   - iam_menu 种子行不比（运行时累积表：主库 105 行含管理端运行时添加，
#     干净链 57 行属预期）
#   - TRIGGER/POLICY 为包含性验证（干净链 ⊆ 演进库）：scratch 的每个对象
#     必须存在于参照库；演进库多出的历史残渣不阻断（清理另行立项）
#   - CONSTRAINT/SEED(基线)/FUNC/VIEW/INDEX 严格一致
echo ""
echo "[7/8] 与参照库 ${REF_DB} 结构比对 ..."
cat > /tmp/verify_compare.sql <<'EOF'
\pset tuples_only on
\pset format unaligned
SELECT 'TABLE|' || table_name || '|' || string_agg(column_name || ':' || data_type || CASE WHEN udt_name<>data_type THEN ':'||udt_name ELSE '' END, ',' ORDER BY column_name)
FROM information_schema.columns
WHERE table_schema='platform' AND table_name <> 'schema_migrations'
GROUP BY table_name ORDER BY table_name;
SELECT 'CONSTRAINT|' || c.relname || '|' || con.conname || '|' || con.contype::text
FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
WHERE c.relnamespace='platform'::regnamespace AND c.relname <> 'schema_migrations'
ORDER BY c.relname, con.conname;
SELECT 'SEED|app_config|' || count(*) FROM app_config
UNION ALL SELECT 'SEED|dict_type|' || count(*) FROM dict_type
UNION ALL SELECT 'SEED|dict_data|' || count(*) FROM dict_data;
SELECT 'FUNC_COUNT|' || count(*) FROM pg_proc p
WHERE p.pronamespace IN ('platform'::regnamespace,'api_v1_platform'::regnamespace)
AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e');
SELECT 'VIEW_COUNT|' || count(*) FROM pg_views WHERE schemaname IN ('platform','api_v1_platform');
-- 40 号方案后 public 为 Logto 专属（外部对象），net/graphql 为扩展宿主：均不参与业务结构比对
SELECT 'TRG|' || n.nspname || '|' || c.relname || '|' || t.tgname
FROM pg_trigger t
JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE t.tgisinternal=false
AND n.nspname NOT IN ('cron','public','net','graphql')
ORDER BY 1;
SELECT 'POL|' || c.relnamespace::regnamespace::text || '|' || c.relname || '|' || p.polname
FROM pg_policy p
JOIN pg_class c ON c.oid=p.polrelid
WHERE c.relnamespace::regnamespace::text NOT IN ('cron','public','net','graphql')
ORDER BY 1;
SELECT 'INDEX_COUNT|' || count(*) FROM pg_indexes WHERE schemaname='platform' AND tablename <> 'schema_migrations';
EOF
# 批次2d前置修复：比对查询加 ON_ERROR_STOP（连接/权限/语法错误原被 2>&1 吞进比对文本，
# diff 会把"错误信息 vs 数据"误报为结构差异）；stderr 分离保留可见性
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U app_owner -d "$REF_DB" -w -v ON_ERROR_STOP=1 -f /tmp/verify_compare.sql > /tmp/verify_ref.txt 2>/tmp/verify_ref.err || {
    echo "❌ 参照库比对查询失败:"; cat /tmp/verify_ref.err; exit 1; }
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U app_owner -d "$DB_NAME" -w -v ON_ERROR_STOP=1 -f /tmp/verify_compare.sql > /tmp/verify_new.txt 2>/tmp/verify_new.err || {
    echo "❌ scratch 库比对查询失败:"; cat /tmp/verify_new.err; exit 1; }

# 口径修订（2026-11-20 收尾批）：TRG|/POL| 行做包含性验证（干净链 ⊆ 演进库），
# 其余行（TABLE 列集/CONSTRAINT/SEED/FUNC/VIEW/INDEX）严格一致
grep -E '^(TRG\||POL\|)' /tmp/verify_ref.txt | sort > /tmp/verify_ref_obj.txt
grep -E '^(TRG\||POL\|)' /tmp/verify_new.txt | sort > /tmp/verify_new_obj.txt
grep -vE '^(TRG\||POL\|)' /tmp/verify_ref.txt > /tmp/verify_ref_strict.txt
grep -vE '^(TRG\||POL\|)' /tmp/verify_new.txt > /tmp/verify_new_strict.txt

STRICT_OK=true
if ! diff -u /tmp/verify_ref_strict.txt /tmp/verify_new_strict.txt; then
    echo "结构比对（严格段: 表列集/约束/种子/函数/视图/索引）: ❌ 存在差异" >&2
    STRICT_OK=false
fi
ONLY_IN_SCRATCH=$(comm -23 /tmp/verify_new_obj.txt /tmp/verify_ref_obj.txt)
if [ -n "$ONLY_IN_SCRATCH" ]; then
    echo "结构比对（包含性: 触发器/策略）: ❌ scratch 存在参照库没有的对象：" >&2
    echo "$ONLY_IN_SCRATCH" >&2
    STRICT_OK=false
fi
if $STRICT_OK; then
    echo "结构比对: ✅ 通过（严格段一致 + 触发器/策略 干净链⊆演进库；主库多出的历史残渣属演进预期，清理另行立项）"
else
    exit 1
fi

# [8] pgTAP
echo ""
echo "[8/8] pgTAP 测试 ..."
if command -v pg_prove >/dev/null 2>&1; then
    TAP_OUT=$(PGPASSWORD="$DB_PASSWORD" pg_prove -h 127.0.0.1 -U app_owner -d "$DB_NAME" --ext .sql -r "$REPO_DIR/db/tests/" 2>&1) || true
    echo "$TAP_OUT" | tail -8
    # casbin「预期失败 3 例」特判已移除（2026-11-20，四节 2 跟进）：075 菜单父级
    #   回填后 test_casbin_view 在全新库全过（不再依赖运行时绑定数据）；
    #   另 06_stage2_semantics_test 已补入（阶段 2 新语义 19 例）——任何失败均为错误。
    if echo "$TAP_OUT" | grep -q "Result: PASS"; then
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
