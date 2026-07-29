param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$runtimeIsWindows = [Environment]::OSVersion.Platform -eq
  [PlatformID]::Win32NT

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

function Get-RequiredFileSha256 {
  param([string]$LiteralPath)

  # hash取得失敗をnull同士の一致として扱わず、必ず例外でfail closedにする。
  $hashResults = @(
    Microsoft.PowerShell.Utility\Get-FileHash `
      -LiteralPath $LiteralPath `
      -Algorithm SHA256 `
      -ErrorAction Stop
  )
  if ($hashResults.Count -ne 1) {
    throw "SHA-256 calculation did not return exactly one result."
  }
  $hash = [string]$hashResults[0].Hash
  if ($hash -cnotmatch '^[0-9A-F]{64}$') {
    throw "SHA-256 calculation returned an invalid digest."
  }
  return $hash
}

function Assert-FileContains {
  param(
    [string]$RelativePath,
    [string]$Pattern,
    [string]$Description
  )

  $filePath = Get-RepoPath $RelativePath
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    Add-Error "Cannot inspect missing file: $RelativePath ($Description)"
    return
  }
  $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
  if ($content -notmatch $Pattern) {
    Add-Error "$RelativePath is missing: $Description"
  }
}

function Assert-FileHasUtf8Bom {
  param([string]$RelativePath)

  $filePath = Get-RepoPath $RelativePath
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    Add-Error "Cannot inspect missing file: $RelativePath (UTF-8 BOM contract)"
    return
  }
  $bytes = [IO.File]::ReadAllBytes($filePath)
  if ($bytes.Length -lt 3 -or
    $bytes[0] -ne 0xEF -or
    $bytes[1] -ne 0xBB -or
    $bytes[2] -ne 0xBF) {
    Add-Error "$RelativePath must keep a UTF-8 BOM because Windows PowerShell 5.1 executes its Japanese comments."
  }
}

function Assert-FinalScanDeadlineContract {
  param([string]$RelativePath)

  $filePath = Get-RepoPath $RelativePath
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    Add-Error "Cannot inspect missing file: $RelativePath (final scan deadline contract)"
    return
  }
  $source = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8

  # finding payload と clean result は、stream取得・serialize後のemit直前に
  # 同じscan-wide時計を再確認する。途中のdeadline callだけでは合格させない。
  $findingWrites = [regex]::Matches(
    $source,
    '(?m)^[ \t]*\$reportStream\.Write\('
  ).Count
  $guardedFindingWrites = [regex]::Matches(
    $source,
    '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
      '[ \t]*\$reportStream\.Write\('
  ).Count
  $openStandardOutputCount = [regex]::Matches(
    $source,
    '\[Console\]::OpenStandardOutput\(\)'
  ).Count
  if ($findingWrites -ne 1 -or
    $guardedFindingWrites -ne 1 -or
    $openStandardOutputCount -ne 1) {
    Add-Error "$RelativePath must recheck the scan-wide deadline immediately before one atomic finding stdout write."
  }

  $successPattern = (
    '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
    '[ \t]*Write-Host[ \t]+' +
    '"Private marker scan passed \(scan target: \$scanMode\)\."[ \t]*$'
  )
  if ([regex]::Matches($source, $successPattern).Count -ne 1) {
    Add-Error "$RelativePath must recheck the scan-wide deadline immediately before its only success output."
  }

  # integrity失敗はraw path/valueを含めず、固定prefix＋列挙済みreasonだけを出す。
  $integrityWritePattern = (
    '(?ms)^[ \t]*\[Console\]::Out\.WriteLine\(\s*' +
    '"Private marker scan failed closed \(integrity: \$Reason\)\."\s*\)'
  )
  if ([regex]::Matches($source, $integrityWritePattern).Count -ne 1) {
    Add-Error "$RelativePath must keep one fixed redacted integrity diagnostic."
  }
}

function Assert-WorkflowExactContract {
  param([string]$RelativePath)

  $filePath = Get-RepoPath $RelativePath
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    Add-Error "Cannot inspect missing workflow file: $RelativePath"
    return
  }
  try {
    $workflowSource = [IO.File]::ReadAllText(
      $filePath,
      (New-Object Text.UTF8Encoding($false, $true))
    )
  }
  catch {
    Add-Error "$RelativePath must be valid BOM-less UTF-8."
    return
  }

  # comment/blankだけを除き、top-level trigger・permissions・jobs と
  # validate job内の全active keyを順序込みで完全一致させる。後続jobへ
  # regexが跨いで偽合格する余地を作らない。
  $actual = @(
    $workflowSource -split '\r?\n' |
      Where-Object { $_ -notmatch '^[ \t]*(?:#.*)?$' } |
      ForEach-Object { $_.TrimEnd() }
  )
  $expected = @(
    'name: CI',
    'on:',
    '  pull_request:',
    '  push:',
    '    branches:',
    '      - main',
    '  workflow_dispatch:',
    'permissions:',
    '  contents: read',
    'jobs:',
    '  validate:',
    '    name: Validate repository',
    '    runs-on: windows-latest',
    '    steps:',
    '      - name: Checkout',
    '        uses: actions/checkout@v4',
    '      - name: Scan for private markers',
    '        shell: pwsh',
    '        run: .\scripts\scan-private-markers.ps1',
    '      - name: Run scanner regression tests',
    '        shell: pwsh',
    '        run: .\tests\scan-private-markers.Tests.ps1',
    '      - name: Check OSS readiness',
    '        shell: pwsh',
    '        run: .\scripts\assert-oss-ready.ps1',
    '      - name: Check whitespace in tracked files',
    '        shell: pwsh',
    '        run: .\scripts\check-whitespace.ps1'
  )
  if ($actual.Count -ne $expected.Count) {
    Add-Error "$RelativePath active workflow shape changed (expected $($expected.Count) significant lines, found $($actual.Count))."
    return
  }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if ($actual[$index] -cne $expected[$index]) {
      Add-Error "$RelativePath active workflow shape changed at significant line $($index + 1)."
      return
    }
  }
}

# 公開exampleの名称・path・証跡カテゴリを1つのmanifestへ閉じる。
# README / SKILL / examples directoryを別々に更新してもgreenにならない形にする。
function Get-PublicExampleManifest {
  return @(
    [pscustomobject]@{
      Label = "UI verification checklist"
      Path = "examples/ui-verification-checklist.md"
      Role = "asset"
      EvidenceHeading = ""
      Categories = @()
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Final report template"
      Path = "examples/final-report-template.md"
      Role = "asset"
      EvidenceHeading = ""
      Categories = @()
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Bounded server runbook"
      Path = "examples/server-runbook.md"
      Role = "asset"
      EvidenceHeading = ""
      Categories = @()
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Bounded server executable template"
      Path = "examples/server-runbook.ps1"
      Role = "asset"
      EvidenceHeading = ""
      Categories = @()
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Evidence matrix example"
      Path = "examples/evidence-matrix.md"
      Role = "report"
      EvidenceHeading = "Evidence Matrix"
      Categories = @(
        "Server startup",
        "Health check",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Console",
        "Network",
        "Hover state",
        "Focus state",
        "Loading state",
        "Empty state",
        "Error state"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Failed verification report example"
      Path = "examples/failed-verification-report.md"
      Role = "report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Console",
        "Network",
        "Hover state",
        "Focus state",
        "Cleanup"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Protected route blocked verification report"
      Path = "examples/protected-route-report.md"
      Role = "report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Public login route",
        "Login form labels",
        "Protected route navigation",
        "Console",
        "Network",
        "Authenticated admin table",
        "Role-specific actions",
        "Cleanup"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Responsive overflow verification report"
      Path = "examples/responsive-overflow-report.md"
      Role = "report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Screenshot inspection",
        "Focus state",
        "Hover state",
        "Console",
        "Network",
        "Loading state",
        "Cleanup"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Blank render target verification report"
      Path = "examples/blank-render-target-report.md"
      Role = "report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Route load",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Render target pixel check",
        "Screenshot inspection",
        "Console",
        "Network",
        "Interaction",
        "Cleanup"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Hover and focus state verification report"
      Path = "examples/hover-focus-state-report.md"
      Role = "report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Hover state",
        "Keyboard focus",
        "Focus visibility",
        "Active/pressed state",
        "Disabled state",
        "Console",
        "Network",
        "Error state",
        "Cleanup"
      )
      StateCategories = @()
    },
    [pscustomobject]@{
      Label = "Loading, empty, and error state verification report"
      Path = "examples/loading-empty-error-state-report.md"
      Role = "state-report"
      EvidenceHeading = "Evidence Collected"
      Categories = @(
        "Server startup",
        "Health check",
        "Smartphone viewport",
        "Tablet viewport",
        "Desktop viewport",
        "Loading state",
        "Empty state",
        "Error state",
        "Screenshot inspection",
        "Console",
        "Network",
        "Retry interaction",
        "Cleanup"
      )
      StateCategories = @(
        "Loading state",
        "Empty state",
        "Error state"
      )
    }
  )
}






function Get-MarkdownVisibleLines {
  param([string]$Content)

  $visibleLines = New-Object System.Collections.Generic.List[string]
  $inFence = $false
  $fenceCharacter = ""
  $fenceLength = 0
  $inHtmlComment = $false

  foreach ($sourceLine in ($Content -split '\r?\n')) {
    # fence内のlink/table風文字列は公開indexや証跡として数えない。
    if ($inFence) {
      $closingPattern = (
        '^ {0,3}' +
        [regex]::Escape($fenceCharacter) +
        "{$fenceLength,}[ \t]*$"
      )
      if ($sourceLine -match $closingPattern) {
        $inFence = $false
        $fenceCharacter = ""
        $fenceLength = 0
      }
      continue
    }

    # inline / multiline HTML commentを除去し、comment内のdecoyを見ない。
    $remaining = $sourceLine
    $visible = ""
    while ($remaining.Length -gt 0) {
      if ($inHtmlComment) {
        $commentEnd = $remaining.IndexOf(
          "-->",
          [StringComparison]::Ordinal
        )
        if ($commentEnd -lt 0) {
          $remaining = ""
          break
        }
        $remaining = $remaining.Substring($commentEnd + 3)
        $inHtmlComment = $false
        continue
      }

      $commentStart = $remaining.IndexOf(
        "<!--",
        [StringComparison]::Ordinal
      )
      if ($commentStart -lt 0) {
        $visible += $remaining
        $remaining = ""
        break
      }
      $visible += $remaining.Substring(0, $commentStart)
      $remaining = $remaining.Substring($commentStart + 4)
      $inHtmlComment = $true
    }

    $openingFence = [regex]::Match(
      $visible,
      '^ {0,3}(?<Fence>`{3,}|~{3,}).*$'
    )
    if ($openingFence.Success) {
      $fence = $openingFence.Groups["Fence"].Value
      $fenceCharacter = $fence.Substring(0, 1)
      $fenceLength = $fence.Length
      $inFence = $true
      continue
    }

    $visibleLines.Add($visible) | Out-Null
  }

  return $visibleLines.ToArray()
}


function Get-MarkdownH2Section {
  param(
    [string]$Content,
    [string]$Heading
  )

  $visibleLines = @(Get-MarkdownVisibleLines -Content $Content)
  $headingPattern = (
    '^##[ \t]+' +
    [regex]::Escape($Heading) +
    '[ \t]*$'
  )
  $headingIndexes = New-Object System.Collections.Generic.List[int]
  for ($index = 0; $index -lt $visibleLines.Count; $index++) {
    if ($visibleLines[$index] -match $headingPattern) {
      $headingIndexes.Add($index) | Out-Null
    }
  }

  $sectionLines = New-Object System.Collections.Generic.List[string]
  if ($headingIndexes.Count -eq 1) {
    for (
      $index = $headingIndexes[0] + 1;
      $index -lt $visibleLines.Count;
      $index++
    ) {
      if ($visibleLines[$index] -match '^#{1,2}[ \t]+') {
        break
      }
      $sectionLines.Add($visibleLines[$index]) | Out-Null
    }
  }

  return [pscustomobject]@{
    MatchCount = $headingIndexes.Count
    Lines = $sectionLines.ToArray()
  }
}

function Get-MarkdownH2RawSection {
  param(
    [string]$Content,
    [string]$Heading
  )

  $sectionLines = New-Object System.Collections.Generic.List[string]
  $headingMatchCount = 0
  $collectSection = $false
  $inFence = $false
  $fenceCharacter = ""
  $fenceLength = 0
  $inHtmlComment = $false
  $headingPattern = (
    '^ {0,3}##[ \t]+' +
    [regex]::Escape($Heading) +
    '[ \t]*$'
  )

  foreach ($sourceLine in ($Content -split '\r?\n')) {
    # 対象section内のfence本文はそのまま保持し、コード中の見かけ上のheadingを無視する。
    if ($inFence) {
      if ($collectSection) {
        $sectionLines.Add($sourceLine) | Out-Null
      }
      $closingPattern = (
        '^ {0,3}' +
        [regex]::Escape($fenceCharacter) +
        "{$fenceLength,}[ \t]*$"
      )
      if ($sourceLine -match $closingPattern) {
        $inFence = $false
        $fenceCharacter = ""
        $fenceLength = 0
      }
      continue
    }

    # HTML comment内のheading / fence decoyは構造として扱わない。
    $remaining = $sourceLine
    $visible = ""
    while ($remaining.Length -gt 0) {
      if ($inHtmlComment) {
        $commentEnd = $remaining.IndexOf(
          "-->",
          [StringComparison]::Ordinal
        )
        if ($commentEnd -lt 0) {
          # commentを削除せず同じ長さの空白へ置換し、delimiter断片の連結を防ぐ。
          $visible += (" " * $remaining.Length)
          $remaining = ""
          break
        }
        $visible += (" " * ($commentEnd + 3))
        $remaining = $remaining.Substring($commentEnd + 3)
        $inHtmlComment = $false
        continue
      }

      $commentStart = $remaining.IndexOf(
        "<!--",
        [StringComparison]::Ordinal
      )
      if ($commentStart -lt 0) {
        $visible += $remaining
        $remaining = ""
        break
      }
      $visible += $remaining.Substring(0, $commentStart)
      $visible += (" " * 4)
      $remaining = $remaining.Substring($commentStart + 4)
      $inHtmlComment = $true
    }

    $openingFence = [regex]::Match(
      $visible,
      '^ {0,3}(?<Fence>`{3,}|~{3,}).*$'
    )
    if ($openingFence.Success) {
      if ($collectSection) {
        $sectionLines.Add($visible) | Out-Null
      }
      $fence = $openingFence.Groups["Fence"].Value
      $fenceCharacter = $fence.Substring(0, 1)
      $fenceLength = $fence.Length
      $inFence = $true
      continue
    }

    # 同名H2は文書全体で一意とし、comment / fence外のduplicateもfail closedにする。
    if ($visible -cmatch $headingPattern) {
      $headingMatchCount++
      $collectSection = $true
      continue
    }
    if ($collectSection -and $visible -match '^ {0,3}#{1,2}[ \t]+') {
      $collectSection = $false
      continue
    }
    if ($collectSection) {
      $sectionLines.Add($visible) | Out-Null
    }
  }

  return [pscustomobject]@{
    MatchCount = $headingMatchCount
    Lines = $sectionLines.ToArray()
  }
}

function Get-MarkdownFencedBlocks {
  param([string[]]$Lines)

  $blocks = New-Object System.Collections.Generic.List[object]
  $blockLines = New-Object System.Collections.Generic.List[string]
  $inFence = $false
  $fenceCharacter = ""
  $fenceLength = 0
  $fenceInfo = ""

  foreach ($line in $Lines) {
    if (-not $inFence) {
      $openingFence = [regex]::Match(
        $line,
        '^ {0,3}(?<Fence>`{3,}|~{3,})(?<Info>.*)$'
      )
      if (-not $openingFence.Success) {
        continue
      }
      $fence = $openingFence.Groups["Fence"].Value
      $fenceCharacter = $fence.Substring(0, 1)
      $fenceLength = $fence.Length
      $fenceInfo = $openingFence.Groups["Info"].Value.Trim()
      $blockLines = New-Object System.Collections.Generic.List[string]
      $inFence = $true
      continue
    }

    $closingPattern = (
      '^ {0,3}' +
      [regex]::Escape($fenceCharacter) +
      "{$fenceLength,}[ \t]*$"
    )
    if ($line -match $closingPattern) {
      $blocks.Add([pscustomobject]@{
        Info = $fenceInfo
        Content = ($blockLines.ToArray() -join "`n")
        IsClosed = $true
      }) | Out-Null
      $inFence = $false
      $fenceCharacter = ""
      $fenceLength = 0
      $fenceInfo = ""
      continue
    }
    $blockLines.Add($line) | Out-Null
  }

  # 閉じ忘れを無視せず、明示的なinvalid blockとして後段へ渡す。
  if ($inFence) {
    $blocks.Add([pscustomobject]@{
      Info = $fenceInfo
      Content = ($blockLines.ToArray() -join "`n")
      IsClosed = $false
    }) | Out-Null
  }

  return $blocks.ToArray()
}



function Test-RuntimePortableRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or
    $Path -cne $Path.Trim() -or
    [IO.Path]::IsPathRooted($Path) -or
    $Path.Contains("\")) {
    return $false
  }
  $segments = @($Path -split "/")
  foreach ($segment in $segments) {
    if ([string]::IsNullOrWhiteSpace($segment) -or
      $segment -in @(".", "..") -or
      $segment -match '[\x00-\x1F<>:"\\|?*]' -or
      $segment -match '[. ]$' -or
      $segment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(?:\..*)?$') {
      return $false
    }
  }
  return $true
}


