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
  "examples/final-report-template.md",
  "examples/server-runbook.md",
  "examples/ui-verification-checklist.md",
  "scripts/assert-oss-ready.ps1",
  "scripts/check-whitespace.ps1",
  "scripts/private-marker-process.ps1",
  "scripts/private-scan-config.ps1",
  "scripts/scan-private-markers.ps1",
  "tests/scan-private-markers.Tests.ps1"
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
  "tests/scan-private-markers.Tests.ps1"
)) {
  Assert-FileHasUtf8Bom -RelativePath $scriptPath
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
