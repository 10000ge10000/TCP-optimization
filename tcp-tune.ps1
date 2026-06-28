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
$ToolRoot = Join-Path $env:LOCALAPPDATA "TCP-optimization"
$IperfCacheDir = Join-Path $ToolRoot "iperf3"
$DefaultAiGatewayUrl = "https://tcp-optimization-ai-gateway.10454728.workers.dev/v1"
$AiModelCandidates = @("minimaxai/minimax-m3", "moonshotai/kimi-k2.6", "minimaxai/minimax-m2.7", "z-ai/glm-5.1")

# 显示宽度感知的 padding：中文字符占 2 列，ASCII 占 1 列
function Format-Pad {
  param([string]$Text, [int]$Width)
  $displayWidth = 0
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if ($code -ge 0x1100 -and ($code -le 0x115F -or ($code -ge 0x2E80 -and $code -le 0xA4CF) -or ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or ($code -ge 0xFE30 -and $code -le 0xFE4F) -or ($code -ge 0xFF00 -and $code -le 0xFF60) -or ($code -ge 0xFFE0 -and $code -le 0xFFE6))) {
      $displayWidth += 2
    } else {
      $displayWidth += 1
    }
  }
  $pad = $Width - $displayWidth
  if ($pad -gt 0) {
    return $Text + (" " * $pad)
  }
  return $Text
}

function Write-Rule {
  Write-Host ("━" * 58) -ForegroundColor Cyan
}

function Write-Header {
  param([string]$Title)
  Clear-Host
  Write-Host ""
  Write-Host "  $Title" -ForegroundColor Cyan
  Write-Rule
}

function Write-KeyValue {
  param([string]$Label, [string]$Value)
  $padded = Format-Pad -Text $Label -Width 12
  Write-Host "  $padded  $Value"
}

function Write-PanelRule {
  Write-Host ("─" * 58) -ForegroundColor DarkGray
}

function Write-PanelRow {
  param([string]$Label, [string]$Value)
  $padded = Format-Pad -Text $Label -Width 12
  Write-Host "  $padded  $Value"
}

function Write-Section {
  param([string]$Title)
  Write-Host "  ▎ $Title" -ForegroundColor Cyan
}

function Write-Note {
  param([string]$Label, [string]$Text)
  $padded = Format-Pad -Text $Label -Width 12
  Write-Host "  $padded  $Text" -ForegroundColor DarkGray
}

function Write-Subtitle {
  param([string]$Text)
  Write-Host "  $Text" -ForegroundColor DarkGray
}

function Write-ModeCard {
  param([string]$Number, [string]$Title, [string]$Description, [string]$Target, [string]$Color = "Cyan")
  $padded = Format-Pad -Text $Title -Width 10
  Write-Host "  [$Number] " -NoNewline -ForegroundColor $Color
  Write-Host $padded -NoNewline -ForegroundColor White
  Write-Host "  $Description"
  Write-Host ("           目标：{0}" -f $Target) -ForegroundColor DarkGray
}

function Write-MetricLine {
  param([string]$Label, [string]$Value, [string]$Color = "Cyan")
  $padded = Format-Pad -Text $Label -Width 10
  Write-Host "  $padded  " -NoNewline
  Write-Host $Value -ForegroundColor $Color
}

function Write-MenuGroup {
  param([string]$Text)
  Write-Host "  $Text" -ForegroundColor Cyan
}

function Write-MenuItem {
  param([string]$Number, [string]$Title, [string]$Description, [string]$Color = "Cyan")
  $padded = Format-Pad -Text $Title -Width 16
  Write-Host "  [$Number] " -NoNewline -ForegroundColor $Color
  Write-Host $padded -NoNewline -ForegroundColor White
  Write-Host "  $Description" -ForegroundColor DarkGray
}

function Repair-DisplayText {
  param([string]$Text)
  if (-not $Text) { return "" }
  if ($Text -match "[ÃÂäåæçèé]") {
    try {
      return [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding(28591).GetBytes($Text))
    } catch {
      return $Text
    }
  }
  return $Text
}

function Get-PercentDelta {
  param([double]$Before, [double]$After)
  if ($Before -le 0) { return "建立基线" }
  $delta = (($After - $Before) * 100.0) / $Before
  if ($delta -gt 0) { return ("+{0:N0}%" -f $delta) }
  return ("{0:N0}%" -f $delta)
}

