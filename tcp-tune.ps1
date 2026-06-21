param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("client", "join", "status")]
  [string]$Command,

  [string]$Peer,
  [string]$Token,
  [int]$IperfPort = 5201,
  [ValidateSet("retrans", "throughput", "startup")]
  [string]$Objective = "retrans",
  [int]$TargetRetr = 0,
  [int]$Rounds = 5,
  [ValidateSet("download", "upload")]
  [string]$Direction = "download",
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/10000ge10000/TCP-optimization"

function Write-Rule {
  Write-Host ("-" * 60) -ForegroundColor DarkGray
}

function Write-Header {
  param([string]$Title)
  Clear-Host
  Write-Host $Title -ForegroundColor Cyan
  Write-Rule
}

function Write-KeyValue {
  param([string]$Label, [string]$Value)
  Write-Host ("  {0,-12} {1}" -f $Label, $Value)
}

function Install-Iperf3 {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id ESnet.iperf3 -e --accept-package-agreements --accept-source-agreements
    return
  }
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco install iperf3 -y
    return
  }
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    scoop install iperf3
    return
  }
  throw "缺少 iperf3，且未找到 winget、choco 或 scoop。请先安装 iperf3 并加入 PATH。"
}

function Ensure-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    if ($Name -eq "iperf3" -and $Yes) {
      Install-Iperf3
    }
  }
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "缺少命令：$Name。请安装 Windows 版 iperf3 并加入 PATH。"
  }
}

function Invoke-AgentPost {
  param(
    [string]$Url,
    [string]$TokenValue,
    [object]$Body
  )
  $headers = @{ "X-TCP-Tune-Token" = $TokenValue }
  $json = $Body | ConvertTo-Json -Depth 6
  Invoke-RestMethod -Method Post -Uri $Url -Headers $headers -ContentType "application/json" -Body $json
}

function Invoke-AgentGet {
  param([string]$Url, [string]$TokenValue)
  Invoke-RestMethod -Method Get -Uri $Url -Headers @{ "X-TCP-Tune-Token" = $TokenValue }
}

function Get-PeerHost {
  param([string]$Url)
  return ([Uri]$Url).Host
}

function Get-LocalLanIPv4 {
  try {
    $config = Get-NetIPConfiguration -ErrorAction Stop |
      Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
      Sort-Object { $_.NetAdapter.InterfaceMetric } |
      Select-Object -First 1
    if ($config -and $config.IPv4Address.IPAddress) {
      return [string]($config.IPv4Address.IPAddress | Select-Object -First 1)
    }
  } catch {
    # Older Windows editions may not expose NetTCPIP cmdlets.
  }

  $address = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object {
      $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
      -not $_.IPAddressToString.StartsWith("127.") -and
      -not $_.IPAddressToString.StartsWith("169.254.")
    } |
    Select-Object -First 1
  if ($address) { return $address.IPAddressToString }
  return "未识别"
}

function Get-ObjectiveLabel {
  param([string]$Value)
  switch ($Value) {
    "throughput" { return "吞吐优先" }
    "startup" { return "快速起速" }
    default { return "重传优先" }
  }
}

function Get-DirectionLabel {
  param([string]$Value)
  if ($Value -eq "upload") { return "上传（本机 → 服务端）" }
  return "下载（服务端 → 本机）"
}

function Format-Rate {
  param([double]$BitsPerSecond)
  if ($BitsPerSecond -ge 1000000000) {
    return ("{0:N2} Gbps" -f ($BitsPerSecond / 1000000000))
  }
  return ("{0:N1} Mbps" -f ($BitsPerSecond / 1000000))
}

function Run-Iperf {
  param(
    [string]$HostName,
    [int]$Port,
    [string]$LocalAddress,
    [switch]$Reverse
  )
  $arguments = @("-c", $HostName, "-p", "$Port", "-t", "15", "-i", "1", "-J")
  if ($LocalAddress -and $LocalAddress -ne "未识别" -and $HostName -notin @("127.0.0.1", "localhost", $LocalAddress)) {
    $arguments += @("-B", $LocalAddress)
  }
  if ($Reverse) { $arguments += "-R" }

  $raw = & iperf3 @arguments
  if ($LASTEXITCODE -ne 0) { throw "iperf3 测试失败。" }
  return ($raw | Out-String | ConvertFrom-Json)
}

function Get-IperfMetrics {
  param([object]$Result)
  $summary = $Result.end.sum_received
  if (-not $summary) { $summary = $Result.end.sum_sent }

  $retransmits = 0
  if ($Result.end.sum_sent -and $null -ne $Result.end.sum_sent.retransmits) {
    $retransmits = [int64]$Result.end.sum_sent.retransmits
  }
  $bitsPerSecond = 0.0
  if ($summary -and $summary.bits_per_second) {
    $bitsPerSecond = [double]$summary.bits_per_second
  }
  $firstSecondBits = 0.0
  if ($Result.intervals -and $Result.intervals.Count -gt 0 -and $Result.intervals[0].sum.bits_per_second) {
    $firstSecondBits = [double]$Result.intervals[0].sum.bits_per_second
  }

  return [pscustomobject]@{
    BitsPerSecond = $bitsPerSecond
    FirstSecondBitsPerSecond = $firstSecondBits
    Retransmits = $retransmits
  }
}

