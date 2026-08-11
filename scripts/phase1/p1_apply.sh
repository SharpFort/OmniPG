#!/usr/bin/env bash
# =============================================================================
# p1_apply.sh — 已废弃（N24，2026-08-11）
# =============================================================================
# 本脚本为 Phase1（Casdoor 时代）遗留：引用的大量文件已删除
#   （rpc_create_user / rpc_update_user_status / rpc_kick_user / rpc_user_login /
#    db/api_v1/sys/rpc/rpc_ensure_user.sql 等——015/035 已清理，镜像表写入通道
#    收敛为 webhook sync_* + JIT，见 docs/审查文档/33-Logto镜像表同步与对账审查清单.md），
#   且 set -e 下直接运行必然失败，故不再维护。
#
# 正确的全量重放入口（幂等，src → api_v1 → init → migrations 顺序）:
#   bash scripts/apply-src.sh
#
# 单迁移重放（示例）:
#   psql -h 127.0.0.1 -U app_owner -d app_db -f db/migrations/public/051_logto_guard_cleanup.sql
# =============================================================================
set -euo pipefail

echo "⚠️  p1_apply.sh 已废弃（N24）——请使用: bash scripts/apply-src.sh" >&2
exit 1
