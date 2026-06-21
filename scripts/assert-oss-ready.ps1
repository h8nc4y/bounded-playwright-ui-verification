param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "private-scan-config.ps1")

$repoRoot = Resolve-Path -LiteralPath $Root
$errors = New-Object System.Collections.Generic.List[string]
$unverifiedMarker = ([string]([char]0x672A)) + ([string]([char]0x78BA)) + ([string]([char]0x8A8D))

function Add-Error {
  param([string]$Message)
  $errors.Add($Message) | Out-Null
}

function Get-RepoPath {
  param([string]$RelativePath)

  $path = $repoRoot.Path
  foreach ($part in ($RelativePath -split "[\\/]")) {
    if ($part.Length -gt 0) {
      $path = Join-Path $path $part
    }
  }
  return $path
}

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

function Get-RepoText {
  param([string]$RelativePath)
  return Get-Content -LiteralPath (Get-RepoPath $RelativePath) -Raw -Encoding UTF8
}

$requiredFiles = @(
  "SKILL.md",
  "README.md",
  "LICENSE",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "SECURITY.md",
  "CODE_OF_CONDUCT.md",
  "SUPPORT.md",
  ".editorconfig",
  ".gitattributes",
  ".github/workflows/ci.yml",
  ".github/ISSUE_TEMPLATE/bug_report.yml",
  ".github/ISSUE_TEMPLATE/feature_request.yml",
  ".github/ISSUE_TEMPLATE/config.yml",
  ".github/pull_request_template.md",
  "docs/release-checklist.md",
  "examples/final-report-template.md",
  "examples/server-runbook.md",
  "examples/ui-verification-checklist.md",
  "scripts/assert-oss-ready.ps1",
  "scripts/scan-private-markers.ps1"
)

foreach ($relativePath in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Get-RepoPath $relativePath) -PathType Leaf)) {
    Add-Error "Missing required file: $relativePath"
  }
}

if (Test-Path -LiteralPath (Get-RepoPath "SKILL.md") -PathType Leaf) {
  $skill = Get-RepoText "SKILL.md"
  if (-not $skill.StartsWith("---")) {
    Add-Error "SKILL.md must start with YAML front matter."
  }
  if ($skill -notmatch "(?m)^name:\s*bounded-playwright-ui-verification\s*$") {
    Add-Error "SKILL.md must declare the expected skill name."
  }
  if ($skill -notmatch "(?m)^description:\s*.{80,}$") {
    Add-Error "SKILL.md must include a specific description in front matter."
  }

  foreach ($requiredSection in @(
    "Bounded Server Rule",
    "Minimum Viewports",
    "Checks To Perform",
    "Report Format",
    "Stop Conditions"
  )) {
    if (-not $skill.Contains($requiredSection)) {
      Add-Error "SKILL.md is missing section: $requiredSection"
    }
  }

  if (-not $skill.Contains($unverifiedMarker)) {
    Add-Error "SKILL.md must explicitly name the unverified marker."
  }
}

if (Test-Path -LiteralPath (Get-RepoPath "README.md") -PathType Leaf) {
  $readme = Get-RepoText "README.md"
  foreach ($requiredSection in @(
    "## Install",
    "## Manual Use",
    "## Validation And Scan",
    "## Contributing",
    "## Security",
    "## License"
  )) {
    if (-not $readme.Contains($requiredSection)) {
      Add-Error "README.md is missing section: $requiredSection"
    }
  }
}

# Single source of truth shared with scan-private-markers.ps1 (review S-1).
$excludedDirectories = Get-PrivateScanExcludedDirectories

$mojibakeMarkers = @(
  [char]0x8B5B,
  [char]0x9052,
  [char]0x96B1,
  [char]0xFFFD
)

$placeholderWords = @(
  ("TB" + "D"),
  ("TO" + "DO"),
  ("FIX" + "ME")
)

$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object {
  $relative = Get-RelativePath -BasePath $repoRoot.Path -TargetPath $_.FullName
  $parts = $relative -split "[\\/]"
  -not ($parts | Where-Object { $excludedDirectories -contains $_ })
}

foreach ($file in $files) {
  $relativePath = Get-RelativePath -BasePath $repoRoot.Path -TargetPath $file.FullName
  # Force an array so single-line files are not indexed character-by-character.
  $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $lineNumber = $i + 1

    foreach ($marker in $mojibakeMarkers) {
      if ($line.Contains($marker)) {
        Add-Error "Mojibake or replacement character found: ${relativePath}:$lineNumber"
      }
    }

    foreach ($word in $placeholderWords) {
      if ($line -match "\b$word\b") {
        Add-Error "Placeholder marker '$word' found: ${relativePath}:$lineNumber"
      }
    }
  }
}

$markdownFiles = $files | Where-Object { $_.Extension -in @(".md", ".markdown") }
$linkRegex = [regex]"(?<!!)\[[^\]]+\]\((?<target>[^)]+)\)"

foreach ($file in $markdownFiles) {
  $relativePath = Get-RelativePath -BasePath $repoRoot.Path -TargetPath $file.FullName
  $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  foreach ($match in $linkRegex.Matches($content)) {
    $target = $match.Groups["target"].Value.Trim()
    if ($target -match "^(https?|mailto):" -or $target.StartsWith("#")) {
      continue
    }

    $withoutAnchor = ($target -split "#", 2)[0]
    if ([string]::IsNullOrWhiteSpace($withoutAnchor)) {
      continue
    }

    $decodedTarget = [Uri]::UnescapeDataString($withoutAnchor)
    $targetPath = Join-Path $file.DirectoryName $decodedTarget
    if (-not (Test-Path -LiteralPath $targetPath)) {
      Add-Error "Broken markdown link in ${relativePath}: $target"
    }
  }
}

if ($errors.Count -gt 0) {
  Write-Output "OSS readiness check failed:"
  foreach ($errorItem in $errors) {
    Write-Output "- $errorItem"
  }
  exit 1
}

Write-Output "OSS readiness check passed."
