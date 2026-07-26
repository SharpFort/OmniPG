#!/bin/bash
set -e

cd /root/OmniPG/db

echo "========================================"
echo " Phase 4: 数据库迁移 (dbmate) + 源码部署"
echo "========================================"
echo ""

# Step 1: 创建缺失的角色
echo "[1/6] 创建缺失的角色..."
su - postgres -c "psql -c 'CREATE ROLE IF NOT EXISTS authenticated;'" 2>/dev/null || true
su - postgres -c "psql -c 'CREATE ROLE IF NOT EXISTS anonymous;'" 2>/dev/null || true
echo "  ✅ 角色创建完成"

echo ""
echo "[2/6] 安装 dbmate..."
if ! command -v dbmate &>/dev/null; then
  rm -f /usr/local/bin/dbmate
  export http_proxy=http://127.0.0.1:10808
  export https_proxy=http://127.0.0.1:10808
  curl -fsSL --max-time 60 https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 -o /usr/local/bin/dbmate
  chmod +x /usr/local/bin/dbmate
fi
dbmate --version

echo ""
echo "[3/6] 执行数据库迁移 (dbmate)..."
DBMATE_URL="postgres://app_owner:dev_password_change_me@127.0.0.1:5432/app_db?sslmode=disable"
echo "  当前状态:"
dbmate --url "$DBMATE_URL" status
echo ""
echo "  执行迁移:"
dbmate --url "$DBMATE_URL" up
echo ""
echo "  迁移后状态:"
dbmate --url "$DBMATE_URL" status

echo ""
echo "[4/6] 刷入 Schema 初始化脚本..."
cd /root/OmniPG
echo "  sys/_init_schema.sql"
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f db/src/sys/_init_schema.sql 2>&1 | tail -3
echo "  sales/_init_schema.sql"
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f db/src/sales/_init_schema.sql 2>&1 | tail -3
echo "  inventory/_init_schema.sql"
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f db/src/inventory/_init_schema.sql 2>&1 | tail -3

echo ""
echo "[5/6] 刷入所有幂等源码..."
for f in $(find db/src -name '*.sql' -not -name '_*' | sort); do
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f" 2>&1 | tail -1
done

echo ""
echo "[6/6] 验证..."
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT schemaname, count(*) as tables FROM pg_tables WHERE schemaname NOT LIKE 'pg_%' AND schemaname NOT LIKE 'information_schema' GROUP BY schemaname ORDER BY schemaname;"

PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT n.nspname, count(*) as functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname LIKE 'api_v1%' GROUP BY n.nspname ORDER BY n.nspname;"

echo ""
echo "========================================"
echo " 数据库部署完成!"
echo "========================================"
