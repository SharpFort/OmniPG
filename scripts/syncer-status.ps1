# ==============================================================================
# Policy Syncer 状态检查 (PowerShell)
# 修复 N-4: 使用 --tail 限制日志量
# ==============================================================================

$ErrorActionPreference = "SilentlyContinue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Policy Syncer 状态检查" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. 检查容器状态
$containerStatus = docker inspect --format='{{.State.Status}}' policy-syncer 2>$null
if ($containerStatus -eq "running") {
    Write-Host "✅ 容器状态: running" -ForegroundColor Green
} else {
    Write-Host "❌ 容器状态: $containerStatus" -ForegroundColor Red
}

# 2. 检查最近日志
Write-Host ""
Write-Host "📋 最近 10 行日志：" -ForegroundColor Yellow
docker logs --tail=10 policy-syncer

# 3. 检查关键日志关键字（修复 N-4: 使用 --tail=100 而非全量日志）
Write-Host ""
Write-Host "🔍 关键状态：" -ForegroundColor Yellow
$logs = docker logs --tail=100 policy-syncer 2>$null
if ($logs -match "正在监听 PostgreSQL|casbin_channel") {
    Write-Host "  ✅ PostgreSQL 监听已建立" -ForegroundColor Green
}
if ($logs -match "Advisory Lock") {
    Write-Host "  ✅ 已成为 leader" -ForegroundColor Green
}
if ($logs -match "已同步.*条策略") {
    Write-Host "  ✅ 策略已同步" -ForegroundColor Green
}
if ($logs -match "哈希匹配") {
    Write-Host "  ✅ 对账通过" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