function Get-RuntimeClosureExpectedPaths {
  param([object[]]$PublicExampleManifest)

  # runtime正本は、SKILL本体と既存public manifestの順序付きpathだけへ閉じる。
  return @("SKILL.md") + @(
    $PublicExampleManifest |
      ForEach-Object { [string]$_.Path }
  )
}

function Get-RuntimeClosureSupportedSkillLinkLines {
  param([object[]]$PublicExampleManifest)

  # Markdownを再実装せず、現在サポートするsingle-line linkの全文だけを許可する。
  $supportedLines = New-Object System.Collections.Generic.List[string]
  $supportedLines.Add(
    '[Playwright discourages using `networkidle`](https://playwright.dev/docs/api/class-page#page-goto-option-wait-until)'
  ) | Out-Null
  foreach ($entry in $PublicExampleManifest) {
    $supportedLines.Add(
      "- [$([string]$entry.Label)]($([string]$entry.Path))"
    ) | Out-Null
  }
  return $supportedLines.ToArray()
}

function Get-OrdinalOccurrenceCount {
  param(
    [string]$Text,
    [string]$Needle
  )

  if ([string]::IsNullOrEmpty($Needle)) {
    throw "Occurrence needle must not be empty."
  }
  $count = 0
  $offset = 0
  while ($offset -le ($Text.Length - $Needle.Length)) {
    $matchIndex = $Text.IndexOf(
      $Needle,
      $offset,
      [StringComparison]::Ordinal
    )
    if ($matchIndex -lt 0) {
      break
    }
    $count++
    $offset = $matchIndex + $Needle.Length
  }
  return $count
}

function Get-RuntimeCloneBlockTemplate {
  # Install節の先頭blockも全文固定し、clone手順へcopy commandを隠す迂回を防ぐ。
  return @'
git clone https://github.com/h8nc4y/bounded-playwright-ui-verification.git
cd bounded-playwright-ui-verification
'@
}

