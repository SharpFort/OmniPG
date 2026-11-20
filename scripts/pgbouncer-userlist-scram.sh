#!/bin/bash
# =============================================================================
# pgbouncer-userlist-scram.sh — 从 pg_authid 生成 SCRAM verifier 形态的 userlist
# S-G2（2026-11-20）：pgbouncer ≥1.14 支持以 SCRAM verifier 认证客户端并对后端做
# SCRAM passthrough（要求：auth_type=scram-sha-256，且客户端走 SCRAM——libpq 默认）。
# 本脚本是 userlist 的部署期权威生成通道：明文密码不落地，直接读库端 verifier。
# 用法:
#   sudo -u postgres ./scripts/pgbouncer-userlist-scram.sh <role>[,<role>...] > userlist.txt
#   例: sudo -u postgres ./scripts/pgbouncer-userlist-scram.sh app_owner,authenticator,logto,dbuser_monitor \
#         > /etc/pgbouncer/userlist.txt && psql -p 6432 -U app_owner -d pgbouncer -c RELOAD
# 依赖: psql 可用（peer 认证或经 -h/-U 提供超管凭据）；角色须已设密码（pg_authid 有 verifier）
# =============================================================================
set -euo pipefail

ROLES="${1:?用法: $0 <role>[,<role>...]}"
IFS=',' read -ra ROLE_ARR <<< "$ROLES"
[ ${#ROLE_ARR[@]} -gt 0 ] || { echo "角色列表为空" >&2; exit 1; }

LIST=$(printf "'%s',\n" "${ROLE_ARR[@]}")
LIST="${LIST%,}"

QUERY="SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
       FROM pg_authid
       WHERE rolpassword IS NOT NULL AND rolname IN ($LIST)
       ORDER BY rolname"

# psql 纯文本输出即 userlist 语法；验证取回数与请求一致，防角色名拼写错误静默丢行
PSQL_OUT=$(psql -At -c "$QUERY")
[ -n "$PSQL_OUT" ] || { echo "ERROR: 未取到任何 verifier（角色不存在或未设密码）" >&2; exit 1; }
GOT=$(printf '%s\n' "$PSQL_OUT" | wc -l)
WANT=${#ROLE_ARR[@]}
if [ "$GOT" -lt "$WANT" ]; then
    echo "WARN: 请求 $WANT 个角色，仅取到 $GOT 个 verifier（缺角色或未设密码）" >&2
fi
printf '%s\n' "$PSQL_OUT"
