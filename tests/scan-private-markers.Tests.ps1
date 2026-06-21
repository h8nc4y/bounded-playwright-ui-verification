[CmdletBinding()]
param()

# Dependency-free regression tests for scan-private-markers.ps1.
# All fixtures are synthetic and written to a temp directory; no real secrets,
# private data, or network access are involved. Findings are asserted to be
# redacted (no value replay).

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scannerPath = Join-Path $repoRoot "scripts/scan-private-markers.ps1"
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bpuiv-scan-tests-" + [System.Guid]::NewGuid().ToString("N"))
$failures = New-Object System.Collections.Generic.List[string]

function New-FixtureFile {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $fullPath = Join-Path $fixtureRoot $RelativePath
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
  Set-Content -LiteralPath $fullPath -Value $Content -Encoding utf8
}

function Invoke-Scanner {
  $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $scannerPath -Root $fixtureRoot 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = ($output | Out-String)
  }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected' but got '$Actual'."
  }
}

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) {
    throw "$Message Missing '$Needle'. Output: $Text"
  }
}

function Assert-NotContains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if ($Text.Contains($Needle)) {
    throw "$Message Unexpected '$Needle'. Output: $Text"
  }
}

function Invoke-Test {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Body
  )

  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
  try {
    & $Body
    Write-Host "PASS $Name"
  } catch {
    $script:failures.Add("${Name}: $($_.Exception.Message)") | Out-Null
    Write-Host "FAIL $Name"
    Write-Host $_.Exception.Message
  }
}

# Each detected-secret case builds the marker from split fragments so this test
# file itself does not carry a verbatim secret-shaped value.
$detectCases = @(
  @{ Name = "AWS access key id"; Type = "AWS access key id"; Value = ("AKIA" + "ABCDEFGHIJKLMNOP") },
  @{ Name = "Google API key"; Type = "Google API key"; Value = ("AIza" + "0123456789012345678901234567890ABCD") },
  @{ Name = "Slack user token"; Type = "Slack token (user/app/legacy)"; Value = ("xo" + "xp-1234567890-ABCDEFGH") },
  @{ Name = "Slack app-level token"; Type = "Slack app-level token"; Value = ("xa" + "pp-1-ABCDEFGH-1234567890") },
  @{ Name = "Stripe live secret key"; Type = "Stripe live secret key"; Value = ("sk" + "_live_0123456789ABCDEFGH") },
  @{ Name = "PEM RSA private key"; Type = "PEM private key block"; Value = ("-----BEGIN " + "RSA PRIVATE KEY-----") },
  @{ Name = "Bearer token with value"; Type = "Bearer token"; Value = ("Bearer " + "abcdef0123456789") }
)

try {
  foreach ($case in $detectCases) {
    $localCase = $case
    Invoke-Test "detects and redacts: $($localCase.Name)" {
      New-FixtureFile -RelativePath "docs/sample.md" -Content "leaked value: $($localCase.Value)"
      $result = Invoke-Scanner
      Assert-Equal -Actual $result.ExitCode -Expected 1 -Message "Marker '$($localCase.Name)' should fail the scan."
      Assert-Contains -Text $result.Output -Needle $localCase.Type -Message "Finding should name the '$($localCase.Type)' rule."
      Assert-Contains -Text $result.Output -Needle "<redacted>" -Message "Finding should be redacted."
      Assert-NotContains -Text $result.Output -Needle $localCase.Value -Message "Finding output must not replay the value."
    }
  }

  Invoke-Test "passes a safe synthetic fixture" {
    $ownRepoUrl = "https://github.com/h8nc4y/bounded-playwright-ui-verification"
    New-FixtureFile -RelativePath "README.md" -Content @"
# Safe fixture

Clone: $ownRepoUrl

Synthetic examples only.
"@
    $result = Invoke-Scanner
    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Safe fixture should pass."
    Assert-Contains -Text $result.Output -Needle "passed" -Message "Passing scan should report success."
  }

  Invoke-Test "does not flag prose mention of a Bearer token (false-positive guard)" {
    New-FixtureFile -RelativePath "docs/guidance.md" -Content "Never send a Bearer token to an external service."
    $result = Invoke-Scanner
    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Bearer prose without a value should pass."
  }

  Invoke-Test "does not flag reserved example.com email (false-positive guard)" {
    New-FixtureFile -RelativePath "docs/contact.md" -Content "Contact support@example.com for help."
    $result = Invoke-Scanner
    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "Reserved example.com email should pass."
  }

  Invoke-Test "flags marker-like values even on a scanner-named line (no blanket exempt)" {
    # A real secret shape written next to the literal "scanner-marker" comment
    # must still be detected: the previous blanket line exemption is gone.
    $marker = ("AKIA" + "ZZZZZZZZZZZZZZZZ")
    New-FixtureFile -RelativePath "scripts/note.ps1" -Content "`$fixture = '$marker' # scanner-marker"
    $result = Invoke-Scanner
    Assert-Equal -Actual $result.ExitCode -Expected 1 -Message "A scanner-marker line must not exempt real secrets."
    Assert-Contains -Text $result.Output -Needle "AWS access key id" -Message "Finding should name the AWS rule."
    Assert-NotContains -Text $result.Output -Needle $marker -Message "Finding output must not replay the value."
  }
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Test failures:"
  foreach ($failure in $failures) {
    Write-Host "- $failure"
  }
  exit 1
}

Write-Host ""
Write-Host "All scan-private-markers tests passed."
exit 0