function Get-TrendLabel {
  param([Nullable[Int64]]$Current, [Nullable[Int64]]$Previous)
  if ($null -eq $Previous) { return "建立基线" }
  if ($Current -lt $Previous) { return "重传下降" }
  if ($Current -gt $Previous) { return "重传上升" }
  return "保持稳定"
}

function Get-NextActionLabel {
  param([string]$ObjectiveValue, [Int64]$Retransmits, [Int64]$TargetRetransmits)
  switch ($ObjectiveValue) {
    "throughput" {
      if ($Retransmits -le $TargetRetransmits) { return "重传可接受，继续观察稳定吞吐。" }
      return "重传偏高，建议先降低排队压力。"
    }
    "startup" { return "关注首秒速度，判断短连接起速表现。" }
    default {
      if ($Retransmits -le $TargetRetransmits) { return "已达到目标，保持当前建议。" }
      return "继续压低重传，优先减少排队。"
    }
  }
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

  Write-Host "未找到 winget/choco/scoop，改用用户目录下载 iperf3。" -ForegroundColor Yellow
  New-Item -ItemType Directory -Force -Path $IperfCacheDir | Out-Null
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ar51an/iperf3-win-builds/releases/latest" -Headers @{ "User-Agent" = "TCP-optimization" }
  $asset = $release.assets |
    Where-Object { $_.name -match 'win64\.zip$' -and $_.name -notmatch 'auth|win7' } |
    Select-Object -First 1
  if (-not $asset) {
    throw "无法找到 Windows iperf3 下载包。"
  }
  $zipPath = Join-Path $IperfCacheDir $asset.name
  $extractPath = Join-Path $IperfCacheDir "current"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
  if (Test-Path $extractPath) { Remove-Item -LiteralPath $extractPath -Recurse -Force }
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
  $exe = Get-ChildItem -LiteralPath $extractPath -Recurse -Filter iperf3.exe | Select-Object -First 1
  if (-not $exe) {
    throw "下载包中未找到 iperf3.exe。"
  }
  $env:PATH = "$($exe.Directory.FullName);$env:PATH"
  Write-Host "iperf3 已安装到用户缓存：$($exe.FullName)" -ForegroundColor Green
}

function Ensure-Command {
  param([string]$Name)
  if ($Name -eq "iperf3") {
    $cached = Get-CachedIperf3
    if ($cached) {
      $env:PATH = "$((Split-Path -Parent $cached));$env:PATH"
    }
  }
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    if ($Name -eq "iperf3" -and $Yes) {
      Install-Iperf3
    }
  }
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "缺少命令：$Name。请安装 Windows 版 iperf3 并加入 PATH。"
  }
}

function Get-CachedIperf3 {
  if (-not (Test-Path $IperfCacheDir)) { return $null }
  $exe = Get-ChildItem -LiteralPath $IperfCacheDir -Recurse -Filter iperf3.exe -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($exe) { return $exe.FullName }
  return $null
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

function Get-LocalLanIPv6 {
  try {
    $addr = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop |
      Where-Object {
        $_.AddressState -eq "Preferred" -and
        $_.IPAddress -ne "::1" -and
        $_.IPAddress -notlike "fe80*" -and
        $_.IPAddress -notlike "fd*" -and
        $_.IPAddress -notlike "fc*"
      } |
      Sort-Object InterfaceMetric |
      Select-Object -First 1
    if ($addr -and $addr.IPAddress) { return [string]$addr.IPAddress }
  } catch {
    # Older Windows editions may not expose NetTCPIP cmdlets.
  }
  return "未识别"
}

function Test-IPv6Literal {
  param([string]$HostName)
  $ip = $null
  if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) {
    return $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
  }
  return $false
}

