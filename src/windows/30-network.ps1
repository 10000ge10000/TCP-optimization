function Get-PresetProfiles {
  return @(
    [pscustomobject]@{ Index = "1"; Name = "近距轻载"; Rtt = "RTT < 30ms"; Rmem = "64MiB"; Wmem = "32MiB"; Comment = "低延迟链路，优先控制发送队列和重传。" },
    [pscustomobject]@{ Index = "2"; Name = "近距高速"; Rtt = "RTT 30~70ms"; Rmem = "64MiB"; Wmem = "64MiB"; Comment = "同区域或精品线路，适合较高下行和稳定短中距链路。" },
    [pscustomobject]@{ Index = "3"; Name = "中距均衡"; Rtt = "RTT 70~130ms"; Rmem = "约 85MiB"; Wmem = "约 41MiB"; Comment = "跨境中等延迟，接收缓冲略大于发送缓冲。" },
    [pscustomobject]@{ Index = "4"; Name = "长距增强"; Rtt = "RTT 130~190ms"; Rmem = "约 100MiB"; Wmem = "约 48MiB"; Comment = "亚太/跨海高带宽链路，适合较大 BDP。" },
    [pscustomobject]@{ Index = "5"; Name = "远距大带宽"; Rtt = "RTT > 190ms"; Rmem = "约 178MiB"; Wmem = "约 85MiB"; Comment = "欧美等高延迟链路，缓冲更大，低内存设备需谨慎。" }
  )
}

function Get-RttMilliseconds {
  param([string]$HostName)
  try {
    $samples = Test-Connection -ComputerName $HostName -Count 3 -ErrorAction Stop
    $values = foreach ($sample in $samples) {
      if ($null -ne $sample.ResponseTime) { [double]$sample.ResponseTime }
      elseif ($null -ne $sample.Latency) { [double]$sample.Latency }
    }
    if ($values) { return [Nullable[Int32]][int](($values | Measure-Object -Average).Average) }
  } catch {
  }
  # ICMP 被禁或探测失败时返回未知，不得当作 0ms 参与挡位判断。
  return $null
}

function Format-RttText {
  param([Nullable[Int32]]$RttMs)
  if ($null -eq $RttMs) { return "未检测（ICMP 可能被禁）" }
  return ("{0}ms" -f $RttMs)
}

function Select-PresetByProbe {
  param([Nullable[Int32]]$RttMs, [Nullable[Int64]]$Retransmits, [double]$DownloadBitsPerSecond)
  if ($null -eq $RttMs) { $index = 3 }
  elseif ($RttMs -lt 30) { $index = 1 }
  elseif ($RttMs -lt 70) { $index = 2 }
  elseif ($RttMs -lt 130) { $index = 3 }
  elseif ($RttMs -lt 190) { $index = 4 }
  else { $index = 5 }
  if ($null -ne $Retransmits -and $Retransmits -gt 500 -and $index -gt 1) { $index-- }
  if ($DownloadBitsPerSecond -gt 0 -and $DownloadBitsPerSecond -lt 20000000 -and $index -gt 3) { $index = 3 }
  return (Get-PresetProfiles | Where-Object { $_.Index -eq "$index" } | Select-Object -First 1)
}

function Get-CachedIperf3 {
  if (-not $IperfPackage.Sha256 -or $IperfPackage.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { return $null }
  $versionDir = Join-Path $IperfCacheDir $IperfPackage.Version
  $marker = Join-Path $versionDir ".tcp-tune-sha256"
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $null }
  if (([IO.File]::ReadAllText($marker).Trim()) -ne $IperfPackage.Sha256) { return $null }
  $executables = @(Get-ChildItem -LiteralPath $versionDir -Recurse -File -Filter iperf3.exe -ErrorAction SilentlyContinue)
  if ($executables.Count -eq 1) { return $executables[0].FullName }
  return $null
}

function Invoke-AgentPost {
  param(
    [string]$Url,
    [string]$TokenValue,
    [object]$Body
  )
  if (-not $TokenValue -or $TokenValue.Length -gt 256 -or $TokenValue -match '[\r\n]') { throw "Agent token 无效。" }
  $uri = [Uri]$Url
  if ($uri.Scheme -notin @("http", "https")) { throw "Agent URL 只允许 HTTP(S)。" }
  $headers = @{ "X-TCP-Tune-Token" = $TokenValue }
  $json = $Body | ConvertTo-Json -Depth 6
  if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw "Agent 请求体超过 32 KiB。" }
  Invoke-RestMethod -Method Post -Uri $Url -Headers $headers -ContentType "application/json" -Body $json -TimeoutSec 30
}