function Get-RuntimeClosureInstallBlockTemplate {
  param([int]$ExpectedFileCount = 12)

  # READMEの実行可能なinstall例を全文固定し、comment decoyや一部だけ正しいcopyを許可しない。
  $template = @'
# runtime-closure-install:start
$repoRoot = (Resolve-Path ".").Path
$manifestPath = Join-Path $repoRoot "runtime-files.txt"
$runtimeFiles = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
if ($runtimeFiles.Count -ne __EXPECTED_FILE_COUNT__) {
  throw "Runtime manifest must contain exactly __EXPECTED_FILE_COUNT__ files."
}
$runtimeFilesUnique = @($runtimeFiles | Sort-Object -Unique)
if ($runtimeFilesUnique.Count -ne $runtimeFiles.Count) {
  throw "Runtime manifest contains a duplicate path."
}
$assertPortableRuntimePath = {
  param([string]$CandidatePath)

  if ([string]::IsNullOrWhiteSpace($CandidatePath) -or
    $CandidatePath -cne $CandidatePath.Trim() -or
    [IO.Path]::IsPathRooted($CandidatePath) -or
    $CandidatePath.Contains("\")) {
    throw "Runtime manifest contains an unsafe path."
  }
  foreach ($candidateSegment in @($CandidatePath -split "/")) {
    if ([string]::IsNullOrWhiteSpace($candidateSegment) -or
      $candidateSegment -in @(".", "..") -or
      $candidateSegment -match '[\x00-\x1F<>:"\\|?*]' -or
      $candidateSegment -match '[. ]$' -or
      $candidateSegment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(?:\..*)?$') {
      throw "Runtime manifest contains an unsafe path."
    }
  }
}

$getRequiredFileSha256 = {
  param([string]$LiteralPath)

  # hash取得失敗をnull同士の一致として扱わず、必ず例外でfail closedにする。
  $hashResults = @(
    Microsoft.PowerShell.Utility\Get-FileHash `
      -LiteralPath $LiteralPath `
      -Algorithm SHA256 `
      -ErrorAction Stop
  )
  if ($hashResults.Count -ne 1) {
    throw "SHA-256 calculation did not return exactly one result."
  }
  $hash = [string]$hashResults[0].Hash
  if ($hash -cnotmatch '^[0-9A-F]{64}$') {
    throw "SHA-256 calculation returned an invalid digest."
  }
  return $hash
}

$skillRoot = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path (Join-Path $HOME ".codex") "skills"
}
$skillRootFullPath = [IO.Path]::GetFullPath($skillRoot)
if (-not (Test-Path -LiteralPath $skillRootFullPath -PathType Container)) {
  throw "Skill root does not exist: $skillRootFullPath"
}
$targetFullPath = [IO.Path]::GetFullPath(
  (Join-Path $skillRootFullPath "bounded-playwright-ui-verification")
)
if (Test-Path -LiteralPath $targetFullPath) {
  throw "Skill already exists: $targetFullPath"
}
$repoItem = Get-Item -LiteralPath $repoRoot -ErrorAction Stop
if ($repoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
  throw "Repository root must not be a reparse point."
}

$repoBoundary = $repoRoot.TrimEnd([char]47, [char]92) +
  [IO.Path]::DirectorySeparatorChar
$stagingName = ".bounded-playwright-ui-verification.install-" +
  [guid]::NewGuid().ToString("N")
$stagingFullPath = [IO.Path]::GetFullPath(
  (Join-Path $skillRootFullPath $stagingName)
)
$stagingBoundary = $stagingFullPath.TrimEnd([char]47, [char]92) +
  [IO.Path]::DirectorySeparatorChar
$copyPlan = foreach ($relativePath in $runtimeFiles) {
  & $assertPortableRuntimePath $relativePath
  $segments = @($relativePath -split "/")

  $sourcePath = [IO.Path]::GetFullPath((Join-Path $repoRoot $relativePath))
  $destinationPath = [IO.Path]::GetFullPath(
    (Join-Path $stagingFullPath $relativePath)
  )
  if (-not $sourcePath.StartsWith(
      $repoBoundary,
      [StringComparison]::OrdinalIgnoreCase
    ) -or
    -not $destinationPath.StartsWith(
      $stagingBoundary,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Runtime manifest path escaped its allowed root."
  }

  $sourceCursor = $repoRoot
  foreach ($segment in $segments) {
    $sourceCursor = Join-Path $sourceCursor $segment
    $sourceItem = Get-Item -LiteralPath $sourceCursor -ErrorAction Stop
    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Runtime manifest path contains a reparse point."
    }
  }
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Runtime manifest source is not a file."
  }

  [pscustomobject]@{
    Source = $sourcePath
    Destination = $destinationPath
    Segments = $segments
    ExpectedHash = & $getRequiredFileSha256 $sourcePath
  }
}

try {
  New-Item `
    -ItemType Directory `
    -Path $stagingFullPath `
    -ErrorAction Stop | Out-Null
  foreach ($copyItem in $copyPlan) {
    $destinationDirectory = Split-Path -Parent $copyItem.Destination
    New-Item `
      -ItemType Directory `
      -Path $destinationDirectory `
      -Force `
      -ErrorAction Stop | Out-Null
    Copy-Item `
      -LiteralPath $copyItem.Source `
      -Destination $copyItem.Destination `
      -ErrorAction Stop
    if ($copyItem.ExpectedHash -cne
      (& $getRequiredFileSha256 $copyItem.Destination)) {
      throw "Runtime file copy failed its SHA-256 check."
    }
  }

  # claim直前にsource/staging chainとpreflight hashを再検査し、通常の同時変更を拒否する。
  $stagingItem = Get-Item -LiteralPath $stagingFullPath -ErrorAction Stop
  if ($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Runtime staging root changed before atomic claim."
  }
  foreach ($copyItem in $copyPlan) {
    $sourceCursor = $repoRoot
    foreach ($segment in $copyItem.Segments) {
      $sourceCursor = Join-Path $sourceCursor $segment
      $sourceItem = Get-Item -LiteralPath $sourceCursor -ErrorAction Stop
      if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Runtime source changed after its preflight hash."
      }
    }
    if (-not (Test-Path -LiteralPath $copyItem.Source -PathType Leaf) -or
      (& $getRequiredFileSha256 $copyItem.Source) -cne
        $copyItem.ExpectedHash) {
      throw "Runtime source changed after its preflight hash."
    }

    $destinationCursor = $stagingFullPath
    foreach ($segment in $copyItem.Segments) {
      $destinationCursor = Join-Path $destinationCursor $segment
      $destinationItem = Get-Item `
        -LiteralPath $destinationCursor `
        -ErrorAction Stop
      if ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Runtime staging path changed before atomic claim."
      }
    }
    if (-not (Test-Path -LiteralPath $copyItem.Destination -PathType Leaf) -or
      (& $getRequiredFileSha256 $copyItem.Destination) -cne
        $copyItem.ExpectedHash) {
      throw "Runtime staging path changed before atomic claim."
    }
  }
  [IO.Directory]::Move($stagingFullPath, $targetFullPath)
} catch {
  Write-Warning (
    "Install failed. Staging was not removed automatically; " +
    "verify ownership before cleanup: $stagingFullPath"
  )
  throw
}
# runtime-closure-install:end
'@
  return $template.Replace(
    "__EXPECTED_FILE_COUNT__",
    [string]$ExpectedFileCount
  )
}

function Get-RuntimeClosureInstallSectionTemplate {
  param([int]$ExpectedFileCount = 12)

  # READMEのInstall全体をraw canonical textとして固定し、Markdown意味解析を契約外にする。
  $section = @'
## Install

Clone the repository:

```powershell
__CLONE_BLOCK__
```

Run the repository checks (see [Validation And Scan](#validation-and-scan))
before copying the skill.

`runtime-files.txt` is the deterministic runtime closure: `SKILL.md` plus the
11 ordered paths in the existing public-example manifest. The same manifest
already fixes the label, path, count, and publication section in both `SKILL.md`
and this README. The required-file gate verifies that every declaration is a
present leaf. Every manifest component must also be portable to Windows (no
reserved device names, alternate data streams, wildcards, control characters,
or trailing dots/spaces).

The supported `SKILL.md` link surface is deliberately small: one exact official
Playwright link followed by the 11 exact single-line public-example links.
Unknown raw `](` lines, reference-style `]:` syntax, and raw HTML `<a>` / `<img>`
link surfaces are unsupported and fail closed. Adding another runtime file is a
reviewed public-manifest change, not automatic CommonMark link discovery.

The repository check does not claim to parse arbitrary Markdown containers.
Instead, it compares this complete `## Install` section through the fixed
`## Manual Use` boundary with canonical text using ordinal equality. Alternate
Install headings, runtime markers, and runtime copy/claim tokens outside this
canonical block are unsupported lexical surfaces, including when they appear in
code or comments. The canonical PowerShell block is also parsed with the
PowerShell AST parser before acceptance.

Manual install into a Codex-style skill directory:

```powershell
__RUNTIME_BLOCK__
```

If your agent runtime uses a different skill location, use the same
manifest-driven copy with that documented skill root. The example refuses to
overwrite an existing target, including one created after preflight. It copies
into a unique sibling staging directory and atomically claims the final target
only after the source and staging chains are revalidated against their preflight
SHA-256 values. Run it only from a trusted, quiescent clone: a malicious local
process racing individual path opens is outside this snippet's safety boundary.
On failure it deliberately retains staging because a pathname alone cannot
prove directory ownership; verify ownership before removing it. Review or remove
an old installation separately instead of mixing versions.
'@
  $cloneBlock = (Get-RuntimeCloneBlockTemplate).Replace("`r`n", "`n")
  $runtimeBlock = (
    Get-RuntimeClosureInstallBlockTemplate `
      -ExpectedFileCount $ExpectedFileCount
  ).Replace("`r`n", "`n")
  return (
    $section.Replace("__CLONE_BLOCK__", $cloneBlock).Replace(
      "__RUNTIME_BLOCK__",
      $runtimeBlock
    ).TrimEnd([char]13, [char]10) +
    "`n`n"
  )
}

function Get-PowerShellParseErrors {
  param([string]$ScriptText)

  # 実行せずAST parserだけを通し、READMEのcopy可能なPowerShell本文の構文退行を検出する。
  $parseTokens = $null
  $parseErrors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseInput(
    $ScriptText,
    [ref]$parseTokens,
    [ref]$parseErrors
  )
  return @($parseErrors)
}


function Get-RuntimeClosureContractErrors {
  param(
    [string]$RuntimeManifestText,
    [string]$ReadmeText,
    [string]$SkillText,
    [object[]]$PublicExampleManifest
  )

  $contractErrors = New-Object System.Collections.Generic.List[string]
  $addContractError = {
    param([string]$Message)

    if (-not $contractErrors.Contains($Message)) {
      $contractErrors.Add($Message) | Out-Null
    }
  }

  # runtime closureの正本は、固定のSKILL本体とpublic manifestの順序付きpathだけに閉じる。
  $expectedPaths = @(
    Get-RuntimeClosureExpectedPaths `
      -PublicExampleManifest $PublicExampleManifest
  )
  $supportedSkillLines = @(
    Get-RuntimeClosureSupportedSkillLinkLines `
      -PublicExampleManifest $PublicExampleManifest
  )
  if ($expectedPaths.Count -ne 12 -or
    $supportedSkillLines.Count -ne 12) {
    & $addContractError (
      "[runtime-closure-skill-links] The canonical runtime and SKILL link " +
      "surfaces must each contain exactly 12 entries."
    )
  }

  # SKILL.mdはraw single-line linkの全文、個数、順序だけを受理し、Markdown意味解析を行わない。
  $skillLines = @(
    $SkillText.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n"
  )
  $actualSkillLinkLines = @(
    $skillLines |
      Where-Object { ([string]$_).Contains("](") }
  )
  $skillLinkSurfaceChanged = (
    $actualSkillLinkLines.Count -ne $supportedSkillLines.Count
  )
  if (-not $skillLinkSurfaceChanged) {
    for (
      $lineIndex = 0;
      $lineIndex -lt $supportedSkillLines.Count;
      $lineIndex++
    ) {
      if ($actualSkillLinkLines[$lineIndex] -cne
        $supportedSkillLines[$lineIndex]) {
        $skillLinkSurfaceChanged = $true
        break
      }
    }
  }
  if ($skillLinkSurfaceChanged) {
    & $addContractError (
      "[runtime-closure-skill-links] SKILL.md raw link lines changed in " +
      "content, count, or order."
    )
  }
  if ($SkillText.Contains("]:")) {
    & $addContractError (
      "[runtime-closure-skill-links] SKILL.md reference-style link " +
      "definitions are unsupported."
    )
  }
  if ($SkillText -match '(?i)<(?:a|img)\b') {
    & $addContractError (
      "[runtime-closure-skill-links] SKILL.md raw HTML local-link surfaces " +
      "are unsupported."
    )
  }

  # manifestはLF終端、portable relative path、Windows相当の重複禁止、exact orderを固定する。
  $normalizedManifest = $RuntimeManifestText.Replace("`r`n", "`n")
  if ($normalizedManifest.Contains("`r")) {
    & $addContractError (
      "[runtime-closure-manifest] Manifest contains a bare carriage return."
    )
  }
  $manifestHasFinalLf = $normalizedManifest.EndsWith("`n")
  if (-not $manifestHasFinalLf) {
    & $addContractError (
      "[runtime-closure-manifest] Manifest must end with one LF."
    )
  }
  $manifestBody = if ($manifestHasFinalLf) {
    $normalizedManifest.Substring(0, $normalizedManifest.Length - 1)
  } else {
    $normalizedManifest
  }
  $actualPaths = if ([string]::IsNullOrEmpty($manifestBody)) {
    @()
  } else {
    @($manifestBody -split "`n")
  }

  $hasUnsafePath = $false
  foreach ($path in $actualPaths) {
    if (-not (Test-RuntimePortableRelativePath -Path ([string]$path))) {
      $hasUnsafePath = $true
      break
    }
  }
  if ($hasUnsafePath) {
    & $addContractError (
      "[runtime-closure-manifest] Manifest contains an unsafe path."
    )
  }

  $hasDuplicatePath = $false
  for (
    $leftIndex = 0;
    $leftIndex -lt $actualPaths.Count -and -not $hasDuplicatePath;
    $leftIndex++
  ) {
    for (
      $rightIndex = $leftIndex + 1;
      $rightIndex -lt $actualPaths.Count;
      $rightIndex++
    ) {
      if ([string]::Equals(
          [string]$actualPaths[$leftIndex],
          [string]$actualPaths[$rightIndex],
          [StringComparison]::OrdinalIgnoreCase
        )) {
        $hasDuplicatePath = $true
        break
      }
    }
  }
  if ($hasDuplicatePath) {
    & $addContractError (
      "[runtime-closure-manifest] Manifest contains a duplicate path."
    )
  }

  if ($actualPaths.Count -ne $expectedPaths.Count) {
    & $addContractError (
      "[runtime-closure-manifest] Manifest file count changed."
    )
  } else {
    for (
      $pathIndex = 0;
      $pathIndex -lt $expectedPaths.Count;
      $pathIndex++
    ) {
      if ($actualPaths[$pathIndex] -cne $expectedPaths[$pathIndex]) {
        & $addContractError (
          "[runtime-closure-manifest] Manifest order or path changed."
        )
        break
      }
    }
  }

  # READMEはInstallからManual Use直前までをraw canonical textとして比較する。
  $expectedInstallSection = (
    Get-RuntimeClosureInstallSectionTemplate `
      -ExpectedFileCount $expectedPaths.Count
  ).Replace("`r`n", "`n")
  $installHeading = "## Install"
  $manualUseHeading = "## Manual Use"
  $readmeLines = @($ReadmeText -split "`n")
  $installHeadingCount = @(
    $readmeLines |
      Where-Object { $_ -ceq $installHeading }
  ).Count
  $manualUseHeadingCount = @(
    $readmeLines |
      Where-Object { $_ -ceq $manualUseHeading }
  ).Count
  $expectedSectionCount = Get-OrdinalOccurrenceCount `
    -Text $ReadmeText `
    -Needle $expectedInstallSection
  if ($installHeadingCount -ne 1 -or
    $manualUseHeadingCount -ne 1) {
    & $addContractError (
      "[runtime-closure-install] README.md must contain unique exact Install " +
      "and Manual Use boundaries."
    )
  }
  if ($expectedSectionCount -ne 1) {
    & $addContractError (
      "[runtime-closure-install] README.md canonical Install section changed."
    )
  }

  # inline prose内の同じ文字列を飛ばし、完全一致行のIndexOf位置だけを返す。
  $getExactLineStartIndex = {
    param(
      [string]$Text,
      [string]$Line
    )

    $searchIndex = 0
    while ($searchIndex -le ($Text.Length - $Line.Length)) {
      $candidateIndex = $Text.IndexOf(
        $Line,
        $searchIndex,
        [StringComparison]::Ordinal
      )
      if ($candidateIndex -lt 0) {
        return -1
      }
      $hasStartBoundary = (
        $candidateIndex -eq 0 -or
        $Text[$candidateIndex - 1] -eq [char]10
      )
      $afterCandidateIndex = $candidateIndex + $Line.Length
      $hasEndBoundary = (
        $afterCandidateIndex -eq $Text.Length -or
        $Text[$afterCandidateIndex] -eq [char]10
      )
      if ($hasStartBoundary -and $hasEndBoundary) {
        return $candidateIndex
      }
      $searchIndex = $candidateIndex + 1
    }
    return -1
  }
  $installStartIndex = & $getExactLineStartIndex `
    -Text $ReadmeText `
    -Line $installHeading
  $manualUseStartIndex = & $getExactLineStartIndex `
    -Text $ReadmeText `
    -Line $manualUseHeading
  $installHasExactLineBoundary = (
    $installStartIndex -ge 0 -and
    ($installStartIndex -eq 0 -or
      $ReadmeText[$installStartIndex - 1] -eq [char]10) -and
    ($installStartIndex + $installHeading.Length) -lt $ReadmeText.Length -and
    $ReadmeText[$installStartIndex + $installHeading.Length] -eq [char]10
  )
  $manualUseHasExactLineBoundary = (
    $manualUseStartIndex -ge 0 -and
    ($manualUseStartIndex -eq 0 -or
      $ReadmeText[$manualUseStartIndex - 1] -eq [char]10) -and
    ($manualUseStartIndex + $manualUseHeading.Length) -lt
      $ReadmeText.Length -and
    $ReadmeText[$manualUseStartIndex + $manualUseHeading.Length] -eq [char]10
  )
  $hasOrderedReadmeBoundaries = (
    $installHeadingCount -eq 1 -and
    $manualUseHeadingCount -eq 1 -and
    $installHasExactLineBoundary -and
    $manualUseHasExactLineBoundary -and
    $manualUseStartIndex -gt $installStartIndex
  )
  # boundary不正時はfull READMEをoutsideとして扱い、fail-openを避ける。
  $outsideInstallText = $ReadmeText
  $installPrefixText = ""
  if (-not $hasOrderedReadmeBoundaries) {
    & $addContractError (
      "[runtime-closure-install] README.md Install boundary order is invalid."
    )
  } else {
    $actualInstallSection = $ReadmeText.Substring(
      $installStartIndex,
      $manualUseStartIndex - $installStartIndex
    )
    if ($actualInstallSection -cne $expectedInstallSection) {
      & $addContractError (
        "[runtime-closure-install] README.md Install bytes changed."
      )
    }

    # valid boundary時だけcanonical sectionをoutside検査対象から除く。
    $installPrefixText = $ReadmeText.Substring(0, $installStartIndex)
    $outsideInstallText = (
      $installPrefixText +
      $ReadmeText.Substring($manualUseStartIndex)
    )
  }

  # Install前に未対応containerを許すとcanonical bytes全体を非表示にできるため、一律拒否する。
  if ($hasOrderedReadmeBoundaries) {
    $installPrefixLines = @($installPrefixText -split "`n")
    $hasInstallPrefixFence = @(
      $installPrefixLines |
        Where-Object { $_ -match '^[ ]{0,3}(?:`{3,}|~{3,})' }
    ).Count -gt 0
    if ($installPrefixText.IndexOf(
        "<",
        [StringComparison]::Ordinal
      ) -ge 0 -or $hasInstallPrefixFence) {
      & $addContractError (
        "[runtime-closure-install] README.md Install prefix contains an " +
        "unsupported raw HTML or top-level fence wrapper surface."
      )
    }
  }

  # canonical外はruntime専用marker/tokenだけをdenylistし、一般proseの意味解析を主張しない。
  $outsideRuntimeTokens = @(
    "runtime-closure-install:start",
    "runtime-closure-install:end",
    "runtime-files.txt",
    "Copy-Item",
    "[IO.Directory]::Move",
    '$runtimeFiles',
    '$stagingFullPath',
    '$stagingName',
    '$targetFullPath',
    '$copyPlan',
    '$assertPortableRuntimePath',
    '$getRequiredFileSha256'
  )
  foreach ($outsideRuntimeToken in $outsideRuntimeTokens) {
    if ($outsideInstallText.IndexOf(
        $outsideRuntimeToken,
        [StringComparison]::OrdinalIgnoreCase
      ) -ge 0) {
      & $addContractError (
        "[runtime-closure-install] README.md contains a runtime marker or " +
        "copy/claim token outside the canonical Install section."
      )
      break
    }
  }

  # outsideの`#`行を既知headingだけへ閉じ、container内のsemantic ATXもfail closedにする。
  $outsideReadmeLines = @($outsideInstallText -split "`n")
  $expectedOutsideHashLines = @(
    "# bounded-playwright-ui-verification",
    "## Who It Is For",
    "## What It Solves",
    "## Manual Use",
    "## Examples",
    "## Validation And Scan",
    "## Contributing",
    "## Security",
    "## Limitations",
    "## Non-Goals",
    "## Safety Notes",
    "## License"
  )
  $actualOutsideHashLines = @(
    $outsideReadmeLines |
      Where-Object { $_.IndexOf("#", [StringComparison]::Ordinal) -ge 0 } |
      ForEach-Object { [string]$_ }
  )
  $outsideHashLinesMatch = (
    $actualOutsideHashLines.Count -eq
      $expectedOutsideHashLines.Count
  )
  if ($outsideHashLinesMatch) {
    for (
      $headingIndex = 0;
      $headingIndex -lt $expectedOutsideHashLines.Count;
      $headingIndex++
    ) {
      if ($actualOutsideHashLines[$headingIndex] -cne
        $expectedOutsideHashLines[$headingIndex]) {
        $outsideHashLinesMatch = $false
        break
      }
    }
  }
  if (-not $outsideHashLinesMatch) {
    & $addContractError (
      "[runtime-closure-install] README.md outside hash-bearing lines " +
      "changed from the exact heading allowlist, order, or count."
    )
  }

  # entity decodeは実装せず、canonical外ではcharacter reference自体を非対応とする。
  $characterReferencePattern = (
    '&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);'
  )
  if ($outsideInstallText -match $characterReferencePattern) {
    & $addContractError (
      "[runtime-closure-install] README.md contains an unsupported " +
      "character reference outside the canonical Install section."
    )
  }

  # raw HTML / Setext headingはsemantic labelを解釈せず、一律fail closedにする。
  foreach ($outsideReadmeLine in $outsideReadmeLines) {
    if ($outsideReadmeLine -match '(?i)<h[1-6]\b') {
      & $addContractError (
        "[runtime-closure-install] README.md contains an unsupported raw " +
        "HTML heading surface."
      )
      break
    }
  }
  $setextUnderlinePattern = (
    '^[ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|\d{1,9}[.)])[ \t]+))*' +
    '[ \t]*(?:=+|-+)[ \t]*$'
  )
  for (
    $readmeLineIndex = 0;
    $readmeLineIndex -lt ($outsideReadmeLines.Count - 1);
    $readmeLineIndex++
  ) {
    $isSetextUnderline = (
      $outsideReadmeLines[$readmeLineIndex + 1] -match
        $setextUnderlinePattern
    )
    if ($isSetextUnderline) {
      & $addContractError (
        "[runtime-closure-install] README.md contains an unsupported " +
        "Setext heading surface outside the canonical Install section."
      )
      break
    }
  }

  # canonical templateとREADME内のactual marker区間をPowerShell parserで独立検証する。
  $runtimeTemplate = Get-RuntimeClosureInstallBlockTemplate `
    -ExpectedFileCount $expectedPaths.Count
  if (@(
      Get-PowerShellParseErrors -ScriptText $runtimeTemplate
    ).Count -ne 0) {
    & $addContractError (
      "[runtime-closure-powershell] Runtime closure template has invalid " +
      "PowerShell syntax."
    )
  }

  $runtimeStartMarker = "# runtime-closure-install:start"
  $runtimeEndMarker = "# runtime-closure-install:end"
  $runtimeStartCount = Get-OrdinalOccurrenceCount `
    -Text $ReadmeText `
    -Needle $runtimeStartMarker
  $runtimeEndCount = Get-OrdinalOccurrenceCount `
    -Text $ReadmeText `
    -Needle $runtimeEndMarker
  $runtimeStartIndex = $ReadmeText.IndexOf(
    $runtimeStartMarker,
    [StringComparison]::Ordinal
  )
  $runtimeEndIndex = $ReadmeText.IndexOf(
    $runtimeEndMarker,
    [StringComparison]::Ordinal
  )
  $hasOrderedRuntimeMarkers = (
    $runtimeStartCount -eq 1 -and
    $runtimeEndCount -eq 1 -and
    $runtimeStartIndex -ge 0 -and
    $runtimeEndIndex -gt $runtimeStartIndex
  )
  if (-not $hasOrderedRuntimeMarkers) {
    & $addContractError (
      "[runtime-closure-install] README.md runtime markers must each occur " +
      "once and in order."
    )
  } else {
    if ($hasOrderedReadmeBoundaries -and
      ($runtimeStartIndex -lt $installStartIndex -or
        $runtimeEndIndex -ge $manualUseStartIndex)) {
      & $addContractError (
        "[runtime-closure-install] README.md runtime markers escaped the " +
        "canonical Install section."
      )
    }
    $actualRuntimeScript = $ReadmeText.Substring(
      $runtimeStartIndex,
      ($runtimeEndIndex + $runtimeEndMarker.Length) - $runtimeStartIndex
    )
    if (@(
        Get-PowerShellParseErrors -ScriptText $actualRuntimeScript
      ).Count -ne 0) {
      & $addContractError (
        "[runtime-closure-powershell] README.md runtime closure block has " +
        "invalid PowerShell syntax."
      )
    }
  }

  return $contractErrors.ToArray()
}

function Assert-RuntimeClosureContractMutations {
  param(
    [string]$RuntimeManifestText,
    [string]$ReadmeText,
    [string]$SkillText,
    [object[]]$PublicExampleManifest
  )

  $selfTestErrorCountBefore = $errors.Count
  $expectedMutationCount = 38
  $expectedPaths = @(
    Get-RuntimeClosureExpectedPaths `
      -PublicExampleManifest $PublicExampleManifest
  )
  $supportedSkillLines = @(
    Get-RuntimeClosureSupportedSkillLinkLines `
      -PublicExampleManifest $PublicExampleManifest
  )
  $markdownFence = ([string][char]96) * 3
  $mutationCases = New-Object System.Collections.Generic.List[object]

  # fixture生成時の誤置換を自己検出し、狙った1箇所だけを変える。
  $replaceExactlyOnce = {
    param(
      [string]$Text,
      [string]$Needle,
      [string]$Replacement,
      [string]$MutationName
    )

    $occurrenceCount = Get-OrdinalOccurrenceCount `
      -Text $Text `
      -Needle $Needle
    if ($occurrenceCount -ne 1) {
      Add-Error (
        "[runtime-closure-self-test] Mutation '$MutationName' expected " +
        "one source occurrence, found $occurrenceCount."
      )
      return $Text
    }
    return $Text.Replace($Needle, $Replacement)
  }
  $addMutation = {
    param(
      [string]$Name,
      [string]$Expected,
      [string]$Manifest,
      [string]$Readme,
      [string]$Skill
    )

    $mutationCases.Add([pscustomobject]@{
      Name = $Name
      Expected = $Expected
      Manifest = $Manifest
      Readme = $Readme
      Skill = $Skill
    }) | Out-Null
  }

  # mutationに入る前に、現在の正本がstrict contractを満たすことを固定する。
  $baselineErrors = @(
    Get-RuntimeClosureContractErrors `
      -RuntimeManifestText $RuntimeManifestText `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -PublicExampleManifest $PublicExampleManifest
  )
  if ($baselineErrors.Count -ne 0) {
    Add-Error (
      "[runtime-closure-self-test] Baseline failed the runtime closure " +
      "contract: $($baselineErrors -join '; ')"
    )
  }
  if ($expectedPaths.Count -lt 3 -or
    $supportedSkillLines.Count -lt 3) {
    Add-Error (
      "[runtime-closure-self-test] Expected at least three runtime paths " +
      "and supported SKILL link lines."
    )
    return
  }

  # manifestは集合、順序、重複、portable pathを独立した5クラスで検証する。
  $missingPaths = @($expectedPaths | Select-Object -Skip 1)
  & $addMutation `
    "manifest-missing" `
    "[runtime-closure-manifest]" `
    (($missingPaths -join "`n") + "`n") `
    $ReadmeText `
    $SkillText

  $extraPaths = @($expectedPaths) + @("examples/undeclared.md")
  & $addMutation `
    "manifest-extra" `
    "[runtime-closure-manifest]" `
    (($extraPaths -join "`n") + "`n") `
    $ReadmeText `
    $SkillText

  $reorderedPaths = @(
    $expectedPaths |
      ForEach-Object { [string]$_ }
  )
  $reorderedPath = $reorderedPaths[1]
  $reorderedPaths[1] = $reorderedPaths[2]
  $reorderedPaths[2] = $reorderedPath
  & $addMutation `
    "manifest-reordered" `
    "[runtime-closure-manifest]" `
    (($reorderedPaths -join "`n") + "`n") `
    $ReadmeText `
    $SkillText

  $duplicatePaths = @(
    $expectedPaths |
      ForEach-Object { [string]$_ }
  )
  $duplicatePaths[$duplicatePaths.Count - 1] = $duplicatePaths[0]
  & $addMutation `
    "manifest-duplicate" `
    "[runtime-closure-manifest]" `
    (($duplicatePaths -join "`n") + "`n") `
    $ReadmeText `
    $SkillText

  $unsafePaths = @(
    $expectedPaths |
      ForEach-Object { [string]$_ }
  )
  $unsafePaths[0] = "../SKILL.md"
  & $addMutation `
    "manifest-unsafe" `
    "[runtime-closure-manifest]" `
    (($unsafePaths -join "`n") + "`n") `
    $ReadmeText `
    $SkillText

  # SKILL.mdは、許可したsingle-line linkの全文、順序、個数だけを受理する。
  $missingSkillLine = & $replaceExactlyOnce `
    $SkillText `
    ($supportedSkillLines[0] + "`n") `
    "" `
    "skill-supported-line-missing"
  & $addMutation `
    "skill-supported-line-missing" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $missingSkillLine

  $duplicateSkillLine = (
    $SkillText.TrimEnd([char]10) +
    "`n`n" +
    $supportedSkillLines[0] +
    "`n"
  )
  & $addMutation `
    "skill-supported-line-duplicate" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $duplicateSkillLine

  $orderedSkillPair = (
    $supportedSkillLines[1] +
    "`n" +
    $supportedSkillLines[2]
  )
  $reorderedSkillPair = (
    $supportedSkillLines[2] +
    "`n" +
    $supportedSkillLines[1]
  )
  $reorderedSkill = & $replaceExactlyOnce `
    $SkillText `
    $orderedSkillPair `
    $reorderedSkillPair `
    "skill-supported-lines-reordered"
  & $addMutation `
    "skill-supported-lines-reordered" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $reorderedSkill

  $extraOnAllowedLine = & $replaceExactlyOnce `
    $SkillText `
    $supportedSkillLines[0] `
    ($supportedSkillLines[0] + " [extra](CONTRIBUTING.md)") `
    "skill-allowed-line-plus-extra"
  & $addMutation `
    "skill-allowed-line-plus-extra" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $extraOnAllowedLine

  # v11で見つかったcontainer解釈の差は、strict lexical subsetでは未対応として拒否する。
  $unknownSkillLink = (
    $SkillText.TrimEnd([char]10) +
    "`n`n" +
    "- list item`n" +
    "`n" +
    "  > ${markdownFence}text`n" +
    "  > [unsupported](CONTRIBUTING.md)`n" +
    "  > $markdownFence" +
    "`n"
  )
  & $addMutation `
    "skill-unknown-link-in-container" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $unknownSkillLink

  $referenceStyleSkill = (
    $SkillText.TrimEnd([char]10) +
    "`n`n[runtime-extra]: CONTRIBUTING.md`n"
  )
  & $addMutation `
    "skill-reference-style-definition" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $referenceStyleSkill

  $rawHtmlSkill = (
    $SkillText.TrimEnd([char]10) +
    "`n`n<a href=`"CONTRIBUTING.md`">local link</a>`n"
  )
  & $addMutation `
    "skill-raw-html-local-link" `
    "[runtime-closure-skill-links]" `
    $RuntimeManifestText `
    $ReadmeText `
    $rawHtmlSkill

  # READMEはInstallからManual Use直前までのcanonical bytesと外側のdenylistを固定する。
  $readmeByteDrift = & $replaceExactlyOnce `
    $ReadmeText `
    "Clone the repository:" `
    "Clone this repository:" `
    "readme-canonical-byte-drift"
  & $addMutation `
    "readme-canonical-byte-drift" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeByteDrift `
    $SkillText

  # hash helperのmodule qualification、terminating error、digest形状を個別に固定する。
  $readmeUnqualifiedHashCommand = & $replaceExactlyOnce `
    $ReadmeText `
    "Microsoft.PowerShell.Utility\Get-FileHash" `
    "Get-FileHash" `
    "readme-hash-command-unqualified"
  & $addMutation `
    "readme-hash-command-unqualified" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeUnqualifiedHashCommand `
    $SkillText

  $lineContinuation = [string][char]96
  $hashErrorActionNeedle = (
    "      -Algorithm SHA256 $lineContinuation`n" +
    "      -ErrorAction Stop`n"
  )
  $readmeHashErrorActionMissing = & $replaceExactlyOnce `
    $ReadmeText `
    $hashErrorActionNeedle `
    "      -Algorithm SHA256`n" `
    "readme-hash-erroraction-missing"
  & $addMutation `
    "readme-hash-erroraction-missing" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeHashErrorActionMissing `
    $SkillText

  $readmeHashDigestGateDisabled = & $replaceExactlyOnce `
    $ReadmeText `
    '  if ($hash -cnotmatch ''^[0-9A-F]{64}$'') {' `
    '  if ($false) {' `
    "readme-hash-digest-gate-disabled"
  & $addMutation `
    "readme-hash-digest-gate-disabled" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeHashDigestGateDisabled `
    $SkillText

  # canonical bytesを保ったまま外側containerで非表示にする反例を固定する。
  $readmeHtmlCommentWrapped = & $replaceExactlyOnce `
    $ReadmeText `
    "## Install`n" `
    "<!--`n## Install`n" `
    "readme-html-comment-wrap-install"
  $readmeHtmlCommentWrapped = & $replaceExactlyOnce `
    $readmeHtmlCommentWrapped `
    "## Manual Use`n" `
    "## Manual Use`n-->`n" `
    "readme-html-comment-wrap-install"
  & $addMutation `
    "readme-html-comment-wrap-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeHtmlCommentWrapped `
    $SkillText

  $readmeFenceWrapped = & $replaceExactlyOnce `
    $ReadmeText `
    "## Install`n" `
    "~~~~`n## Install`n" `
    "readme-top-level-fence-wrap-install"
  $readmeFenceWrapped = & $replaceExactlyOnce `
    $readmeFenceWrapped `
    "## Manual Use`n" `
    "## Manual Use`n~~~~`n" `
    "readme-top-level-fence-wrap-install"
  & $addMutation `
    "readme-top-level-fence-wrap-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeFenceWrapped `
    $SkillText

  # raw heading allowlistで、render時だけ同名になる装飾やclosing hashを拒否する。
  $readmeInlineSplitInstall = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n## In**stall**`n"
  )
  & $addMutation `
    "readme-inline-split-semantic-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeInlineSplitInstall `
    $SkillText

  $readmeContainerAtxInstall = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n> ## In**stall**`n"
  )
  & $addMutation `
    "readme-container-atx-semantic-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeContainerAtxInstall `
    $SkillText

  $readmeContainerSetextInstall = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n> Install`n> ---`n"
  )
  & $addMutation `
    "readme-container-setext-semantic-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeContainerSetextInstall `
    $SkillText

  $readmeManualUseClosingHashBeforeInstall = & $replaceExactlyOnce `
    $ReadmeText `
    "## Install`n" `
    "## Manual Use ##`n`n## Install`n" `
    "readme-closing-hash-manual-use-before-install"
  & $addMutation `
    "readme-closing-hash-manual-use-before-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeManualUseClosingHashBeforeInstall `
    $SkillText

  # entity decodeを実装しない代わりに、outside character referenceを一律拒否する。
  $readmeEntityRuntimeTokenOutside = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`nOutside token: ``C&#x6f;py-Item```n"
  )
  & $addMutation `
    "readme-entity-runtime-token-outside-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeEntityRuntimeTokenOutside `
    $SkillText

  $readmePrefixedInstall = & $replaceExactlyOnce `
    $ReadmeText `
    "## Install`n" `
    "x## Install`n" `
    "readme-prefixed-canonical-install"
  & $addMutation `
    "readme-prefixed-canonical-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmePrefixedInstall `
    $SkillText

  $readmeMarkerOutside = (
    "# runtime-closure-install:start`n" +
    $ReadmeText
  )
  & $addMutation `
    "readme-marker-outside-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeMarkerOutside `
    $SkillText

  $readmeTokenOutside = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`nOutside token: ``cOpY-iTeM```n"
  )
  & $addMutation `
    "readme-mixed-case-copy-token-outside-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeTokenOutside `
    $SkillText

  $readmeRuntimeVariableOutside = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n" +
    'Outside variable: `$RuNtImEfIlEs`' +
    "`n"
  )
  & $addMutation `
    "readme-mixed-case-runtime-variable-outside-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeRuntimeVariableOutside `
    $SkillText

  $readmeHashHelperOutside = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n" +
    'Outside variable: `$GeTrEqUiReDfIlEsHa256`' +
    "`n"
  )
  & $addMutation `
    "readme-mixed-case-hash-helper-outside-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeHashHelperOutside `
    $SkillText

  $readmeClosingHashHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n* * *`n  ## Install ##`n"
  )
  & $addMutation `
    "readme-alternate-atx-closing-hash" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeClosingHashHeading `
    $SkillText

  $readmeSetextHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`nInstall`n-------`n"
  )
  & $addMutation `
    "readme-setext-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeSetextHeading `
    $SkillText

  $readmeInlineHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n* `n  ## *Install*`n"
  )
  & $addMutation `
    "readme-inline-format-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeInlineHeading `
    $SkillText

  $readmeEntityAtxHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n## Inst&#x61;ll`n"
  )
  & $addMutation `
    "readme-entity-atx-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeEntityAtxHeading `
    $SkillText

  $readmeHtmlCommentSplitAtxHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n## Inst<!-- -->all`n"
  )
  & $addMutation `
    "readme-html-comment-split-atx-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeHtmlCommentSplitAtxHeading `
    $SkillText

  $readmeRawHtmlHeading = (
    $ReadmeText.TrimEnd([char]10) +
    "`n`n<!-- prefix --><h2>Install</h2>`n"
  )
  & $addMutation `
    "readme-prefixed-raw-html-h2-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeRawHtmlHeading `
    $SkillText

  $readmeManualUseMissing = & $replaceExactlyOnce `
    $ReadmeText `
    "## Manual Use`n" `
    "## Manual Usage`n" `
    "readme-manual-use-missing"
  & $addMutation `
    "readme-manual-use-missing" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeManualUseMissing `
    $SkillText

  $readmeManualUseDuplicate = & $replaceExactlyOnce `
    $ReadmeText `
    "## Manual Use`n" `
    "## Manual Use`n## Manual Use`n" `
    "readme-manual-use-duplicate"
  & $addMutation `
    "readme-manual-use-duplicate" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeManualUseDuplicate `
    $SkillText

  $readmeWithoutManualUse = & $replaceExactlyOnce `
    $ReadmeText `
    "## Manual Use`n" `
    "" `
    "readme-manual-use-before-install"
  $readmeManualUseBeforeInstall = & $replaceExactlyOnce `
    $readmeWithoutManualUse `
    "## Install`n" `
    "## Manual Use`n`n## Install`n" `
    "readme-manual-use-before-install"
  & $addMutation `
    "readme-manual-use-before-install" `
    "[runtime-closure-install]" `
    $RuntimeManifestText `
    $readmeManualUseBeforeInstall `
    $SkillText

  $readmeAstInvalid = & $replaceExactlyOnce `
    $ReadmeText `
    '$repoRoot = (Resolve-Path ".").Path' `
    '$repoRoot = )' `
    "readme-runtime-powershell-invalid"
  & $addMutation `
    "readme-runtime-powershell-invalid" `
    "[runtime-closure-powershell]" `
    $RuntimeManifestText `
    $readmeAstInvalid `
    $SkillText

  # fixture数、入力変化、error prefixを同時に検査し、自己テストのfalse-greenを防ぐ。
  if ($mutationCases.Count -ne $expectedMutationCount) {
    Add-Error (
      "[runtime-closure-self-test] Expected $expectedMutationCount " +
      "mutation classes, found $($mutationCases.Count)."
    )
  }
  foreach ($mutation in $mutationCases) {
    $changedInputCount = 0
    if ($mutation.Manifest -cne $RuntimeManifestText) {
      $changedInputCount++
    }
    if ($mutation.Readme -cne $ReadmeText) {
      $changedInputCount++
    }
    if ($mutation.Skill -cne $SkillText) {
      $changedInputCount++
    }
    if ($changedInputCount -ne 1) {
      Add-Error (
        "[runtime-closure-self-test] Mutation '$($mutation.Name)' changed " +
        "$changedInputCount inputs instead of exactly one."
      )
      continue
    }

    $mutationErrors = @(
      Get-RuntimeClosureContractErrors `
        -RuntimeManifestText $mutation.Manifest `
        -ReadmeText $mutation.Readme `
        -SkillText $mutation.Skill `
        -PublicExampleManifest $PublicExampleManifest
    )
    $hasExpectedPrefix = @(
      $mutationErrors |
        Where-Object {
          ([string]$_).StartsWith(
            [string]$mutation.Expected,
            [StringComparison]::Ordinal
          )
        }
    ).Count -gt 0
    if (-not $hasExpectedPrefix) {
      Add-Error (
        "[runtime-closure-self-test] Mutation '$($mutation.Name)' was not " +
        "rejected with $($mutation.Expected). Actual: " +
        "$($mutationErrors -join '; ')"
      )
    }
  }

  if ($errors.Count -eq $selfTestErrorCountBefore) {
    Write-Output (
      "Runtime closure strict contract self-test passed " +
      "($($expectedPaths.Count) files, " +
      "$($mutationCases.Count) hostile mutation classes rejected)."
    )
  }
}

