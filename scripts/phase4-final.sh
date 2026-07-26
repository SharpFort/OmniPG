#!/bin/bash
set -e

cd /root/OmniPG

echo "=== 刷入 api_v1 源码 ==="
for f in $(find db/api_v1 -name '*.sql' | sort); do
  echo "执行: $f"
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f" > /dev/null 2>&1 || true
done

echo ""
echo "=== 验证 api_v1 Schema ==="
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'api_v1%' ORDER BY schema_name;"

echo ""
echo "=== 验证 API 函数 ==="
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT n.nspname, count(*) as functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname LIKE 'api_v1%' GROUP BY n.nspname ORDER BY n.nspname;"

echo ""
echo "=== 重启 Docker Compose ==="
cd /root/OmniPG/gateway
docker compose down
docker compose up -d apisix postgrest casdoor swagger-ui

echo ""
echo "=== 等待服务启动 ==="
sleep 15

echo ""
echo "=== 健康检查 ==="
echo -n "  APISIX: "
curl -sf http://localhost:9080/apisix/status > /dev/null 2>&1 && echo "✅" || echo "❌"

echo -n "  PostgREST: "
curl -sf http://localhost:3001/ > /dev/null 2>&1 && echo "✅" || echo "❌"

echo -n "  Casdoor: "
curl -sf http://localhost:8000/api/health > /dev/null 2>&1 && echo "✅" || echo "❌"

echo -n "  Swagger UI: "
curl -sf http://localhost:8082/ > /dev/null 2>&1 && echo "✅" || echo "❌"

echo ""
echo "=== 完成 ==="
