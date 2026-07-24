[CmdletBinding()]
param(
    [Alias('Root')]
    [string]$Path = '',

    # production上限は固定し、self-testだけが短い期限でfail-closedを再現する。
    [ValidateRange(250, 10000)]
    [int]$GitCommandTimeoutMilliseconds = 10000,

    # public entrypoint の不正値も raw parameter-binding error へ流さず、
    # 下の固定診断境界で exit 2 に統一するため、ここでは型変換しない。
    [object]$ScanDeadlineMilliseconds = 120000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtimeIsWindows = [Environment]::OSVersion.Platform -eq
    [PlatformID]::Win32NT

# 曖昧な入力・helper/process境界の失敗は固定codeだけを出し、local pathや
# native/provider例外をstdout/stderrへ渡さずexit 2へ統一する。
$script:scanIntegrityFailureEmitted = $false
function Stop-ScanIntegrityFailure {
    param([string]$Reason)

    # exitによるstack unwind中にfinallyのcleanupも失敗して再入しても、
    # 元の固定診断だけを残し、複数行・別reason・内部pathの混在を防ぐ。
    if ($script:scanIntegrityFailureEmitted) {
        exit 2
    }
    $script:scanIntegrityFailureEmitted = $true
    [Console]::Out.WriteLine(
        "Private marker scan failed closed (integrity: $Reason)."
    )
    exit 2
}

# Gitだけでなく列挙・decode・regex・最終serializeまで同じ時計で制限する。
# public値はscript本体のtry内でparseし、範囲外・非整数を固定1行へ畳み込む。
$validatedScanDeadlineMilliseconds = 0
try {
    $deadlineIsValid = [int]::TryParse(
        [string]$ScanDeadlineMilliseconds,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$validatedScanDeadlineMilliseconds
    )
    if (-not $deadlineIsValid -or
        $validatedScanDeadlineMilliseconds -lt 1 -or
        $validatedScanDeadlineMilliseconds -gt 120000) {
        Stop-ScanIntegrityFailure -Reason 'scan-deadline-parameter'
    }
}
catch {
    Stop-ScanIntegrityFailure -Reason 'scan-deadline-parameter'
}
$ScanDeadlineMilliseconds = $validatedScanDeadlineMilliseconds

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$processSupport = Join-Path $scriptRoot 'private-marker-process.ps1'
try {
    if (-not (Test-Path -LiteralPath $processSupport -PathType Leaf)) {
        Stop-ScanIntegrityFailure -Reason 'process-boundary-bootstrap'
    }
    # helper由来のsuccess/error/information streamもbootstrap境界から外へ出さない。
    . $processSupport *> $null
    if ($null -eq (Get-Command `
        Invoke-PrivateMarkerBoundedProcess `
        -CommandType Function `
        -ErrorAction SilentlyContinue)) {
        Stop-ScanIntegrityFailure -Reason 'process-boundary-bootstrap'
    }
}
catch {
    Stop-ScanIntegrityFailure -Reason 'process-boundary-bootstrap'
}
$scanConfig = Join-Path $scriptRoot 'private-scan-config.ps1'
try {
    if (-not (Test-Path -LiteralPath $scanConfig -PathType Leaf)) {
        Stop-ScanIntegrityFailure -Reason 'scan-config-bootstrap'
    }
    . $scanConfig *> $null
}
catch {
    Stop-ScanIntegrityFailure -Reason 'scan-config-bootstrap'
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = $Path
# このリポジトリ自身だけを公開URLとして許可し、別リポジトリは必ず検出する。
$ownRepoUrlPattern = '^https://github\.com/h8nc4y/bounded-playwright-ui-verification(?:\.git)?$'
$maxGitMetadataBytes = 16777216
$maxTextFileBytes = 8388608
$maxTotalScanBytes = 67108864
$maxGitDiagnosticBytes = 262144
$maxGitIndexEntries = 4096
$maxGitProcesses = 7
$maxFindings = 100
$maxFindingOutputBytes = 16384
$maxDisplayPathCharacters = 2048
$maxScanTargets = 8192
$maxWorkingTreeEntries = 32768
$maxScanLines = 1000000
$maxRegexMatches = 100000
$maxLocalMarkerBytes = 262144
$maxLocalMarkers = 256
$maxLocalMarkerCharacters = 4096
$maxGitPathCharacters = 32768
$maxGitPathSegments = 1024
$totalScanBytes = 0L
$gitProcessCount = 0
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$workingTreeEntryCount = 0
$totalScanLines = 0
$regexMatchCount = 0

$rules = New-Object System.Collections.Generic.List[object]

# 検出規則は名前・種類・allowlistを構造化し、報告へ生値を渡さない。
function Add-ScanRule {
    param(
        [string]$Name,
        [string]$Pattern,
        [ValidateSet('literal', 'regex')]
        [string]$Kind,
        # Optional: suppress regex matches whose value is a known-safe placeholder.
        # This keeps documentation examples from becoming noisy findings.
        [string]$Allowlist = ''
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return
    }

    $rules.Add([pscustomobject]@{
        Name = $Name
        Pattern = $Pattern
        Kind = $Kind
        Allowlist = $Allowlist
    }) | Out-Null
}

Add-ScanRule -Name 'openai-api-key-prefix' -Pattern '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}' -Kind 'regex'
Add-ScanRule -Name 'github-classic-token-prefix' -Pattern ('g' + 'hp_') -Kind 'literal'
Add-ScanRule -Name 'github-fine-grained-token-prefix' -Pattern ('github' + '_pat_') -Kind 'literal'
Add-ScanRule -Name 'slack-bot-token-prefix' -Pattern ('xo' + 'xb-') -Kind 'literal'
# 値を伴わない説明文は許可し、token shapeが続く場合だけ検出する。
Add-ScanRule -Name 'bearer-token-header' -Pattern 'Bearer [A-Za-z0-9._\-]{8,}' -Kind 'regex'
Add-ScanRule -Name 'private-key-block' -Pattern ('BEGIN ' + 'PRIVATE KEY') -Kind 'literal'
# RFC予約済みexample domainは公開fixture専用として既存どおり許可する。
$reservedExampleEmailAllowlist = '(?i)@example\.(?:com|org|net)$'
Add-ScanRule -Name 'email-address' -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' -Kind 'regex' -Allowlist $reservedExampleEmailAllowlist
# windows-absolute-path detects private-looking absolute Windows paths while allowing
# documented placeholders. The regex stops before bracketed placeholder segments and
# can also greedily include trailing prose, so the allowlist suppresses either:
#   (a) values ending at a path separator with only placeholder or parent words, or
#   (b) full placeholder-only paths, with optional trailing prose.
# Real-looking paths with non-placeholder child segments remain findings.
# Keep literal absolute paths out of comments so this script does not flag itself.
$winPathPlaceholderWord = '(?:path|to|repo|you|your|example|placeholder|dir|folder|project|projects)'
$winPathParentWord = '(?:users|user|home|documents|appdata|local|roaming)'
$windowsPathPlaceholderAllowlist = '(?ix)^[A-Za-z]:\\(?:' +
    # (a) Placeholder or parent words only, ending at a separator.
    "(?:(?:$winPathPlaceholderWord|$winPathParentWord)\\)+" +
    '|' +
    # (b) Full placeholder-only paths, optionally followed by prose.
    "(?:$winPathPlaceholderWord\\?)+(?:\s.*)?" +
    ')$'
Add-ScanRule -Name 'windows-absolute-path' -Pattern '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}' -Kind 'regex' -Allowlist $windowsPathPlaceholderAllowlist

# Additional cloud / key-block prefixes for higher secret recall.
# Prefixes are split so this scanner does not match its own rule definitions.
Add-ScanRule -Name 'aws-access-key-id' -Pattern ('A' + 'KIA') -Kind 'literal'
Add-ScanRule -Name 'gcp-api-key-prefix' -Pattern ('AIza' + '[0-9A-Za-z_\-]{35}') -Kind 'regex'
Add-ScanRule -Name 'slack-user-token-prefix' -Pattern ('xo' + 'xp-') -Kind 'literal'
Add-ScanRule -Name 'slack-legacy-app-token-prefix' -Pattern ('xo' + 'xa-') -Kind 'literal'
Add-ScanRule -Name 'slack-app-level-token-prefix' -Pattern ('xa' + 'pp-') -Kind 'literal'
Add-ScanRule -Name 'stripe-live-secret-key' -Pattern ('(s' + 'k|rk)_live_[0-9A-Za-z]{16,}') -Kind 'regex'
Add-ScanRule -Name 'pem-private-key-block' -Pattern ('BEGIN ' + '(RSA|EC|OPENSSH|ENCRYPTED) PRIVATE KEY') -Kind 'regex'

$localMarkerIndex = 0

# scan-wide deadlineはCPU側の列挙・decode・regex・出力にも適用する。
# deadline違反時は固定codeだけを出し、pathや子process診断を露出しない。
function Assert-PrivateMarkerScanDeadline {
    if ($script:scanStopwatch.ElapsedMilliseconds -ge
        $ScanDeadlineMilliseconds) {
        Stop-ScanIntegrityFailure -Reason 'scan-deadline'
    }
}

# local markerは件数・長さを先に制限し、動的regexではなくliteralとして扱う。
function Add-LocalMarker {
    param([string]$Marker)

    $trimmed = $Marker.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }
    if ($trimmed.Length -gt $maxLocalMarkerCharacters) {
        Stop-ScanIntegrityFailure -Reason 'local-marker-length'
    }
    if ($script:localMarkerIndex -ge $maxLocalMarkers) {
        Stop-ScanIntegrityFailure -Reason 'local-marker-count'
    }

    $script:localMarkerIndex++
    Add-ScanRule -Name "local-private-marker-$script:localMarkerIndex" -Pattern $trimmed -Kind 'literal'
}

function Add-LocalMarkersFromText {
    param([string]$Text)

    $markerReader = New-Object System.IO.StringReader($Text)
    try {
        while ($markerReader.Peek() -ge 0) {
            Assert-PrivateMarkerScanDeadline
            Add-LocalMarker -Marker $markerReader.ReadLine()
        }
    }
    finally {
        $markerReader.Dispose()
    }
}

$environmentMarkers = [Environment]::GetEnvironmentVariable(
    'BOUNDED_PLAYWRIGHT_UI_VERIFICATION_PRIVATE_MARKERS'
)
if (-not [string]::IsNullOrWhiteSpace($environmentMarkers)) {
    if ([Text.Encoding]::UTF8.GetByteCount($environmentMarkers) -gt
        $maxLocalMarkerBytes) {
        Stop-ScanIntegrityFailure -Reason 'local-marker-size'
    }
    Add-LocalMarkersFromText -Text $environmentMarkers
}

$githubUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
$findings = New-Object System.Collections.Generic.List[object]
$findingsTruncated = $false

# finding総数を有限に保ち、pathは既にsanitizedされた表示値だけを保持する。
function Add-ScanFinding {
    param(
        [string]$File,
        [int]$Line,
        [string]$Rule
    )

    Assert-PrivateMarkerScanDeadline
    # A marker-dense line is untrusted input. Retain a useful bounded report
    # rather than allowing regex matches to grow memory and CI output without
    # limit.
    if ($script:findings.Count -ge $maxFindings) {
        $script:findingsTruncated = $true
        return $false
    }
    $script:findings.Add([pscustomobject]@{
        File = $File
        Line = $Line
        Rule = $Rule
        Match = '<redacted>'
    }) | Out-Null
    return $true
}

# Limit scanning to text files to avoid binary noise and expensive regex work.
# Extensionless text files such as LICENSE are still allowed. Dotfiles like
# .env are "all extension" to GetExtension, so the secret-prone ones are
# listed explicitly — otherwise they would be silently skipped.
$textExtensions = @(
    '.md', '.markdown', '.txt', '.ps1', '.psm1', '.psd1', '.yml', '.yaml',
    '.json', '.jsonc', '.toml', '.ini', '.cfg', '.conf', '.xml', '.csv',
    '.sh', '.bash', '.bat', '.cmd', '.py', '.js', '.ts', '.css', '.html',
    '.htm', '.pem', '.key', '.crt', '.cer',
    '.editorconfig', '.gitattributes', '.gitignore',
    '.env', '.envrc', '.npmrc', '.netrc'
)
$textExtensionSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$textExtensions, [System.StringComparer]::OrdinalIgnoreCase)

# `.env`やextensionless fileを含め、secretが置かれやすいtext候補を明示判定する。
function Test-IsTextFile {
    param([string]$FullPath)

    $fileName = [IO.Path]::GetFileName($FullPath)
    if ($fileName.Equals('.env', [StringComparison]::OrdinalIgnoreCase) -or
        $fileName.StartsWith(
            '.env.',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        # Common dotenv variants (.env.local, .env.production, and similar)
        # use the suffix as a profile name rather than a file type.
        return $true
    }
    if ($fileName.StartsWith('.') -and
        $fileName.IndexOf('.', 1) -lt 0) {
        # A single-leading-dot name has no semantic extension even though
        # GetExtension treats the whole name as one (for example `.hidden`).
        return $true
    }
    $extension = [System.IO.Path]::GetExtension($FullPath)
    if ([string]::IsNullOrEmpty($extension)) {
        # Treat extensionless files as text.
        return $true
    }
    return $textExtensionSet.Contains($extension)
}

# directory除外はassert scriptと同じ設定を使い、Git pathにもsegment単位で適用する。
function Test-IsExcludedGitPath {
    param([string]$GitPath)

    foreach ($segment in @($GitPath -split '/')) {
        Assert-PrivateMarkerScanDeadline
        if ($excludedDirectoryNames.Contains($segment)) {
            return $true
        }
    }
    return $false
}

function Test-BoundedProcessHealthy {
    param([object]$Result)

    return -not $Result.TimedOut -and
        -not $Result.OutputLimitExceeded -and
        $Result.ContainmentEstablished -and
        $Result.TreeStopped -and
        $Result.StreamsDrained
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if (($index -band 4095) -eq 0) {
            Assert-PrivateMarkerScanDeadline
        }
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $true
    }

    # PowerShell on POSIX exposes symbolic links through LinkType even on
    # runtimes where FileAttributes does not report ReparsePoint consistently.
    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    return $null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)
}

function Test-HasGitMetadataAncestor {
    param([string]$StartPath)

    $directory = New-Object System.IO.DirectoryInfo($StartPath)
    $nameComparison = if ($runtimeIsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    while ($null -ne $directory) {
        Assert-PrivateMarkerScanDeadline
        # markerを直接resolveすると、dangling symlink/junctionを「不存在」と
        # 誤認し得る。親を非再帰で列挙し、targetを辿らずentry名で判定する。
        try {
            $ancestryEntries = @(
                Get-ChildItem `
                    -LiteralPath $directory.FullName `
                    -Force `
                    -Filter '.git' `
                    -ErrorAction Stop |
                    Select-Object -First 2
            )
        }
        catch {
            Stop-ScanIntegrityFailure -Reason 'git-ancestry-inspection'
        }
        foreach ($entry in $ancestryEntries) {
            if ([string]::Equals(
                $entry.Name,
                '.git',
                $nameComparison
            )) {
                return $true
            }
        }
        $directory = $directory.Parent
    }
    return $false
}

# control/bidi/line-separatorをescapeし、1件の表示pathにもbyte予算を課す。
function ConvertTo-SafeDisplayPath {
    param([string]$RelativePath)

    $builder = New-Object System.Text.StringBuilder
    $truncationSuffix = '...<truncated>'
    $displayPrefixLimit =
        $maxDisplayPathCharacters - $truncationSuffix.Length
    foreach ($character in $RelativePath.ToCharArray()) {
        Assert-PrivateMarkerScanDeadline
        $category = [char]::GetUnicodeCategory($character)
        if ($character -eq [char]92) {
            # Git paths use `/` separators. A literal POSIX backslash is data,
            # so escape it rather than making it look like a path boundary.
            $displayPiece = '\u005c'
        } elseif ([char]::IsControl($character) -or
            $category -eq [Globalization.UnicodeCategory]::Format -or
            $category -eq [Globalization.UnicodeCategory]::LineSeparator -or
            $category -eq
            [Globalization.UnicodeCategory]::ParagraphSeparator) {
            # Escape bidi/zero-width format characters and Unicode line
            # separators as well as C0/C1 controls so a path cannot reorder or
            # forge CI log text.
            $displayPiece = '\u{0:x4}' -f [int][char]$character
        } else {
            $displayPiece = [string]$character
        }
        if (($builder.Length + $displayPiece.Length) -gt
            $displayPrefixLimit) {
            [void]$builder.Append($truncationSuffix)
            return $builder.ToString()
        }
        [void]$builder.Append($displayPiece)
    }
    return $builder.ToString()
}

# worktreeはlink/reparseを辿らず、read前後の型・長さ・実体を再検証する。
function Get-SafeTrackedWorktreeState {
    param(
        [string]$RepositoryRoot,
        [string]$GitPath,
        [string]$Mode
    )

    # Inspect each component from the validated repository root. A normal leaf
    # beneath a linked directory is not itself marked as a reparse point, so
    # checking only the final Get-Item would follow an external target.
    if ($GitPath.Length -gt $maxGitPathCharacters) {
        Stop-ScanIntegrityFailure -Reason 'git-index-path-budget'
    }
    $segments = @($GitPath -split '/')
    if ($segments.Count -gt $maxGitPathSegments) {
        Stop-ScanIntegrityFailure -Reason 'git-index-path-budget'
    }
    $currentPath = $RepositoryRoot
    for ($index = 0; $index -lt $segments.Count; $index++) {
        Assert-PrivateMarkerScanDeadline
        $currentPath = Join-Path $currentPath $segments[$index]
        $item = Get-Item `
            -LiteralPath $currentPath `
            -Force `
            -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            return [pscustomobject]@{
                State = 'missing'
                Bytes = $null
            }
        }

        $isFinalComponent = $index -eq ($segments.Count - 1)
        if (Test-IsReparsePoint -Item $item) {
            # Even for mode 120000, reading the worktree path would dereference
            # the link and ignoring it would miss an unstaged target change.
            # The immutable index blob is scanned when the worktree link is
            # absent; a present link is therefore an explicit fail-closed state.
            Stop-ScanIntegrityFailure -Reason 'worktree-reparse-path'
        }
        if (-not $isFinalComponent -and -not $item.PSIsContainer) {
            Stop-ScanIntegrityFailure -Reason 'worktree-parent-type'
        }
        if ($isFinalComponent -and $item.PSIsContainer) {
            Stop-ScanIntegrityFailure -Reason 'worktree-type-directory'
        }
    }

    if ($item.Length -gt $maxTextFileBytes) {
        Stop-ScanIntegrityFailure -Reason 'worktree-size'
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($currentPath)
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'worktree-read'
    }

    # Re-walk the full path after reading. This catches replacement with a
    # symlink/reparse path and rejects same-path type drift without following a
    # newly introduced external target on the next operation.
    $verifyPath = $RepositoryRoot
    for ($index = 0; $index -lt $segments.Count; $index++) {
        Assert-PrivateMarkerScanDeadline
        $verifyPath = Join-Path $verifyPath $segments[$index]
        try {
            $verifiedItem = Get-Item `
                -LiteralPath $verifyPath `
                -Force `
                -ErrorAction Stop
        }
        catch {
            Stop-ScanIntegrityFailure -Reason 'worktree-type-drift'
        }
        if (Test-IsReparsePoint -Item $verifiedItem) {
            Stop-ScanIntegrityFailure -Reason 'worktree-type-drift'
        }
        if ($index -lt ($segments.Count - 1) -and
            -not $verifiedItem.PSIsContainer) {
            Stop-ScanIntegrityFailure -Reason 'worktree-type-drift'
        }
    }
    if ($verifiedItem.PSIsContainer -or
        $verifiedItem.Length -ne $bytes.Length) {
        Stop-ScanIntegrityFailure -Reason 'worktree-type-drift'
    }

    return [pscustomobject]@{
        State = 'regular'
        Bytes = $bytes
    }
}

# index blobとworktree snapshotを同じtarget形式へ揃え、合計byte上限を集約する。
function Add-ScanTarget {
    param(
        [System.Collections.Generic.List[object]]$Targets,
        [string]$DisplayPath,
        [byte[]]$Bytes
    )

    Assert-PrivateMarkerScanDeadline
    if ($Targets.Count -ge $maxScanTargets) {
        Stop-ScanIntegrityFailure -Reason 'scan-target-count'
    }
    if ($null -eq $Bytes -or $Bytes.Length -gt $maxTextFileBytes) {
        Stop-ScanIntegrityFailure -Reason 'scan-target-size'
    }
    $script:totalScanBytes += $Bytes.Length
    if ($script:totalScanBytes -gt $maxTotalScanBytes) {
        Stop-ScanIntegrityFailure -Reason 'scan-total-size'
    }
    $Targets.Add([pscustomobject]@{
        DisplayPath = ConvertTo-SafeDisplayPath -RelativePath $DisplayPath
        Bytes = $Bytes
    }) | Out-Null
}

# Git childは専用環境・protocol遮断・deadline・output capの共通境界からだけ起動する。
function Invoke-ScannerGitProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$IsolationRoot,
        [string]$WorkingDirectory,
        [int]$MaxStdoutBytes,
        [AllowNull()]
        [byte[]]$StandardInputBytes = $null
    )

    $script:gitProcessCount++
    if ($script:gitProcessCount -gt $maxGitProcesses) {
        Stop-ScanIntegrityFailure -Reason 'git-process-budget'
    }
    Assert-PrivateMarkerScanDeadline
    $remaining = $ScanDeadlineMilliseconds -
        $script:scanStopwatch.ElapsedMilliseconds
    if ($remaining -le 0) {
        Stop-ScanIntegrityFailure -Reason 'git-deadline'
    }
    $commandTimeout = [int][Math]::Min(
        [long]$GitCommandTimeoutMilliseconds,
        $remaining
    )
    # argument構築後・process start直前にも再確認し、deadline外起動を防ぐ。
    Assert-PrivateMarkerScanDeadline
    try {
        return Invoke-PrivateMarkerBoundedProcess `
            -FileName $FileName `
            -Arguments $Arguments `
            -IsolationRoot $IsolationRoot `
            -WorkingDirectory $WorkingDirectory `
            -StandardInputBytes $StandardInputBytes `
            -TimeoutMilliseconds $commandTimeout `
            -MaxStdoutBytes $MaxStdoutBytes `
            -MaxStderrBytes $maxGitDiagnosticBytes
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'process-boundary'
    }
}

# Prefer the exact index plus existing regular worktree content. This covers
# staged-only and unstaged-only markers while avoiding symlink target traversal.
# Non-git fixture directories use the working-tree fallback.
try {
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
}
catch {
    Stop-ScanIntegrityFailure -Reason 'scan-root-missing'
}
if (-not $rootItem.PSIsContainer -or (Test-IsReparsePoint -Item $rootItem)) {
    Stop-ScanIntegrityFailure -Reason 'scan-root-type'
}
$root = [IO.Path]::GetFullPath($rootItem.FullName)
$pathComparison = if ($runtimeIsWindows) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}
$pathComparer = if ($runtimeIsWindows) {
    [StringComparer]::OrdinalIgnoreCase
} else {
    [StringComparer]::Ordinal
}
$excludedDirectoryNames = [System.Collections.Generic.HashSet[string]]::new(
    [string[]](Get-PrivateScanExcludedDirectories),
    $pathComparer
)
$trackedFullPaths = [System.Collections.Generic.HashSet[string]]::new(
    $pathComparer
)
$scanTargets = New-Object System.Collections.Generic.List[object]
$usingGitIndex = $false
$gitExe = Get-Command git -ErrorAction SilentlyContinue

# The local marker file is configuration, not a scan target. Read it only after
# validating the root, reject links, and decode strictly so an external target
# or malformed byte sequence cannot silently alter the rule set.
$localMarkerFile = Join-Path $root '.private-markers.local'
$localMarkerItem = Get-Item `
    -LiteralPath $localMarkerFile `
    -Force `
    -ErrorAction SilentlyContinue
if ($null -ne $localMarkerItem) {
    if ($localMarkerItem.PSIsContainer -or
        (Test-IsReparsePoint -Item $localMarkerItem) -or
        $localMarkerItem.Length -gt $maxLocalMarkerBytes) {
        Stop-ScanIntegrityFailure -Reason 'local-marker-type'
    }
    try {
        $localMarkerBytes = [IO.File]::ReadAllBytes($localMarkerFile)
        $localMarkerItemAfter = Get-Item `
            -LiteralPath $localMarkerFile `
            -Force `
            -ErrorAction Stop
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'local-marker-read'
    }
    if ($localMarkerItemAfter.PSIsContainer -or
        (Test-IsReparsePoint -Item $localMarkerItemAfter) -or
        $localMarkerItemAfter.Length -ne $localMarkerBytes.Length) {
        Stop-ScanIntegrityFailure -Reason 'local-marker-drift'
    }
    try {
        $localMarkerText = [System.Text.UTF8Encoding]::new(
            $false,
            $true
        ).GetString($localMarkerBytes)
        $localMarkerText = $localMarkerText.TrimStart([char]0xFEFF)
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'local-marker-encoding'
    }
    Add-LocalMarkersFromText -Text $localMarkerText
}

if ($null -ne $gitExe) {
    $gitIsolationRoot = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) ("bounded-playwright-ui-verification-public-git-" +
        [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $gitIsolationRoot -ErrorAction Stop |
            Out-Null
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'git-isolation-create'
    }
    try {
        $topLevelResult = Invoke-ScannerGitProcess `
            -FileName $gitExe.Source `
            -Arguments @('-C', $root, 'rev-parse', '--show-toplevel') `
            -IsolationRoot $gitIsolationRoot `
            -WorkingDirectory $root `
            -MaxStdoutBytes 65536
        if (-not (Test-BoundedProcessHealthy -Result $topLevelResult)) {
            Stop-ScanIntegrityFailure -Reason 'git-top-level-process'
        }

        if ($topLevelResult.ExitCode -eq 0) {
            $usingGitIndex = $true
            $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
            try {
                $topLevelText = $strictUtf8.GetString(
                    $topLevelResult.StdoutBytes
                ).TrimEnd([char[]]@([char]13, [char]10))
            }
            catch {
                Stop-ScanIntegrityFailure -Reason 'git-top-level-encoding'
            }
            if ([string]::IsNullOrWhiteSpace($topLevelText)) {
                Stop-ScanIntegrityFailure -Reason 'git-top-level-empty'
            }
            if ($topLevelText.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0) {
                Stop-ScanIntegrityFailure -Reason 'git-top-level-record'
            }
            try {
                $resolvedTopLevel = (Resolve-Path -LiteralPath $topLevelText).Path
            }
            catch {
                Stop-ScanIntegrityFailure -Reason 'git-top-level-missing'
            }
            if (-not [string]::Equals($root, $resolvedTopLevel, $pathComparison)) {
                Stop-ScanIntegrityFailure -Reason 'git-root-mismatch'
            }

            $indexResult = Invoke-ScannerGitProcess `
                -FileName $gitExe.Source `
                -Arguments @('-C', $root, 'ls-files', '-z', '--stage', '--') `
                -IsolationRoot $gitIsolationRoot `
                -WorkingDirectory $root `
                -MaxStdoutBytes $maxGitMetadataBytes
            if (-not (Test-BoundedProcessHealthy -Result $indexResult) -or
                $indexResult.ExitCode -ne 0) {
                Stop-ScanIntegrityFailure -Reason 'git-index-list'
            }

            # Parse NUL records as bytes so tabs/newlines inside paths do not
            # corrupt the stage header or path boundary.
            $records = New-Object System.Collections.Generic.List[object]
            $recordStart = 0
            for ($offset = 0; $offset -lt $indexResult.StdoutBytes.Length; $offset++) {
                if (($offset -band 4095) -eq 0) {
                    Assert-PrivateMarkerScanDeadline
                }
                if ($indexResult.StdoutBytes[$offset] -ne 0) {
                    continue
                }
                $recordLength = $offset - $recordStart
                $recordBytes = New-Object byte[] $recordLength
                if ($recordLength -gt 0) {
                    [Array]::Copy(
                        $indexResult.StdoutBytes,
                        $recordStart,
                        $recordBytes,
                        0,
                        $recordLength
                    )
                }
                $records.Add($recordBytes) | Out-Null
                $recordStart = $offset + 1
            }
            if ($recordStart -ne $indexResult.StdoutBytes.Length) {
                Stop-ScanIntegrityFailure -Reason 'git-index-nul'
            }
            if ($records.Count -gt $maxGitIndexEntries) {
                Stop-ScanIntegrityFailure -Reason 'git-index-entry-budget'
            }

            # `ls-files --stage` cannot distinguish an actual empty blob from
            # the extended-index intent-to-add bit. Read the index debug flags
            # through the same bounded/hermetic Git boundary and compare every
            # raw stage header/path byte before trusting CE_INTENT_TO_ADD.
            $debugResult = Invoke-ScannerGitProcess `
                -FileName $gitExe.Source `
                -Arguments @(
                    '-C',
                    $root,
                    'ls-files',
                    '-z',
                    '--stage',
                    '--debug',
                    '--'
                ) `
                -IsolationRoot $gitIsolationRoot `
                -WorkingDirectory $root `
                -MaxStdoutBytes $maxGitMetadataBytes
            if (-not (Test-BoundedProcessHealthy -Result $debugResult) -or
                $debugResult.ExitCode -ne 0) {
                Stop-ScanIntegrityFailure -Reason 'git-index-debug'
            }

            $debugOffset = 0
            foreach ($recordBytes in $records) {
                Assert-PrivateMarkerScanDeadline
                if (($debugOffset + $recordBytes.Length) -ge
                    $debugResult.StdoutBytes.Length) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-debug-record'
                }
                for ($recordByteIndex = 0;
                    $recordByteIndex -lt $recordBytes.Length;
                    $recordByteIndex++) {
                    if (($recordByteIndex -band 4095) -eq 0) {
                        Assert-PrivateMarkerScanDeadline
                    }
                    if ($debugResult.StdoutBytes[
                            $debugOffset + $recordByteIndex
                        ] -ne $recordBytes[$recordByteIndex]) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-debug-record'
                    }
                }
                $debugOffset += $recordBytes.Length
                if ($debugResult.StdoutBytes[$debugOffset] -ne 0) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-debug-nul'
                }
                $debugOffset++

                $debugLines = New-Object `
                    System.Collections.Generic.List[string]
                for ($debugLineIndex = 0;
                    $debugLineIndex -lt 5;
                    $debugLineIndex++) {
                    Assert-PrivateMarkerScanDeadline
                    $lineEnd = -1
                    $lineSearchLimit = [Math]::Min(
                        $debugResult.StdoutBytes.Length,
                        $debugOffset + 256
                    )
                    for ($offset = $debugOffset;
                        $offset -lt $lineSearchLimit;
                        $offset++) {
                        if ($debugResult.StdoutBytes[$offset] -eq 10) {
                            $lineEnd = $offset
                            break
                        }
                        if ($debugResult.StdoutBytes[$offset] -gt 127) {
                            Stop-ScanIntegrityFailure `
                                -Reason 'git-index-debug-encoding'
                        }
                    }
                    if ($lineEnd -lt 0) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-debug-line'
                    }
                    $debugLines.Add(
                        [Text.Encoding]::ASCII.GetString(
                            $debugResult.StdoutBytes,
                            $debugOffset,
                            $lineEnd - $debugOffset
                        )
                    ) | Out-Null
                    $debugOffset = $lineEnd + 1
                }

                if ($debugLines[0] -notmatch
                    '^  ctime: [0-9]+:[0-9]+$' -or
                    $debugLines[1] -notmatch
                    '^  mtime: [0-9]+:[0-9]+$' -or
                    $debugLines[2] -notmatch
                    "^  dev: [0-9]+`tino: [0-9]+$" -or
                    $debugLines[3] -notmatch
                    "^  uid: [0-9]+`tgid: [0-9]+$") {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-debug-metadata'
                }
                $flagsMatch = [regex]::Match(
                    $debugLines[4],
                    "^  size: [0-9]+`tflags: (?<flags>[0-9a-fA-F]+)$"
                )
                [uint64]$debugFlags = 0
                if (-not $flagsMatch.Success -or
                    -not [uint64]::TryParse(
                        $flagsMatch.Groups['flags'].Value,
                        [Globalization.NumberStyles]::HexNumber,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$debugFlags
                    )) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-debug-flags'
                }
                if (($debugFlags -band [uint64]0x20000000) -ne 0) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-intent-to-add'
                }
            }
            if ($debugOffset -ne $debugResult.StdoutBytes.Length) {
                Stop-ScanIntegrityFailure `
                    -Reason 'git-index-debug-trailing'
            }

            $indexEntries = New-Object System.Collections.Generic.List[object]
            $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
                $pathComparer
            )
            foreach ($recordBytes in $records) {
                Assert-PrivateMarkerScanDeadline
                if ($recordBytes.Length -eq 0) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-empty-record'
                }
                $tabOffset = [Array]::IndexOf($recordBytes, [byte]9)
                if ($tabOffset -le 0 -or $tabOffset -ge ($recordBytes.Length - 1)) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-record'
                }
                $header = [Text.Encoding]::ASCII.GetString(
                    $recordBytes,
                    0,
                    $tabOffset
                )
                $headerMatch = [regex]::Match(
                    $header,
                    '^(?<mode>[0-9]{6}) (?<oid>[0-9a-fA-F]{40}|[0-9a-fA-F]{64}) (?<stage>[0-3])$'
                )
                if (-not $headerMatch.Success) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-header'
                }

                $pathLength = $recordBytes.Length - $tabOffset - 1
                try {
                    $gitPath = $strictUtf8.GetString(
                        $recordBytes,
                        $tabOffset + 1,
                        $pathLength
                    )
                }
                catch {
                    Stop-ScanIntegrityFailure -Reason 'git-index-path-encoding'
                }
                if ($gitPath.Length -gt $maxGitPathCharacters) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-path-budget'
                }
                $gitPathSegments = @($gitPath -split '/')
                if ($gitPathSegments.Count -gt $maxGitPathSegments -or
                    [string]::IsNullOrEmpty($gitPath) -or
                    [IO.Path]::IsPathRooted($gitPath) -or
                    @($gitPathSegments | Where-Object {
                        $_ -eq '' -or $_ -eq '.' -or $_ -eq '..'
                    }).Count -gt 0) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-path'
                }

                $mode = $headerMatch.Groups['mode'].Value
                $oid = $headerMatch.Groups['oid'].Value.ToLowerInvariant()
                $stage = [int]$headerMatch.Groups['stage'].Value
                if ($stage -ne 0) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-conflict'
                }
                if ($oid -match '^0+$') {
                    Stop-ScanIntegrityFailure -Reason 'git-index-intent-to-add'
                }
                if ($mode -eq '160000') {
                    Stop-ScanIntegrityFailure -Reason 'git-index-gitlink'
                }
                if ($mode -notin @('100644', '100755', '120000')) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-mode'
                }
                if ($gitPath -eq '.private-markers.local') {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-local-marker'
                }
                # 除外対象であっても index record 自体の一意性は先に検証し、
                # 壊れた index を「除外ディレクトリだから安全」と見逃さない。
                if (-not $seenPaths.Add($gitPath)) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-duplicate-path'
                }
                if (Test-IsExcludedGitPath -GitPath $gitPath) {
                    continue
                }

                $nativeRelativePath = $gitPath.Replace(
                    [char]47,
                    [IO.Path]::DirectorySeparatorChar
                )
                try {
                    $fullPath = [IO.Path]::GetFullPath(
                        (Join-Path $root $nativeRelativePath)
                    )
                }
                catch {
                    Stop-ScanIntegrityFailure -Reason 'git-index-full-path'
                }
                $rootBoundary = $root.TrimEnd([char]47, [char]92) +
                    [IO.Path]::DirectorySeparatorChar
                if (-not $fullPath.StartsWith($rootBoundary, $pathComparison) -or
                    -not $trackedFullPaths.Add($fullPath)) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-path-boundary'
                }

                $indexEntries.Add([pscustomobject]@{
                    Mode = $mode
                    Oid = $oid
                    Path = $gitPath
                    FullPath = $fullPath
                }) | Out-Null
            }

            # Fetch all unique text blobs through one binary-safe batch. This
            # keeps process count constant instead of multiplying per tracked
            # file, while the parser still enforces every object ID/type/size
            # and the exact trailing byte boundary.
            $blobCache = @{}
            $blobOids = New-Object System.Collections.Generic.List[string]
            $blobOidSet = [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal
            )
            foreach ($entry in $indexEntries) {
                Assert-PrivateMarkerScanDeadline
                if ((Test-IsTextFile -FullPath $entry.Path) -and
                    $blobOidSet.Add($entry.Oid)) {
                    $blobOids.Add($entry.Oid) | Out-Null
                }
            }
            if ($blobOids.Count -gt 0) {
                $batchInputText = ($blobOids -join "`n") + "`n"
                $batchInputBytes = [Text.Encoding]::ASCII.GetBytes(
                    $batchInputText
                )
                $batchOutputLimit = [int](
                    $maxTotalScanBytes + ($blobOids.Count * 160) + 1
                )
                $batchResult = Invoke-ScannerGitProcess `
                    -FileName $gitExe.Source `
                    -Arguments @('-C', $root, 'cat-file', '--batch') `
                    -IsolationRoot $gitIsolationRoot `
                    -WorkingDirectory $root `
                    -MaxStdoutBytes $batchOutputLimit `
                    -StandardInputBytes $batchInputBytes
                if (-not (Test-BoundedProcessHealthy -Result $batchResult) -or
                    $batchResult.ExitCode -ne 0) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-blob-batch'
                }

                $batchOffset = 0
                $batchBlobTotal = 0L
                foreach ($expectedOid in $blobOids) {
                    Assert-PrivateMarkerScanDeadline
                    $headerEnd = -1
                    $headerSearchLimit = [Math]::Min(
                        $batchResult.StdoutBytes.Length,
                        $batchOffset + 256
                    )
                    for ($offset = $batchOffset;
                        $offset -lt $headerSearchLimit;
                        $offset++) {
                        if ($batchResult.StdoutBytes[$offset] -eq 10) {
                            $headerEnd = $offset
                            break
                        }
                    }
                    if ($headerEnd -lt 0) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-blob-header'
                    }
                    for ($offset = $batchOffset;
                        $offset -lt $headerEnd;
                        $offset++) {
                        if ($batchResult.StdoutBytes[$offset] -gt 127) {
                            Stop-ScanIntegrityFailure `
                                -Reason 'git-index-blob-header-encoding'
                        }
                    }
                    $batchHeader = [Text.Encoding]::ASCII.GetString(
                        $batchResult.StdoutBytes,
                        $batchOffset,
                        $headerEnd - $batchOffset
                    )
                    $batchHeaderMatch = [regex]::Match(
                        $batchHeader,
                        '^(?<oid>[0-9a-fA-F]{40}|[0-9a-fA-F]{64}) blob (?<size>0|[1-9][0-9]*)$'
                    )
                    if (-not $batchHeaderMatch.Success -or
                        -not $batchHeaderMatch.Groups['oid'].Value.Equals(
                            $expectedOid,
                            [StringComparison]::OrdinalIgnoreCase
                        )) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-blob-header'
                    }
                    $blobSize = 0L
                    if (-not [long]::TryParse(
                        $batchHeaderMatch.Groups['size'].Value,
                        [Globalization.NumberStyles]::None,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$blobSize
                    ) -or
                        $blobSize -gt $maxTextFileBytes) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-blob-size'
                    }
                    $batchBlobTotal += $blobSize
                    if ($batchBlobTotal -gt $maxTotalScanBytes) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-blob-total-size'
                    }
                    $blobStart = $headerEnd + 1
                    $blobEnd = $blobStart + $blobSize
                    if ($blobEnd -ge $batchResult.StdoutBytes.Length -or
                        $batchResult.StdoutBytes[$blobEnd] -ne 10) {
                        Stop-ScanIntegrityFailure `
                            -Reason 'git-index-blob-boundary'
                    }
                    $indexBytes = New-Object byte[] ([int]$blobSize)
                    if ($blobSize -gt 0) {
                        [Array]::Copy(
                            $batchResult.StdoutBytes,
                            $blobStart,
                            $indexBytes,
                            0,
                            [int]$blobSize
                        )
                    }
                    $blobCache[$expectedOid] = $indexBytes
                    $batchOffset = [int]($blobEnd + 1)
                }
                if ($batchOffset -ne $batchResult.StdoutBytes.Length) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'git-index-blob-trailing'
                }
            }

            foreach ($entry in $indexEntries) {
                Assert-PrivateMarkerScanDeadline
                if (-not (Test-IsTextFile -FullPath $entry.Path)) {
                    continue
                }
                if (-not $blobCache.ContainsKey($entry.Oid)) {
                    Stop-ScanIntegrityFailure -Reason 'git-index-blob-cache'
                }
                $indexBytes = [byte[]]$blobCache[$entry.Oid]

                $worktreeState = Get-SafeTrackedWorktreeState `
                    -RepositoryRoot $root `
                    -GitPath $entry.Path `
                    -Mode $entry.Mode
                if ($worktreeState.State -eq 'missing') {
                    $state = if ($entry.Mode -eq '120000') {
                        'index symlink; worktree missing'
                    } else {
                        'index; worktree missing'
                    }
                    Add-ScanTarget `
                        -Targets $scanTargets `
                        -DisplayPath "$($entry.Path) [$state]" `
                        -Bytes $indexBytes
                } elseif (Test-ByteArraysEqual `
                    -Left $indexBytes `
                    -Right $worktreeState.Bytes) {
                    Add-ScanTarget `
                        -Targets $scanTargets `
                        -DisplayPath $entry.Path `
                        -Bytes $indexBytes
                } else {
                    Add-ScanTarget `
                        -Targets $scanTargets `
                        -DisplayPath "$($entry.Path) [index]" `
                        -Bytes $indexBytes
                    Add-ScanTarget `
                        -Targets $scanTargets `
                        -DisplayPath "$($entry.Path) [worktree]" `
                        -Bytes $worktreeState.Bytes
                }
            }

            # Re-read the exact raw stage listing after every index/worktree
            # snapshot has been captured. An index mutation during the scan
            # invalidates the result even when all already-read blobs were
            # internally consistent.
            $indexVerifyResult = Invoke-ScannerGitProcess `
                -FileName $gitExe.Source `
                -Arguments @('-C', $root, 'ls-files', '-z', '--stage', '--') `
                -IsolationRoot $gitIsolationRoot `
                -WorkingDirectory $root `
                -MaxStdoutBytes $maxGitMetadataBytes
            if (-not (Test-BoundedProcessHealthy -Result $indexVerifyResult) -or
                $indexVerifyResult.ExitCode -ne 0) {
                Stop-ScanIntegrityFailure -Reason 'git-index-verify'
            }
            if (-not (Test-ByteArraysEqual `
                -Left $indexResult.StdoutBytes `
                -Right $indexVerifyResult.StdoutBytes)) {
                Stop-ScanIntegrityFailure -Reason 'git-index-drift'
            }
        } elseif (Test-HasGitMetadataAncestor -StartPath $root) {
            Stop-ScanIntegrityFailure -Reason 'git-probe'
        }
    }
    finally {
        try {
            if (Test-Path `
                -LiteralPath $gitIsolationRoot `
                -ErrorAction Stop) {
                Remove-Item `
                    -LiteralPath $gitIsolationRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch {
            Stop-ScanIntegrityFailure -Reason 'git-isolation-cleanup'
        }
    }
} elseif (Test-HasGitMetadataAncestor -StartPath $root) {
    Stop-ScanIntegrityFailure -Reason 'git-unavailable'
}