function Assert-RuntimeClosureAtomicClaimFixture {
  $fixtureRoot = Join-Path (
    [IO.Path]::GetTempPath()
  ) (
    "bounded-playwright-runtime-claim-" +
    [guid]::NewGuid().ToString("N")
  )
  $stagingPath = Join-Path $fixtureRoot "staging"
  $targetPath = Join-Path $fixtureRoot "target"
  $fixtureCreated = $false

  try {
    # preflight後に別installerがtargetを作った順序を、同一processで決定論的に再現する。
    New-Item `
      -ItemType Directory `
      -Path $fixtureRoot `
      -ErrorAction Stop | Out-Null
    $fixtureCreated = $true
    New-Item `
      -ItemType Directory `
      -Path $stagingPath `
      -ErrorAction Stop | Out-Null
    Set-Content `
      -LiteralPath (Join-Path $stagingPath "payload.txt") `
      -Value "staging-owner" `
      -Encoding UTF8 `
      -NoNewline `
      -ErrorAction Stop

    if (Test-Path -LiteralPath $targetPath) {
      throw "Atomic claim fixture target unexpectedly exists before interleaving."
    }
    New-Item `
      -ItemType Directory `
      -Path $targetPath `
      -ErrorAction Stop | Out-Null
    $sentinelPath = Join-Path $targetPath "sentinel.txt"
    Set-Content `
      -LiteralPath $sentinelPath `
      -Value "concurrent-owner" `
      -Encoding UTF8 `
      -NoNewline `
      -ErrorAction Stop

    $claimRejected = $false
    try {
      [IO.Directory]::Move($stagingPath, $targetPath)
    } catch [IO.IOException] {
      $claimRejected = $true
    }
    if (-not $claimRejected) {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "Directory.Move did not reject the concurrent target."
      )
    }
    if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -or
      (Get-Content -LiteralPath $sentinelPath -Raw -Encoding UTF8) -cne
        "concurrent-owner") {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "Concurrent target content was changed."
      )
    }
    if (-not (Test-Path `
        -LiteralPath (Join-Path $stagingPath "payload.txt") `
        -PathType Leaf)) {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "Rejected staging content was not retained for ownership verification."
      )
    }

    # 同じpathを別regular directoryへ置換し、boolean所有判定では守れないraceを再現する。
    $ownedStagingPath = Join-Path $fixtureRoot "owned-staging"
    [IO.Directory]::Move($stagingPath, $ownedStagingPath)
    New-Item `
      -ItemType Directory `
      -Path $stagingPath `
      -ErrorAction Stop | Out-Null
    $replacementSentinelPath = Join-Path $stagingPath "replacement-sentinel.txt"
    Set-Content `
      -LiteralPath $replacementSentinelPath `
      -Value "replacement-owner" `
      -Encoding UTF8 `
      -NoNewline `
      -ErrorAction Stop

    # installerと同じく失敗pathを自動削除せず、identityを証明できないreplacementを保持する。
    if (-not (Test-Path -LiteralPath $replacementSentinelPath -PathType Leaf)) {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "Failure cleanup deleted a replacement staging directory."
      )
    }
    if (-not (Test-Path `
        -LiteralPath (Join-Path $ownedStagingPath "payload.txt") `
        -PathType Leaf)) {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "The originally created staging directory was not preserved."
      )
    }
    if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -or
      (Get-Content -LiteralPath $sentinelPath -Raw -Encoding UTF8) -cne
        "concurrent-owner") {
      Add-Error (
        "[runtime-closure-atomic-fixture] " +
        "Failure retention changed the concurrent target."
      )
    }
  } catch {
    Add-Error (
      "[runtime-closure-atomic-fixture] Fixture failed with " +
      "$($_.Exception.GetType().Name)."
    )
  } finally {
    # GUID配下だけを自己所有fixtureとして削除し、target外をcleanupしない。
    if ($fixtureCreated -and
      (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
      Remove-Item `
        -LiteralPath $fixtureRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    }
  }

  Write-Output "Runtime closure atomic claim and failure retention fixture passed."
}

