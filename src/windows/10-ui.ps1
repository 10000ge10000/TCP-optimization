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

function Write-Host {
  param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
    [ConsoleColor]$ForegroundColor,
    [switch]$NoNewline
  )
  $parameters = @{ Object = $Object; NoNewline = $NoNewline }
  if ($script:UseColor -and $PSBoundParameters.ContainsKey("ForegroundColor")) { $parameters.ForegroundColor = $ForegroundColor }
  Microsoft.PowerShell.Utility\Write-Host @parameters
}

function Write-Rule {
  Write-Host ("━" * 58) -ForegroundColor Cyan
}

function Write-Header {
  param([string]$Title)
  if (-not $script:IsNonInteractive) { Clear-Host }
  Write-Host ""
  Write-Host "  $Title" -ForegroundColor Cyan
  Write-Rule
}

function Write-KeyValue {
  param([string]$Label, [string]$Value)
  $padded = Format-Pad -Text $Label -Width 12
  $Value = Format-DisplayText -Text $Value
  Write-Host "  $padded  $Value"
}

function Write-PanelRule {
  Write-Host ("─" * 58) -ForegroundColor DarkGray
}

function Write-PanelRow {
  param([string]$Label, [string]$Value)
  $padded = Format-Pad -Text $Label -Width 12
  $Value = Format-DisplayText -Text $Value
  Write-Host "  $padded  $Value"
}

function Write-Section {
  param([string]$Title)
  Write-Host "  ▎ $Title" -ForegroundColor Cyan
}

function Write-Note {
  param([string]$Label, [string]$Text)
  $padded = Format-Pad -Text $Label -Width 12
  $Text = Format-DisplayText -Text $Text
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

function Test-BackChoice {
  param([string]$Value)
  return $Value -in @("0", "q", "Q", "b", "B")
}

function Write-BackMenuItem {
  Write-MenuItem "0" "返回主菜单" "不执行本页操作" "DarkGray"
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

function Format-DisplayText {
  param([string]$Text, [int]$MaxWidth = 58)
  if (-not $Text) { return "" }
  try {
    if ($Host.UI.RawUI.WindowSize.Width -ge 90) { return $Text }
  } catch {
    return $Text
  }
  if ($Text.Length -le $MaxWidth) { return $Text }
  return $Text.Substring(0, [Math]::Max(0, $MaxWidth - 3)) + "..."
}

function Get-PercentDelta {
  param([Nullable[Double]]$Before, [Nullable[Double]]$After)
  if ($null -eq $Before -or $null -eq $After) { return "未检测" }
  if ($Before -le 0) { return "建立基线" }
  $delta = (($After - $Before) * 100.0) / $Before
  if ($delta -gt 0) { return ("+{0:N0}%" -f $delta) }
  return ("{0:N0}%" -f $delta)
}

function Get-TrendLabel {
  param([Nullable[Int64]]$Current, [Nullable[Int64]]$Previous)
  if ($null -eq $Current) { return "未检测" }
  if ($null -eq $Previous) { return "建立基线" }
  if ($Current -lt $Previous) { return "重传下降" }
  if ($Current -gt $Previous) { return "重传上升" }
  return "保持稳定"
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

function Get-NextActionLabel {
  param([string]$ObjectiveValue, [Nullable[Int64]]$Retransmits, [Int64]$TargetRetransmits)
  if ($null -eq $Retransmits) { return "未检测到重传指标，不能据此判断。" }
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
