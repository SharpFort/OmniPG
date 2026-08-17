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
# 编码: UTF-8 with BOM（PowerShell 5.1 必需，否则中文被按 GBK 解码导致解析错乱）
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"

# 需要转发的端口（宿主 Pigsty 服务）
$Ports = 5432, 6432

# 获取 WSL2 发行版 IP（默认发行版；多发行版可指定 wsl -d <distro> hostname -I）
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
if (-not $wslIp) {
    Write-Host "ERROR: WSL2 not running or no IP obtained"
    exit 1
}
Write-Host "WSL2 IP: $wslIp"

foreach ($port in $Ports) {
    # 清除旧规则（IP 漂移后旧规则指向过期地址）
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 | Out-Null
    # 建立新转发: Windows:port -> WSL2 IP:port
    netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=$wslIp | Out-Null
    Write-Host "  OK portproxy $port -> $wslIp"
}

Write-Host ""
Write-Host "Current portproxy rules:"
netsh interface portproxy show all

# 防火墙放行（如未配置过）
$rule = Get-NetFirewallRule -DisplayName "OmniPG WSL2 PortProxy" -ErrorAction SilentlyContinue
if (-not $rule) {
    $fwParams = @{
        DisplayName = "OmniPG WSL2 PortProxy"
        Direction   = "Inbound"
        Action      = "Allow"
        Protocol    = "TCP"
        LocalPort   = ($Ports -join ",")
    }
    New-NetFirewallRule @fwParams | Out-Null
    Write-Host "  OK firewall rule created (OmniPG WSL2 PortProxy)"
}

# 验证: 从本机访问转发端口
foreach ($port in $Ports) {
    $ok = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
    if ($ok.TcpTestSucceeded) {
        Write-Host ("  127.0.0.1:{0} -> reachable" -f $port)
    } else {
        Write-Host ("  127.0.0.1:{0} -> UNREACHABLE" -f $port)
    }
}