function Assert-RuntimeClosureSourceMutationFixture {
  $fixtureRoot = Join-Path (
    [IO.Path]::GetTempPath()
  ) (
    "bounded-playwright-runtime-source-" +
    [guid]::NewGuid().ToString("N")
  )
  $fixtureCreated = $false

  try {
    New-Item `
      -ItemType Directory `
      -Path $fixtureRoot `
      -ErrorAction Stop | Out-Null
    $fixtureCreated = $true
    $sourcePath = Join-Path $fixtureRoot "source.txt"
    $destinationPath = Join-Path $fixtureRoot "destination.txt"
    $missingHashPath = Join-Path $fixtureRoot "missing.txt"

    # missing sourceのhash取得がnullを返して続行せず、terminating errorになることを固定する。
    $hashFailureRejected = $false
    try {
      Get-RequiredFileSha256 -LiteralPath $missingHashPath | Out-Null
    } catch {
      $hashFailureRejected = $true
    }
    if (-not $hashFailureRejected) {
      Add-Error (
        "[runtime-closure-source-fixture] " +
        "A failed SHA-256 calculation did not fail closed."
      )
    }

    Set-Content `
      -LiteralPath $sourcePath `
      -Value "trusted-before-copy" `
      -Encoding UTF8 `
      -NoNewline `
      -ErrorAction Stop
    $expectedHash = Get-RequiredFileSha256 -LiteralPath $sourcePath
    Copy-Item `
      -LiteralPath $sourcePath `
      -Destination $destinationPath `
      -ErrorAction Stop
    if ((Get-RequiredFileSha256 -LiteralPath $destinationPath) -cne
      $expectedHash) {
      throw "Source mutation fixture initial copy changed unexpectedly."
    }

    # copy後・claim前の持続的なsource変更を再現し、preflight hashとの差で拒否する。
    Set-Content `
      -LiteralPath $sourcePath `
      -Value "changed-after-copy" `
      -Encoding UTF8 `
      -NoNewline `
      -ErrorAction Stop
    $sourceMutationRejected = (
      (Get-RequiredFileSha256 -LiteralPath $sourcePath) -cne $expectedHash
    )
    if (-not $sourceMutationRejected) {
      Add-Error (
        "[runtime-closure-source-fixture] " +
        "A source mutation after copy was not rejected."
      )
    }
  } catch {
    Add-Error (
      "[runtime-closure-source-fixture] Fixture failed with " +
      "$($_.Exception.GetType().Name)."
    )
  } finally {
    if ($fixtureCreated -and
      (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
      Remove-Item `
        -LiteralPath $fixtureRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    }
  }

  Write-Output "Runtime closure hash failure and source mutation fixture passed."
}

function Get-JavaScriptLexicalMap {
  param([string]$Content)

  # 公開exampleは小さい固定snippetである。異常に巨大な入力は正規表現評価へ渡さない。
  $maximumContractCodeLength = 200000
  if ($Content.Length -gt $maximumContractCodeLength) {
    return [pscustomobject]@{
      IsValid = $false
      Error = "JavaScript evidence block exceeds the lexical scan limit."
      Mask = ""
    }
  }

  $mask = New-Object System.Text.StringBuilder($Content.Length)
  $state = "code"
  $escaped = $false
  $lexicalError = ""

  for ($index = 0; $index -lt $Content.Length; $index++) {
    $character = $Content[$index]
    $nextCharacter = if ($index + 1 -lt $Content.Length) {
      $Content[$index + 1]
    } else {
      [char]0
    }

    if ($state -ceq "code") {
      # comment開始記号自体も空白化し、内部tokenをactive codeとして数えない。
      if ($character -eq "/" -and $nextCharacter -eq "/") {
        [void]$mask.Append("  ")
        $index++
        $state = "line-comment"
        continue
      }
      if ($character -eq "/" -and $nextCharacter -eq "*") {
        [void]$mask.Append("  ")
        $index++
        $state = "block-comment"
        continue
      }
      if ($character -eq "'") {
        [void]$mask.Append(" ")
        $state = "single-quoted-string"
        $escaped = $false
        continue
      }
      if ($character -eq '"') {
        [void]$mask.Append(" ")
        $state = "double-quoted-string"
        $escaped = $false
        continue
      }
      if ($character -eq [char]96) {
        [void]$mask.Append(" ")
        $state = "template-literal"
        $escaped = $false
        continue
      }
      [void]$mask.Append($character)
      continue
    }

    if ($state -ceq "line-comment") {
      if ($character -eq "`r" -or $character -eq "`n") {
        [void]$mask.Append($character)
        $state = "code"
      } else {
        [void]$mask.Append(" ")
      }
      continue
    }

    if ($state -ceq "block-comment") {
      if ($character -eq "*" -and $nextCharacter -eq "/") {
        [void]$mask.Append("  ")
        $index++
        $state = "code"
      } elseif ($character -eq "`r" -or $character -eq "`n") {
        [void]$mask.Append($character)
      } else {
        [void]$mask.Append(" ")
      }
      continue
    }

    # quoted string / template literalは同じ長さの空白へ置換し、offset対応を保つ。
    if ($escaped) {
      if ($character -eq "`r" -or $character -eq "`n") {
        [void]$mask.Append($character)
      } else {
        [void]$mask.Append(" ")
      }
      $escaped = $false
      continue
    }
    if ($character -eq "\") {
      [void]$mask.Append(" ")
      $escaped = $true
      continue
    }
    if (
      $state -ceq "template-literal" -and
      $character -eq '$' -and
      $nextCharacter -eq '{'
    ) {
      # `${...}` はliteral本文ではなく実行式になる。部分parseせず、境界をfail closedにする。
      [void]$mask.Append(" ")
      if ([string]::IsNullOrEmpty($lexicalError)) {
        $lexicalError = "JavaScript template interpolation is not allowed."
      }
      continue
    }

    $closingCharacter = switch ($state) {
      "single-quoted-string" { "'" }
      "double-quoted-string" { '"' }
      "template-literal" { [char]96 }
    }
    if ($character -eq $closingCharacter) {
      [void]$mask.Append(" ")
      $state = "code"
      continue
    }
    if ($character -eq "`r" -or $character -eq "`n") {
      [void]$mask.Append($character)
      if (
        $state -ne "template-literal" -and
        [string]::IsNullOrEmpty($lexicalError)
      ) {
        $lexicalError = "Quoted JavaScript string crosses an unescaped line boundary."
      }
    } else {
      [void]$mask.Append(" ")
    }
  }

  if (
    $state -ne "code" -and
    $state -ne "line-comment" -and
    [string]::IsNullOrEmpty($lexicalError)
  ) {
    $lexicalError = "JavaScript comment or string is not terminated."
  }

  return [pscustomobject]@{
    IsValid = [string]::IsNullOrEmpty($lexicalError)
    Error = $lexicalError
    Mask = $mask.ToString()
  }
}

function Get-JavaScriptLineAtOffset {
  param(
    [string]$Content,
    [int]$Offset
  )

  if ($Offset -lt 0 -or $Offset -ge $Content.Length) {
    return ""
  }
  $lineStart = if ($Offset -eq 0) {
    0
  } else {
    $Content.LastIndexOf("`n", $Offset - 1) + 1
  }
  $lineEnd = $Content.IndexOf("`n", $Offset)
  if ($lineEnd -lt 0) {
    $lineEnd = $Content.Length
  }
  return $Content.Substring($lineStart, $lineEnd - $lineStart).TrimEnd([char]13)
}

function Get-SkillReadinessContractErrors {
  param([string]$SkillText)

  $contractErrors = New-Object System.Collections.Generic.List[string]
  $section = Get-MarkdownH2RawSection `
    -Content $SkillText `
    -Heading "Suggested Playwright Evidence"
  if ($section.MatchCount -ne 1) {
    $contractErrors.Add(
      "[skill-readiness-section] Suggested Playwright Evidence H2 must appear exactly once."
    ) | Out-Null
    return $contractErrors.ToArray()
  }

  # 対象sectionの別fenceへ正解を置くdecoyを防ぐため、単一JavaScript blockへ閉じる。
  $blocks = @(Get-MarkdownFencedBlocks -Lines $section.Lines)
  if (
    $blocks.Count -ne 1 -or
    $blocks[0].Info -cne "javascript" -or
    -not $blocks[0].IsClosed
  ) {
    $contractErrors.Add(
      "[skill-readiness-fence] Suggested Playwright Evidence must contain one closed javascript fence."
    ) | Out-Null
    return $contractErrors.ToArray()
  }

  $code = $blocks[0].Content
  $lexicalMap = Get-JavaScriptLexicalMap -Content $code
  if (-not $lexicalMap.IsValid) {
    $contractErrors.Add(
      "[skill-readiness-code] Active JavaScript evidence is lexically invalid: $($lexicalMap.Error)"
    ) | Out-Null
    return $contractErrors.ToArray()
  }

  # tokenのactive位置を先に確定し、raw lineのquoted option値はその位置からだけ評価する。
  $locatorTokenMatches = [regex]::Matches(
    $lexicalMap.Mask,
    '(?m)^[ \t]*const[ \t]+readyLocator\b'
  )
  $navigationTokenMatches = [regex]::Matches(
    $lexicalMap.Mask,
    '\bpage\.goto\b'
  )
  $waitTokenMatches = [regex]::Matches(
    $lexicalMap.Mask,
    '\breadyLocator\.waitFor\b'
  )
  $locatorLine = if ($locatorTokenMatches.Count -eq 1) {
    Get-JavaScriptLineAtOffset `
      -Content $code `
      -Offset $locatorTokenMatches[0].Index
  } else {
    ""
  }
  $navigationLine = if ($navigationTokenMatches.Count -eq 1) {
    Get-JavaScriptLineAtOffset `
      -Content $code `
      -Offset $navigationTokenMatches[0].Index
  } else {
    ""
  }
  $waitLine = if ($waitTokenMatches.Count -eq 1) {
    Get-JavaScriptLineAtOffset `
      -Content $code `
      -Offset $waitTokenMatches[0].Index
  } else {
    ""
  }
  $locatorPattern = (
    '^[ \t]*const[ \t]+readyLocator[ \t]*=[ \t]*' +
    'page\.getByRole\([ \t]*"main"[ \t]*\)[ \t]*;[ \t]*$'
  )
  $navigationPattern = (
    '^[ \t]*await[ \t]+page\.goto\([ \t]*targetUrl[ \t]*,[ \t]*' +
    '\{[ \t]*waitUntil:[ \t]*"load"[ \t]*,[ \t]*timeout:[ \t]*15000[ \t]*' +
    '\}[ \t]*\)[ \t]*;[ \t]*$'
  )
  $waitPattern = (
    '^[ \t]*await[ \t]+readyLocator\.waitFor\([ \t]*' +
    '\{[ \t]*state:[ \t]*"visible"[ \t]*,[ \t]*timeout:[ \t]*10000[ \t]*' +
    '\}[ \t]*\)[ \t]*;[ \t]*$'
  )
  $locatorIsExact = (
    $locatorTokenMatches.Count -eq 1 -and
    $locatorLine -cmatch $locatorPattern
  )
  $navigationIsExact = (
    $navigationTokenMatches.Count -eq 1 -and
    $navigationLine -cmatch $navigationPattern
  )
  $waitIsExact = (
    $waitTokenMatches.Count -eq 1 -and
    $waitLine -cmatch $waitPattern
  )

  if (
    $navigationTokenMatches.Count -eq 1 -and
    $navigationLine -match '(?i)"networkidle"'
  ) {
    $contractErrors.Add(
      "[skill-readiness-networkidle] Active Playwright evidence code must not use networkidle."
    ) | Out-Null
  }
  if (-not $locatorIsExact) {
    $contractErrors.Add(
      "[skill-readiness-locator] Exact route/state readiness locator must appear once."
    ) | Out-Null
  }
  if (-not $navigationIsExact) {
    $contractErrors.Add(
      "[skill-readiness-navigation] Exact bounded load navigation must appear once."
    ) | Out-Null
  }
  if (-not $waitIsExact) {
    $contractErrors.Add(
      "[skill-readiness-wait] Exact bounded visible locator wait must appear once."
    ) | Out-Null
  }

  # 各statementが正しいだけでなく、locator準備→navigation→UI readyの順序も固定する。
  if (
    $locatorIsExact -and
    $navigationIsExact -and
    $waitIsExact -and
    -not (
      $locatorTokenMatches[0].Index -lt $navigationTokenMatches[0].Index -and
      $navigationTokenMatches[0].Index -lt $waitTokenMatches[0].Index
    )
  ) {
    $contractErrors.Add(
      "[skill-readiness-order] Locator, navigation, and readiness wait must remain ordered."
    ) | Out-Null
  }

  return $contractErrors.ToArray()
}

function Assert-SkillReadinessContractMutations {
  param([string]$SkillText)

  $baselineErrors = @(Get-SkillReadinessContractErrors -SkillText $SkillText)
  if ($baselineErrors.Count -gt 0) {
    Add-Error "[skill-readiness-mutation] Baseline contract is invalid; mutation self-test skipped."
    return
  }

  $expectedMutationCount = 28
  $gotoLine = '  await page.goto(targetUrl, { waitUntil: "load", timeout: 15000 });'
  $waitLine = '  await readyLocator.waitFor({ state: "visible", timeout: 10000 });'
  $networkidleSkill = $SkillText.Replace(
    'waitUntil: "load"',
    'waitUntil: "networkidle"'
  )
  $commentDecoySkill = $networkidleSkill.Replace(
    $gotoLine.Replace('"load"', '"networkidle"'),
    ('// ' + $gotoLine + "`n" + $gotoLine.Replace('"load"', '"networkidle"'))
  )
  $blockCommentDecoySkill = $networkidleSkill.Replace(
    $gotoLine.Replace('"load"', '"networkidle"'),
    (
      '/* ' +
      $gotoLine +
      " */`n" +
      $gotoLine.Replace('"load"', '"networkidle"')
    )
  )
  $evidencePrefix = (
    'Adapt this pattern to the project. Keep all waits bounded.' +
    "`n`n" +
    '```javascript'
  )
  $otherFenceSkill = $networkidleSkill.Replace(
    $evidencePrefix,
    (
      'Adapt this pattern to the project. Keep all waits bounded.' +
      "`n`n" +
      '```javascript' +
      "`n$gotoLine`n" +
      '```' +
      "`n`n" +
      '```javascript'
    )
  )
  $reversedOrderSkill = $SkillText.Replace(
    ($gotoLine + "`n" + $waitLine),
    ($waitLine + "`n" + $gotoLine)
  )
  $closingFenceNeedle = '}' + "`n" + '```' + "`n"
  $unterminatedFenceSkill = $SkillText.Replace(
    $closingFenceNeedle,
    ('}' + "`n")
  )
  # HTML commentをdelimiterの間へ挟み、除去後の連結で構造を合成できないことを固定する。
  $commentSplitHeadingSkill = $SkillText.Replace(
    '## Suggested Playwright Evidence',
    '#<!-- heading split --># Suggested Playwright Evidence'
  )
  $commentSplitFenceSkill = $SkillText.Replace(
    '```javascript',
    (
      [char]96 +
      '<!-- fence split -->' +
      [char]96 +
      [char]96 +
      'javascript'
    )
  )
  # indent付きの別H2は対象sectionを閉じ、その後のfenceを対象blockへ混入させない。
  $indentedNonTargetBoundarySkill = $SkillText.Replace(
    '## Synthetic Examples',
    (
      ' ## Synthetic Boundary' +
      "`n`n" +
      '```javascript' +
      "`n" +
      'page.goto("synthetic-only");' +
      "`n" +
      '```' +
      "`n`n" +
      '## Synthetic Examples'
    )
  )
  # 正解行を非実行領域へ移すdecoyを作り、tokenの見た目だけでは合格しないことを固定する。
  $templateLiteralNavigationDecoySkill = $SkillText.Replace(
    $gotoLine,
    (
      '  const navigationDecoy = ' +
      [char]96 +
      "`n" +
      $gotoLine +
      "`n" +
      [char]96 +
      ';'
    )
  )
  $singleQuotedNavigationDecoySkill = $SkillText.Replace(
    $gotoLine,
    "  const navigationDecoy = 'page.goto(targetUrl)';"
  )
  $doubleQuotedNavigationDecoySkill = $SkillText.Replace(
    $gotoLine,
    '  const navigationDecoy = "page.goto(targetUrl)";'
  )
  # 未終端literalは後続行を誤ってactive codeへ戻さず、lexical errorとしてfail closedにする。
  $unterminatedSingleQuotedStringSkill = $SkillText.Replace(
    $gotoLine,
    "  const navigationDecoy = 'page.goto(targetUrl);"
  )
  $unterminatedDoubleQuotedStringSkill = $SkillText.Replace(
    $gotoLine,
    '  const navigationDecoy = "page.goto(targetUrl);'
  )
  $unterminatedTemplateLiteralSkill = $SkillText.Replace(
    $gotoLine,
    (
      '  const navigationDecoy = ' +
      [char]96 +
      "`n" +
      $gotoLine
    )
  )
  # template interpolationは式を実行するため、内容にかかわらずfail closedにする。
  $templateInterpolationNavigationSkill = $SkillText.Replace(
    $gotoLine,
    (
      '  const interpolationDecoy = ' +
      [char]96 +
      'ignored ${page.goto(targetUrl)}' +
      [char]96 +
      ';' +
      "`n" +
      $gotoLine
    )
  )
  $benignTemplateInterpolationSkill = $SkillText.Replace(
    $gotoLine,
    (
      '  const benignInterpolation = ' +
      [char]96 +
      'target=${targetUrl}' +
      [char]96 +
      ';' +
      "`n" +
      $gotoLine
    )
  )
  # `\${` はinterpolation開始ではない。literal内tokenをactive navigationへ数えない。
  $escapedTemplateInterpolationDecoySkill = $SkillText.Replace(
    $gotoLine,
    (
      '  const navigationDecoy = ' +
      [char]96 +
      'literal \${page.goto(targetUrl)}' +
      [char]96 +
      ';'
    )
  )
  $mutationCases = @(
    [pscustomobject]@{
      Name = "networkidle-navigation"
      Expected = "[skill-readiness-networkidle]"
      SkillText = $networkidleSkill
    },
    [pscustomobject]@{
      Name = "missing-navigation-timeout"
      Expected = "[skill-readiness-navigation]"
      SkillText = $SkillText.Replace(', timeout: 15000 });', ' });')
    },
    [pscustomobject]@{
      Name = "missing-readiness-wait"
      Expected = "[skill-readiness-wait]"
      SkillText = $SkillText.Replace(($waitLine + "`n"), "")
    },
    [pscustomobject]@{
      Name = "missing-readiness-timeout"
      Expected = "[skill-readiness-wait]"
      SkillText = $SkillText.Replace(', timeout: 10000 });', ' });')
    },
    [pscustomobject]@{
      Name = "reversed-navigation-and-wait"
      Expected = "[skill-readiness-order]"
      SkillText = $reversedOrderSkill
    },
    [pscustomobject]@{
      Name = "line-comment-navigation-decoy"
      Expected = "[skill-readiness-networkidle]"
      SkillText = $commentDecoySkill
    },
    [pscustomobject]@{
      Name = "block-comment-navigation-decoy"
      Expected = "[skill-readiness-networkidle]"
      SkillText = $blockCommentDecoySkill
    },
    [pscustomobject]@{
      Name = "other-fence-navigation-decoy"
      Expected = "[skill-readiness-fence]"
      SkillText = $otherFenceSkill
    },
    [pscustomobject]@{
      Name = "wrong-readiness-locator"
      Expected = "[skill-readiness-locator]"
      SkillText = $SkillText.Replace(
        'page.getByRole("main")',
        'page.locator("body")'
      )
    },
    [pscustomobject]@{
      Name = "duplicate-navigation"
      Expected = "[skill-readiness-navigation]"
      SkillText = $SkillText.Replace(
        $gotoLine,
        ($gotoLine + "`n" + $gotoLine)
      )
    },
    [pscustomobject]@{
      Name = "unterminated-javascript-fence"
      Expected = "[skill-readiness-fence]"
      SkillText = $unterminatedFenceSkill
    },
    [pscustomobject]@{
      Name = "duplicate-readiness-heading"
      Expected = "[skill-readiness-section]"
      SkillText = ($SkillText + "`n## Suggested Playwright Evidence`n")
    },
    [pscustomobject]@{
      Name = "template-literal-navigation-decoy"
      Expected = "[skill-readiness-navigation]"
      SkillText = $templateLiteralNavigationDecoySkill
    },
    [pscustomobject]@{
      Name = "single-quoted-navigation-decoy"
      Expected = "[skill-readiness-navigation]"
      SkillText = $singleQuotedNavigationDecoySkill
    },
    [pscustomobject]@{
      Name = "double-quoted-navigation-decoy"
      Expected = "[skill-readiness-navigation]"
      SkillText = $doubleQuotedNavigationDecoySkill
    },
    [pscustomobject]@{
      Name = "unterminated-single-quoted-string"
      Expected = "[skill-readiness-code]"
      SkillText = $unterminatedSingleQuotedStringSkill
    },
    [pscustomobject]@{
      Name = "unterminated-double-quoted-string"
      Expected = "[skill-readiness-code]"
      SkillText = $unterminatedDoubleQuotedStringSkill
    },
    [pscustomobject]@{
      Name = "unterminated-template-literal"
      Expected = "[skill-readiness-code]"
      SkillText = $unterminatedTemplateLiteralSkill
    },
    [pscustomobject]@{
      Name = "locator-role-case-drift"
      Expected = "[skill-readiness-locator]"
      SkillText = $SkillText.Replace(
        'page.getByRole("main")',
        'page.getByRole("Main")'
      )
    },
    [pscustomobject]@{
      Name = "navigation-option-case-drift"
      Expected = "[skill-readiness-navigation]"
      SkillText = $SkillText.Replace(
        'waitUntil: "load"',
        'waituntil: "load"'
      )
    },
    [pscustomobject]@{
      Name = "readiness-option-case-drift"
      Expected = "[skill-readiness-wait]"
      SkillText = $SkillText.Replace(
        'state: "visible"',
        'State: "visible"'
      )
    },
    [pscustomobject]@{
      Name = "template-interpolation-navigation"
      Expected = "[skill-readiness-code]"
      SkillText = $templateInterpolationNavigationSkill
    },
    [pscustomobject]@{
      Name = "benign-template-interpolation"
      Expected = "[skill-readiness-code]"
      SkillText = $benignTemplateInterpolationSkill
    },
    [pscustomobject]@{
      Name = "escaped-template-interpolation-decoy"
      Expected = "[skill-readiness-navigation]"
      SkillText = $escapedTemplateInterpolationDecoySkill
    },
    [pscustomobject]@{
      Name = "readiness-heading-case-drift"
      Expected = "[skill-readiness-section]"
      SkillText = $SkillText.Replace(
        '## Suggested Playwright Evidence',
        '## suggested playwright evidence'
      )
    },
    [pscustomobject]@{
      Name = "html-comment-split-readiness-heading"
      Expected = "[skill-readiness-section]"
      SkillText = $commentSplitHeadingSkill
    },
    [pscustomobject]@{
      Name = "html-comment-split-javascript-fence"
      Expected = "[skill-readiness-fence]"
      SkillText = $commentSplitFenceSkill
    },
    [pscustomobject]@{
      Name = "indented-duplicate-readiness-heading"
      Expected = "[skill-readiness-section]"
      SkillText = ($SkillText + "`n ## Suggested Playwright Evidence`n")
    }
  )

  if ($mutationCases.Count -ne $expectedMutationCount) {
    Add-Error "[skill-readiness-mutation] Mutation fixture count changed."
    return
  }
  foreach ($mutationCase in $mutationCases) {
    if ($mutationCase.SkillText -ceq $SkillText) {
      Add-Error (
        "[skill-readiness-mutation] Mutation fixture did not change input: " +
        $mutationCase.Name
      )
      continue
    }
    $mutationErrors = @(
      Get-SkillReadinessContractErrors -SkillText $mutationCase.SkillText
    )
    $matched = @(
      $mutationErrors |
        Where-Object { $_.Contains($mutationCase.Expected) }
    )
    if ($matched.Count -eq 0) {
      Add-Error (
        "[skill-readiness-mutation] Mutation escaped contract: " +
        $mutationCase.Name
      )
    }
  }

  if ($indentedNonTargetBoundarySkill -ceq $SkillText) {
    Add-Error "[skill-readiness-mutation] Indented non-target H2 positive fixture did not change input."
  } else {
    $indentedBoundaryErrors = @(
      Get-SkillReadinessContractErrors -SkillText $indentedNonTargetBoundarySkill
    )
    if ($indentedBoundaryErrors.Count -gt 0) {
      Add-Error (
        "[skill-readiness-mutation] Valid indented non-target H2 boundary was rejected."
      )
    }
  }

  Write-Output (
    "Skill readiness contract self-test passed " +
    "($($mutationCases.Count) hostile mutations rejected)."
  )
}

function Get-PublicExampleEvidenceTable {
  param(
    [string]$Content,
    [string]$Heading
  )

  $section = Get-MarkdownH2Section `
    -Content $Content `
    -Heading $Heading
  $rows = New-Object System.Collections.Generic.List[object]
  $headerPattern = [regex](
    '^\|\s*Category\s*\|' +
    '\s*Evidence(?: Collected)?\s*\|' +
    '\s*Result\s*\|' +
    '\s*(?:Correct Report Wording|Report Wording)\s*\|\s*$'
  )
  $separatorPattern = [regex](
    '^\|\s*:?-{3,}:?\s*\|' +
    '\s*:?-{3,}:?\s*\|' +
    '\s*:?-{3,}:?\s*\|' +
    '\s*:?-{3,}:?\s*\|\s*$'
  )
  $rowPattern = [regex](
    '^\|\s*(?<Category>[^|]+?)\s*\|' +
    '\s*(?<Evidence>[^|]*?)\s*\|' +
    '\s*(?<Result>[^|]*?)\s*\|' +
    '\s*(?<Wording>[^|]*?)\s*\|\s*$'
  )
  $headerIndexes = New-Object System.Collections.Generic.List[int]
  for ($index = 0; $index -lt $section.Lines.Count; $index++) {
    if ($headerPattern.IsMatch($section.Lines[$index])) {
      $headerIndexes.Add($index) | Out-Null
    }
  }

  if ($section.MatchCount -eq 1 -and $headerIndexes.Count -eq 1) {
    $headerIndex = $headerIndexes[0]
    $separatorIndex = $headerIndex + 1
    if ($separatorIndex -lt $section.Lines.Count -and
      $separatorPattern.IsMatch($section.Lines[$separatorIndex])) {
      for (
        $index = $separatorIndex + 1;
        $index -lt $section.Lines.Count;
        $index++
      ) {
        $match = $rowPattern.Match($section.Lines[$index])
        if (-not $match.Success) {
          break
        }
        $rows.Add([pscustomobject]@{
          Category = $match.Groups["Category"].Value.Trim()
          Evidence = $match.Groups["Evidence"].Value.Trim()
          Result = $match.Groups["Result"].Value.Trim()
          Wording = $match.Groups["Wording"].Value.Trim()
        }) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    SectionCount = $section.MatchCount
    HeaderCount = $headerIndexes.Count
    Rows = $rows.ToArray()
  }
}

function Copy-PublicExampleTextMap {
  param([hashtable]$Source)

  $copy = @{}
  foreach ($key in $Source.Keys) {
    $copy[$key] = $Source[$key]
  }
  return $copy
}

function Get-PublicExampleContractErrors {
  param(
    [string]$ReadmeText,
    [string]$SkillText,
    [string[]]$ExamplePaths,
    [hashtable]$ExampleTextByPath,
    [object[]]$Manifest
  )

  $contractErrors = New-Object System.Collections.Generic.List[string]
  $expectedPaths = @($Manifest | ForEach-Object { [string]$_.Path })
  $normalizedActualPaths = @(
    $ExamplePaths |
      ForEach-Object { ([string]$_).Replace("\", "/") }
  )

  # manifest自体のduplicateとrole/schema driftを先に拒否する。
  foreach ($entry in $Manifest) {
    if (@($Manifest | Where-Object { $_.Path -ceq $entry.Path }).Count -ne 1) {
      $contractErrors.Add(
        "[public-example-manifest] Duplicate manifest path: $($entry.Path)"
      ) | Out-Null
    }
    if (@($Manifest | Where-Object { $_.Label -ceq $entry.Label }).Count -ne 1) {
      $contractErrors.Add(
        "[public-example-manifest] Duplicate manifest label: $($entry.Label)"
      ) | Out-Null
    }
    if ($entry.Role -notin @("asset", "report", "state-report")) {
      $contractErrors.Add(
        "[public-example-manifest] Unknown manifest role: $($entry.Role)"
      ) | Out-Null
    } elseif ($entry.Role -ceq "asset" -and
      (-not [string]::IsNullOrEmpty($entry.EvidenceHeading) -or
        $entry.Categories.Count -ne 0 -or
        $entry.StateCategories.Count -ne 0)) {
      $contractErrors.Add(
        "[public-example-manifest] Asset schema must not declare evidence categories."
      ) | Out-Null
    } elseif ($entry.Role -ceq "report" -and
      ([string]::IsNullOrEmpty($entry.EvidenceHeading) -or
        $entry.Categories.Count -eq 0 -or
        $entry.StateCategories.Count -ne 0)) {
      $contractErrors.Add(
        "[public-example-manifest] Report schema must declare only evidence categories."
      ) | Out-Null
    } elseif ($entry.Role -ceq "state-report" -and
      ([string]::IsNullOrEmpty($entry.EvidenceHeading) -or
        $entry.Categories.Count -eq 0 -or
        $entry.StateCategories.Count -eq 0)) {
      $contractErrors.Add(
        "[public-example-manifest] State-report schema must declare evidence and state categories."
      ) | Out-Null
    }
    foreach ($stateCategory in $entry.StateCategories) {
      if (@(
        $entry.StateCategories |
          Where-Object { $_ -ceq $stateCategory }
      ).Count -ne 1) {
        $contractErrors.Add(
          "[public-example-manifest] Duplicate state category: $stateCategory"
        ) | Out-Null
      }
    }
  }
  if (@($Manifest | Where-Object { $_.Role -ceq "state-report" }).Count -ne 1) {
    $contractErrors.Add(
      "[public-example-manifest] Manifest must declare exactly one state-report."
    ) | Out-Null
  }

  # directoryとmanifestを双方向に照合し、未公開fileや存在しない公開項目を拒否する。
  foreach ($entry in $Manifest) {
    if (@($normalizedActualPaths | Where-Object { $_ -ceq $entry.Path }).Count -ne 1) {
      $contractErrors.Add(
        "[public-example-manifest] Expected exactly one file: $($entry.Path)"
      ) | Out-Null
    }
  }
  foreach ($actualPath in $normalizedActualPaths) {
    if (@($expectedPaths | Where-Object { $_ -ceq $actualPath }).Count -ne 1) {
      $contractErrors.Add(
        "[public-example-manifest] Undeclared example file: $actualPath"
      ) | Out-Null
    }
  }

  # READMEとSKILLは同じexact label/path一覧を1回ずつ公開する。
  $linkPattern = [regex]'^-\s+\[(?<Label>[^\]\r\n]+)\]\((?<Path>examples/[^)#\r\n]+)\)\s*$'
  foreach ($document in @(
    [pscustomobject]@{
      Name = "README.md"
      Text = $ReadmeText
      Section = "Examples"
    },
    [pscustomobject]@{
      Name = "SKILL.md"
      Text = $SkillText
      Section = "Synthetic Examples"
    }
  )) {
    $indexSection = Get-MarkdownH2Section `
      -Content $document.Text `
      -Heading $document.Section
    if ($indexSection.MatchCount -ne 1) {
      $contractErrors.Add(
        "[public-example-link] $($document.Name) must contain exactly one '$($document.Section)' section."
      ) | Out-Null
    }
    $actualLinks = New-Object System.Collections.Generic.List[object]
    foreach ($sectionLine in $indexSection.Lines) {
      $linkMatch = $linkPattern.Match($sectionLine)
      if ($linkMatch.Success) {
        $actualLinks.Add($linkMatch) | Out-Null
      }
    }
    if ($actualLinks.Count -ne $Manifest.Count) {
      $contractErrors.Add(
        "[public-example-link] $($document.Name) must publish exactly $($Manifest.Count) example links."
      ) | Out-Null
    }
    foreach ($entry in $Manifest) {
      $matchingLinks = @(
        $actualLinks.ToArray() |
          Where-Object {
            $_.Groups["Label"].Value -ceq $entry.Label -and
            $_.Groups["Path"].Value -ceq $entry.Path
          }
      )
      if ($matchingLinks.Count -ne 1) {
        $contractErrors.Add(
          "[public-example-link] $($document.Name) must link exactly once: $($entry.Label) -> $($entry.Path)"
        ) | Out-Null
      }
    }
    foreach ($actualLink in $actualLinks.ToArray()) {
      $knownLink = @(
        $Manifest |
          Where-Object {
            $_.Label -ceq $actualLink.Groups["Label"].Value -and
            $_.Path -ceq $actualLink.Groups["Path"].Value
          }
      )
      if ($knownLink.Count -ne 1) {
        $contractErrors.Add(
          "[public-example-link] $($document.Name) publishes an undeclared example link."
        ) | Out-Null
      }
    }
  }

  # report例はカテゴリ集合をexactに閉じ、行の削除・重複・別名化を同じ判定で拒否する。
  foreach ($entry in $Manifest | Where-Object { $_.Role -in @("report", "state-report") }) {
    if (-not $ExampleTextByPath.ContainsKey($entry.Path)) {
      $contractErrors.Add(
        "[public-example-category] Cannot inspect missing report: $($entry.Path)"
      ) | Out-Null
      continue
    }
    $evidenceTable = Get-PublicExampleEvidenceTable `
      -Content $ExampleTextByPath[$entry.Path] `
      -Heading $entry.EvidenceHeading
    if ($evidenceTable.SectionCount -ne 1 -or
      $evidenceTable.HeaderCount -ne 1) {
      $contractErrors.Add(
        "[public-example-category] $($entry.Path) must contain one visible '$($entry.EvidenceHeading)' table."
      ) | Out-Null
    }
    $rows = @($evidenceTable.Rows)
    $actualCategories = @($rows | ForEach-Object { $_.Category })
    if ($actualCategories.Count -ne $entry.Categories.Count) {
      $contractErrors.Add(
        "[public-example-category] $($entry.Path) must contain exactly $($entry.Categories.Count) evidence categories."
      ) | Out-Null
    }
    foreach ($category in $entry.Categories) {
      if (@($actualCategories | Where-Object { $_ -ceq $category }).Count -ne 1) {
        $contractErrors.Add(
          "[public-example-category] $($entry.Path) must contain exactly one '$category' row."
        ) | Out-Null
      }
    }
    foreach ($actualCategory in $actualCategories) {
      if (@($entry.Categories | Where-Object { $_ -ceq $actualCategory }).Count -ne 1) {
        $contractErrors.Add(
          "[public-example-category] $($entry.Path) contains an undeclared '$actualCategory' row."
        ) | Out-Null
      }
    }
  }

  # 専用state例は3状態すべてを合成fixtureで完了した報告として固定する。
  # 後段へ相反する未確認/失敗文を足して表だけgreenにするappend bypassも拒否する。
  $stateEntries = @(
    $Manifest |
      Where-Object { $_.Role -ceq "state-report" }
  )
  if ($stateEntries.Count -eq 1) {
    $stateEntry = $stateEntries[0]
    $statePath = $stateEntry.Path
    foreach ($stateCategory in $stateEntry.StateCategories) {
      if (@(
        $stateEntry.Categories |
          Where-Object { $_ -ceq $stateCategory }
      ).Count -ne 1) {
        $contractErrors.Add(
          "[public-example-manifest] State category is not exact in report schema: $stateCategory"
        ) | Out-Null
      }
    }
  }
  if ($stateEntries.Count -eq 1 -and
    $ExampleTextByPath.ContainsKey($statePath)) {
    $stateText = [string]$ExampleTextByPath[$statePath]
    $stateEvidenceTable = Get-PublicExampleEvidenceTable `
      -Content $stateText `
      -Heading $stateEntry.EvidenceHeading
    $stateRows = @($stateEvidenceTable.Rows)
    # 表セルと表外claimで同じnegative語彙を使い、片側だけが緩むdriftを防ぐ。
    $negativeVerdictPattern = (
      '(?i)(?:' +
      [regex]::Escape($unverifiedMarker) +
      '|未実施' +
      '|\bunverified\b' +
      '|\bunchecked\b' +
      '|\bnot\s+(?:checked|verified|inspected|exercised)\b' +
      '|\bblocked\b' +
      '|\bfailed\b' +
      '|\bfailure\b' +
      '|\berror(?:ed)?\b' +
      '|\bincomplete\b)'
    )
    # 各state名を起点にした同じ構文を表セルと表外claimの両方へ適用する。
    # `Error state checked ...`のような正常文中のcategory名だけでは失敗扱いしない。
    $stateVerdictPatternByCategory = @{}
    foreach ($stateCategory in $stateEntry.StateCategories) {
      $shortState = $stateCategory -replace '(?i)\s+state$', ''
      $stateVerdictPatternByCategory[$stateCategory] = (
        '(?i)^(?:The\s+)?' +
        [regex]::Escape($shortState) +
        '(?:\s+state)?\s*' +
        '(?:(?:is|remains|was|has\s+been)\s+|[:=-]\s*)?' +
        '(?:currently\s+|still\s+)?' +
        $negativeVerdictPattern
      )
    }
    foreach ($stateCategory in $stateEntry.StateCategories) {
      $matchingRows = @(
        $stateRows |
          Where-Object { $_.Category -ceq $stateCategory }
      )
      if ($matchingRows.Count -eq 1) {
        $stateRow = $matchingRows[0]
        # Correct Report Wordingはinline codeで記録されるため、同じ長さのdelimiter
        # 1組だけを外して可視claim本文へ正規化する。装飾で先頭anchorを迂回させない。
        $visibleStateWording = $stateRow.Wording.Trim()
        $inlineCodeMatch = [regex]::Match(
          $visibleStateWording,
          '^(?<Delimiter>`+)(?<Text>.*)\k<Delimiter>$'
        )
        if ($inlineCodeMatch.Success) {
          $visibleStateWording = $inlineCodeMatch.Groups["Text"].Value.Trim()
        }
        if ($stateRow.Result -cne "Completed" -or
          $stateRow.Evidence -notmatch '(?i)\bsynthetic\b' -or
          $visibleStateWording -match
            $stateVerdictPatternByCategory[$stateCategory]) {
          $contractErrors.Add(
            "[public-example-state] $statePath has a contradictory '$stateCategory' verdict."
          ) | Out-Null
        }
      }
    }
    foreach ($visibleLine in (Get-MarkdownVisibleLines -Content $stateText)) {
      # heading / blockquote / bullet / ordered-list prefixを剥がしてclaim本文を比較する。
      $claimLine = $visibleLine.Trim()
      while ($claimLine.Length -gt 0) {
        if ($claimLine -match '^>+[ \t]*(?<Rest>.*)$') {
          $claimLine = $Matches["Rest"].Trim()
          continue
        }
        if ($claimLine -match (
          '^(?:#{1,6}|[-*+]|\d+[.)])[ \t]+(?<Rest>.*)$'
        )) {
          $claimLine = $Matches["Rest"].Trim()
          continue
        }
        break
      }
      foreach ($stateCategory in $stateEntry.StateCategories) {
        if ($claimLine -match
          $stateVerdictPatternByCategory[$stateCategory]) {
          $contractErrors.Add(
            "[public-example-state] $statePath appends a contradictory '$stateCategory' verdict."
          ) | Out-Null
        }
      }
    }
  }

  return $contractErrors.ToArray()
}

function Assert-PublicExampleContractMutations {
  param(
    [string]$ReadmeText,
    [string]$SkillText,
    [string[]]$ExamplePaths,
    [hashtable]$ExampleTextByPath,
    [object[]]$Manifest
  )

  $baselineErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $ExampleTextByPath `
      -Manifest $Manifest
  )
  if ($baselineErrors.Count -gt 0) {
    Add-Error "[public-example-mutation] Baseline contract is invalid; mutation self-test skipped."
    return
  }

  $stateEntries = @(
    $Manifest |
      Where-Object { $_.Role -ceq "state-report" }
  )
  if ($stateEntries.Count -ne 1) {
    Add-Error "[public-example-mutation] Exact state-report manifest entry is unavailable."
    return
  }
  $stateEntry = $stateEntries[0]
  $statePath = $stateEntry.Path
  $stateLabel = $stateEntry.Label
  $expectedPublicExampleMutationCount = 17
  $mutationCases = New-Object System.Collections.Generic.List[object]

  # link欠落: README側だけから専用state例を除き、片側driftを再現する。
  $missingLinkPattern = [regex](
    '(?m)^-\s+\[' + [regex]::Escape($stateLabel) + '\]\(' +
    [regex]::Escape($statePath) + '\)\s*\r?\n?'
  )
  $missingLinkReadme = $missingLinkPattern.Replace($ReadmeText, "", 1)
  $missingLinkErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $missingLinkReadme `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $ExampleTextByPath `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "missing-readme-link"
    Expected = "[public-example-link]"
    Errors = $missingLinkErrors
  }) | Out-Null

  # state欠落: 表からEmptyだけを削り、他2状態が残る部分合格を再現する。
  $missingStateMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $missingStateCategory = $stateEntry.StateCategories[1]
  $missingStatePattern = [regex](
    '(?m)^\| ' +
    [regex]::Escape($missingStateCategory) +
    ' \|[^\r\n]*\r?\n?'
  )
  $missingStateMap[$statePath] = $missingStatePattern.Replace(
    $missingStateMap[$statePath],
    "",
    1
  )
  $missingStateErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $missingStateMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "missing-empty-state"
    Expected = "[public-example-category]"
    Errors = $missingStateErrors
  }) | Out-Null

  # name drift: fileと両リンクを同時改名してもmanifest正本との差分を拒否する。
  $driftPath = "examples/loading-empty-error-report.md"
  $driftReadme = $ReadmeText.Replace($statePath, $driftPath)
  $driftSkill = $SkillText.Replace($statePath, $driftPath)
  $driftPaths = @(
    $ExamplePaths |
      ForEach-Object {
        if ($_ -ceq $statePath) {
          $driftPath
        } else {
          $_
        }
      }
  )
  $driftMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $driftMap[$driftPath] = $driftMap[$statePath]
  $driftMap.Remove($statePath)
  $nameDriftErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $driftReadme `
      -SkillText $driftSkill `
      -ExamplePaths $driftPaths `
      -ExampleTextByPath $driftMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "example-name-drift"
    Expected = "[public-example-manifest]"
    Errors = $nameDriftErrors
  }) | Out-Null

  # 矛盾append: 正しい表の後ろへ相反する未確認文を足す偽合格を再現する。
  $contradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $contradictionMap[$statePath] = (
    $contradictionMap[$statePath] +
    [Environment]::NewLine +
    "$($stateEntry.StateCategories[-1]) remains $unverifiedMarker."
  )
  $contradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $contradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "contradictory-state-append"
    Expected = "[public-example-state]"
    Errors = $contradictionErrors
  }) | Out-Null

  # nested file: 再帰列挙された未宣言exampleをmanifest外として拒否する。
  $nestedPath = "examples/nested/undeclared-example.md"
  $nestedPaths = @($ExamplePaths) + @($nestedPath)
  $nestedMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $nestedMap[$nestedPath] = "# Undeclared Synthetic Example"
  $nestedErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $nestedPaths `
      -ExampleTextByPath $nestedMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "nested-undeclared-example"
    Expected = "[public-example-manifest]"
    Errors = $nestedErrors
  }) | Out-Null

  # link comment decoy: index行をHTML commentへ移して公開linkに見せる偽合格を再現する。
  $stateLinkLine = "- [$stateLabel]($statePath)"
  $commentedLinkReadme = $ReadmeText.Replace(
    $stateLinkLine,
    "<!-- $stateLinkLine -->"
  )
  $commentedLinkErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $commentedLinkReadme `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $ExampleTextByPath `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "commented-readme-link"
    Expected = "[public-example-link]"
    Errors = $commentedLinkErrors
  }) | Out-Null

  # link fence decoy: 同じ行をcode fenceへ移してもindex linkには数えない。
  $fenceMarker = ('`' * 3) -join ''
  $fencedLinkSkill = $SkillText.Replace(
    $stateLinkLine,
    (
      $fenceMarker +
      "markdown" +
      [Environment]::NewLine +
      $stateLinkLine +
      [Environment]::NewLine +
      $fenceMarker
    )
  )
  $fencedLinkErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $fencedLinkSkill `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $ExampleTextByPath `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "fenced-skill-link"
    Expected = "[public-example-link]"
    Errors = $fencedLinkErrors
  }) | Out-Null

  # table comment decoy: 必須state行をHTML commentへ移しても証跡行には数えない。
  $stateLines = @($ExampleTextByPath[$statePath] -split '\r?\n')
  $commentedStateRow = @(
    $stateLines |
      Where-Object {
        $_.StartsWith(
          "| $missingStateCategory |",
          [StringComparison]::Ordinal
        )
      }
  )[0]
  $commentedStateMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $commentedStateMap[$statePath] = $commentedStateMap[$statePath].Replace(
    $commentedStateRow,
    "<!-- $commentedStateRow -->"
  )
  $commentedStateErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $commentedStateMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "commented-state-row"
    Expected = "[public-example-category]"
    Errors = $commentedStateErrors
  }) | Out-Null

  # table fence decoy: 必須state行をcode fenceへ移しても実tableには数えない。
  $fencedStateCategory = $stateEntry.StateCategories[-1]
  $fencedStateRow = @(
    $stateLines |
      Where-Object {
        $_.StartsWith(
          "| $fencedStateCategory |",
          [StringComparison]::Ordinal
        )
      }
  )[0]
  $fencedStateMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $fencedStateMap[$statePath] = $fencedStateMap[$statePath].Replace(
    $fencedStateRow,
    (
      $fenceMarker +
      "markdown" +
      [Environment]::NewLine +
      $fencedStateRow +
      [Environment]::NewLine +
      $fenceMarker
    )
  )
  $fencedStateErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $fencedStateMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "fenced-state-row"
    Expected = "[public-example-category]"
    Errors = $fencedStateErrors
  }) | Out-Null

  # table relocation decoy: 必須行を別sectionへ移しても指定tableの証跡には数えない。
  $relocatedStateMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $relocatedStateMap[$statePath] = (
    $missingStatePattern.Replace(
      $relocatedStateMap[$statePath],
      "",
      1
    ) +
    [Environment]::NewLine +
    "## Decoy State Rows" +
    [Environment]::NewLine +
    $commentedStateRow
  )
  $relocatedStateErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $relocatedStateMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "relocated-state-row"
    Expected = "[public-example-category]"
    Errors = $relocatedStateErrors
  }) | Out-Null

  # contradiction variants: short label、文章prefix、blockquoteを同じ意味判定で拒否する。
  $shortState = $stateEntry.StateCategories[0] -replace '(?i)\s+state$', ''
  $shortContradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $shortContradictionMap[$statePath] += (
    [Environment]::NewLine +
    "- ${shortState}: $unverifiedMarker"
  )
  $shortContradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $shortContradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "short-state-contradiction"
    Expected = "[public-example-state]"
    Errors = $shortContradictionErrors
  }) | Out-Null

  $sentenceState = $stateEntry.StateCategories[1]
  $sentenceContradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $sentenceContradictionMap[$statePath] += (
    [Environment]::NewLine +
    "- The $sentenceState is blocked."
  )
  $sentenceContradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $sentenceContradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "sentence-state-contradiction"
    Expected = "[public-example-state]"
    Errors = $sentenceContradictionErrors
  }) | Out-Null

  $blockquoteState = $stateEntry.StateCategories[-1]
  $blockquoteContradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $blockquoteContradictionMap[$statePath] += (
    [Environment]::NewLine +
    "> $blockquoteState failed verification."
  )
  $blockquoteContradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $blockquoteContradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "blockquote-state-contradiction"
    Expected = "[public-example-state]"
    Errors = $blockquoteContradictionErrors
  }) | Out-Null

  # CommonMark blockquoteの空白なし形とerror verdictも同じ矛盾として拒否する。
  $errorVerdictState = $stateEntry.StateCategories[0]
  $errorVerdictMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $errorVerdictMap[$statePath] += (
    [Environment]::NewLine +
    ">${errorVerdictState}: error"
  )
  $errorVerdictErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $errorVerdictMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "blockquote-error-verdict"
    Expected = "[public-example-state]"
    Errors = $errorVerdictErrors
  }) | Out-Null

  # table-cell bypass: 表のResult/Evidenceが正しくてもWording内のerrorを拒否する。
  $tableCellState = $stateEntry.StateCategories[0]
  $tableCellRow = @(
    $stateLines |
      Where-Object {
        $_.StartsWith(
          "| $tableCellState |",
          [StringComparison]::Ordinal
        )
      }
  )[0]
  $tableCellErrorRow = [regex]::Replace(
    $tableCellRow,
    '\|[^|]*\|\s*$',
    (
      '| {0}{1} is error.{0} |' -f
        ([char]0x60),
        $tableCellState
    )
  )
  $tableCellErrorMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $tableCellErrorMap[$statePath] = $tableCellErrorMap[$statePath].Replace(
    $tableCellRow,
    $tableCellErrorRow
  )
  $tableCellErrorErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $tableCellErrorMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "table-cell-error-verdict"
    Expected = "[public-example-state]"
    Errors = $tableCellErrorErrors
  }) | Out-Null

  # ordered-list prefixを通るclaimも、通常bulletと同じsemantic判定へ固定する。
  $orderedState = $stateEntry.StateCategories[-1]
  $orderedContradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $orderedContradictionMap[$statePath] += (
    [Environment]::NewLine +
    "1. The $orderedState is incomplete."
  )
  $orderedContradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $orderedContradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "ordered-list-state-contradiction"
    Expected = "[public-example-state]"
    Errors = $orderedContradictionErrors
  }) | Out-Null

  # 日本語の未確認だけでなく英語unverified branchも独立fixtureで固定する。
  $englishState = $stateEntry.StateCategories[1]
  $englishContradictionMap = Copy-PublicExampleTextMap -Source $ExampleTextByPath
  $englishContradictionMap[$statePath] += (
    [Environment]::NewLine +
    "$englishState remains unverified."
  )
  $englishContradictionErrors = @(
    Get-PublicExampleContractErrors `
      -ReadmeText $ReadmeText `
      -SkillText $SkillText `
      -ExamplePaths $ExamplePaths `
      -ExampleTextByPath $englishContradictionMap `
      -Manifest $Manifest
  )
  $mutationCases.Add([pscustomobject]@{
    Name = "english-unverified-state-contradiction"
    Expected = "[public-example-state]"
    Errors = $englishContradictionErrors
  }) | Out-Null

  if ($mutationCases.Count -ne $expectedPublicExampleMutationCount) {
    Add-Error "[public-example-mutation] Mutation fixture count changed."
    return
  }
  foreach ($mutationCase in $mutationCases) {
    $matched = @(
      $mutationCase.Errors |
        Where-Object { $_.Contains($mutationCase.Expected) }
    )
    if ($matched.Count -eq 0) {
      Add-Error (
        "[public-example-mutation] Mutation escaped contract: " +
        $mutationCase.Name
      )
    }
  }

  Write-Output (
    "Public example contract self-test passed " +
    "($($Manifest.Count) examples, " +
    "$(@($Manifest | Where-Object { $_.Categories.Count -gt 0 }).Count) report schemas, " +
    "$($mutationCases.Count) hostile mutations rejected)."
  )
}

$publicExampleManifest = @(Get-PublicExampleManifest)
$requiredFiles = @(
  "SKILL.md",
  "runtime-files.txt",
  "README.md",
  "LICENSE",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "SECURITY.md",
  "CODE_OF_CONDUCT.md",
  "SUPPORT.md",
  ".editorconfig",
  ".gitattributes",
  ".gitignore",
  ".github/workflows/ci.yml",
  ".github/ISSUE_TEMPLATE/bug_report.yml",
  ".github/ISSUE_TEMPLATE/feature_request.yml",
  ".github/ISSUE_TEMPLATE/config.yml",
  ".github/pull_request_template.md",
  "docs/release-checklist.md",
  "docs/private-marker-scanner-hardening.md",
  "docs/server-runbook-cleanup-contract.md",
  "scripts/assert-oss-ready.ps1",
  "scripts/check-whitespace.ps1",
  "scripts/private-marker-process.ps1",
  "scripts/private-scan-config.ps1",
  "scripts/scan-private-markers.ps1",
  "tests/fixtures/synthetic-http-server.js",
  "tests/server-runbook-contract.Tests.ps1",
  "tests/scan-private-markers.Tests.ps1"
)
$requiredFiles += @(
  $publicExampleManifest |
    ForEach-Object { $_.Path }
)

foreach ($relativePath in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Get-RepoPath $relativePath) -PathType Leaf)) {
    Add-Error "Missing required file: $relativePath"
  }
}

foreach ($scriptPath in @(
  "scripts/assert-oss-ready.ps1",
  "scripts/check-whitespace.ps1",
  "scripts/private-marker-process.ps1",
  "scripts/private-scan-config.ps1",
  "scripts/scan-private-markers.ps1",
  "tests/server-runbook-contract.Tests.ps1",
  "tests/scan-private-markers.Tests.ps1"
)) {
  Assert-FileHasUtf8Bom -RelativePath $scriptPath
}

$skillReadinessErrors = @(
  Get-SkillReadinessContractErrors -SkillText (Get-RepoText "SKILL.md")
)
foreach ($skillReadinessError in $skillReadinessErrors) {
  Add-Error $skillReadinessError
}
if ($skillReadinessErrors.Count -eq 0) {
  Assert-SkillReadinessContractMutations `
    -SkillText (Get-RepoText "SKILL.md")
}