function Invoke-AgentGet {
  param([string]$Url, [string]$TokenValue, [int]$TimeoutSec = 30)
  if (-not $TokenValue -or $TokenValue.Length -gt 256 -or $TokenValue -match '[\r\n]') { throw "Agent token 无效。" }
  Invoke-RestMethod -Method Get -Uri $Url -Headers @{ "X-TCP-Tune-Token" = $TokenValue } -TimeoutSec $TimeoutSec
}

function Test-RemoteDefaultsAvailable {
  param([string]$PeerUrl, [string]$TokenValue)
  try {
    $data = Invoke-AgentGet -Url "$PeerUrl/defaults" -TokenValue $TokenValue -TimeoutSec 5
    return [bool]$data.available
  } catch {
    return $false
  }
}

function Get-DefaultsMenuTag {
  param([string]$PeerUrl, [string]$TokenValue)
  # 每次重绘菜单都探测会在服务端无响应时反复卡住；本会话只探测一次。
  if ($null -eq $script:DefaultsMenuTagCache) {
    $remote = if (Test-RemoteDefaultsAvailable -PeerUrl $PeerUrl -TokenValue $TokenValue) { "服务端已记录" } else { "服务端未知" }
    $script:DefaultsMenuTagCache = "[本机不适用 / $remote]"
  }
  return $script:DefaultsMenuTagCache
}

function Get-PeerHost {
  param([string]$Url)
  $uri = Test-PeerUri -Url $Url
  return $uri.DnsSafeHost
}

function Test-PeerUri {
  param([Parameter(Mandatory)][string]$Url)
  $uri = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "Peer 必须是绝对 HTTP(S) URL。" }
  if ($uri.Scheme -notin @("http", "https")) { throw "Peer 只允许 http 或 https。" }
  if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or $uri.Query -or $uri.Fragment) { throw "Peer 不允许用户信息、查询参数或片段。" }
  if ($uri.AbsolutePath -ne "/") { throw "Peer URL 不应包含接口路径。" }
  Test-IperfHost -HostName $uri.DnsSafeHost | Out-Null
  return $uri
}

function Test-IperfHost {
  param([Parameter(Mandatory)][string]$HostName)
  if ($HostName.Length -gt 253 -or $HostName.StartsWith("-") -or $HostName -match '[\x00-\x20/\\]') {
    throw "对端主机名不安全或超出长度限制。"
  }
  $ip = $null
  if ([Net.IPAddress]::TryParse($HostName, [ref]$ip)) { return $true }
  if ($HostName -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
    throw "对端主机名格式无效。"
  }
  return $true
}

function Get-LocalLanIPv4 {
  try {
    $interfaces = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up }
    foreach ($interface in $interfaces) {
      $properties = $interface.GetIPProperties()
      if (-not @($properties.GatewayAddresses).Count) { continue }
      $address = $properties.UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.IPAddressToString -notlike "169.254.*" } |
        Select-Object -First 1
      if ($address) { return $address.Address.IPAddressToString }
    }
  } catch {
    # Fall through to DNS-based discovery for restricted environments.
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
    foreach ($interface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ($interface.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
      $address = $interface.GetIPProperties().UnicastAddresses |
        Where-Object {
          $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and
          -not $_.Address.IsIPv6LinkLocal -and -not $_.Address.IsIPv6Multicast -and $_.Address.IPAddressToString -ne "::1"
        } | Select-Object -First 1
      if ($address) { return $address.Address.IPAddressToString }
    }
  } catch {
    # Return an explicit unknown state below.
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
  param([Nullable[Double]]$BitsPerSecond)
  if ($null -eq $BitsPerSecond) { return "未检测" }
  if ($BitsPerSecond -ge 1000000000) {
    return ("{0:N2} Gbps" -f ($BitsPerSecond / 1000000000))
  }
  return ("{0:N1} Mbps" -f ($BitsPerSecond / 1000000))
}

function Test-IperfBindCompatible {
  param([string]$HostName, [string]$LocalAddress)
  if (-not $LocalAddress -or $LocalAddress -eq "未识别" -or $HostName -in @("127.0.0.1", "localhost", $LocalAddress)) {
    return $false
  }
  $localIp = $null
  if (-not [Net.IPAddress]::TryParse($LocalAddress, [ref]$localIp)) { return $false }
  $targetIp = $null
  if ([Net.IPAddress]::TryParse($HostName, [ref]$targetIp)) {
    return $localIp.AddressFamily -eq $targetIp.AddressFamily
  }
  # 已通过 Test-IperfHost 校验的 hostname 保持既有绑定行为，地址族由系统解析决定。
  return $true
}

function Run-Iperf {
  param(
    [string]$HostName,
    [int]$Port,
    [string]$LocalAddress,
    [switch]$Reverse
  )
  Test-IperfHost -HostName $HostName | Out-Null
  if ($Port -lt 1 -or $Port -gt 65535) { throw "iperf3 端口必须在 1 到 65535 之间。" }
  $arguments = @("-c", $HostName, "-p", "$Port", "-t", "15", "-i", "1", "-J")
  if (Test-IperfBindCompatible -HostName $HostName -LocalAddress $LocalAddress) {
    $arguments += @("-B", $LocalAddress)
  }
  if ($Reverse) { $arguments += "-R" }

  $raw = Invoke-IperfProcess -Arguments $arguments -TimeoutSeconds 35
  try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "iperf3 返回了无效 JSON。" }
}