function Get-LocalBindAddress {
  param([string]$HostName)
  if (Test-IPv6Literal -HostName $HostName) {
    return Get-LocalLanIPv6
  }
  return Get-LocalLanIPv4
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

function Invoke-AIChat {
  param([string]$Model, [string]$Prompt, [int]$MaxTokens = 512)
  $baseUrl = $env:TCP_TUNE_AI_GATEWAY_URL
  if (-not $baseUrl) { $baseUrl = $DefaultAiGatewayUrl }
  $baseUrl = $baseUrl.TrimEnd("/")
  $headers = @{
    "Content-Type" = "application/json"
    "Accept" = "application/json"
    "User-Agent" = "TCP-optimization/Windows"
  }
  if ($env:NVIDIA_API_KEY) {
    $headers["Authorization"] = "Bearer $env:NVIDIA_API_KEY"
  } elseif ($env:TCP_TUNE_AI_GATEWAY_TOKEN) {
    $headers["Authorization"] = "Bearer $env:TCP_TUNE_AI_GATEWAY_TOKEN"
  }
  $body = @{
    model = $Model
    messages = @(@{ role = "user"; content = $Prompt })
    temperature = 0
    max_tokens = $MaxTokens
  } | ConvertTo-Json -Depth 8
  $timeout = 30
  if ($env:TCP_TUNE_AI_TIMEOUT) { $timeout = [int]$env:TCP_TUNE_AI_TIMEOUT }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/chat/completions" -Headers $headers -Body $body -TimeoutSec $timeout
      $content = $response.choices[0].message.content
      if ($content -is [array]) {
        $content = ($content | ForEach-Object {
          if ($_.text) { $_.text } elseif ($_.content) { $_.content } else { "" }
        }) -join ""
      }
      if ($content) { return [string]$content }
    } catch {
      if ($attempt -eq 3) { throw }
      Start-Sleep -Seconds 1
    }
  }
  throw "AI 没有返回内容。"
}

function Select-AIModel {
  if ($env:NVIDIA_MODEL -and $env:NVIDIA_MODEL -ne "auto") { return $env:NVIDIA_MODEL }
  foreach ($model in $AiModelCandidates) {
    try {
      $ok = Invoke-AIChat -Model $model -Prompt "Return only OK." -MaxTokens 16
      if ($ok) { return $model }
    } catch {
      continue
    }
  }
  throw "没有可用 AI 模型。"
}

function ConvertFrom-AIJson {
  param([string]$Text)
  $match = [regex]::Match($Text, "\{[\s\S]*\}")
  if (-not $match.Success) { throw "AI 未返回 JSON。" }
  return ($match.Value | ConvertFrom-Json)
}

function Invoke-WindowsAITuning {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  Write-Header "AI 智能调参"
  Write-Subtitle "Windows 端会真实测速并显示 AI 建议；默认不写 Windows TCP 栈。"
  Write-Host ""
  Write-Section "AI 调参目标"
  Write-ModeCard "1" "快速起速" "适合网页、短连接、小文件。" "缩短连接初期提速时间" "Yellow"
  Write-ModeCard "2" "吞吐优先" "适合下载、备份、大文件。" "优先提高稳定传输速度" "Cyan"
  Write-ModeCard "3" "重传优先" "适合游戏、语音、远程桌面。" "优先压低重传" "Green"
  $modeChoice = Read-Host "请选择 AI 调参目标 [1-3]"
  switch ($modeChoice) {
    "2" { $objective = "throughput"; $objectiveName = "吞吐优先" }
    "3" { $objective = "retrans"; $objectiveName = "重传优先" }
    default { $objective = "startup"; $objectiveName = "快速起速" }
  }

  Write-Host ""
  Write-Section "测速"
  Write-Note "上传" "本机 -> 对端"
  $upload = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress)
  Write-Note "下载" "对端 -> 本机"
  $download = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress -Reverse)
  Write-Section "测速摘要"
  Write-MetricLine "上传速度" (Format-Rate $upload.BitsPerSecond) "Cyan"
  Write-MetricLine "上传重传" ("{0:N0} 次" -f $upload.Retransmits) $(if ($upload.Retransmits -gt 0) { "Yellow" } else { "Green" })
  Write-MetricLine "下载速度" (Format-Rate $download.BitsPerSecond) "Cyan"
  Write-MetricLine "下载重传" ("{0:N0} 次" -f $download.Retransmits) $(if ($download.Retransmits -gt 0) { "Yellow" } else { "Green" })

  Invoke-AgentPost -Url "$PeerUrl/report" -TokenValue $TokenValue -Body ([pscustomobject]@{
    role = "windows-ai-result"
    lan_ip = $LocalAddress
    objective = $objective
    direction = "both"
    retransmits = $upload.Retransmits + $download.Retransmits
    bits_per_second = [Math]::Max($upload.BitsPerSecond, $download.BitsPerSecond)
    upload_bits_per_second = $upload.BitsPerSecond
    upload_retransmits = $upload.Retransmits
    download_bits_per_second = $download.BitsPerSecond
    download_retransmits = $download.Retransmits
    time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }) | Out-Null

  $model = Select-AIModel
  $summary = [pscustomobject]@{
    objective = $objective
    role = "windows"
    upload_bits_per_second = $upload.BitsPerSecond
    upload_retransmits = $upload.Retransmits
    download_bits_per_second = $download.BitsPerSecond
    download_retransmits = $download.Retransmits
    first_second_bits_per_second = $download.FirstSecondBitsPerSecond
  } | ConvertTo-Json -Compress
  $prompt = @"
