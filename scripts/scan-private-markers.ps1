param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "private-scan-config.ps1")

$allowlistedRepoUrls = @(
  "https://github.com/h8nc4y/bounded-playwright-ui-verification",
  "https://github.com/h8nc4y/bounded-playwright-ui-verification.git"
)

$scanRoot = Resolve-Path -LiteralPath $Root
$findings = New-Object System.Collections.Generic.List[object]

$excludedDirectories = Get-PrivateScanExcludedDirectories

# Literal markers. Private-path / private-repo patterns are assembled from split
# string fragments so the scanner source never contains the literal value
# verbatim. That removes the need for a blanket self-exemption: real secrets are
# detected anywhere (including in this file), while these rule definitions do not
# trip their own rules. (Review drift item: align with 020 no-blanket-exempt.)
$literalMarkers = @(
  @{ Name = "OpenAI API key prefix"; Value = ("s" + "k-") },
  @{ Name = "GitHub classic token prefix"; Value = ("g" + "hp_") },
  @{ Name = "GitHub fine-grained token prefix"; Value = ("github" + "_pat_") },
  @{ Name = "Slack bot token prefix"; Value = ("xo" + "xb-") },
  @{ Name = "Private key block"; Value = ("BEGIN " + "PRIVATE KEY") },
  @{ Name = "Private inventory repo"; Value = ("h8nc4y" + "/codex-global-context") },
  @{ Name = "Private Windows project root"; Value = ("D:" + "\Agent\Codex\Projects") },
  @{ Name = "Private Windows user root"; Value = ("C:" + "\Users\h8nc4") }
)

# Regex markers. Prefixes that benefit from a length/charset shape, plus secret
# formats added in the hardening pass (AWS / GCP / Slack variants / Stripe / PEM).
$regexMarkers = @(
  @{ Name = "AWS access key id"; Pattern = [regex]'AKIA[0-9A-Z]{16}' },
  @{ Name = "Google API key"; Pattern = [regex]'AIza[0-9A-Za-z_\-]{35}' },
  @{ Name = "Slack token (user/app/legacy)"; Pattern = [regex]'xox[apbr]-[0-9A-Za-z-]{8,}' },
  @{ Name = "Slack app-level token"; Pattern = [regex]'xapp-[0-9A-Za-z-]{8,}' },
  @{ Name = "Stripe live secret key"; Pattern = [regex]'(?:sk|rk)_live_[0-9A-Za-z]{16,}' },
  @{ Name = "PEM private key block"; Pattern = [regex]'BEGIN (?:RSA|EC|DSA|OPENSSH|ENCRYPTED) PRIVATE KEY' },
  # Bearer only matches when an actual token value follows, so prose such as
  # "send a Bearer token" no longer trips it (review M-1).
  @{ Name = "Bearer token"; Pattern = [regex]'Bearer [A-Za-z0-9._\-]{8,}' }
)

# Email: require a word/whitespace boundary on both sides and skip reserved
# example domains and npm-style scope fragments to cut false positives (M-2).
$emailRegex = [regex]'(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}(?![A-Z0-9.\-])'
$emailAllowlistDomains = @(
  "EXAMPLE.COM",
  "EXAMPLE.ORG",
  "EXAMPLE.NET"
)
$windowsPathRegex = [regex]'(?<![A-Za-z0-9_])[A-Za-z]:\\[^\s"''<>|]+'
$githubRepoUrlRegex = [regex]'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'

function Get-RelativePath {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
  $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)

  if (-not $baseFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $baseFullPath += [System.IO.Path]::DirectorySeparatorChar
  }

  $baseUri = New-Object System.Uri($baseFullPath)
  $targetUri = New-Object System.Uri($targetFullPath)
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

function Add-Finding {
  param(
    [string]$Path,
    [int]$LineNumber,
    [string]$Type,
    [string]$Detail
  )

  $findings.Add([pscustomobject]@{
    Path = $Path
    Line = $LineNumber
    Type = $Type
    Detail = $Detail
  }) | Out-Null
}

function Test-EmailAllowlisted {
  param([string]$UpperEmail)

  foreach ($domain in $emailAllowlistDomains) {
    if ($UpperEmail.EndsWith("@" + $domain) -or $UpperEmail.EndsWith("." + $domain)) {
      return $true
    }
  }
  return $false
}

$files = Get-ChildItem -LiteralPath $scanRoot -Recurse -File -Force | Where-Object {
  $relative = Get-RelativePath -BasePath $scanRoot.Path -TargetPath $_.FullName
  $parts = $relative -split '[\\/]'
  -not ($parts | Where-Object { $excludedDirectories -contains $_ })
}

foreach ($file in $files) {
  $relativePath = Get-RelativePath -BasePath $scanRoot.Path -TargetPath $file.FullName
  # Force an array so single-line files are not indexed character-by-character.
  $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $lineNumber = $i + 1

    foreach ($marker in $literalMarkers) {
      if ($line.Contains($marker.Value)) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type $marker.Name -Detail "<redacted>"
      }
    }

    foreach ($marker in $regexMarkers) {
      if ($marker.Pattern.IsMatch($line)) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type $marker.Name -Detail "<redacted>"
      }
    }

    foreach ($match in $githubRepoUrlRegex.Matches($line)) {
      if ($allowlistedRepoUrls -notcontains $match.Value) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Non-allowlisted GitHub repo URL" -Detail "<redacted>"
      }
    }

    $upperLine = $line.ToUpperInvariant()
    foreach ($match in $emailRegex.Matches($upperLine)) {
      if (-not (Test-EmailAllowlisted -UpperEmail $match.Value)) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Email address" -Detail "<redacted>"
      }
    }

    foreach ($match in $windowsPathRegex.Matches($line)) {
      Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Windows absolute path" -Detail "<redacted>"
    }
  }
}

if ($findings.Count -gt 0) {
  Write-Output "Private marker scan failed (values redacted):"
  $findings | Sort-Object Path, Line, Type | Format-Table -AutoSize
  exit 1
}

Write-Output "Private marker scan passed: no disallowed markers found."
