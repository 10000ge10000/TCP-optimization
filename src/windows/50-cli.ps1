function Invoke-WindowsPresetAssessment {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  Write-Header "预制参数评估"
  Write-Subtitle "Windows 端只做测速和推荐，不自动修改 Windows TCP 栈。"
  Write-Host ""
  Write-Section "检测中"
  Write-Note "动作" "正在检测 RTT、iperf3 上传/下载、重传和首秒速度..."

  $rtt = Get-RttMilliseconds -HostName $HostName
  $upload = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress)
  $download = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress -Reverse)
  $totalRetr = Add-NullableInt64 -Left $upload.Retransmits -Right $download.Retransmits
  $recommended = Select-PresetByProbe -RttMs $rtt -Retransmits $totalRetr -DownloadBitsPerSecond $download.BitsPerSecond

  Invoke-AgentPost -Url "$PeerUrl/report" -TokenValue $TokenValue -Body ([pscustomobject]@{
    role = "windows-preset-assessment"
    lan_ip = $LocalAddress
    stage = "preset-probe"
    result = "ok"
    detail = $recommended.Name
    bits_per_second = Max-NullableDouble -Left $upload.BitsPerSecond -Right $download.BitsPerSecond
    retransmits = $totalRetr
    first_second_bits_per_second = Max-NullableDouble -Left $upload.FirstSecondBitsPerSecond -Right $download.FirstSecondBitsPerSecond
    time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }) | Out-Null

  Write-Header "预制参数评估"
  Write-Section "检测结果"
  Write-PanelRow "本机地址" $LocalAddress
  Write-PanelRow "RTT" ("{0}ms" -f $rtt)
  Write-PanelRow "上传" ("{0} / 重传 {1} / 首秒 {2}" -f (Format-Rate $upload.BitsPerSecond), (Format-Retransmits $upload.Retransmits), (Format-Rate $upload.FirstSecondBitsPerSecond))
  Write-PanelRow "下载" ("{0} / 重传 {1} / 首秒 {2}" -f (Format-Rate $download.BitsPerSecond), (Format-Retransmits $download.Retransmits), (Format-Rate $download.FirstSecondBitsPerSecond))
  Write-Host ""
  Write-Section "推荐挡位"
  Write-PanelRow "预设挡位" $recommended.Name
  Write-PanelRow "适用范围" $recommended.Rtt
  Write-PanelRow "接收缓冲" $recommended.Rmem
  Write-PanelRow "发送缓冲" $recommended.Wmem
  Write-Note "说明" $recommended.Comment
  Write-Host ""
  Write-Section "可选挡位"
  foreach ($profile in Get-PresetProfiles) {
    Write-MenuItem $profile.Index $profile.Name ("{0} / 接收 {1} / 发送 {2}" -f $profile.Rtt, $profile.Rmem, $profile.Wmem)
  }
  Write-Host ""
  Write-Note "Windows" "这里只提供评估建议，不自动写入系统 TCP 参数。"
  return $true
}

function Show-AgentEventSummary {
  param([string]$PeerUrl, [string]$TokenValue)
  $data = Invoke-AgentGet -Url "$PeerUrl/events" -TokenValue $TokenValue
  if ($data.summaries -and $data.summaries.Count -gt 0) {
    foreach ($line in $data.summaries) {
      Write-Host "  $line"
    }
    return
  }
  Write-Host "  暂无过程记录。" -ForegroundColor DarkGray
}

function Invoke-RestoreDefaultsMenu {
  param([string]$PeerUrl, [string]$TokenValue)
  Write-Header "恢复默认值"
  Write-Subtitle "Windows 端不自动写入本机 TCP 栈，只请求服务端恢复启动时快照。"
  Write-Host ""
  Write-Section "快照状态"
  Write-PanelRow "本机快照" "不适用"
  if (Test-RemoteDefaultsAvailable -PeerUrl $PeerUrl -TokenValue $TokenValue) {
    Write-PanelRow "服务端快照" "已记录"
  } else {
    Write-PanelRow "服务端快照" "未知或不可用"
  }
  Write-Host ""
  Write-Note "范围" "只恢复服务端首次记录的 TCP/sysctl 快照，不提交任意参数。"
  $answer = Read-Host "确认请求服务端恢复默认值？输入 yes 继续，其他返回"
  if ($answer -ne "yes") { return $false }
  try {
    $result = Invoke-AgentPost -Url "$PeerUrl/restore-defaults" -TokenValue $TokenValue -Body ([pscustomobject]@{})
    if ($result.ok) {
      Write-Host "服务端默认值恢复请求已执行。" -ForegroundColor Green
      return $true
    }
    Write-Host "服务端返回恢复失败。" -ForegroundColor Yellow
    return $false
  } catch {
    Write-Host "服务端默认值恢复请求失败：$($_.Exception.Message)" -ForegroundColor Yellow
    return $false
  }
}

