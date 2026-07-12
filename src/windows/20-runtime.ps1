function Install-Iperf3 {
  if (-not $IperfPackage.Sha256 -or $IperfPackage.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
    throw "自动安装已安全停止：iperf3 $($IperfPackage.Version) 的发布 SHA256 尚未由维护者确认。请手动安装可信版本并加入 PATH。"
  }
  New-Item -ItemType Directory -Force -Path $IperfCacheDir | Out-Null
  $staging = Join-Path $IperfCacheDir ("staging-" + [guid]::NewGuid().ToString("N"))
  $zipPath = Join-Path $staging $IperfPackage.Asset
  $extractPath = Join-Path $staging "extract"
  try {
    New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
    try {
      Invoke-WebRequest -Uri $IperfPackage.Url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
    } catch {
      $message = $_.Exception.Message
      if ($message -match '407|proxy') { throw "iperf3 下载失败：代理认证失败（HTTP 407）。请检查系统代理。" }
      if ($message -match '403|429') { throw "iperf3 下载被上游拒绝或限流。请稍后重试或手动安装固定版本 $($IperfPackage.Version)。" }
      throw "iperf3 下载失败：$message"
    }
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne $IperfPackage.Sha256) { throw "iperf3 SHA256 校验失败，安装已取消。" }
    Expand-SafeZip -ZipPath $zipPath -DestinationPath $extractPath
    $executables = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter iperf3.exe)
    if ($executables.Count -ne 1) { throw "压缩包必须且只能包含一个 iperf3.exe。" }
    $versionText = (& $executables[0].FullName --version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch [regex]::Escape($IperfPackage.Version)) { throw "iperf3 版本验证失败。" }
    $target = Join-Path $IperfCacheDir $IperfPackage.Version
    $oldTarget = $null
    if (Test-Path -LiteralPath $target) {
      $oldTarget = Join-Path $IperfCacheDir ("previous-" + [guid]::NewGuid().ToString("N"))
      Move-Item -LiteralPath $target -Destination $oldTarget
    }
    try {
      Move-Item -LiteralPath $extractPath -Destination $target
      [IO.File]::WriteAllText((Join-Path $target ".tcp-tune-sha256"), $IperfPackage.Sha256, [Text.UTF8Encoding]::new($false))
    } catch {
      if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
      if ($oldTarget -and (Test-Path -LiteralPath $oldTarget)) { Move-Item -LiteralPath $oldTarget -Destination $target }
      throw
    }
    if ($oldTarget -and (Test-Path -LiteralPath $oldTarget)) { Remove-Item -LiteralPath $oldTarget -Recurse -Force }
    $exe = Get-ChildItem -LiteralPath $target -Recurse -File -Filter iperf3.exe | Select-Object -First 1
    $env:PATH = "$($exe.Directory.FullName);$env:PATH"
    Write-Host "iperf3 已安装到用户缓存：$($exe.FullName)" -ForegroundColor Green
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  }
}

function Expand-SafeZip {
  param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$DestinationPath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $root = [IO.Path]::GetFullPath($DestinationPath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    foreach ($entry in $archive.Entries) {
      if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
      $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
      $dosAttributes = ($entry.ExternalAttributes -band 0xFFFF)
      if ($unixType -eq 0xA000 -or ($dosAttributes -band 0x400)) { throw "压缩包包含链接或重解析点。" }
      if ($entry.FullName.IndexOf([char]0) -ge 0 -or $entry.FullName -match '^[\\/]|^[A-Za-z]:|(^|[\\/])\.\.([\\/]|$)') {
        throw "压缩包包含不安全路径：$($entry.FullName)"
      }
      $target = [IO.Path]::GetFullPath((Join-Path $DestinationPath $entry.FullName))
      if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "压缩包路径越界。" }
    }
  } finally { $archive.Dispose() }
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestinationPath -Force
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
