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
  $script:DefaultAiGatewayUrl = "https://gateway.example.invalid/v1"
  $script:DefaultAiModel = "gpt-5.5"
  $script:AiModelCandidates = @("gpt-5.5")

  . (Join-Path $script:RepoRoot "src\windows\10-ui.ps1")
  . (Join-Path $script:RepoRoot "src\windows\20-runtime.ps1")
  . (Join-Path $script:RepoRoot "src\windows\30-network.ps1")
  . (Join-Path $script:RepoRoot "src\windows\40-ai.ps1")
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

Describe "strict AI JSON" {
  It "accepts the exact schema" {
    $value = ConvertFrom-AIJson '{"action":"observe","risk":"low","reason":"stable","windows_change":"none"}'
    $value.risk | Should -Be "low"
  }

  It "rejects prose, unknown fields and invalid enums" {
    { ConvertFrom-AIJson 'result: {"action":"x","risk":"low","reason":"x","windows_change":"none"}' } | Should -Throw
    { ConvertFrom-AIJson '{"action":"x","risk":"low","reason":"x","windows_change":"none","command":"whoami"}' } | Should -Throw
    { ConvertFrom-AIJson '{"action":"x","risk":"critical","reason":"x","windows_change":"none"}' } | Should -Throw
  }
}

Describe "AI credential boundary" {
  BeforeEach {
    $script:seenHeaders = $null
    $env:NVIDIA_API_KEY = "test-nvidia-placeholder"
    $env:TCP_TUNE_AI_GATEWAY_TOKEN = $null
    $env:TCP_TUNE_AI_TIMEOUT = "5"
    Mock Invoke-RestMethod {
      param($Method, $Uri, $Headers, $Body, $TimeoutSec)
      $script:seenHeaders = $Headers
      return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = "OK" } }) }
    }
  }

  AfterEach {
    Remove-Item Env:NVIDIA_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:NVIDIA_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:TCP_TUNE_AI_GATEWAY_URL -ErrorAction SilentlyContinue
    Remove-Item Env:TCP_TUNE_AI_GATEWAY_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:TCP_TUNE_AI_TIMEOUT -ErrorAction SilentlyContinue
  }

  It "does not send NVIDIA_API_KEY to a gateway" {
    $env:TCP_TUNE_AI_GATEWAY_URL = "https://gateway.example.invalid/v1"
    Invoke-AIChat -Model "gpt-5.5" -Prompt "test" -MaxTokens 16 | Should -Be "OK"
    $script:seenHeaders.ContainsKey("Authorization") | Should -Be $false
  }

  It "uses NVIDIA_API_KEY only for the configured NVIDIA direct endpoint" {
    $env:NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1"
    $env:TCP_TUNE_AI_GATEWAY_URL = $env:NVIDIA_BASE_URL
    Invoke-AIChat -Model "gpt-5.5" -Prompt "test" -MaxTokens 16 | Should -Be "OK"
    $script:seenHeaders.Authorization | Should -Be "Bearer test-nvidia-placeholder"
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
