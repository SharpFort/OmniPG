# ==============================================================================
# Policy Syncer 重启
# ==============================================================================

Write-Host "🔄 重启 Policy Syncer..." -ForegroundColor Yellow
docker compose restart syncer
Start-Sleep -Seconds 3
docker compose logs -f syncer