You are a conservative TCP tuning assistant for a Windows client.
Return only JSON: {"action":"short Chinese action","risk":"low|medium|high","reason":"short Chinese reason","windows_change":"none|manual-only"}.
Do not suggest shell commands. Windows client should not auto-write TCP stack.
Objective: $objectiveName
Metrics: $summary
"@
  $decision = ConvertFrom-AIJson (Invoke-AIChat -Model $model -Prompt $prompt -MaxTokens 256)
  Write-Host ""
  Write-Section "AI 建议摘要"
  Write-MetricLine "模型" $model "Cyan"
  Write-MetricLine "目标" $objectiveName "Cyan"
  Write-MetricLine "建议动作" (Repair-DisplayText ([string]$decision.action)) "Yellow"
  Write-MetricLine "风险" (Repair-DisplayText ([string]$decision.risk)) $(if ($decision.risk -eq "low") { "Green" } else { "Yellow" })
  Write-MetricLine "修改方式" "Windows 默认不自动写 TCP 栈" "Green"
  Write-MetricLine "AI 理由" (Repair-DisplayText ([string]$decision.reason)) "Cyan"
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
  Write-Header "正在优化 · $modeName"
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
    Write-Host "  连接测试 → 分析结果 → 应用调整 → 复测确认" -ForegroundColor Cyan
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
    Write-MetricLine "当前重传" ("{0:N0} 次（上轮 {1}）" -f $metrics.Retransmits, $prevRetrText) $(if ($metrics.Retransmits -le $SelectedTargetRetr) { "Green" } else { "Red" })
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

    if ($SelectedObjective -eq "retrans" -and $metrics.Retransmits -le $SelectedTargetRetr) {
      Write-Host ""
      Write-Host ("目标已达成：重传降至 {0:N0} 次。" -f $metrics.Retransmits) -ForegroundColor Green
      break
    }
    $previousRetransmits = $metrics.Retransmits
    $previousRate = $metrics.BitsPerSecond
  }

  if ($completedRounds -le 0) { $completedRounds = $SelectedRounds }
  Write-Header "优化完成"
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
  } elseif ($lastMetrics.Retransmits -gt $SelectedTargetRetr) {
    Write-PanelRow "结论" "重传尚未达到目标，建议先检查 Wi-Fi、网线、代理链路或拥塞。"
  } else {
    Write-PanelRow "结论" ("目标已达成：重传降至 {0:N0} 次。" -f $lastMetrics.Retransmits)
  }
  Write-Host ""
  Write-Section "优化前后"
  $hdrLabel = Format-Pad -Text "指标" -Width 12
  Write-Host ("  $hdrLabel │ {0,-14} │ {1,-14} │ {2,-10}" -f "优化前", "优化后", "变化") -ForegroundColor Cyan
  Write-Host ("  {0}" -f ("─" * 57)) -ForegroundColor DarkGray
  $lbl1 = Format-Pad -Text "传输速度" -Width 12
  Write-Host ("  $lbl1 │ {0,-14} │ {1,-14} │ {2,-10}" -f $firstRateText, $lastRateText, $speedDelta)
  $lbl2 = Format-Pad -Text "重传次数" -Width 12
  Write-Host ("  $lbl2 │ {0,-14} │ {1,-14} │ {2,-10}" -f ("{0:N0}" -f $firstMetrics.Retransmits), ("{0:N0}" -f $lastMetrics.Retransmits), $retrDelta)
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
  Write-MenuItem "4" "回滚本次修改" "恢复优化前的系统参数" "Yellow"
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
  $modeChoice = Read-Host "请选择优化目标 [1-3]"
  switch ($modeChoice) {
    "2" { $selectedObjective = "throughput"; $selectedRounds = 3; $selectedTarget = 10 }
    "3" { $selectedObjective = "startup"; $selectedRounds = 3; $selectedTarget = 5 }
    default { $selectedObjective = "retrans"; $selectedRounds = 5; $selectedTarget = 0 }
  }

  Write-Host ""
  Write-Section "测试方向"
  Write-Host "  [1] 下载  服务端 -> 本机"
  Write-Host "  [2] 上传  本机 -> 服务端"
  Write-Host "当前选择：" -NoNewline -ForegroundColor Green
  Write-Host ("{0} · 默认下载方向" -f (Get-ObjectiveLabel -Value $selectedObjective))
  $directionChoice = Read-Host "请选择测试方向 [1-2]"
  $selectedDirection = if ($directionChoice -eq "2") { "upload" } else { "download" }
  Invoke-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress -SelectedObjective $selectedObjective -SelectedDirection $selectedDirection -SelectedRounds $selectedRounds -SelectedTargetRetr $selectedTarget
}

