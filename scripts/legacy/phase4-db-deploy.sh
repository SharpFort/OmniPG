#!/bin/bash
set -e

cd /root/OmniPG

echo "========================================"
echo " Phase 4: 数据库部署"
echo "========================================"
echo ""

# Step 1: 安装 dbmate
echo "[1/7] 安装 dbmate..."
if ! command -v dbmate &>/dev/null; then
  rm -f /usr/local/bin/dbmate
  export http_proxy=http://127.0.0.1:10808 https_proxy=http://127.0.0.1:10808
  curl -fsSL --max-time 60 https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64 -o /usr/local/bin/dbmate
  chmod +x /usr/local/bin/dbmate
fi
dbmate --version

echo ""
echo "[2/7] 创建缺失的角色..."
su - postgres -c "psql -c 'CREATE ROLE IF NOT EXISTS authenticated;'" 2>/dev/null || true
su - postgres -c "psql -c 'CREATE ROLE IF NOT EXISTS anonymous;'" 2>/dev/null || true

echo ""
echo "[3/7] 执行迁移..."
cd /root/OmniPG/db
dbmate up

echo ""
echo "[4/7] 迁移状态..."
cd /root/OmniPG/db
dbmate status

echo ""
echo "[5/7] 刷入 Schema 初始化..."
cd /root/OmniPG
for schema in sys sales inventory; do
  echo "  $schema/_init_schema.sql"
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f db/src/$schema/_init_schema.sql 2>&1 | tail -3
done

echo ""
echo "[6/7] 刷入幂等源码..."
for f in $(find db/src -name '*.sql' -not -name '_*' | sort); do
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f" 2>&1 | tail -1
done

echo ""
echo "[7/7] 验证..."
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT schemaname, count(*) as tables FROM pg_tables WHERE schemaname NOT LIKE 'pg_%' AND schemaname NOT LIKE 'information_schema' GROUP BY schemaname ORDER BY schemaname;"

echo ""
echo "========================================"
echo " 数据库部署完成!"
echo "========================================"
