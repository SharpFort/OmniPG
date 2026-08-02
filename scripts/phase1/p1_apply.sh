#!/bin/bash
# Phase 1 部署: 刷新函数/RLS/新RPC（在 WSL 内执行）
set -e
export PGPASSWORD=dev_password_change_me
PSQL=(psql -h 127.0.0.1 -U app_owner -d app_db -v ON_ERROR_STOP=1 -q)

echo "=== 0) 007 up 段先行（建表；SQL 函数创建时校验表存在性）==="
awk '/^-- migrate:down/{exit} {print}' db/migrations/sys/007_casdoor_user_mirror.sql > /tmp/007_up.sql
"${PSQL[@]}" -f /tmp/007_up.sql
echo "  OK: 007 up"

echo "=== 1) 认证函数 ==="
for f in \
  db/src/sys/functions/current_user_id.sql \
  db/src/sys/functions/current_tenant_id.sql \
  db/src/sys/functions/current_user_dept_id.sql \
  db/src/sys/functions/is_super_admin.sql \
  db/src/sys/functions/audit_created_at.sql \
  db/src/sys/functions/audit_deletion_user.sql \
  db/src/sys/functions/audit_user_fields.sql \
  db/src/sys/functions/check_token_blacklist.sql \
  db/src/sys/functions/is_uuid_v7.sql \
  db/src/sys/functions/refresh_token_rtr.sql \
  db/src/sys/functions/user_login_sso.sql \
  db/src/sys/functions/write_audit_log.sql; do
  "${PSQL[@]}" -f "$f"
  echo "  OK: $f"
done

echo "=== 2) RLS ==="
"${PSQL[@]}" -f db/src/sys/privileges/rls_policies.sql
echo "  OK: rls_policies"

echo "=== 3) 新 RPC（视图已由 p1_views.sh 重建）==="
# 007 重跑会级联删除依赖 public.sys_user 的 api_v1 视图，先恢复关键视图
"${PSQL[@]}" -f db/api_v1/sys/views/sys_user.sql
echo "  OK: db/api_v1/sys/views/sys_user.sql"
for f in \
  db/api_v1/sys/rpc/rpc_ensure_user.sql \
  db/api_v1/sys/rpc/rpc_webhook_user_upsert.sql \
  db/api_v1/sys/rpc/rpc_webhook_user_delete.sql \
  db/api_v1/sys/rpc/rpc_create_user.sql \
  db/api_v1/sys/rpc/rpc_update_user_status.sql \
  db/api_v1/sys/rpc/rpc_batch_update_user_status.sql \
  db/src/sys/functions/approve_role_request.sql \
  db/api_v1/sys/rpc/rpc_get_current_user.sql \
  db/api_v1/sys/rpc/rpc_get_user_permissions.sql \
  db/api_v1/sys/rpc/rpc_logout.sql \
  db/api_v1/sys/rpc/rpc_reject_role_request.sql \
  db/api_v1/sys/rpc/rpc_submit_role_request.sql \
  db/api_v1/sys/rpc/rpc_get_config.sql \
  db/api_v1/sys/rpc/rpc_get_all_public_configs.sql \
  db/api_v1/sys/rpc/rpc_update_config.sql \
  db/api_v1/sys/rpc/rpc_export_csv.sql \
  db/api_v1/sys/rpc/rpc_import_csv.sql \
  db/api_v1/sys/rpc/rpc_kick_user.sql \
  db/api_v1/sys/rpc/rpc_refresh_token.sql \
  db/api_v1/sys/rpc/rpc_user_login.sql; do
  "${PSQL[@]}" -f "$f"
  echo "  OK: $f"
done

echo "=== 4) 重跑 007 验证幂等（只执行 up 段；psql 不识别 migrate:down 标记）==="
awk '/^-- migrate:down/{exit} {print}' db/migrations/sys/007_casdoor_user_mirror.sql > /tmp/007_up.sql
"${PSQL[@]}" -f /tmp/007_up.sql
echo "  OK: 007 idempotent (up 段)"
# 007 的 DROP VIEW CASCADE 会删依赖视图，重跑后全量恢复
for f in $(find db/api_v1/sys -path "*/views/*.sql" | sort); do
  "${PSQL[@]}" -f "$f"
done
echo "  OK: 全部 sys 视图恢复"

echo "=== 4c) 权限授予（grant_all，视图就绪后）==="
"${PSQL[@]}" -f db/api_v1/sys/privileges/grant_all.sql
echo "  OK: grant_all"

echo "=== 5) 验证结构 ==="
"${PSQL[@]}" -t -A -c "SELECT 'mirror 列数: '||count(*) FROM information_schema.columns WHERE table_name='casdoor_user_mirror'"
"${PSQL[@]}" -t -A -c "SELECT 'profile 列数: '||count(*) FROM information_schema.columns WHERE table_name='sys_user_profile'"
"${PSQL[@]}" -t -A -c "SELECT '兼容视图: '||string_agg(column_name, ',') FROM information_schema.columns WHERE table_name='sys_user' AND table_schema='public'"
"${PSQL[@]}" -t -A -c "SELECT '触发器: '||string_agg(trigger_name, ',') FROM information_schema.triggers WHERE event_object_table='casdoor_user_mirror'"
"${PSQL[@]}" -t -A -c "SELECT 'FK 到 mirror: '||count(*) FROM pg_constraint WHERE confrelid='casdoor_user_mirror'::regclass"
"${PSQL[@]}" -t -A -c "SELECT '新RPC: '||string_agg(proname, ',') FROM pg_proc WHERE proname IN ('ensure_user','webhook_user_upsert','webhook_user_delete')"
echo "=== ALL DONE ==="
