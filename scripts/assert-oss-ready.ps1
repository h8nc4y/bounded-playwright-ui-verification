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
  -Pattern '\$timeoutMilliseconds = if \(\$runtimeIsWindows\) \{ 300 \} else \{ 4000 \}(?s:.{0,300})\$timeoutElapsedLimitMilliseconds\s*=(?s:.{0,100})if \(\$runtimeIsWindows\) \{ 900 \} else \{ 7000 \}' `
  -Description "platform-bounded timeout and process-tree sentinel regression"
Assert-FileContains `
  -RelativePath "tests/scan-private-markers.Tests.ps1" `
  -Pattern '\$timeoutGrandchildStarted(?s:.{0,300})\$timeoutSurvivalRelease(?s:.{0,2500})__GRANDCHILD_STARTED__(?s:.{0,800})__SURVIVAL_RELEASE__(?s:.{0,800})__SURVIVAL_SENTINEL__' `
  -Description "POSIX released-grandchild process-tree oracle"
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