function Show-ClientDashboard {
  param([string]$LocalAddress, [int]$Port)
  Write-Header "TCP 双端调优器 0.1.0 - Windows 客户端"
  Write-KeyValue "连接状态" "已连接"
  Write-KeyValue "本机设备" "Windows · $LocalAddress"
  Write-KeyValue "测速节点" "已连接的服务端"
  Write-KeyValue "测试端口" "$Port"
  Write-Host ""
  Write-Host "当前会话已连接。远端代理地址仅用于内部通讯，不作为本机 Host 展示。" -ForegroundColor Green
  Write-Host "Windows 客户端默认只测速和给出建议，不自动修改 Windows TCP 栈。" -ForegroundColor DarkGray
}

function Invoke-WindowsOptimization {
  param(
    [string]$PeerUrl,
    [string]$TokenValue,
    [string]$HostName,
    [int]$Port,
    [string]$LocalAddress,
    [string]$SelectedObjective,
    [string]$SelectedDirection,
    [int]$SelectedRounds,
    [int]$SelectedTargetRetr
  )

  $modeName = Get-ObjectiveLabel -Value $SelectedObjective
  $directionName = Get-DirectionLabel -Value $SelectedDirection
  Write-Header "开始测试 · $modeName"
  Write-KeyValue "测试方向" $directionName
  Write-KeyValue "本机地址" $LocalAddress
  Write-KeyValue "测速节点" "已连接的服务端"
  Write-KeyValue "最大轮数" "$SelectedRounds"
  Write-Host ""
  Write-Host "说明：Windows 端进行真实链路测试并给出建议，不自动写系统 TCP 参数。" -ForegroundColor DarkGray

  $previousRetransmits = $null
  $bestRate = 0.0
  $lastMetrics = $null
  for ($round = 1; $round -le $SelectedRounds; $round++) {
    Write-Host ""
    Write-Rule
    Write-Host ("第 {0}/{1} 轮 · 正在测试链路..." -f $round, $SelectedRounds) -ForegroundColor Cyan
    $result = Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress -Reverse:($SelectedDirection -eq "download")
    $metrics = Get-IperfMetrics -Result $result
    $lastMetrics = $metrics
    if ($metrics.BitsPerSecond -gt $bestRate) { $bestRate = $metrics.BitsPerSecond }

    Write-Host ("  速度：{0}" -f (Format-Rate $metrics.BitsPerSecond)) -ForegroundColor Cyan
    Write-Host ("  重传：{0:N0} 次" -f $metrics.Retransmits) -ForegroundColor $(if ($metrics.Retransmits -le $SelectedTargetRetr) { "Green" } else { "Red" })
    if ($SelectedObjective -eq "startup") {
      Write-Host ("  首秒速度：{0}" -f (Format-Rate $metrics.FirstSecondBitsPerSecond)) -ForegroundColor Yellow
    }
    if ($null -ne $previousRetransmits) {
      if ($metrics.Retransmits -lt $previousRetransmits) {
        Write-Host "  趋势：重传正在下降" -ForegroundColor Green
      } elseif ($metrics.Retransmits -gt $previousRetransmits) {
        Write-Host "  趋势：重传暂时上升" -ForegroundColor Yellow
      } else {
        Write-Host "  趋势：重传保持不变"
      }
    }

    switch ($SelectedObjective) {
      "throughput" { Write-Host "  关注点：记录最高稳定速度，并观察重传是否可接受。" }
      "startup" { Write-Host "  关注点：比较首秒速度，判断短连接起速表现。" }
      default { Write-Host "  关注点：继续观察重传能否降到目标值。" }
    }

    Invoke-AgentPost -Url "$PeerUrl/report" -TokenValue $TokenValue -Body ([pscustomobject]@{
      role = "windows-client"
      lan_ip = $LocalAddress
      round = $round
      retransmits = $metrics.Retransmits
      bits_per_second = $metrics.BitsPerSecond
      first_second_bits_per_second = $metrics.FirstSecondBitsPerSecond
      objective = $SelectedObjective
      direction = $SelectedDirection
      time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }) | Out-Null

    if ($SelectedObjective -eq "retrans" -and $metrics.Retransmits -le $SelectedTargetRetr) {
      Write-Host ""
      Write-Host ("目标已达成：重传降至 {0:N0} 次。" -f $metrics.Retransmits) -ForegroundColor Green
      break
    }
    $previousRetransmits = $metrics.Retransmits
  }

  Write-Host ""
  Write-Rule
  if (-not $lastMetrics) { return }
  if ($SelectedObjective -eq "throughput") {
    Write-Host ("测试完成：最高速度 {0}。" -f (Format-Rate $bestRate)) -ForegroundColor Green
  } elseif ($SelectedObjective -eq "startup") {
    Write-Host ("测试完成：末轮首秒速度 {0}。" -f (Format-Rate $lastMetrics.FirstSecondBitsPerSecond)) -ForegroundColor Green
  } elseif ($lastMetrics.Retransmits -gt $SelectedTargetRetr) {
    Write-Host "测试完成，但重传尚未达到目标。建议先检查 Wi-Fi、网线、代理链路或拥塞。" -ForegroundColor Yellow
  }
  Write-Host "Windows TCP 参数未自动修改。" -ForegroundColor DarkGray
}

