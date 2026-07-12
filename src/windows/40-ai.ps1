function Invoke-AIChat {
  param([string]$Model, [string]$Prompt, [int]$MaxTokens = 512)
  if (-not $Model -or $Model.Length -gt 128 -or $Model -notmatch '^[A-Za-z0-9._:/-]+$') { throw "AI 模型名称无效。" }
  if (-not $Prompt -or $Prompt.Length -gt 32000) { throw "AI 请求内容为空或超过 32000 字符。" }
  if ($MaxTokens -lt 1 -or $MaxTokens -gt 1024) { throw "AI max_tokens 必须在 1 到 1024 之间。" }
  $baseUrl = $env:TCP_TUNE_AI_GATEWAY_URL
  if (-not $baseUrl) { $baseUrl = $DefaultAiGatewayUrl }
  $baseUrl = $baseUrl.TrimEnd("/")
  $headers = @{
    "Content-Type" = "application/json"
    "Accept" = "application/json"
    "User-Agent" = "TCP-optimization/Windows"
  }
  $baseUri = $null
  if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$baseUri) -or $baseUri.Scheme -ne "https") { throw "AI 网关必须是 HTTPS URL。" }
  $nvidiaBase = if ($env:NVIDIA_BASE_URL) { $env:NVIDIA_BASE_URL.TrimEnd("/") } else { "https://integrate.api.nvidia.com/v1" }
  $nvidiaUri = [Uri]$nvidiaBase
  $isNvidiaDirect = $baseUri.Host -eq $nvidiaUri.Host -and $baseUri.AbsolutePath.TrimEnd("/") -eq $nvidiaUri.AbsolutePath.TrimEnd("/")
  if ($isNvidiaDirect -and $env:NVIDIA_API_KEY) {
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
  $timeout = 90
  if ($env:TCP_TUNE_AI_TIMEOUT) {
    $parsedTimeout = 0
    if (-not [int]::TryParse($env:TCP_TUNE_AI_TIMEOUT, [ref]$parsedTimeout) -or $parsedTimeout -lt 5 -or $parsedTimeout -gt 180) { throw "TCP_TUNE_AI_TIMEOUT 必须在 5 到 180 秒之间。" }
    $timeout = $parsedTimeout
  }
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

function Format-Retransmits {
  param([Nullable[Int64]]$Retransmits)
  if ($null -eq $Retransmits) { return "未检测" }
  return ("{0:N0} 次" -f $Retransmits)
}

function Get-RetransmitsColor {
  param([Nullable[Int64]]$Retransmits)
  if ($null -eq $Retransmits) { return "DarkGray" }
  if ($Retransmits -gt 0) { return "Yellow" }
  return "Green"
}

function Test-RetransmitsAtOrBelowTarget {
  param([Nullable[Int64]]$Retransmits, [Int64]$Target)
  return ($null -ne $Retransmits -and $Retransmits -le $Target)
}

function Select-AIModel {
  if ($env:NVIDIA_MODEL -and $env:NVIDIA_MODEL -ne "auto") { return $env:NVIDIA_MODEL }
  if (-not $env:NVIDIA_MODEL) { return $DefaultAiModel }
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
  if (-not $Text -or $Text.Length -gt 16000) { throw "AI 响应为空或过大。" }
  $trimmed = $Text.Trim()
  if (-not ($trimmed.StartsWith("{") -and $trimmed.EndsWith("}"))) { throw "AI 必须只返回一个 JSON 对象。" }
  try { $result = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { throw "AI 返回的 JSON 无效。" }
  $allowed = @("action", "risk", "reason", "windows_change")
  $names = @($result.PSObject.Properties.Name)
  if (@($names | Where-Object { $_ -notin $allowed }).Count -gt 0) { throw "AI JSON 包含未知字段。" }
  foreach ($required in $allowed) { if ($required -notin $names) { throw "AI JSON 缺少字段：$required" } }
  if ([string]$result.risk -notin @("low", "medium", "high")) { throw "AI risk 枚举无效。" }
  if ([string]$result.windows_change -notin @("none", "manual-only")) { throw "AI windows_change 枚举无效。" }
  if ([string]$result.action -match '[\r\n]' -or ([string]$result.action).Length -gt 256) { throw "AI action 超出限制。" }
  if ([string]$result.reason -match '[\r\n]' -or ([string]$result.reason).Length -gt 512) { throw "AI reason 超出限制。" }
  return $result
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
  Write-BackMenuItem
  $modeChoice = Read-Host "请选择 AI 调参目标 [1-3/0]"
  if (Test-BackChoice $modeChoice) { return $false }
  switch ($modeChoice) {
    "1" { $objective = "startup"; $objectiveName = "快速起速" }
    "2" { $objective = "throughput"; $objectiveName = "吞吐优先" }
    "3" { $objective = "retrans"; $objectiveName = "重传优先" }
    default { Write-Host "无效 AI 调参目标。" -ForegroundColor Yellow; return $false }
  }

  Write-Host ""
  Write-Section "测速"
  Write-Note "上传" "本机 -> 对端"
  $upload = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress)
  Write-Note "下载" "对端 -> 本机"
  $download = Get-IperfMetrics -Result (Run-Iperf -HostName $HostName -Port $Port -LocalAddress $LocalAddress -Reverse)
  Write-Section "测速摘要"
  Write-MetricLine "上传速度" (Format-Rate $upload.BitsPerSecond) "Cyan"
  Write-MetricLine "上传重传" (Format-Retransmits $upload.Retransmits) (Get-RetransmitsColor $upload.Retransmits)
  Write-MetricLine "下载速度" (Format-Rate $download.BitsPerSecond) "Cyan"
  Write-MetricLine "下载重传" (Format-Retransmits $download.Retransmits) (Get-RetransmitsColor $download.Retransmits)

  Invoke-AgentPost -Url "$PeerUrl/report" -TokenValue $TokenValue -Body ([pscustomobject]@{
    role = "windows-ai-result"
    lan_ip = $LocalAddress
    objective = $objective
    direction = "both"
    retransmits = Add-NullableInt64 -Left $upload.Retransmits -Right $download.Retransmits
    bits_per_second = Max-NullableDouble -Left $upload.BitsPerSecond -Right $download.BitsPerSecond
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
  $decision = ConvertFrom-AIJson (Invoke-AIChat -Model $model -Prompt $prompt -MaxTokens 512)
  Write-Host ""
  Write-Section "AI 建议摘要"
  Write-MetricLine "模型" $model "Cyan"
  Write-MetricLine "目标" $objectiveName "Cyan"
  Write-MetricLine "建议动作" (Repair-DisplayText ([string]$decision.action)) "Yellow"
  Write-MetricLine "风险" (Repair-DisplayText ([string]$decision.risk)) $(if ($decision.risk -eq "low") { "Green" } else { "Yellow" })
  Write-MetricLine "修改方式" "Windows 默认不自动写 TCP 栈" "Green"
  Write-MetricLine "AI 理由" (Repair-DisplayText ([string]$decision.reason)) "Cyan"
  return $true
}
