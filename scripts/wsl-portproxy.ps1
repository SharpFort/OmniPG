# =============================================================================
# WSL2 端口转发脚本（Windows 侧，PowerShell）
# 用途: Docker 容器(host.docker.internal) → Windows 端口 → WSL2 宿主服务
#       解决 Windows 10（无 mirrored 网络模式）下容器无法访问 WSL2 内
#       Pigsty PostgreSQL/pgBouncer 的问题。
# 用法:
#   手动:   powershell -ExecutionPolicy Bypass -File scripts/wsl-portproxy.ps1
#   自动:   Win+R → shell:startup → 放入快捷方式；或任务计划程序（登录时触发）
# 配套文档: docs/审查文档/22-移除DockerPG统一由Pigsty管理-实施记录与网络方案.md §4.3
# 注意: 需要管理员权限（netsh 修改 portproxy）
# 2026-11-19 批次2d前置修复：
#   * 提权检查（原无检查时 netsh 逐条静默失败）
#   * WSL 未运行/空输出的空引用防护 + IP 格式校验
#   * netsh/防火墙失败显式报错（原 SilentlyContinue 掩盖一切）
#   * 防火墙规则收窄：RemoteAddress=LocalSubnet（Profile 不限制——WSL vEthernet
#     适配器常被 Windows 判为 Public，按 Profile 过滤会误杀 Docker 主用途流量）
#   * 规则幂等重建（旧参数规则不残留）
# 编码: UTF-8 with BOM（PowerShell 5.1 必需，否则中文被按 GBK 解码导致解析错乱）
# =============================================================================
$ErrorActionPreference = "Continue"   # 保持 Continue：PS 5.1 的 Stop 会把原生命令 stderr
                                      # 升级为终止性 NativeCommandError（netsh delete 预期报错会杀死脚本）；
                                      # 失败改由 $LASTEXITCODE / $? 显式检查

# 提权检查
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: 需要管理员权限（netsh portproxy）——请以管理员身份运行 PowerShell"
    exit 1
}

# 需要转发的端口（宿主 Pigsty 服务）
$Ports = 5432, 6432

# 获取 WSL2 发行版 IP（默认发行版；多发行版可指定 wsl -d <distro> hostname -I）
$rawIp = wsl hostname -I
if (-not $rawIp -or -not "$rawIp".Trim()) {
    Write-Host "ERROR: WSL2 not running or no IP obtained"
    exit 1
}
$wslIp = "$rawIp".Trim().Split(' ')[0]
if (-not ($wslIp -as [System.Net.IPAddress])) {
    Write-Host "ERROR: 无法解析 WSL2 IP: $wslIp"
    exit 1
}
Write-Host "WSL2 IP: $wslIp"

$failed = 0
foreach ($port in $Ports) {
    # 清除旧规则（IP 漂移后旧规则指向过期地址）
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 | Out-Null
    # 建立新转发: Windows:port -> WSL2 IP:port
    netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=$wslIp | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  ERROR portproxy {0} 添加失败 (exit {1})" -f $port, $LASTEXITCODE)
        $failed++
    } else {
        Write-Host "  OK portproxy $port -> $wslIp"
    }
}

Write-Host ""
Write-Host "Current portproxy rules:"
netsh interface portproxy show all

# 防火墙放行（幂等重建：参数收窄后的规则不与旧版本残留混用）
Remove-NetFirewallRule -DisplayName "OmniPG WSL2 PortProxy" -ErrorAction SilentlyContinue
$fwParams = @{
    DisplayName  = "OmniPG WSL2 PortProxy"
    Direction    = "Inbound"
    Action       = "Allow"
    Protocol     = "TCP"
    LocalPort    = ($Ports -join ",")
    RemoteAddress = "LocalSubnet"   # 收窄：仅本机子网（原无限制=公网可达 5432/6432）；
                                    # Profile 不限制——WSL vEthernet 常判为 Public，按 Profile 过滤会误杀 Docker 流量
}
New-NetFirewallRule @fwParams | Out-Null
if (-not $?) {
    Write-Host "ERROR: 防火墙规则创建失败"
    exit 1
}
Write-Host "  OK firewall rule (LocalSubnet)"

# 验证: 从本机访问转发端口
foreach ($port in $Ports) {
    $ok = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
    if ($ok.TcpTestSucceeded) {
        Write-Host ("  127.0.0.1:{0} -> reachable" -f $port)
    } else {
        Write-Host ("  127.0.0.1:{0} -> UNREACHABLE" -f $port)
        $failed++
    }
}

if ($failed -gt 0) {
    Write-Host "ERROR: $failed 项失败，请检查上方输出"
    exit 1
}