function Add-NullableInt64 {
  param([Nullable[Int64]]$Left, [Nullable[Int64]]$Right)
  if ($null -eq $Left -or $null -eq $Right) { return $null }
  return [Int64]($Left + $Right)
}

function Max-NullableDouble {
  param([Nullable[Double]]$Left, [Nullable[Double]]$Right)
  if ($null -eq $Left) { return $Right }
  if ($null -eq $Right) { return $Left }
  return [Math]::Max($Left.Value, $Right.Value)
}

function Invoke-IperfProcess {
  param([string[]]$Arguments, [int]$TimeoutSeconds)
  if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) { throw "iperf3 超时时间无效。" }
  $command = Get-Command iperf3 -ErrorAction Stop
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $command.Source
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.Arguments = (($Arguments | ForEach-Object {
    if ($_ -match '[\x00\r\n"]') { throw "iperf3 参数包含非法字符。" }
    '"' + $_ + '"'
  }) -join ' ')
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  try {
    if (-not $process.Start()) { throw "无法启动 iperf3。" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill() } catch {}
      throw "iperf3 测试超时，进程已停止。"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      $detail = if ($stderr) { $stderr.Trim() } else { "exit $($process.ExitCode)" }
      throw "iperf3 测试失败：$detail"
    }
    return $stdout
  } finally { $process.Dispose() }
}

function Invoke-Iperf3Speedtest {
  param([string]$HostName, [int]$Port)

  Write-Header "iperf3 速度测试"
  Write-Subtitle "简单测速，不修改任何参数"
  Write-Host ""
  Write-Section "测试参数"
  Write-PanelRow "对端地址" $HostName
  Write-PanelRow "端口" $Port
  Write-PanelRow "测试方向" "下载（服务端 → 本机）"
  Write-PanelRow "测试时长" "10秒"
  if (Test-IPv6Literal -HostName $HostName) {
    Write-Note "IPv6" "检测到 IPv6 地址，使用 IPv6 测速"
  }
  Write-Host ""
  Write-Note "状态" "正在测速..."
  Ensure-Command -Name "iperf3"
  Write-Host ""
  $arguments = @("-c", $HostName, "-p", "$Port", "-R", "-t", "10")
  & iperf3 @arguments
  if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Section "测速完成"
  } else {
    Write-Host ""
    Write-Host "测速失败，请检查对端 iperf3 服务是否运行。" -ForegroundColor Yellow
  }
}

function Get-IperfMetrics {
  param([object]$Result)
  if (-not $Result -or -not $Result.end) {
    throw "iperf3 测试失败：未获得有效结果。"
  }
  $summary = $Result.end.sum_received
  if (-not $summary) { $summary = $Result.end.sum_sent }
  if (-not $summary) {
    throw "iperf3 测试失败：缺少传输汇总。"
  }

  [Nullable[Int64]]$retransmits = $null
  if ($Result.end.sum_sent -and $null -ne $Result.end.sum_sent.retransmits) {
    $retransmits = [int64]$Result.end.sum_sent.retransmits
  }
  $bitsPerSecond = 0.0
  if ($summary -and $summary.bits_per_second) {
    $bitsPerSecond = [double]$summary.bits_per_second
  }
  if ($bitsPerSecond -le 0) {
    throw "iperf3 测试失败：速率为 0，请检查对端端口和链路。"
  }
  [Nullable[Double]]$firstSecondBits = $null
  if ($Result.intervals -and $Result.intervals.Count -gt 0 -and $Result.intervals[0].sum -and $null -ne $Result.intervals[0].sum.bits_per_second) {
    $firstSecondBits = [double]$Result.intervals[0].sum.bits_per_second
  }

  return [pscustomobject]@{
    BitsPerSecond = $bitsPerSecond
    FirstSecondBitsPerSecond = $firstSecondBits
    Retransmits = $retransmits
  }
}