function Show-ClientDashboard {
  param([string]$LocalAddress, [int]$Port)
  Write-Header "TCP 双端调优器 · 客户端"
  Write-Subtitle "Windows 设备已连接，可直接选择优化目标"
  Write-Host ""
  Write-Section "连接状态"
  Write-PanelRow "会话" "已连接"
  Write-PanelRow "本机" "Windows · $LocalAddress"
  Write-PanelRow "测速节点" "已连接的服务端"
  Write-PanelRow "测试端口" "$Port"
  Write-Host ""
  Write-Note "提示" "代理/公网地址仅用于脚本通讯，界面和测试源地址优先使用本机局域网 IP。"
  Write-Note "Windows" "默认只测速和给出建议，不自动修改 Windows TCP 栈。"
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
  Write-Header "正在评估 · $modeName"
  Write-Subtitle "$directionName · 本机 $LocalAddress · 第 1/$SelectedRounds 轮"
  Write-Host ""
  Write-Section "优化概览"
  Write-PanelRow "模式" $modeName
  Write-PanelRow "测试方向" $directionName
  Write-PanelRow "本机地址" $LocalAddress
  Write-PanelRow "测速节点" "已连接的服务端"
  Write-PanelRow "最大轮数" "$SelectedRounds"
  Write-Host ""
  Write-Note "说明" "Windows 端进行真实链路测试并给出建议，不自动写系统 TCP 参数。"

  $previousRetransmits = $null
  $previousRate = $null
  $firstMetrics = $null
  $bestRate = 0.0
  $lastMetrics = $null
  $completedRounds = 0
  for ($round = 1; $round -le $SelectedRounds; $round++) {
    Write-Host ""
    Write-Section ("第 {0}/{1} 轮测试" -f $round, $SelectedRounds)
    Write-Host "  连接测试 → 分析结果 → 多轮复测 → 生成建议" -ForegroundColor Cyan
    Write-Host ("  轮次 {0}/{1}" -f $round, $SelectedRounds) -ForegroundColor DarkGray
    Write-Note "状态" "正在用 iperf3 测试真实链路..."
    $result = Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress -Reverse:($SelectedDirection -eq "download")
    $metrics = Get-IperfMetrics -Result $result
    $lastMetrics = $metrics
    $completedRounds = $round
    if (-not $firstMetrics) { $firstMetrics = $metrics }
    if ($metrics.BitsPerSecond -gt $bestRate) { $bestRate = $metrics.BitsPerSecond }

    $prevRateText = if ($null -eq $previousRate) { "无" } else { Format-Rate $previousRate }
    $prevRetrText = if ($null -eq $previousRetransmits) { "无" } else { "{0:N0} 次" -f $previousRetransmits }
    $trend = Get-TrendLabel -Current $metrics.Retransmits -Previous $previousRetransmits
    $delta = Get-PercentDelta -Before $firstMetrics.Retransmits -After $metrics.Retransmits
    $action = Get-NextActionLabel -ObjectiveValue $SelectedObjective -Retransmits $metrics.Retransmits -TargetRetransmits $SelectedTargetRetr
    $trendColor = if ($trend -eq "重传上升") { "Yellow" } else { "Green" }
    Write-MetricLine "当前速度" ("{0}（上轮 {1}）" -f (Format-Rate $metrics.BitsPerSecond), $prevRateText) "Cyan"
    $currentRetrText = Format-Retransmits $metrics.Retransmits
    $currentRetrColor = if ($null -eq $metrics.Retransmits) { "DarkGray" } elseif (Test-RetransmitsAtOrBelowTarget $metrics.Retransmits $SelectedTargetRetr) { "Green" } else { "Red" }
    Write-MetricLine "当前重传" ("{0}（上轮 {1}）" -f $currentRetrText, $prevRetrText) $currentRetrColor
    Write-MetricLine "改善幅度" ("{0} · {1}" -f $delta, $trend) $trendColor
    Write-MetricLine "当前动作" $action "Yellow"
    if ($SelectedObjective -eq "startup") {
      Write-MetricLine "首秒速度" (Format-Rate $metrics.FirstSecondBitsPerSecond) "Yellow"
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

    if ($SelectedObjective -eq "retrans" -and (Test-RetransmitsAtOrBelowTarget $metrics.Retransmits $SelectedTargetRetr)) {
      Write-Host ""
      Write-Host ("目标已达成：重传降至 {0:N0} 次。" -f $metrics.Retransmits) -ForegroundColor Green
      break
    }
    $previousRetransmits = $metrics.Retransmits
    $previousRate = $metrics.BitsPerSecond
  }

  if ($completedRounds -le 0) { $completedRounds = $SelectedRounds }
  Write-Header "链路评估完成"
  Write-Subtitle "$modeName · $directionName · 共测试 $completedRounds 轮"
  Write-Host ""
  Write-Section "结论"
  if (-not $lastMetrics) { return }
  $firstRateText = Format-Rate $firstMetrics.BitsPerSecond
  $lastRateText = Format-Rate $lastMetrics.BitsPerSecond
  $speedDelta = Get-PercentDelta -Before $firstMetrics.BitsPerSecond -After $lastMetrics.BitsPerSecond
  $retrDelta = Get-PercentDelta -Before $firstMetrics.Retransmits -After $lastMetrics.Retransmits
  if ($SelectedObjective -eq "throughput") {
    Write-PanelRow "结论" ("测试完成：最高速度 {0}。" -f (Format-Rate $bestRate))
  } elseif ($SelectedObjective -eq "startup") {
    Write-PanelRow "结论" ("测试完成：末轮首秒速度 {0}。" -f (Format-Rate $lastMetrics.FirstSecondBitsPerSecond))
  } elseif ($null -eq $lastMetrics.Retransmits) {
    Write-PanelRow "结论" "未检测到重传指标，不能判断是否达到目标。"
  } elseif ($lastMetrics.Retransmits -gt $SelectedTargetRetr) {
    Write-PanelRow "结论" "重传尚未达到目标，建议先检查 Wi-Fi、网线、代理链路或拥塞。"
  } else {
    Write-PanelRow "结论" ("目标已达成：重传降至 {0:N0} 次。" -f $lastMetrics.Retransmits)
  }
  Write-Host ""
  Write-Section "首轮与末轮对比"
  $hdrLabel = Format-Pad -Text "指标" -Width 12
  Write-Host ("  $hdrLabel │ {0,-14} │ {1,-14} │ {2,-10}" -f "优化前", "优化后", "变化") -ForegroundColor Cyan
  Write-Host ("  {0}" -f ("─" * 57)) -ForegroundColor DarkGray
  $lbl1 = Format-Pad -Text "传输速度" -Width 12
  Write-Host ("  $lbl1 │ {0,-14} │ {1,-14} │ {2,-10}" -f $firstRateText, $lastRateText, $speedDelta)
  $lbl2 = Format-Pad -Text "重传次数" -Width 12
  Write-Host ("  $lbl2 │ {0,-14} │ {1,-14} │ {2,-10}" -f (Format-Retransmits $firstMetrics.Retransmits), (Format-Retransmits $lastMetrics.Retransmits), $retrDelta)
  if ($SelectedObjective -eq "startup") {
    $startupDelta = Get-PercentDelta -Before $firstMetrics.FirstSecondBitsPerSecond -After $lastMetrics.FirstSecondBitsPerSecond
    $firstStartupText = Format-Rate $firstMetrics.FirstSecondBitsPerSecond
    $lastStartupText = Format-Rate $lastMetrics.FirstSecondBitsPerSecond
    $lbl3 = Format-Pad -Text "首秒速度" -Width 12
    Write-Host ("  $lbl3 │ {0,-14} │ {1,-14} │ {2,-10}" -f $firstStartupText, $lastStartupText, $startupDelta)
  }
  Write-Host ""
  Write-Section "配置摘要"
  Write-Note "Windows" "未自动修改 TCP 栈；以上为真实链路测试结果和优化建议。"
  Write-Host ""
  Write-Section "下一步操作"
  Write-MenuItem "1" "返回客户端主页" "回到操作菜单"
  Write-MenuItem "2" "换一种模式继续" "重新选择优化目标"
  Write-MenuItem "3" "查看详细参数" "检查当前 TCP 配置"
  Write-MenuItem "4" "无需回滚" "Windows 端未修改系统 TCP 栈" "DarkGray"
}

function Select-WindowsOptimization {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  Write-Header "选择优化目标"
  Write-Subtitle "先选目标，再选测试方向。所有修改都可以回滚。"
  Write-Host ""
  Write-Section "优化模式"
  Write-ModeCard "1" "重传优先" "适合游戏、语音、远程桌面。" "尽量把重传降到 0" "Green"
  Write-ModeCard "2" "吞吐优先" "适合下载、备份、大文件。" "优先提升稳定传输速率" "Cyan"
  Write-ModeCard "3" "快速起速" "适合网页、短连接、小文件。" "缩短连接初期的提速时间" "Yellow"
  Write-BackMenuItem
  $modeChoice = Read-Host "请选择优化目标 [1-3/0]"
  if (Test-BackChoice $modeChoice) { return $false }
  switch ($modeChoice) {
    "1" { $selectedObjective = "retrans"; $selectedRounds = 5; $selectedTarget = 0 }
    "2" { $selectedObjective = "throughput"; $selectedRounds = 3; $selectedTarget = 10 }
    "3" { $selectedObjective = "startup"; $selectedRounds = 3; $selectedTarget = 5 }
    default { Write-Host "无效优化目标。" -ForegroundColor Yellow; return $false }
  }

  Write-Host ""
  Write-Section "测试方向"
  Write-Host "  [1] 下载  服务端 -> 本机"
  Write-Host "  [2] 上传  本机 -> 服务端"
  Write-BackMenuItem
  Write-Host "当前选择：" -NoNewline -ForegroundColor Green
  Write-Host ("{0} · 默认下载方向" -f (Get-ObjectiveLabel -Value $selectedObjective))
  $directionChoice = Read-Host "请选择测试方向 [1-2/0]"
  if (Test-BackChoice $directionChoice) { return $false }
  switch ($directionChoice) {
    "1" { $selectedDirection = "download" }
    "2" { $selectedDirection = "upload" }
    default { Write-Host "无效测试方向。" -ForegroundColor Yellow; return $false }
  }
  Invoke-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress -SelectedObjective $selectedObjective -SelectedDirection $selectedDirection -SelectedRounds $selectedRounds -SelectedTargetRetr $selectedTarget
  return $true
}

function Invoke-ClientMenu {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  while ($true) {
    Show-ClientDashboard -LocalAddress $LocalAddress -Port $Port
    Write-Host ""
    Write-Section "操作菜单"
    Write-MenuGroup "优化"
    Write-MenuItem "0" "预制参数评估" "先检测双端基础信息，再推荐五档参数" "Yellow"
    Write-MenuItem "1" "稳定自动优化" "规则固定，自动测速迭代" "Green"
    Write-Host ""
    Write-MenuGroup "状态"
    Write-MenuItem "3" "查看本机状态" "系统 / TCP 参数"
    Write-MenuItem "4" "查看服务端状态" "会话 / 测速服务"
    Write-MenuItem "5" "查看过程记录" "中文摘要日志"
    Write-Host ""
    Write-MenuGroup "测速"
    Write-MenuItem "8" "iperf3 速度测试" "简单测速，不修改参数" "Cyan"
    Write-Host ""
    Write-MenuGroup "退出"
    Write-MenuItem "6" "回滚最近修改" "Windows 端不自动写入，仅提示说明" "Yellow"
    Write-MenuItem "9" "恢复默认值" (Get-DefaultsMenuTag -PeerUrl $PeerUrl -TokenValue $TokenValue) "Yellow"
    Write-MenuItem "7" "停止会话并退出" "清理 Agent / iperf3" "Yellow"
    Write-MenuItem "q" "退出客户端" "不停止服务端会话" "DarkGray"
    $choice = Read-Host "请选择"
    switch ($choice) {
      "0" { if (Invoke-WindowsPresetAssessment -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress) { Read-Host "按回车返回主菜单" | Out-Null } }
      "1" { if (Select-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress) { Read-Host "按回车返回主菜单" | Out-Null } }
      "3" { & $PSCommandPath status; Read-Host "按回车返回主菜单" | Out-Null }
      "4" { Invoke-AgentGet -Url "$PeerUrl/status" -TokenValue $TokenValue | ConvertTo-Json -Depth 8; Read-Host "按回车返回主菜单" | Out-Null }
      "5" { Show-AgentEventSummary -PeerUrl $PeerUrl -TokenValue $TokenValue; Read-Host "按回车返回主菜单" | Out-Null }
      "6" { Write-Host "Windows 端默认没有自动写入 TCP 参数，无需回滚。" -ForegroundColor Yellow; Read-Host "按回车返回主菜单" | Out-Null }
      "7" { Invoke-AgentPost -Url "$PeerUrl/stop" -TokenValue $TokenValue -Body ([pscustomobject]@{}) | Out-Null; return }
      "8" { Invoke-Iperf3Speedtest -HostName $HostName -Port $Port; Read-Host "按回车返回主菜单" | Out-Null }
      "9" { Invoke-RestoreDefaultsMenu -PeerUrl $PeerUrl -TokenValue $TokenValue | Out-Null; Read-Host "按回车返回主菜单" | Out-Null }
      "q" { return }
      "Q" { return }
      default { Write-Host "无效选择。" -ForegroundColor Yellow }
    }
  }
}

function Invoke-TcpTuneMain {
if ($Rounds -lt 1 -or $Rounds -gt 10) { throw "Rounds 必须在 1 到 10 之间。" }
if ($TargetRetr -lt 0 -or $TargetRetr -gt 1000000) { throw "TargetRetr 超出允许范围。" }
if ($IperfPort -lt 1 -or $IperfPort -gt 65535) { throw "IperfPort 必须在 1 到 65535 之间。" }
if ($Command -eq "status") {
  $cachedIperf = Get-CachedIperf3
  $statusData = [pscustomobject]@{
    App = "TCP 双端调优器 Windows 客户端"
    Version = $AppVersion
    Repo = $RepoUrl
    OS = [System.Environment]::OSVersion.VersionString
    Architecture = $env:PROCESSOR_ARCHITECTURE
    LanIPv4 = Get-LocalLanIPv4
    LanIPv6 = Get-LocalLanIPv6
    HasIperf3 = [bool]((Get-Command iperf3 -ErrorAction SilentlyContinue) -or $cachedIperf)
    CachedIperf3 = $cachedIperf
    HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    HasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    HasScoop = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
  }
  if ($Json) {
    [pscustomobject]@{ schema_version = 1; ok = $true; command = "status"; data = $statusData; errors = @() } | ConvertTo-Json -Depth 6
  } else {
    $statusData | ConvertTo-Json -Depth 4
  }
  return
}

if ($Command -eq "join" -or $Command -eq "client") {
  if (-not $Peer) { throw "$Command 需要 -Peer http://IP:PORT" }
  if (-not $Token) { throw "$Command 需要 -Token" }
  Test-PeerUri -Url $Peer | Out-Null
  Ensure-Command -Name "iperf3"

  $hostName = Get-PeerHost -Url $Peer
  $localAddress = Get-LocalBindAddress -HostName $hostName
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

  if ($Command -eq "client") {
    Write-Host "已连接到服务端会话。" -ForegroundColor Green
    if (-not $script:IsNonInteractive) {
      Invoke-ClientMenu -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress
    }
    return
  }

  Invoke-WindowsOptimization -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress -SelectedObjective $Objective -SelectedDirection $Direction -SelectedRounds $Rounds -SelectedTargetRetr $TargetRetr
}
}

try {
  Invoke-TcpTuneMain
} catch {
  $message = $_.Exception.Message
  $code = $ExitNetwork
  if ($message -match 'token|auth|401|403') { $code = $ExitAuthentication }
  elseif ($message -match 'iperf3.*(测试|JSON|速率|超时)|测速') { $code = $ExitBenchmark }
  elseif ($message -match '缺少命令|安装|SHA256|压缩包|版本验证') { $code = $ExitDependency }
  elseif ($message -match '必须|无效|超出|不允许|格式') { $code = $ExitArguments }
  if ($Json) {
    [pscustomobject]@{ schema_version = 1; ok = $false; command = $Command; data = $null; errors = @([pscustomobject]@{ code = $code; message = $message }) } | ConvertTo-Json -Depth 6
  } else {
    [Console]::Error.WriteLine($message)
  }
  exit $code
}