function Select-WindowsOptimization {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  Write-Header "选择优化目标"
  Write-Host "  1 重传优先" -ForegroundColor Green
  Write-Host "    尽量把重传降到 0，适合游戏、语音和远程桌面。"
  Write-Host ""
  Write-Host "  2 吞吐优先" -ForegroundColor Cyan
  Write-Host "    优先评估稳定传输速率，适合下载、备份和大文件。"
  Write-Host ""
  Write-Host "  3 快速起速" -ForegroundColor Yellow
  Write-Host "    重点观察首秒速度，适合网页、短连接和小文件。"
  $modeChoice = Read-Host "请选择优化目标 [1-3]"
  switch ($modeChoice) {
    "2" { $selectedObjective = "throughput"; $selectedRounds = 3; $selectedTarget = 10 }
    "3" { $selectedObjective = "startup"; $selectedRounds = 3; $selectedTarget = 5 }
    default { $selectedObjective = "retrans"; $selectedRounds = 5; $selectedTarget = 0 }
  }

  Write-Host ""
  Write-Host "  1 下载：服务端 → 本机"
  Write-Host "  2 上传：本机 → 服务端"
  $directionChoice = Read-Host "请选择测试方向 [1-2]"
  $selectedDirection = if ($directionChoice -eq "2") { "upload" } else { "download" }
  Invoke-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress -SelectedObjective $selectedObjective -SelectedDirection $selectedDirection -SelectedRounds $selectedRounds -SelectedTargetRetr $selectedTarget
}

function Invoke-ClientMenu {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  while ($true) {
    Show-ClientDashboard -LocalAddress $LocalAddress -Port $Port
    Write-Host ""
    Write-Host "客户端菜单" -ForegroundColor Green
    Write-Rule
    Write-Host "  1 开始优化" -ForegroundColor Green
    Write-Host "    选择重传优先、吞吐优先或快速起速。"
    Write-Host "  2 查看本机状态"
    Write-Host "  3 查看服务端状态"
    Write-Host "  4 查看过程记录"
    Write-Host "  5 停止双方会话并退出" -ForegroundColor Yellow
    Write-Host "  0 退出客户端" -ForegroundColor DarkGray
    $choice = Read-Host "请选择"
    switch ($choice) {
      "1" { Select-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress; Read-Host "按回车返回菜单" | Out-Null }
      "2" { & $PSCommandPath status; Read-Host "按回车返回菜单" | Out-Null }
      "3" { Invoke-AgentGet -Url "$PeerUrl/status" -TokenValue $TokenValue | ConvertTo-Json -Depth 8; Read-Host "按回车返回菜单" | Out-Null }
      "4" { Invoke-AgentGet -Url "$PeerUrl/events" -TokenValue $TokenValue | ConvertTo-Json -Depth 8; Read-Host "按回车返回菜单" | Out-Null }
      "5" { Invoke-AgentPost -Url "$PeerUrl/stop" -TokenValue $TokenValue -Body ([pscustomobject]@{}) | Out-Null; return }
      "0" { return }
      default { Write-Host "无效选择。" -ForegroundColor Yellow }
    }
  }
}

if ($Command -eq "status") {
  [pscustomobject]@{
    App = "TCP 双端调优器 Windows 客户端"
    Repo = $RepoUrl
    OS = [System.Environment]::OSVersion.VersionString
    Architecture = $env:PROCESSOR_ARCHITECTURE
    LanIPv4 = Get-LocalLanIPv4
    HasIperf3 = [bool](Get-Command iperf3 -ErrorAction SilentlyContinue)
    HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    HasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    HasScoop = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
  } | ConvertTo-Json -Depth 4
  exit 0
}

if ($Command -eq "join" -or $Command -eq "client") {
  if (-not $Peer) { throw "$Command 需要 -Peer http://IP:PORT" }
  if (-not $Token) { throw "$Command 需要 -Token" }
  Ensure-Command -Name "iperf3"

  $localAddress = Get-LocalLanIPv4
  $report = [pscustomobject]@{
    role = "windows-client"
    os = [System.Environment]::OSVersion.VersionString
    architecture = $env:PROCESSOR_ARCHITECTURE
    lan_ip = $localAddress
    objective = $Objective
    target_retr = $TargetRetr
    time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
  Invoke-AgentPost -Url "$Peer/report" -TokenValue $Token -Body $report | Out-Null

  $hostName = Get-PeerHost -Url $Peer
  if ($Command -eq "client") {
    Write-Host "已连接到服务端会话。" -ForegroundColor Green
    if ([Environment]::UserInteractive) {
      Invoke-ClientMenu -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress
    }
    exit 0
  }

  Invoke-WindowsOptimization -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress -SelectedObjective $Objective -SelectedDirection $Direction -SelectedRounds $Rounds -SelectedTargetRetr $TargetRetr
}