$missingRuntimeClosureInputs = @(
  "runtime-files.txt",
  "README.md"
) | Where-Object {
  -not (Test-Path -LiteralPath (Get-RepoPath $_) -PathType Leaf)
}
if ($missingRuntimeClosureInputs.Count -eq 0) {
  $runtimeClosureContractErrors = @(
    Get-RuntimeClosureContractErrors `
      -RuntimeManifestText (Get-RepoText "runtime-files.txt") `
      -ReadmeText (Get-RepoText "README.md") `
      -SkillText (Get-RepoText "SKILL.md") `
      -PublicExampleManifest $publicExampleManifest
  )
  foreach ($runtimeClosureContractError in $runtimeClosureContractErrors) {
    Add-Error $runtimeClosureContractError
  }
  if ($runtimeClosureContractErrors.Count -eq 0) {
    Assert-RuntimeClosureContractMutations `
      -RuntimeManifestText (Get-RepoText "runtime-files.txt") `
      -ReadmeText (Get-RepoText "README.md") `
      -SkillText (Get-RepoText "SKILL.md") `
      -PublicExampleManifest $publicExampleManifest
    Assert-RuntimeClosureAtomicClaimFixture
    Assert-RuntimeClosureSourceMutationFixture
  }
}

$publicExamplePaths = @(
  Get-ChildItem -LiteralPath (Get-RepoPath "examples") -Recurse -File |
    ForEach-Object {
      (Get-RelativePath `
        -BasePath $repoRoot.Path `
        -TargetPath $_.FullName).Replace("\", "/")
    }
)
$publicExampleTextByPath = @{}
foreach ($publicExamplePath in $publicExamplePaths) {
  $publicExampleTextByPath[$publicExamplePath] = Get-RepoText $publicExamplePath
}
$publicExampleContractErrors = @(
  Get-PublicExampleContractErrors `
    -ReadmeText (Get-RepoText "README.md") `
    -SkillText (Get-RepoText "SKILL.md") `
    -ExamplePaths $publicExamplePaths `
    -ExampleTextByPath $publicExampleTextByPath `
    -Manifest $publicExampleManifest
)
foreach ($publicExampleContractError in $publicExampleContractErrors) {
  Add-Error $publicExampleContractError
}
if ($publicExampleContractErrors.Count -eq 0) {
  Assert-PublicExampleContractMutations `
    -ReadmeText (Get-RepoText "README.md") `
    -SkillText (Get-RepoText "SKILL.md") `
    -ExamplePaths $publicExamplePaths `
    -ExampleTextByPath $publicExampleTextByPath `
    -Manifest $publicExampleManifest
}

try {
  & (Get-RepoPath "tests/server-runbook-contract.Tests.ps1") -Root $repoRoot.Path
} catch {
  Add-Error "Server runbook cleanup contract regression failed."
}

Assert-FileContains `
  -RelativePath "tests/server-runbook-contract.Tests.ps1" `
  -Pattern '(?m)^\$expectedHostileFixtureCount = 93$' `
  -Description "exact hostile server-runbook fixture count"
Assert-FileContains `
  -RelativePath "tests/server-runbook-contract.Tests.ps1" `
  -Pattern '(?m)^  \$expectedReadOnlyProbeCount = 4$' `
  -Description "exact read-only server-runbook probe count"

foreach ($fixtureName in @(
  "root-param-block",
  "root-using-module",
  "root-trap",
  "root-script-requirements",
  "root-named-end-wrapper",
  "root-begin-end-wrapper",
  "root-process-end-wrapper",
  "root-dynamicparam-end-wrapper",
  "root-clean-end-wrapper",
  "health-loop-attempt-decrement-after-sleep",
  "start-process-function-shadow",
  "url-definition-changed",
  "pid-file-mutated-in-nested-branch",
  "extra-tilde-powershell-block",
  "extra-four-backtick-powershell-block",
  "extra-mixed-case-powershell-block",
  "canonical-soft-hyphen-byte-drift",
  "extra-powershell-block",
  "canonical-code-prefix",
  "canonical-code-suffix",
  "cleanup-stage-aggregate-message-changed",
  "cleanup-outside-finally",
  "task-runner-filepath",
  "server-entry-def-use-cut",
  "server-script-def-use-cut",
  "server-reassigned-after-handle",
  "server-reassigned-with-mixed-case",
  "server-reassigned-with-local-scope",
  "server-reassigned-through-variable-provider",
  "server-property-mutated-after-handle",
  "start-filepath-overwritten",
  "start-filepath-overwritten-with-local-scope",
  "start-filepath-overwritten-through-variable-provider",
  "server-arguments-mutated-by-method",
  "start-filepath-overwritten-through-alias",
  "server-entry-mutated-through-psvariable",
  "dual-list-initializer-removed",
  "raw-stderr-replay",
  "initial-handle-guard-and-instead-of-or",
  "initial-handle-null-check-removed",
  "cleanup-handle-guard-and-instead-of-or",
  "partial-start-cleanup-replaced-by-throw",
  "safe-handle-dispose-removed",
  "process-dispose-removed",
  "stderr-size-provenance-cut",
  "bare-get-item-output",
  "bare-resolve-path-output",
  "bare-new-item-output",
  "bare-join-path-output",
  "bare-health-response-output",
  "bare-pid-json-output",
  "bare-health-test-path-output",
  "verification-placeholder-replaced-by-noop",
  "readiness-forced-true",
  "health-loop-made-effectively-unbounded",
  "health-sleep-made-effectively-unbounded",
  "diagnostic-mutated-through-variable-provider",
  "diagnostic-mutated-in-nested-branch",
  "diagnostic-mutated-through-alias",
  "root-reassigned-before-launch",
  "root-overwritten-by-get-command-outvariable",
  "pid-evidence-source-replaced-by-root",
  "server-start-time-mutated-in-nested-branch",
  "dead-handle-capture",
  "here-string-handle-decoy",
  "handle-mutated-through-get-variable",
  "server-mutated-through-dynamic-set-variable",
  "server-disposed-through-alias",
  "server-mutated-through-psobject",
  "extra-warning-reflects-stderr",
  "bare-stderr-output",
  "return-stderr-output",
  "pid-reresolve-cleanup",
  "dead-kill",
  "kill-race-recheck-removed",
  "unbounded-stop-confirmation",
  "stop-timeout-swallowed",
  "timeout-message-reflects-stderr",
  "diagnostic-classification-removed",
  "absolute-log-path-reflected",
  "absolute-cleanup-report-reflected",
  "dynamic-reader-replays-stderr",
  "static-reader-replays-stderr",
  "dead-verification-catch",
  "here-string-verification-catch",
  "dead-cleanup-catch",
  "dead-dual-failure-add",
  "here-string-rethrow",
  "dual-failure-loses-cleanup",
  "dual-add-order-swapped",
  "dual-failure-collapsed",
  "dual-aggregate-not-final",
  "surface-token-decoy"
)) {
  Assert-FileContains `
    -RelativePath "tests/server-runbook-contract.Tests.ps1" `
    -Pattern ([regex]::Escape($fixtureName)) `
    -Description "server-runbook hostile fixture: $fixtureName"
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

Assert-FileContains `
  -RelativePath ".gitignore" `
  -Pattern '(?m)^\.private-markers\.local\s*$' `
  -Description "ignored local private marker file"
Assert-FileContains `
  -RelativePath ".editorconfig" `
  -Pattern '(?ms)^\[\*\.ps1\]\s*\r?\ncharset\s*=\s*utf-8-bom\b' `
  -Description "PowerShell UTF-8 BOM contract"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'private-marker-process\.ps1' `
  -Description "shared bounded process boundary"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'BOUNDED_PLAYWRIGHT_UI_VERIFICATION_PRIVATE_MARKERS' `
  -Description "existing local marker environment contract"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'h8nc4y/bounded-playwright-ui-verification' `
  -Description "repository-only GitHub URL allowlist"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern '(?s)\[object\]\$ScanDeadlineMilliseconds\s*=\s*120000.*?\[int\]::TryParse\(.*?scan-deadline-parameter' `
  -Description "internally validated scan-wide deadline seam"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'git-index\+working-tree' `
  -Description "index plus full working-tree scan mode"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'Get-ChildItem(?s:.*?)\-Filter\s+''\.git''' `
  -Description "non-recursive Git ancestry entry inspection"
Assert-FinalScanDeadlineContract `
  -RelativePath "scripts/scan-private-markers.ps1"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'Test-FirstBoundedInvocationIsRawTransport' `
  -Description "AST-based first raw transport invocation validator"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'alias-to-function-before' `
  -Description "alias and helper-function AST bypass regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'dynamic-get-command-before' `
  -Description "dynamic Get-Command fail-closed regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'shadow-target-function(?s:.*?)retarget-target-alias(?s:.*?)builtin-gcm-wrapper(?s:.*?)module-qualified-get-command' `
  -Description "target shadow and command-resolution AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'function-scriptblock-member(?s:.*?)invoke-command-function-ref(?s:.*?)class-constructor-before(?s:.*?)class-method-before' `
  -Description "function provider and class execution AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'transitive-function-wrapper-before(?s:.*?)transitive-function-to-type-before(?s:.*?)transitive-type-to-function-before(?s:.*?)transitive-type-wrapper-before' `
  -Description "transitive function and class AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'nested-function-definition-only(?s:.*?)reordered-named-alias-retarget' `
  -Description "definition ownership and reordered alias AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'dynamic-scriptblock-member-before(?s:.*?)foreach-function-ref-before' `
  -Description "dynamic ScriptBlock and pipeline function-provider AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-direct-assignment-before(?s:.*?)bootstrap-scope-assignment-wrapper-before' `
  -Description "fixed process helper bootstrap assignment regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'Microsoft\.PowerShell\.Management\\Join-Path(?s:.*?)PSScriptRoot(?s:.*?)\.\./scripts/private-marker-process\.ps1' `
  -Description "module-qualified immutable bootstrap path"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-plus-equals-before(?s:.*?)bootstrap-join-path-function-shadow-before(?s:.*?)bootstrap-mutable-root-before' `
  -Description "bootstrap operator command binding and provenance regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-set-item-variable-provider-before(?s:.*?)bootstrap-new-item-variable-provider-before(?s:.*?)bootstrap-new-variable-before(?s:.*?)bootstrap-new-variable-alias-before' `
  -Description "bootstrap variable provider and New-Variable regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-new-item-indirect-process-provider-before(?s:.*?)bootstrap-new-item-indirect-root-provider-before(?s:.*?)bootstrap-new-item-composed-provider-before(?s:.*?)bootstrap-new-item-splat-provider-before(?s:.*?)bootstrap-new-item-pipeline-provider-before' `
  -Description "indirect protected Variable provider regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-custom-alias-set-variable-before(?s:.*?)bootstrap-custom-alias-new-variable-before(?s:.*?)bootstrap-custom-alias-set-item-before(?s:.*?)bootstrap-custom-alias-new-item-before(?s:.*?)bootstrap-custom-alias-indirect-new-item-before(?s:.*?)bootstrap-custom-alias-copy-item-before(?s:.*?)bootstrap-custom-alias-set-alias-before(?s:.*?)bootstrap-custom-alias-new-alias-before(?s:.*?)bootstrap-custom-alias-invoke-expression-before(?s:.*?)bootstrap-custom-alias-invoke-command-before(?s:.*?)bootstrap-custom-alias-foreach-before(?s:.*?)bootstrap-custom-alias-where-before' `
  -Description "custom mutation command alias regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-provider-scope-wrapper-before(?s:.*?)bootstrap-set-content-variable-provider-before(?s:.*?)bootstrap-new-variable-wrapper-before' `
  -Description "bootstrap scoped provider wrapper regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'bootstrap-psscriptroot-assignment-before(?s:.*?)bootstrap-psvariable-set-before(?s:.*?)bootstrap-psvariable-set-wrapper-before(?s:.*?)bootstrap-psvariable-value-before(?s:.*?)bootstrap-psvariable-set-value-before' `
  -Description "bootstrap provenance and PSVariable object mutation regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'alias-provider-assignment-shadow-before(?s:.*?)function-provider-assignment-shadow-before(?s:.*?)copy-function-provider-shadow-before(?s:.*?)move-function-provider-shadow-before(?s:.*?)rename-alias-provider-shadow-before' `
  -Description "provider assignment and copy move rename AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'new-item-expression-alias-provider-before' `
  -Description "dynamic New-Item provider path regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'class-inheritance-constructor-before(?s:.*?)class-inheritance-safe-before' `
  -Description "class inheritance dangerous and safe AST regressions"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'Assert-FixedScannerIntegrityFailure' `
  -Description "fixed redacted process-boundary diagnostics"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'helper-and-isolation-cleanup' `
  -Description "idempotent nested process and cleanup diagnostic regression"
Assert-FileContains `
  -RelativePath "scripts/scan-private-markers.ps1" `
  -Pattern 'scanIntegrityFailureEmitted' `
  -Description "single-emission integrity diagnostic guard"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'windows-close-once-started' `
  -Description "Windows Job close retry and termination regression"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'LastSyntheticTerminateAttemptCount' `
  -Description "Windows direct termination fallback evidence"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'TryCloseOwnedJobHandle(?s:.*?)direct termination \+ wait後に同じhandle(?s:.*?)Fallback Job close exceeded' `
  -Description "Windows Job ownership-preserving close retry"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern '\$stopwatch\s*=\s*\[System\.Diagnostics\.Stopwatch\]::StartNew\(\)(?s:.*?)\$deadline\s*=\s*\[long\]\$TimeoutMilliseconds' `
  -Description "atomic Windows launch-inclusive operation clock"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'Set-PrivateMarkerHermeticGitEnvironment(?s:.*?)\$Environment\.Clear\(\)' `
  -Description "fixed allowlist child Git environment"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'IsProcessGroupLeader(?s:.*?)Get-PrivateMarkerPosixSetsidArguments' `
  -Description "portable setsid arguments and verified POSIX process-group gate"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern '\$process\.StartInfo\s*=\s*\$startInfo(?s:.{0,700})Get-PrivateMarkerRemainingMilliseconds(?s:.{0,700})Start-PrivateMarkerProcessWithRawInput' `
  -Description "remaining-budget check immediately before process start"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'function Test-PrivateMarkerMillisecondWaitContract(?s:.{0,5000})\$boundedTypeSources(?s:.{0,5000})\$expectedRemainingFunction(?s:.{0,4000})\$expectedNativeWaitRegion(?s:.{0,5000})\$allNativeWaitCalls\.Count -ne 1(?s:.{0,3000})\$lastRemainingAssignment(?s:.{0,1500})\$actualNativeWaitRegion' `
  -Description "host-independent millisecond wait contract regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern '\$timeoutMilliseconds\s*=\s*4000(?s:.{0,300})\$timeoutElapsedLimitMilliseconds\s*=(?s:.{0,100})if \(\$runtimeIsWindows\) \{ 10000 \} else \{ 15000 \}(?s:.{0,800})\$releaseWait\.ElapsedMilliseconds -lt 25000(?s:.{0,1000})__GRANDCHILD_STARTED__(?s:.{0,800})__SURVIVAL_RELEASE__(?s:.{0,800})__SURVIVAL_SENTINEL__' `
  -Description "platform-bounded released-grandchild process-tree regression"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'public bool WaitForExit\(int milliseconds\)(?s:.{0,160})return WaitForSingleObject\(processHandle, \(uint\)milliseconds\)' `
  -Description "direct millisecond Win32 wait implementation"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern '\$preLaunchElapsedLimitMilliseconds\s*=\s*5000' `
  -Description "prelaunch finite hang guard"
foreach ($boundedProcessDiagnosticLabel in @(
    'timeout/millisecond-structure-contract',
    'timeout/millisecond-caller-rounding-mutation',
    'timeout/millisecond-helper-rounding-mutation',
    'timeout/millisecond-comment-decoy-mutation',
    'timeout/millisecond-string-decoy-mutation',
    'timeout/millisecond-csharp-comment-decoy-mutation',
    'timeout/millisecond-csharp-string-decoy-mutation',
    'timeout/millisecond-extra-wait-mutation',
    'timeout/timed-out',
    'timeout/containment-established',
    'timeout/tree-stopped',
    'timeout/streams-drained',
    'timeout/elapsed-hang-guard',
    'timeout/target-started',
    'timeout/grandchild-started',
    'timeout/sentinel-not-written',
    'prelaunch/timed-out',
    'prelaunch/containment-not-established',
    'prelaunch/tree-stopped',
    'prelaunch/streams-drained',
    'prelaunch/elapsed-hang-guard',
    'prelaunch/target-not-started'
  )) {
  Assert-FileContains `
    -RelativePath "tests/scan-private-markers.Tests.ps1" `
    -Pattern ('(?-i:' +
      [regex]::Escape("[$boundedProcessDiagnosticLabel]") +
      ')') `
    -Description "condition-specific bounded process diagnostic: $boundedProcessDiagnosticLabel"
}
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'ForcePreLaunchDelayMilliseconds 250(?s:.*?)ForcePosixGateDelayMilliseconds 250' `
  -Description "prep and POSIX containment deadline regressions"
Assert-FileContains `
  -RelativePath "scripts/private-marker-process.ps1" `
  -Pattern 'if \(\$timedOut -or -not \[string\]::IsNullOrEmpty\(\$limitExceeded\)\) \{(?s:.{0,500})\$cleanupClock\s*=(?s:.{0,100})\[System\.Diagnostics\.Stopwatch\]::StartNew\(\)(?s:.{0,700})-WaitMilliseconds \$cleanupRemaining(?s:.{0,1800})Get-PrivateMarkerRemainingMilliseconds(?s:.{0,300})-Stopwatch \$cleanupClock(?s:.{0,500})Complete-PrivateMarkerAtomicStreams(?s:.{0,250})-Streams' `
  -Description "single absolute cleanup clock shared by tree stop and stream drain"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'raw native Git transport fixture' `
  -Description "native Git byte-exact transport regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'reuse-owned Windows Job path' `
  -Description "PS5.1 BOM-less nested Git transport regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'dangling \.git junction' `
  -Description "dangling Git metadata regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'linked-worktree-main(?s:.*?)worktree(?s:.*?)add(?s:.*?)linkedScanResult' `
  -Description "normal linked-worktree Gitfile regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern 'untracked-marker\.md' `
  -Description "untracked working-tree marker regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern "RootParameter\s*=\s*'Path'" `
  -Description "legacy Root alias regression"
Assert-FileContains `
  -RelativePath "docs/private-marker-scanner-hardening.md" `
  -Pattern '(?i)untracked|未追跡' `
  -Description "full working-tree and untracked scope"
Assert-FileContains `
  -RelativePath "docs/private-marker-scanner-hardening.md" `
  -Pattern '(?i)ancestor|祖先|親階層' `
  -Description "ancestor Git metadata boundary"
Assert-FileContains `
  -RelativePath "docs/private-marker-scanner-hardening.md" `
  -Pattern '(?i)output|出力' `
  -Description "bounded output contract"
Assert-WorkflowExactContract -RelativePath ".github/workflows/ci.yml"

# Single source of truth shared with scan-private-markers.ps1 (review S-1).
# Windowsだけはfilesystem semanticsに合わせて大小文字を同一視し、
# POSIXでは正確なlowercase `.git` だけをmetadata directoryとして除外する。
$excludedDirectoryComparer = if ($runtimeIsWindows) {
  [StringComparer]::OrdinalIgnoreCase
} else {
  [StringComparer]::Ordinal
}
$excludedDirectories = [Collections.Generic.HashSet[string]]::new(
  [string[]](Get-PrivateScanExcludedDirectories),
  $excludedDirectoryComparer
)
if ($runtimeIsWindows -and -not $excludedDirectories.Contains('.GIT')) {
  Add-Error 'Windows exclusion matching must treat .GIT as .git.'
}
if (-not $runtimeIsWindows -and $excludedDirectories.Contains('.GIT')) {
  Add-Error 'POSIX exclusion matching must scan ordinary .GIT directories.'
}

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
  -not ($parts | Where-Object {
    $excludedDirectories.Contains([string]$_)
  })
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
