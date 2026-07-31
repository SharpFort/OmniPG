# =============================================================================
# WSL2 端口转发脚本（Windows 侧，PowerShell）
# 用途: Docker 容器(host.docker.internal) → Windows 端口 → WSL2 宿主服务
#       解决 Windows 10（无 mirrored 网络模式）下容器无法访问 WSL2 内
#       Pigsty PostgreSQL/pgBouncer 的问题。
# 用法:
#   手动:   powershell -ExecutionPolicy Bypass -File scripts/wsl-portproxy.ps1
#   自动:   Win+R → shell:startup → 放入快捷方式；或任务计划程序（登录时触发）
# 配套文档: docs/审查文档/22-移除DockerPG统一由Pigsty管理-实施记录与网络方案.md §4.3
# 注意: 需要管理员权限（netsh 修改 portproxy）；Windows 防火墙需放行对应端口
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"

# 需要转发的端口（宿主 Pigsty 服务）
$Ports = 5432, 6432

# 获取 WSL2 发行版 IP（默认发行版；多发行版可指定 wsl -d <distro> hostname -I）
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
if (-not $wslIp) {
    Write-Host "❌ WSL2 未启动或未获取到 IP，请先启动 WSL2"
    exit 1
}
Write-Host "WSL2 IP: $wslIp"

foreach ($port in $Ports) {
    # 清除旧规则（IP 漂移后旧规则指向过期地址）
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 | Out-Null
    # 建立新转发: Windows:port -> WSL2 IP:port
    netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=$wslIp | Out-Null
    Write-Host "  ✅ portproxy $port -> $wslIp"
}

Write-Host ""
Write-Host "当前 portproxy 规则:"
netsh interface portproxy show all

# 防火墙放行（如未配置过）
if (-not (Get-NetFirewallRule -DisplayName "OmniPG WSL2 PortProxy" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "OmniPG WSL2 PortProxy" -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort ($Ports -join ",") | Out-Null
    Write-Host "  ✅ 防火墙规则已创建 (OmniPG WSL2 PortProxy)"
}

# 验证: 从本机访问转发端口
foreach ($port in $Ports) {
    $ok = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
    Write-Host ("  {0}:{1} -> {2}" -f "127.0.0.1", $port, $(if ($ok.TcpTestSucceeded) { "可达" } else { "不可达" }))
}
