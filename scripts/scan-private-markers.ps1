param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$allowlistedRepoUrls = @(
  "https://github.com/h8nc4y/bounded-playwright-ui-verification",
  "https://github.com/h8nc4y/bounded-playwright-ui-verification.git"
)

$scanRoot = Resolve-Path -LiteralPath $Root
$scriptPath = $PSCommandPath
$findings = New-Object System.Collections.Generic.List[object]

$excludedDirectories = @(
  ".git",
  ".claude",
  ".codex",
  "node_modules",
  ".ui-verification",
  "playwright-report",
  "test-results",
  "coverage",
  "dist",
  "build"
)

$literalMarkers = @(
  @{ Name = "OpenAI API key prefix"; Value = "sk-" }, # scanner-marker
  @{ Name = "GitHub classic token prefix"; Value = "ghp_" }, # scanner-marker
  @{ Name = "GitHub fine-grained token prefix"; Value = "github_pat_" }, # scanner-marker
  @{ Name = "Slack bot token prefix"; Value = "xoxb-" }, # scanner-marker
  @{ Name = "Bearer token prefix"; Value = "Bearer " }, # scanner-marker
  @{ Name = "Private key block"; Value = "BEGIN PRIVATE KEY" }, # scanner-marker
  @{ Name = "Private inventory repo"; Value = "h8nc4y/codex-global-context" }, # scanner-marker
  @{ Name = "Private Windows project root"; Value = "D:\Agent\Codex\Projects" }, # scanner-marker
  @{ Name = "Private Windows user root"; Value = "C:\Users\h8nc4" } # scanner-marker
)

$emailRegex = [regex]'[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}'
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

function Test-SelfMarkerLine {
  param(
    [string]$Path,
    [string]$Line
  )

  return ($Path -eq $scriptPath -and $Line.Contains("scanner-marker"))
}

$files = Get-ChildItem -LiteralPath $scanRoot -Recurse -File -Force | Where-Object {
  $relative = Get-RelativePath -BasePath $scanRoot.Path -TargetPath $_.FullName
  $parts = $relative -split '[\\/]'
  -not ($parts | Where-Object { $excludedDirectories -contains $_ })
}

foreach ($file in $files) {
  $relativePath = Get-RelativePath -BasePath $scanRoot.Path -TargetPath $file.FullName
  $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $lineNumber = $i + 1
    $isSelfMarkerLine = Test-SelfMarkerLine -Path $file.FullName -Line $line

    foreach ($marker in $literalMarkers) {
      if (-not $isSelfMarkerLine -and $line.Contains($marker.Value)) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type $marker.Name -Detail "literal marker"
      }
    }

    foreach ($match in $githubRepoUrlRegex.Matches($line)) {
      if ($allowlistedRepoUrls -notcontains $match.Value) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Non-allowlisted GitHub repo URL" -Detail $match.Value
      }
    }

    if (-not $isSelfMarkerLine) {
      foreach ($match in $emailRegex.Matches($line.ToUpperInvariant())) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Email address" -Detail "email-like value"
      }

      foreach ($match in $windowsPathRegex.Matches($line)) {
        Add-Finding -Path $relativePath -LineNumber $lineNumber -Type "Windows absolute path" -Detail "absolute path-like value"
      }
    }
  }
}

if ($findings.Count -gt 0) {
  Write-Output "Private marker scan failed:"
  $findings | Sort-Object Path, Line, Type | Format-Table -AutoSize
  exit 1
}

Write-Output "Private marker scan passed: no disallowed markers found."
