param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("client", "join", "status")]
  [string]$Command,

  [string]$Peer,
  [string]$Token,
  [int]$IperfPort = 5201,
  [string]$Objective = "retrans",
  [int]$TargetRetr = 0,
  [int]$Rounds = 5,
  [ValidateSet("download", "upload")]
  [string]$Direction = "download",
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/10000ge10000/TCP-optimization"

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
  throw "Missing command: iperf3. No supported Windows package manager found. Install winget, choco, scoop, or place iperf3.exe in PATH."
}

function Ensure-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    if ($Name -eq "iperf3" -and $Yes) {
      Install-Iperf3
    }
  }
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $Name. Install iperf3 for Windows and make sure iperf3.exe is in PATH."
  }
}

function Invoke-AgentPost {
  param(
    [string]$Url,
    [string]$TokenValue,
    [object]$Body
  )
  $json = $Body | ConvertTo-Json -Depth 6
  $headers = @{
    "X-TCP-Tune-Token" = $TokenValue
  }
  Invoke-RestMethod -Method Post -Uri $Url -Headers $headers -ContentType "application/json" -Body $json
}

function Get-PeerHost {
  param([string]$Url)
  $uri = [Uri]$Url
  return $uri.Host
}

function Run-Iperf {
  param(
    [string]$HostName,
    [int]$Port,
    [switch]$Reverse
  )
  $args = @("-c", $HostName, "-p", "$Port", "-t", "15", "-J")
  if ($Reverse) {
    $args += "-R"
  }
  $raw = & iperf3 @args
  if ($LASTEXITCODE -ne 0) {
    throw "iperf3 test failed."
  }
  return ($raw | Out-String | ConvertFrom-Json)
}

function Invoke-ClientMenu {
  param(
    [string]$PeerUrl,
    [string]$TokenValue,
    [string]$HostName,
    [int]$Port
  )
  while ($true) {
    Write-Host ""
    Write-Host "Windows client menu"
    Write-Host "1. Local status"
    Write-Host "2. Download test (server -> this PC)"
    Write-Host "3. Upload test (this PC -> server)"
    Write-Host "4. Server status"
    Write-Host "5. Server events"
    Write-Host "6. Stop server session and exit"
    Write-Host "0. Exit client"
    $choice = Read-Host "Select"
    switch ($choice) {
      "1" {
        & $PSCommandPath status
      }
      "2" {
        $result = Run-Iperf -HostName $HostName -Port $Port -Reverse
        $sum = $result.end.sum_received
        $retrans = 0
        if ($result.end.sum_sent -and $null -ne $result.end.sum_sent.retransmits) {
          $retrans = [int]$result.end.sum_sent.retransmits
        }
        Write-Host "[INFO] Retr=$retrans bits_per_second=$($sum.bits_per_second)"
      }
      "3" {
        $result = Run-Iperf -HostName $HostName -Port $Port
        $sum = $result.end.sum_received
        if (-not $sum) { $sum = $result.end.sum_sent }
        $retrans = 0
        if ($result.end.sum_sent -and $null -ne $result.end.sum_sent.retransmits) {
          $retrans = [int]$result.end.sum_sent.retransmits
        }
        Write-Host "[INFO] Retr=$retrans bits_per_second=$($sum.bits_per_second)"
      }
      "4" {
        Invoke-RestMethod -Method Get -Uri "$PeerUrl/status" -Headers @{ "X-TCP-Tune-Token" = $TokenValue } | ConvertTo-Json -Depth 8
      }
      "5" {
        Invoke-RestMethod -Method Get -Uri "$PeerUrl/events" -Headers @{ "X-TCP-Tune-Token" = $TokenValue } | ConvertTo-Json -Depth 8
      }
      "6" {
        Invoke-AgentPost -Url "$PeerUrl/stop" -TokenValue $TokenValue -Body ([pscustomobject]@{}) | Out-Null
        return
      }
      "0" { return }
      default { Write-Host "Invalid selection." }
    }
  }
}

if ($Command -eq "status") {
  [pscustomobject]@{
    App = "TCP Tune Windows Client"
    Repo = $RepoUrl
    OS = [System.Environment]::OSVersion.VersionString
    Architecture = $env:PROCESSOR_ARCHITECTURE
    HasIperf3 = [bool](Get-Command iperf3 -ErrorAction SilentlyContinue)
    HasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    HasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    HasScoop = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
  } | ConvertTo-Json -Depth 4
  exit 0
}

if ($Command -eq "join" -or $Command -eq "client") {
  if (-not $Peer) { throw "$Command requires -Peer http://IP:PORT" }
  if (-not $Token) { throw "$Command requires -Token" }

  Ensure-Command -Name "iperf3"

  $report = [pscustomobject]@{
    role = "windows-client"
    os = [System.Environment]::OSVersion.VersionString
    architecture = $env:PROCESSOR_ARCHITECTURE
    objective = $Objective
    target_retr = $TargetRetr
    time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
  Invoke-AgentPost -Url "$Peer/report" -TokenValue $Token -Body $report | Out-Null

  $hostName = Get-PeerHost -Url $Peer
  if ($Command -eq "client") {
    Write-Host "[INFO] Connected to server: $Peer"
    Write-Host "[INFO] Windows client does not change the Windows TCP stack automatically."
    if ([Environment]::UserInteractive) {
      Invoke-ClientMenu -PeerUrl $Peer -TokenValue $Token -HostName $hostName -Port $IperfPort
    }
    exit 0
  }

  for ($i = 1; $i -le $Rounds; $i++) {
    Write-Host "[INFO] Round $i Windows iperf3 test: ${hostName}:$IperfPort"
    $reverse = $Direction -eq "download"
    $result = Run-Iperf -HostName $hostName -Port $IperfPort -Reverse:$reverse
    $sum = $result.end.sum_received
    if (-not $sum) {
      $sum = $result.end.sum_sent
    }
    $retrans = 0
    if ($result.end.sum_sent -and $null -ne $result.end.sum_sent.retransmits) {
      $retrans = [int]$result.end.sum_sent.retransmits
    }
    $bps = 0
    if ($sum -and $sum.bits_per_second) {
      $bps = [double]$sum.bits_per_second
    }
    Write-Host "[INFO] Retr=$retrans bits_per_second=$bps"

    Invoke-AgentPost -Url "$Peer/report" -TokenValue $Token -Body ([pscustomobject]@{
      role = "windows-client"
      round = $i
      retransmits = $retrans
      bits_per_second = $bps
      objective = $Objective
      time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }) | Out-Null

    if ($Objective -eq "retrans" -and $retrans -le $TargetRetr) {
      Write-Host ("[INFO] Retransmit target reached: {0} <= {1}" -f $retrans, $TargetRetr)
      break
    }
  }

  Write-Host "[INFO] Windows client does not change the Windows TCP stack automatically."
}
