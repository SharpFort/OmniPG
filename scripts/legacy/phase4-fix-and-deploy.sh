#!/bin/bash
set -e

cd /root/OmniPG

echo "========================================"
echo " Phase 4: 修复 + 部署"
echo "========================================"
echo ""

# Step 1: 创建缺失的 Schema
echo "[1/6] 创建 api_v1_* Schema..."
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db <<'SQL'
CREATE SCHEMA IF NOT EXISTS api_v1_sys;
CREATE SCHEMA IF NOT EXISTS api_v1_sales;
CREATE SCHEMA IF NOT EXISTS api_v1_inventory;
GRANT USAGE ON SCHEMA api_v1_sys TO authenticated;
GRANT USAGE ON SCHEMA api_v1_sales TO authenticated;
GRANT USAGE ON SCHEMA api_v1_inventory TO authenticated;
GRANT ALL ON SCHEMA api_v1_sys TO app_owner;
GRANT ALL ON SCHEMA api_v1_sales TO app_owner;
GRANT ALL ON SCHEMA api_v1_inventory TO app_owner;
SQL

echo "  ✅ Schema 创建完成"

echo ""
echo "[2/6] 验证 Schema..."
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'api_v1%' ORDER BY schema_name;"

echo ""
echo "[3/6] 修复 sys_audit_log 表..."
# 检查并创建缺失的表
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS public.sys_audit_log (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_id UUID,
    user_id UUID,
    username VARCHAR(100),
    operation VARCHAR(50) NOT NULL,
    table_name VARCHAR(100),
    record_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID
);
CREATE INDEX IF NOT EXISTS idx_audit_tenant ON public.sys_audit_log(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_user ON public.sys_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_operation ON public.sys_audit_log(operation);
CREATE INDEX IF NOT EXISTS idx_audit_created ON public.sys_audit_log(created_at);
SQL

echo "  ✅ sys_audit_log 修复完成"

echo ""
echo "[4/6] 刷入 api_v1 源码..."
for f in $(find db/api_v1 -name '*.sql' | sort); do
  echo "  $f"
  PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=0 -f "$f" 2>&1 | tail -1
done

echo ""
echo "[5/6] 验证..."
PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT n.nspname, count(*) as functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname LIKE 'api_v1%' GROUP BY n.nspname ORDER BY n.nspname;"

echo ""
echo "[6/6] 重启 Docker Compose..."
cd /root/OmniPG/gateway
docker compose down 2>/dev/null || true
docker compose up -d apisix postgrest casdoor swagger-ui

echo ""
echo "等待服务启动..."
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
echo "========================================"
echo " 部署完成!"
echo "========================================"
