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
  [switch]$Yes,
  [switch]$Json,
  [switch]$NonInteractive,
  [switch]$NoColor
)

$ErrorActionPreference = "Stop"
$AppVersion = "0.2.0"
$RepoUrl = "https://github.com/10000ge10000/TCP-optimization"
$ToolRoot = Join-Path $env:LOCALAPPDATA "TCP-optimization"
$IperfCacheDir = Join-Path $ToolRoot "iperf3"
$DefaultAiGatewayUrl = "https://tcp-optimization-ai-gateway.yiwan-share.workers.dev/v1"
$DefaultAiModel = "gpt-5.5"
$AiModelCandidates = @("gpt-5.5")
$ExitSuccess = 0
$ExitArguments = 2
$ExitDependency = 3
$ExitNetwork = 4
$ExitAuthentication = 5
$ExitBenchmark = 6
$ExitAi = 8
$IperfPackage = [pscustomobject]@{
  Version = "3.18"
  Asset = "iperf-3.18-win64.zip"
  Url = "https://github.com/ar51an/iperf3-win-builds/releases/download/3.18/iperf-3.18-win64.zip"
  # 固定 GitHub Release 资产的 SHA256；升级版本时必须重新审查 ZIP 内容并更新。
  Sha256 = "8bb24166d660051ccd8946d4a8d11fca8f4987e2d83fb0300105cadb570774a9"
}
$script:UseColor = -not ($NoColor -or $env:NO_COLOR)
$script:IsNonInteractive = [bool]($NonInteractive -or -not [Environment]::UserInteractive)
if ($PSVersionTable.PSVersion.Major -ge 7 -and -not $script:UseColor) { $PSStyle.OutputRendering = "PlainText" }

# 显示宽度感知的 padding：中文字符占 2 列，ASCII 占 1 列
