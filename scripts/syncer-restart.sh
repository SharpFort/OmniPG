#!/bin/bash
# ==============================================================================
# Policy Syncer 重启
# ==============================================================================

echo "🔄 重启 Policy Syncer..."
docker compose restart syncer
sleep 3
docker compose logs -f syncer