function Invoke-ClientMenu {
  param([string]$PeerUrl, [string]$TokenValue, [string]$HostName, [int]$Port, [string]$LocalAddress)
  while ($true) {
    Show-ClientDashboard -LocalAddress $LocalAddress -Port $Port
    Write-Host ""
    Write-Section "操作菜单"
    Write-MenuGroup "优化"
    Write-MenuItem "1" "开始优化" "重传 / 吞吐 / 快速起速" "Green"
    Write-MenuItem "2" "AI 智能调参" "AI 辅助：快速起速 / 吞吐 / 重传" "Cyan"
    Write-Host ""
    Write-MenuGroup "状态"
    Write-MenuItem "3" "查看本机状态" "系统 / TCP 参数"
    Write-MenuItem "4" "查看服务端状态" "会话 / 测速服务"
    Write-MenuItem "5" "查看过程记录" "任务 / 结果"
    Write-Host ""
    Write-MenuGroup "退出"
    Write-MenuItem "6" "停止会话并退出" "清理 Agent / iperf3" "Yellow"
    Write-MenuItem "0" "退出客户端" "不停止服务端会话" "DarkGray"
    $choice = Read-Host "请选择"
    switch ($choice) {
      "1" { Select-WindowsOptimization -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress; Read-Host "按回车返回菜单" | Out-Null }
      "2" { Invoke-WindowsAITuning -PeerUrl $PeerUrl -TokenValue $TokenValue -HostName $HostName -Port $Port -LocalAddress $LocalAddress; Read-Host "按回车返回菜单" | Out-Null }
      "3" { & $PSCommandPath status; Read-Host "按回车返回菜单" | Out-Null }
      "4" { Invoke-AgentGet -Url "$PeerUrl/status" -TokenValue $TokenValue | ConvertTo-Json -Depth 8; Read-Host "按回车返回菜单" | Out-Null }
      "5" { Invoke-AgentGet -Url "$PeerUrl/events" -TokenValue $TokenValue | ConvertTo-Json -Depth 8; Read-Host "按回车返回菜单" | Out-Null }
      "6" { Invoke-AgentPost -Url "$PeerUrl/stop" -TokenValue $TokenValue -Body ([pscustomobject]@{}) | Out-Null; return }
      "0" { return }
      default { Write-Host "无效选择。" -ForegroundColor Yellow }
    }
  }
}

if ($Command -eq "status") {
  $cachedIperf = Get-CachedIperf3
  [pscustomobject]@{
    App = "TCP 双端调优器 Windows 客户端"
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
  } | ConvertTo-Json -Depth 4
  exit 0
}

if ($Command -eq "join" -or $Command -eq "client") {
  if (-not $Peer) { throw "$Command 需要 -Peer http://IP:PORT" }
  if (-not $Token) { throw "$Command 需要 -Token" }
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
    if ([Environment]::UserInteractive) {
      Invoke-ClientMenu -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress
    }
    exit 0
  }

  Invoke-WindowsOptimization -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort -LocalAddress $localAddress -SelectedObjective $Objective -SelectedDirection $Direction -SelectedRounds $Rounds -SelectedTargetRetr $TargetRetr
}