if ($usingGitIndex) {
    $scanMode = 'git-index+working-tree'
} else {
    $scanMode = 'working-tree'
}

# 019はT-024のtracked-only modeを採用しない。Git index/worktree snapshotに
# 加え、除外対象外のuntracked textも同じsafe readerで必ず走査する。
$pendingDirectories = New-Object `
    'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
$pendingDirectories.Push([System.IO.DirectoryInfo]$rootItem)
while ($pendingDirectories.Count -gt 0) {
    Assert-PrivateMarkerScanDeadline
    $directory = $pendingDirectories.Pop()
    try {
        # Enumerate lazily so the entry budget applies before a hostile
        # directory can be materialized as one large PowerShell array.
        $children = $directory.EnumerateFileSystemInfos()
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'working-tree-enumeration'
    }
    try {
        foreach ($child in $children) {
            Assert-PrivateMarkerScanDeadline
            $script:workingTreeEntryCount++
            if ($script:workingTreeEntryCount -gt
                $maxWorkingTreeEntries) {
                Stop-ScanIntegrityFailure `
                    -Reason 'working-tree-entry-budget'
            }
            if ($child -is [System.IO.DirectoryInfo]) {
                if ($excludedDirectoryNames.Contains($child.Name)) {
                    continue
                }
                if (Test-IsReparsePoint -Item $child) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'working-tree-reparse-directory'
                }
                $pendingDirectories.Push(
                    [System.IO.DirectoryInfo]$child
                )
                continue
            }
            if ([string]::Equals(
                    $child.Name,
                    '.git',
                    $pathComparison
                ) -or
                [string]::Equals(
                    $child.Name,
                    '.private-markers.local',
                    $pathComparison
                ) -or
                -not (Test-IsTextFile -FullPath $child.FullName)) {
                continue
            }
            if (Test-IsReparsePoint -Item $child) {
                Stop-ScanIntegrityFailure `
                    -Reason 'working-tree-reparse-file'
            }
            $childFullPath = [IO.Path]::GetFullPath($child.FullName)
            if ($usingGitIndex -and
                $trackedFullPaths.Contains($childFullPath)) {
                # tracked regular worktree bytes were already captured beside
                # their index blob; do not double-count the same snapshot.
                continue
            }

            $relative = $childFullPath
            $rootBoundary = $root.TrimEnd([char]47, [char]92) +
                [IO.Path]::DirectorySeparatorChar
            if (-not $relative.StartsWith(
                $rootBoundary,
                $pathComparison
            )) {
                Stop-ScanIntegrityFailure `
                    -Reason 'working-tree-path-boundary'
            }
            $relative = $relative.Substring(
                $rootBoundary.Length
            ).Replace(
                [IO.Path]::DirectorySeparatorChar,
                [char]47
            )
            $worktreeState = Get-SafeTrackedWorktreeState `
                -RepositoryRoot $root `
                -GitPath $relative `
                -Mode '100644'
            if ($worktreeState.State -ne 'regular') {
                Stop-ScanIntegrityFailure `
                    -Reason 'working-tree-type-drift'
            }
            Add-ScanTarget `
                -Targets $scanTargets `
                -DisplayPath $relative `
                -Bytes $worktreeState.Bytes
        }
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'working-tree-enumeration'
    }
}

# 確定snapshotをstrict UTF-8で逐次走査し、line/match/findingの全budgetを消費する。
foreach ($target in $scanTargets) {
    Assert-PrivateMarkerScanDeadline
    if ($findingsTruncated) {
        break
    }
    $relative = $target.DisplayPath
    $lineNumber = 0

    # Decode the exact index/worktree snapshot strictly as UTF-8. Invalid bytes
    # fail closed instead of being replaced with U+FFFD, which could hide a
    # marker boundary differently across Windows PowerShell and PowerShell 7.
    try {
        $text = [System.Text.UTF8Encoding]::new(
            $false,
            $true
        ).GetString([byte[]]$target.Bytes)
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'scan-target-encoding'
    }
    $lineReader = New-Object System.IO.StringReader($text)
    try {
        # StringReader avoids the full line-object array created by `-split`.
        # The explicit total line budget also bounds zero-length-line inputs.
        while (-not $findingsTruncated -and $lineReader.Peek() -ge 0) {
            Assert-PrivateMarkerScanDeadline
            if ($script:totalScanLines -ge $maxScanLines) {
                Stop-ScanIntegrityFailure -Reason 'scan-line-budget'
            }
            $line = $lineReader.ReadLine()
            $script:totalScanLines++
            $lineNumber++

            # Walk matches lazily so one marker-dense line cannot allocate an
            # unbounded MatchCollection before the finding cap is applied.
            $githubMatch = [regex]::Match($line, $githubUrlPattern)
            while ($githubMatch.Success) {
                Assert-PrivateMarkerScanDeadline
                $script:regexMatchCount++
                if ($script:regexMatchCount -gt $maxRegexMatches) {
                    Stop-ScanIntegrityFailure `
                        -Reason 'scan-regex-match-budget'
                }
                if ($githubMatch.Value -notmatch $ownRepoUrlPattern -and
                    -not (Add-ScanFinding `
                        -File $relative `
                        -Line $lineNumber `
                        -Rule 'non-allowlisted-github-repo-url')) {
                    break
                }
                $githubMatch = $githubMatch.NextMatch()
            }
            if ($findingsTruncated) {
                break
            }

            foreach ($rule in $rules) {
                Assert-PrivateMarkerScanDeadline
                $matched = $false
                if ($rule.Kind -eq 'literal') {
                    $matched = $line.Contains($rule.Pattern)
                } elseif ([string]::IsNullOrEmpty($rule.Allowlist)) {
                    $matched = [regex]::IsMatch(
                        $line,
                        $rule.Pattern,
                        'IgnoreCase'
                    )
                } else {
                    # Inspect allowlisted regex matches lazily and under one
                    # global match budget. Most lines stop at the first unsafe
                    # value, while placeholder-dense input remains finite.
                    $allowlistMatch = [regex]::Match(
                        $line,
                        $rule.Pattern,
                        'IgnoreCase'
                    )
                    while ($allowlistMatch.Success) {
                        Assert-PrivateMarkerScanDeadline
                        $script:regexMatchCount++
                        if ($script:regexMatchCount -gt
                            $maxRegexMatches) {
                            Stop-ScanIntegrityFailure `
                                -Reason 'scan-regex-match-budget'
                        }
                        if (-not [regex]::IsMatch(
                            $allowlistMatch.Value,
                            $rule.Allowlist
                        )) {
                            $matched = $true
                            break
                        }
                        $allowlistMatch = $allowlistMatch.NextMatch()
                    }
                }

                if ($matched) {
                    [void](Add-ScanFinding `
                        -File $relative `
                        -Line $lineNumber `
                        -Rule $rule.Name)
                    if ($findingsTruncated) {
                        break
                    }
                }
            }
        }
    }
    finally {
        $lineReader.Dispose()
    }
}

# The first raw recheck protects snapshot construction. Repeat it after content
# matching so an index change during a long regex scan cannot be reported as a
# success for a repository state that is no longer current.
if ($usingGitIndex) {
    try {
        New-Item `
            -ItemType Directory `
            -Path $gitIsolationRoot `
            -ErrorAction Stop | Out-Null
    }
    catch {
        Stop-ScanIntegrityFailure -Reason 'git-isolation-create'
    }
    try {
        $reportVerifyResult = Invoke-ScannerGitProcess `
            -FileName $gitExe.Source `
            -Arguments @('-C', $root, 'ls-files', '-z', '--stage', '--') `
            -IsolationRoot $gitIsolationRoot `
            -WorkingDirectory $root `
            -MaxStdoutBytes $maxGitMetadataBytes
        if (-not (Test-BoundedProcessHealthy -Result $reportVerifyResult) -or
            $reportVerifyResult.ExitCode -ne 0) {
            Stop-ScanIntegrityFailure -Reason 'git-index-report-verify'
        }
        if (-not (Test-ByteArraysEqual `
            -Left $indexResult.StdoutBytes `
            -Right $reportVerifyResult.StdoutBytes)) {
            Stop-ScanIntegrityFailure -Reason 'git-index-drift'
        }
        $reportDebugResult = Invoke-ScannerGitProcess `
            -FileName $gitExe.Source `
            -Arguments @(
                '-C',
                $root,
                'ls-files',
                '-z',
                '--stage',
                '--debug',
                '--'
            ) `
            -IsolationRoot $gitIsolationRoot `
            -WorkingDirectory $root `
            -MaxStdoutBytes $maxGitMetadataBytes
        if (-not (Test-BoundedProcessHealthy -Result $reportDebugResult) -or
            $reportDebugResult.ExitCode -ne 0) {
            Stop-ScanIntegrityFailure `
                -Reason 'git-index-report-debug-verify'
        }
        if (-not (Test-ByteArraysEqual `
            -Left $debugResult.StdoutBytes `
            -Right $reportDebugResult.StdoutBytes)) {
            Stop-ScanIntegrityFailure -Reason 'git-index-drift'
        }
    }
    finally {
        try {
            if (Test-Path `
                -LiteralPath $gitIsolationRoot `
                -ErrorAction Stop) {
                Remove-Item `
                    -LiteralPath $gitIsolationRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch {
            Stop-ScanIntegrityFailure -Reason 'git-isolation-cleanup'
        }
    }
}

if ($findings.Count -gt 0) {
    # prefix/header/row/truncation noticeと実OS newlineを同じpayloadへ積み、
    # 最終UTF-8 bytesを一度だけstdoutへ書く。Format-Tableへ敵対的pathを
    # 渡さず、host依存の折返し・部分table・CRLF換算漏れを防ぐ。
    $reportNewline = [Environment]::NewLine
    $reportPrefix = "Private marker scan failed (scan target: $scanMode):"
    $reportHeader = "File`tLine`tRule`tMatch"
    $reportBuilder = New-Object Text.StringBuilder
    [void]$reportBuilder.Append($reportPrefix)
    [void]$reportBuilder.Append($reportNewline)
    [void]$reportBuilder.Append($reportHeader)
    [void]$reportBuilder.Append($reportNewline)
    $reportByteCount = [Text.Encoding]::UTF8.GetByteCount(
        $reportBuilder.ToString()
    )
    foreach ($finding in ($findings | Sort-Object File, Line, Rule)) {
        Assert-PrivateMarkerScanDeadline
        $reportRow = "{0}`t{1}`t{2}`t{3}" -f @(
            $finding.File,
            $finding.Line,
            $finding.Rule,
            $finding.Match
        )
        $rowByteCount = [Text.Encoding]::UTF8.GetByteCount(
            $reportRow + $reportNewline
        )
        if (($reportByteCount + $rowByteCount) -gt
            $maxFindingOutputBytes) {
            Stop-ScanIntegrityFailure -Reason 'finding-output-budget'
        }
        [void]$reportBuilder.Append($reportRow)
        [void]$reportBuilder.Append($reportNewline)
        $reportByteCount += $rowByteCount
    }
    if ($findingsTruncated) {
        $truncationNotice =
            "Additional findings omitted after $maxFindings entries."
        $truncationByteCount = [Text.Encoding]::UTF8.GetByteCount(
            $truncationNotice + $reportNewline
        )
        if (($reportByteCount + $truncationByteCount) -gt
            $maxFindingOutputBytes) {
            Stop-ScanIntegrityFailure -Reason 'finding-output-budget'
        }
        [void]$reportBuilder.Append($truncationNotice)
        [void]$reportBuilder.Append($reportNewline)
        $reportByteCount += $truncationByteCount
    }
    [byte[]]$reportBytes = [Text.Encoding]::UTF8.GetBytes(
        $reportBuilder.ToString()
    )
    if ($reportBytes.Length -ne $reportByteCount -or
        $reportBytes.Length -gt $maxFindingOutputBytes) {
        Stop-ScanIntegrityFailure -Reason 'finding-output-budget'
    }
    $reportStream = [Console]::OpenStandardOutput()
    try {
        # serializeとstream取得後、write直前にscan-wide期限を再確認する。
        Assert-PrivateMarkerScanDeadline
        $reportStream.Write($reportBytes, 0, $reportBytes.Length)
        $reportStream.Flush()
    }
    finally {
        $reportStream.Dispose()
    }
    exit 1
}

# clean判定もemit直前に期限を再確認し、最後のGit probe後の超過を成功にしない。
Assert-PrivateMarkerScanDeadline
Write-Host "Private marker scan passed (scan target: $scanMode)."
exit 0
