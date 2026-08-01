#!/bin/bash
set -e

cd /root/OmniPG

echo '=== Step 5: 刷入幂等源码 ==='

# 遍历 db/src 下所有 .sql 文件（排除 _init_schema.sql）
for f in $(find db/src -name '*.sql' -not -name '_*' 2>/dev/null | sort); do
  echo "  执行: $f"
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f" > /dev/null 2>&1 || true
done

echo ''
echo '=== Step 6: 验证 API 函数 ==='
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT n.nspname, count(*) as functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname LIKE 'api_v1%' GROUP BY n.nspname ORDER BY n.nspname;"

echo ''
echo '=== Step 7: 验证所有 Schema ==='
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%' AND schema_name NOT LIKE 'information_schema' AND schema_name NOT LIKE 'pg_catalog' ORDER BY schema_name;"

echo ''
echo '=== Step 8: Docker Compose 启动 ==='
cd /root/OmniPG/gateway
docker compose down 2>/dev/null || true
docker compose pull
docker compose up -d

echo ''
echo '=== Step 9: 等待服务启动 ==='
sleep 15

echo ''
echo '=== Step 10: 健康检查 ==='
echo -n '  APISIX: '
curl -sf http://localhost:9080/apisix/status > /dev/null 2>&1 && echo '✅' || echo '❌'

echo -n '  PostgREST: '
curl -sf http://localhost:3001/ > /dev/null 2>&1 && echo '✅' || echo '❌'

echo -n '  Casdoor: '
curl -sf http://localhost:8000/api/health > /dev/null 2>&1 && echo '✅' || echo '❌'

echo -n '  Swagger UI: '
curl -sf http://localhost:8082/ > /dev/null 2>&1 && echo '✅' || echo '❌'

echo ''
echo '=== 完成 ==='
