BeforeAll {
  $ErrorActionPreference = "Stop"
  $script:RepoRoot = (Get-Location).Path
  $script:ToolRoot = Join-Path ([IO.Path]::GetTempPath()) ("tcp-tune-test-" + [guid]::NewGuid().ToString("N"))
  $script:IperfCacheDir = Join-Path $script:ToolRoot "iperf3"
  $script:IperfPackage = [pscustomobject]@{
    Version = "3.18"
    Asset = "iperf-3.18-win64.zip"
    Url = "https://example.invalid/iperf-3.18-win64.zip"
    Sha256 = ""
  }
  . (Join-Path $script:RepoRoot "src\windows\10-ui.ps1")
  . (Join-Path $script:RepoRoot "src\windows\20-runtime.ps1")
  . (Join-Path $script:RepoRoot "src\windows\30-network.ps1")
}

Describe "Windows input validation" {
  It "accepts an IPv6 literal" {
    Test-IperfHost -HostName "2001:db8::1" | Should -Be $true
  }

  It "rejects option-like hosts" {
    { Test-IperfHost -HostName "--help" } | Should -Throw
  }

  It "rejects Peer credentials, query and endpoint paths" {
    { Test-PeerUri -Url "http://user:pass@example.test:39188/" } | Should -Throw
    { Test-PeerUri -Url "http://example.test:39188/?token=secret" } | Should -Throw
    { Test-PeerUri -Url "http://example.test:39188/status" } | Should -Throw
  }
}

Describe "iperf3 JSON compatibility" {
  It "does not bind an IPv4 local address to an IPv6 target" {
    $script:capturedIperfArguments = $null
    Mock Invoke-IperfProcess {
      param($Arguments, $TimeoutSeconds)
      $script:capturedIperfArguments = $Arguments
      return '{"end":{"sum_received":{"bits_per_second":1000000}},"intervals":[]}'
    }

    Run-Iperf -HostName "2001:db8::1" -Port 5201 -LocalAddress "192.0.2.10" | Out-Null

    $script:capturedIperfArguments | Should -Not -Contain "-B"
    $script:capturedIperfArguments | Should -Not -Contain "192.0.2.10"
  }

  It "binds only parseable local addresses of the matching target family" {
    Test-IperfBindCompatible -HostName "2001:db8::1" -LocalAddress "2001:db8::2" | Should -BeTrue
    Test-IperfBindCompatible -HostName "192.0.2.1" -LocalAddress "192.0.2.10" | Should -BeTrue
    Test-IperfBindCompatible -HostName "192.0.2.1" -LocalAddress "2001:db8::2" | Should -BeFalse
    Test-IperfBindCompatible -HostName "example.test" -LocalAddress "192.0.2.10" | Should -BeTrue
    Test-IperfBindCompatible -HostName "example.test" -LocalAddress "not-an-ip" | Should -BeFalse
  }

  It "keeps missing retransmits and first-second metrics nullable" {
    $fixture = [pscustomobject]@{
      end = [pscustomobject]@{ sum_received = [pscustomobject]@{ bits_per_second = 1000000 } }
      intervals = @()
    }
    $metrics = Get-IperfMetrics -Result $fixture
    $metrics.BitsPerSecond | Should -Be 1000000
    $metrics.Retransmits | Should -BeNullOrEmpty
    $metrics.FirstSecondBitsPerSecond | Should -BeNullOrEmpty
  }

  It "does not treat missing retransmits and first-second metrics as real zeroes" {
    $missingFixture = [pscustomobject]@{
      end = [pscustomobject]@{ sum_received = [pscustomobject]@{ bits_per_second = 1000000 } }
      intervals = @()
    }
    $zeroFixture = [pscustomobject]@{
      end = [pscustomobject]@{
        sum_received = [pscustomobject]@{ bits_per_second = 1000000 }
        sum_sent = [pscustomobject]@{ retransmits = 0 }
      }
      intervals = @([pscustomobject]@{ sum = [pscustomobject]@{ bits_per_second = 0 } })
    }

    $missing = Get-IperfMetrics -Result $missingFixture
    $zero = Get-IperfMetrics -Result $zeroFixture

    $unknownText = -join ([char]0x672A, [char]0x68C0, [char]0x6D4B)
    $zeroCountText = "0 " + [char]0x6B21

    Format-Retransmits $missing.Retransmits | Should -Be $unknownText
    Get-RetransmitsColor $missing.Retransmits | Should -Be "DarkGray"
    Test-RetransmitsAtOrBelowTarget $missing.Retransmits 0 | Should -BeFalse
    Format-Rate $missing.FirstSecondBitsPerSecond | Should -Be $unknownText

    Format-Retransmits $zero.Retransmits | Should -Be $zeroCountText
    Get-RetransmitsColor $zero.Retransmits | Should -Be "Green"
    Test-RetransmitsAtOrBelowTarget $zero.Retransmits 0 | Should -BeTrue
    $zero.FirstSecondBitsPerSecond | Should -Be 0
    Format-Rate $zero.FirstSecondBitsPerSecond | Should -Be "0.0 Mbps"
  }
}

Describe "cross-module function references" {
  It "resolves every custom function referenced by any module" {
    # Regression guard for the 40-ai.ps1 removal incident: calls into a deleted
    # module only fail at runtime, so enumerate every CommandAst statically and
    # require each name to resolve.
    $moduleNames = @("00-entry.ps1", "10-ui.ps1", "20-runtime.ps1", "30-network.ps1", "50-cli.ps1")
    $moduleFiles = $moduleNames | ForEach-Object { Join-Path $script:RepoRoot "src\windows\$_" }
    $defined = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $asts = @{}
    foreach ($file in $moduleFiles) {
      $tokens = $null; $parseErrors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
      $parseErrors | Should -BeNullOrEmpty
      $asts[$file] = $ast
      foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        [void]$defined.Add($fn.Name)
      }
    }
    $externalAllowlist = @("iperf3")
    $unresolved = [Collections.Generic.List[string]]::new()
    foreach ($file in $moduleFiles) {
      $calls = $asts[$file].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
      foreach ($call in $calls) {
        $name = $call.GetCommandName()
        if (-not $name) { continue }
        if ($defined.Contains($name)) { continue }
        if ($externalAllowlist -contains $name) { continue }
        if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
        $unresolved.Add(("{0} -> {1}" -f (Split-Path -Leaf $file), $name))
      }
    }
    ($unresolved | Sort-Object -Unique) | Should -BeNullOrEmpty
  }
}

Describe "iperf3 installer safety" {
  It "pins the reviewed 3.18 archive hash" {
    $entrySource = Get-Content -LiteralPath (Join-Path $script:RepoRoot "src\windows\00-entry.ps1") -Raw
    $entrySource | Should -Match '8bb24166d660051ccd8946d4a8d11fca8f4987e2d83fb0300105cadb570774a9'
  }

  It "fails closed when the release hash is not verified" {
    { Install-Iperf3 } | Should -Throw
  }

  It "rejects ZipSlip entries" {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $TestDrive "evil.zip"
    $stream = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    [void]$archive.CreateEntry("../escape.txt")
    $archive.Dispose()
    $stream.Dispose()
    $destination = Join-Path $TestDrive "extract"
    New-Item -ItemType Directory -Path $destination | Out-Null
    { Expand-SafeZip -ZipPath $zip -DestinationPath $destination } | Should -Throw
  }
}
