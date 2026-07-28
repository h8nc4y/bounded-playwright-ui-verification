[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtimeIsWindows = [Environment]::OSVersion.Platform -eq
    [PlatformID]::Win32NT

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$selfTestScriptPath = $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
$scanner = Join-Path $root 'scripts/scan-private-markers.ps1'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}
$processSupport = Microsoft.PowerShell.Management\Join-Path `
    $PSScriptRoot `
    '../scripts/private-marker-process.ps1'
if (-not (Test-Path -LiteralPath $processSupport -PathType Leaf)) {
    throw "Missing bounded process support script: $processSupport"
}
. $processSupport
$scanConfig = Join-Path $root 'scripts/private-scan-config.ps1'
if (-not (Test-Path -LiteralPath $scanConfig -PathType Leaf)) {
    throw "Missing private scan config script: $scanConfig"
}
$expectedExcludedDirectoryNames = @(
    '.git',
    '.claude',
    '.codex',
    'node_modules',
    '.ui-verification',
    'playwright-report',
    'test-results',
    'coverage',
    'dist',
    'build'
)

$currentPowerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([string]::IsNullOrWhiteSpace($currentPowerShellExecutable) -or
    -not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    $hostExecutableName = if ($PSVersionTable.PSVersion.Major -le 5) {
        'powershell.exe'
    } elseif ($runtimeIsWindows) {
        'pwsh.exe'
    } else {
        'pwsh'
    }
    $currentPowerShellExecutable = Join-Path $PSHOME $hostExecutableName
}
if (-not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    throw "Cannot resolve the current PowerShell host executable: $currentPowerShellExecutable"
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.Keys) {
        $snapshot["$name"] = [string]$environment[$name]
    }
    return $snapshot
}

function Compare-ProcessEnvironmentSnapshot {
    param([hashtable]$Expected)

    $actual = Get-ProcessEnvironmentSnapshot
    $mismatches = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys + $actual.Keys) | Sort-Object -Unique) {
        if ($Expected.ContainsKey($name) -ne $actual.ContainsKey($name) -or
            ($Expected.ContainsKey($name) -and $Expected[$name] -cne $actual[$name])) {
            # Never include values: ambient environment data may be sensitive.
            $mismatches.Add($name) | Out-Null
        }
    }
    return @($mismatches)
}

function Assert-ProcessEnvironmentUnchanged {
    param(
        [hashtable]$Expected,
        [string]$Context
    )

    $mismatches = @(Compare-ProcessEnvironmentSnapshot -Expected $Expected)
    if ($mismatches.Count -gt 0) {
        Add-Failure "$Context changed parent environment variables: $($mismatches -join ', ')."
    }
}

function Test-BoundedResultHealthy {
    param([object]$Result)

    return $null -ne $Result -and
        -not $Result.TimedOut -and
        -not $Result.OutputLimitExceeded -and
        $Result.ContainmentEstablished -and
        $Result.TreeStopped -and
        $Result.StreamsDrained
}

# Win32 waitまでのmillisecond値をsource構造で検証し、host schedulerを精度oracleに使わない。
function Test-PrivateMarkerMillisecondWaitContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $tokens = $null
    $parseErrors = $null
    $sourceAst = [Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $false
    }
    $normalizeNewlines = {
        param([string]$Text)
        return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    }

    # 実際にAdd-Typeへ渡るhere-stringだけを特定し、PowerShell側decoyを証拠に数えない。
    $boundedTypeSources = @(
        foreach ($command in @($sourceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Add-Type'
        }, $true))) {
            $elements = @($command.CommandElements)
            if ($elements.Count -ne 3 -or
                $elements[1] -isnot
                    [Management.Automation.Language.CommandParameterAst] -or
                $elements[1].ParameterName -cne 'TypeDefinition' -or
                $elements[2] -isnot
                    [Management.Automation.Language.StringConstantExpressionAst]) {
                continue
            }
            $typeSource = [string]$elements[2].Value
            if ($typeSource.Contains(
                'public sealed class BoundedPlaywrightContainedProcess'
            )) {
                $typeSource
            }
        }
    )
    if ($boundedTypeSources.Count -ne 1) {
        return $false
    }

    # C# wrapperは秒換算を挟まず、受け取ったint millisecondsをWin32へ直接渡す。
    $expectedWaitMethod = @'
    public bool WaitForExit(int milliseconds)
    {
        return WaitForSingleObject(processHandle, (uint)milliseconds) ==
            WaitObject0;
    }
'@
    $boundedTypeSource = & $normalizeNewlines $boundedTypeSources[0]
    $normalizedWaitMethod = & $normalizeNewlines $expectedWaitMethod
    $waitMethodIndex = $boundedTypeSource.IndexOf(
        $normalizedWaitMethod,
        [StringComparison]::Ordinal
    )
    if ($waitMethodIndex -lt 0 -or
        $waitMethodIndex -ne $boundedTypeSource.LastIndexOf(
            $normalizedWaitMethod,
            [StringComparison]::Ordinal
        ) -or
        [regex]::Matches(
            $boundedTypeSource,
            '(?m)^[ \t]*public bool WaitForExit\s*\('
        ).Count -ne 1) {
        return $false
    }

    # exact Win32 importも同じAdd-Type sourceへ1件だけ存在させ、別wrapperへ逸らさない。
    $waitForSingleObjectImport =
        'private static extern uint WaitForSingleObject(' +
        'IntPtr handle, uint milliseconds);'
    $waitImportIndex = $boundedTypeSource.IndexOf(
        $waitForSingleObjectImport,
        [StringComparison]::Ordinal
    )
    if ($waitImportIndex -lt 0 -or
        $waitImportIndex -ne $boundedTypeSource.LastIndexOf(
            $waitForSingleObjectImport,
            [StringComparison]::Ordinal
        )) {
        return $false
    }

    # remaining helper全体をexact化し、deadline差分からintへ直返しする経路だけを許す。
    $expectedRemainingFunction = @'
function Get-PrivateMarkerRemainingMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [long]$DeadlineMilliseconds
    )

    $remaining = $DeadlineMilliseconds - $Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) {
        return 0
    }
    if ($remaining -gt [int]::MaxValue) {
        return [int]::MaxValue
    }
    return [int]$remaining
}
'@
    $remainingFunctions = @($sourceAst.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-PrivateMarkerRemainingMilliseconds'
    }, $true))
    if ($remainingFunctions.Count -ne 1 -or
        (& $normalizeNewlines $remainingFunctions[0].Extent.Text) -cne
            (& $normalizeNewlines $expectedRemainingFunction)) {
        return $false
    }

    # 最後のremaining代入からnative waitまでを連続exact regionへ閉じ、再代入を許さない。
    $expectedNativeWaitRegion = @'
        $remaining = if ($null -eq $cleanupClock) {
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $stopwatch `
                -DeadlineMilliseconds $deadline
        } else {
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
        }
        $streamsCompleted = $stdinClosed -and $stdoutClosed -and $stderrClosed
        $processExited = $false
        if ($streamsCompleted -and [string]::IsNullOrEmpty($limitExceeded)) {
            $processExited = if ($null -ne $nativeChild) {
                $nativeChild.WaitForExit($remaining)
'@
    $atomicFunctions = @($sourceAst.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-PrivateMarkerAtomicWindowsProcess'
    }, $true))
    if ($atomicFunctions.Count -ne 1) {
        return $false
    }

    # 引数にかかわらずnativeChild.WaitForExitを全件数え、実行callを1件だけ許す。
    $allNativeWaitCalls = @($atomicFunctions[0].Body.FindAll({
        param($node)
        if ($node -isnot
            [Management.Automation.Language.InvokeMemberExpressionAst]) {
            return $false
        }
        if ($node.Expression -isnot
                [Management.Automation.Language.VariableExpressionAst] -or
            $node.Expression.VariablePath.UserPath -cne 'nativeChild' -or
            $node.Member.Value -cne 'WaitForExit') {
            return $false
        }
        return $true
    }, $true))
    if ($allNativeWaitCalls.Count -ne 1) {
        return $false
    }
    $nativeWaitCall = $allNativeWaitCalls[0]
    if ($nativeWaitCall.Arguments.Count -ne 1 -or
        $nativeWaitCall.Arguments[0] -isnot
            [Management.Automation.Language.VariableExpressionAst] -or
        $nativeWaitCall.Arguments[0].VariablePath.UserPath -cne 'remaining') {
        return $false
    }

    # 実行call直前の最後のremaining代入をASTで選び、その実extentだけをexact比較する。
    $remainingAssignments = @($atomicFunctions[0].Body.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is
                [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq 'remaining'
    }, $true) | Where-Object {
        $_.Extent.EndOffset -le $nativeWaitCall.Extent.StartOffset
    } | Sort-Object -Property { $_.Extent.StartOffset })
    if ($remainingAssignments.Count -eq 0) {
        return $false
    }
    $lastRemainingAssignment = $remainingAssignments[-1]
    $nativeWaitRegionStartOffset =
        $lastRemainingAssignment.Extent.StartOffset -
        ($lastRemainingAssignment.Extent.StartColumnNumber - 1)
    $actualNativeWaitRegion = $Source.Substring(
        $nativeWaitRegionStartOffset,
        $nativeWaitCall.Extent.EndOffset -
            $nativeWaitRegionStartOffset
    )
    return (& $normalizeNewlines $actualNativeWaitRegion) -ceq
        (& $normalizeNewlines $expectedNativeWaitRegion)
}

# function/type 定義や未実行 scriptblock 内の helper call は「先に実行済み」
# ではない。AST の親を辿り、実行可能な top-level call だけを識別する。
function Test-PrivateMarkerCommandIsDeferredDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.Ast]$Node
    )

    $ancestor = $Node.Parent
    while ($null -ne $ancestor) {
        if ($ancestor -is
                [Management.Automation.Language.FunctionDefinitionAst] -or
            $ancestor -is
                [Management.Automation.Language.FunctionMemberAst] -or
            $ancestor -is
                [Management.Automation.Language.TypeDefinitionAst]) {
            return $true
        }
        if ($ancestor -is
            [Management.Automation.Language.ScriptBlockExpressionAst]) {
            # 保存しただけの scriptblock は data だが、command argument や
            # Invoke* member の内側なら eager execution の可能性を残す。
            $container = $ancestor.Parent
            $expressionCanExecuteScriptBlock = $false
            while ($null -ne $container) {
                if ($container -is
                        [Management.Automation.Language.FunctionDefinitionAst] -or
                    $container -is
                        [Management.Automation.Language.FunctionMemberAst] -or
                    $container -is
                        [Management.Automation.Language.TypeDefinitionAst]) {
                    return $true
                }
                if ($container -is
                        [Management.Automation.Language.CommandAst] -or
                    $container -is
                        [Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $expressionCanExecuteScriptBlock = $true
                    break
                }
                $container = $container.Parent
            }
            if (-not $expressionCanExecuteScriptBlock) {
                return $true
            }
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

function ConvertTo-NormalizedPrivateMarkerCommandName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $normalized = $Name.Trim()
    $moduleSeparator = $normalized.LastIndexOf([char]92)
    if ($moduleSeparator -ge 0) {
        $normalized = $normalized.Substring($moduleSeparator + 1)
    }
    while ($normalized -match
        '^(?i)(?:global|script|local|private|function|alias|variable):(?<name>.+)$') {
        $normalized = $Matches['name']
    }
    $normalized = $normalized.ToLowerInvariant()
    # PowerShell 組込み alias も実行時には同じ command へ解決される。
    # source 上の短縮名だけで Get/Invoke/Set 系の到達を隠せないよう正規化する。
    switch ($normalized) {
        'gcm' { return 'get-command' }
        'gi' { return 'get-item' }
        'icm' { return 'invoke-command' }
        'iex' { return 'invoke-expression' }
        'sal' { return 'set-alias' }
        'nal' { return 'new-alias' }
        'si' { return 'set-item' }
        'sc' { return 'set-content' }
        'ni' { return 'new-item' }
        'copy' { return 'copy-item' }
        'cp' { return 'copy-item' }
        'cpi' { return 'copy-item' }
        'move' { return 'move-item' }
        'mv' { return 'move-item' }
        'mi' { return 'move-item' }
        'ren' { return 'rename-item' }
        'rni' { return 'rename-item' }
        'set' { return 'set-variable' }
        'sv' { return 'set-variable' }
        'nv' { return 'new-variable' }
        '%' { return 'foreach-object' }
        '?' { return 'where-object' }
        default { return $normalized }
    }
}

# helper path本体と、その固定provenanceに使うautomatic variableを同じ境界で守る。
function Test-PrivateMarkerProtectedBootstrapVariableName {
    param(
        [AllowNull()]
        [string]$Name
    )

    $normalizedName =
        ConvertTo-NormalizedPrivateMarkerCommandName $Name
    return $normalizedName -in @('processsupport', 'psscriptroot')
}

# custom aliasで隠すとAST上の実行先を失う、dynamic execution/provider mutation群。
function Test-PrivateMarkerDangerousAliasTargetName {
    param(
        [AllowNull()]
        [string]$Name
    )

    $normalizedName =
        ConvertTo-NormalizedPrivateMarkerCommandName $Name
    return $normalizedName -in @(
        'set-variable',
        'new-variable',
        'set-alias',
        'new-alias',
        'invoke-expression',
        'invoke-command',
        'foreach-object',
        'where-object',
        'set-item',
        'set-content',
        'new-item',
        'copy-item',
        'move-item',
        'rename-item'
    )
}

function Get-PrivateMarkerStaticCommandArguments {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.CommandAst]$Command
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($element in @($Command.CommandElements | Select-Object -Skip 1)) {
        if ($element -is
            [Management.Automation.Language.CommandParameterAst]) {
            if ($null -ne $element.Argument) {
                if ($element.Argument -isnot
                    [Management.Automation.Language.StringConstantExpressionAst]) {
                    return [pscustomobject]@{
                        IsStatic = $false
                        Values = @()
                    }
                }
                $values.Add([string]$element.Argument.Value)
            }
            continue
        }
        if ($element -isnot
            [Management.Automation.Language.StringConstantExpressionAst]) {
            return [pscustomobject]@{
                IsStatic = $false
                Values = @()
            }
        }
        $values.Add([string]$element.Value)
    }
    return [pscustomobject]@{
        IsStatic = $true
        Values = @($values)
    }
}

# provider mutationのpath/valueに現れるliteralと変数参照だけを抽出する。
# ScriptBlock本体やsubexpressionの内側まで値として誤認しない。
function Get-PrivateMarkerDirectCommandArguments {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.CommandAst]$Command
    )

    $literalValues = New-Object System.Collections.Generic.List[string]
    $variableNames = New-Object System.Collections.Generic.List[string]
    $hasDynamicArgument = $false
    $hasValueParameter = $false
    $hasPipelineInput = $false
    if ($Command.Parent -is
        [Management.Automation.Language.PipelineAst]) {
        $pipelineElements = @($Command.Parent.PipelineElements)
        for ($pipelineIndex = 1;
            $pipelineIndex -lt $pipelineElements.Count;
            $pipelineIndex++) {
            if ([object]::ReferenceEquals(
                    $pipelineElements[$pipelineIndex],
                    $Command
                )) {
                $hasPipelineInput = $true
                break
            }
        }
    }
    foreach ($element in @($Command.CommandElements | Select-Object -Skip 1)) {
        $argument = $element
        if ($element -is
            [Management.Automation.Language.CommandParameterAst]) {
            # unique prefix（-Val等）もValue parameterとして扱う。-Verbose等は
            # "Value"のprefixではないため一致しない。
            if ('Value'.StartsWith(
                    [string]$element.ParameterName,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                $hasValueParameter = $true
            }
            if ($null -eq $element.Argument) {
                continue
            }
            $argument = $element.Argument
        }
        if ($argument -is
            [Management.Automation.Language.StringConstantExpressionAst]) {
            $literalValues.Add([string]$argument.Value)
            continue
        }
        if ($argument -is
            [Management.Automation.Language.VariableExpressionAst]) {
            if ($argument.Splatted) {
                $hasDynamicArgument = $true
                continue
            }
            $variableNames.Add([string]$argument.VariablePath.UserPath)
            continue
        }
        # provider pathを組み立てる式やScriptBlock valueは、静的なpath/valueとして
        # 証明できない。New-Itemのsink判定側でfail closedにする。
        $hasDynamicArgument = $true
    }
    return [pscustomobject]@{
        LiteralValues = @($literalValues)
        VariableNames = @($variableNames)
        HasDynamicArgument = $hasDynamicArgument
        HasValueParameter = $hasValueParameter
        HasPipelineInput = $hasPipelineInput
    }
}

# raw transport前に許すprocess helper bootstrapは、repo内の固定helperを組み立てる
# 1つの通常代入だけに限定する。文字列差替えやscope-qualified代入を同一視しない。
function Test-PrivateMarkerProcessSupportBootstrapAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.AssignmentStatementAst]$Assignment
    )

    if ($Assignment.Operator.ToString() -cne 'Equals' -or
        $Assignment.Left -isnot
            [Management.Automation.Language.VariableExpressionAst] -or
        $Assignment.Left.VariablePath.UserPath -cne 'processSupport' -or
        $Assignment.Right -isnot
            [Management.Automation.Language.PipelineAst]) {
        return $false
    }
    $pipelineElements = @($Assignment.Right.PipelineElements)
    if ($pipelineElements.Count -ne 1 -or
        $pipelineElements[0] -isnot
            [Management.Automation.Language.CommandAst]) {
        return $false
    }
    $command = $pipelineElements[0]
    # module-qualified cmdletを固定し、同名function/aliasによるpath差替えを許さない。
    if ($command.GetCommandName() -cne
        'Microsoft.PowerShell.Management\Join-Path') {
        return $false
    }
    $elements = @($command.CommandElements)
    return $elements.Count -eq 3 -and
        $elements[1] -is
            [Management.Automation.Language.VariableExpressionAst] -and
        $elements[1].VariablePath.UserPath -ceq 'PSScriptRoot' -and
        $elements[2] -is
            [Management.Automation.Language.StringConstantExpressionAst] -and
        $elements[2].Value -ceq
            '../scripts/private-marker-process.ps1'
}

# AssignmentStatementAstはCommandAstを生成しない。processSupportの再代入と
# Alias:/Function: providerへの代入を、wrapper内も含めて独立したsinkとして扱う。
function Test-PrivateMarkerAssignmentTargetsProtectedBoundary {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.AssignmentStatementAst]$Assignment
    )

    # `(Get-Variable processSupport).Value = ...` や保存したPSVariable objectの
    # `.Value`更新は、左辺がVariableExpressionAstにならない。raw call前の
    # member Value代入を保守的にsink化し、alias経由も同じ扱いにする。
    if ($Assignment.Left -is
            [Management.Automation.Language.MemberExpressionAst]) {
        $memberName = if ($Assignment.Left.Member -is
            [Management.Automation.Language.StringConstantExpressionAst]) {
            [string]$Assignment.Left.Member.Value
        } else {
            ''
        }
        return [string]::IsNullOrEmpty($memberName) -or
            $memberName -match '^(?i)value$'
    }
    if ($Assignment.Left -isnot
            [Management.Automation.Language.VariableExpressionAst]) {
        return $false
    }
    $userPath = [string]$Assignment.Left.VariablePath.UserPath
    # PSScriptRootもmodule-qualified Join-Pathの唯一のprovenanceなので、
    # helper pathを作る前後にsource側から上書きさせない。
    if (Test-PrivateMarkerProtectedBootstrapVariableName $userPath) {
        return $true
    }
    return $userPath -match
        '^(?i)(?:(?:global|script|local|private):)*(?:alias|function):'
}

# `$name = 'Function:target'` のような単一literal assignmentだけを解決する。
# command substitutionや複合式は実行せず、未知のまま残す。
function Get-PrivateMarkerStaticAssignmentString {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.AssignmentStatementAst]$Assignment
    )

    $expression = if ($Assignment.Right -is
        [Management.Automation.Language.CommandExpressionAst]) {
        $Assignment.Right.Expression
    } elseif ($Assignment.Right -is
        [Management.Automation.Language.PipelineAst]) {
        $pipelineElements = @($Assignment.Right.PipelineElements)
        if ($pipelineElements.Count -ne 1 -or
            $pipelineElements[0] -isnot
                [Management.Automation.Language.CommandExpressionAst]) {
            return $null
        }
        $pipelineElements[0].Expression
    } else {
        return $null
    }
    if ($expression -isnot
        [Management.Automation.Language.StringConstantExpressionAst]) {
        return $null
    }
    return [string]$expression.Value
}

# ForEach-Object / Where-Object は、変数や式から渡された ScriptBlock をその場で
# 実行できる。inline ScriptBlock と property/member 形式のliteralだけを静的に許し、
# 保存済み ScriptBlock・splat・subexpression は raw fixture 前で fail closed にする。
function Test-PrivateMarkerPipelineCommandHasDynamicArgument {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.CommandAst]$Command
    )

    foreach ($element in @($Command.CommandElements | Select-Object -Skip 1)) {
        $argument = $element
        if ($element -is
            [Management.Automation.Language.CommandParameterAst]) {
            if ($null -eq $element.Argument) {
                continue
            }
            $argument = $element.Argument
        }
        if ($argument -is
                [Management.Automation.Language.ScriptBlockExpressionAst] -or
            $argument -is
                [Management.Automation.Language.StringConstantExpressionAst] -or
            $argument -is
                [Management.Automation.Language.ConstantExpressionAst]) {
            continue
        }
        return $true
    }
    return $false
}

# function / class 内の node が別の nested definition に属していないことを判定する。
# 外側 definition が内側 helper の存在だけで危険扱いされる誤検知を避ける。
function Test-PrivateMarkerAstBelongsToDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.Ast]$Node,

        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.Ast]$Definition
    )

    $ancestor = $Node
    while ($null -ne $ancestor) {
        if ($ancestor -is
            [Management.Automation.Language.TypeDefinitionAst]) {
            return [object]::ReferenceEquals($ancestor, $Definition)
        }
        if ($ancestor -is
            [Management.Automation.Language.FunctionDefinitionAst]) {
            # class member は FunctionDefinitionAst を内包するため、対象がclassなら
            # member wrapperを越えて所有元TypeDefinitionAstまで辿る。
            if ($Definition -is
                    [Management.Automation.Language.TypeDefinitionAst] -and
                $ancestor.Parent -is
                    [Management.Automation.Language.FunctionMemberAst]) {
                $ancestor = $ancestor.Parent
                continue
            }
            return [object]::ReferenceEquals($ancestor, $Definition)
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

# definition 本体から production helper、既知の危険function、危険typeへ到達するかを
# 1段だけ評価する。caller が固定点まで反復し、多段wrapperも漏らさず閉じる。
function Test-PrivateMarkerDefinitionReachesDangerousBoundary {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.Ast]$Definition,

        [Parameter(Mandatory = $true)]
        [string]$BoundedCommandName,

        [Parameter(Mandatory = $true)]
        [object]$DangerousFunctionNames,

        [Parameter(Mandatory = $true)]
        [object]$DangerousTypeNames,

        [Parameter(Mandatory = $true)]
        [object]$DangerousProviderVariableNames
    )

    $ownedNodes = @(
        $Definition.FindAll(
            {
                param($node)
                return Test-PrivateMarkerAstBelongsToDefinition `
                    -Node $node `
                    -Definition $Definition
            },
            $true
        )
    )
    foreach ($node in $ownedNodes) {
        if ($node -is
                [Management.Automation.Language.AssignmentStatementAst] -and
            (Test-PrivateMarkerAssignmentTargetsProtectedBoundary `
                -Assignment $node)) {
            return $true
        }
        if ($node -is
            [Management.Automation.Language.InvokeMemberExpressionAst]) {
            $memberName = if ($node.Member -is
                [Management.Automation.Language.StringConstantExpressionAst]) {
                [string]$node.Member.Value
            } else {
                ''
            }
            # ScriptBlock.Create(...).Invoke() 等はhelper名をCommandAstに残さない。
            # PSVariableIntrinsics.Set(...)もAssignmentAstを生成しないため、
            # Invoke* / Set* memberまたはdynamic member callを安全証明不能とする。
            if ([string]::IsNullOrEmpty($memberName) -or
                $memberName -match '^(?i)(?:invoke|set)') {
                return $true
            }
            continue
        }
        if ($node -is [Management.Automation.Language.CommandAst]) {
            $commandName = ConvertTo-NormalizedPrivateMarkerCommandName `
                $node.GetCommandName()
            # invocation operator + dynamic expression は静的に到達先を証明できない。
            if ([string]::IsNullOrEmpty($commandName)) {
                return $true
            }
            if ($commandName -ceq $BoundedCommandName -or
                $DangerousFunctionNames.Contains($commandName)) {
                return $true
            }
            if ($commandName -in @('invoke-expression', 'invoke-command')) {
                return $true
            }
            # Copy/Move/Renameはfilesystem providerだけでなくAlias:/Function:
            # providerも変更できる。wrapper内ではtarget解決を推測せずsink扱いする。
            if ($commandName -in @(
                    'copy-item',
                    'move-item',
                    'rename-item'
                )) {
                return $true
            }
            if ($commandName -in @('foreach-object', 'where-object') -and
                (Test-PrivateMarkerPipelineCommandHasDynamicArgument `
                    -Command $node)) {
                return $true
            }
            if ($commandName -in @('set-variable', 'new-variable')) {
                $arguments =
                    Get-PrivateMarkerStaticCommandArguments -Command $node
                if (-not $arguments.IsStatic) {
                    return $true
                }
                foreach ($argument in $arguments.Values) {
                    if (Test-PrivateMarkerProtectedBootstrapVariableName `
                            $argument) {
                        return $true
                    }
                }
            }
            if ($commandName -eq 'new-item') {
                $directArguments =
                    Get-PrivateMarkerDirectCommandArguments -Command $node
                if ($directArguments.HasDynamicArgument -or
                    $directArguments.HasPipelineInput -or
                    ($directArguments.HasValueParameter -and
                        $directArguments.VariableNames.Count -gt 0)) {
                    return $true
                }
                foreach ($argument in $directArguments.LiteralValues) {
                    $referencedName =
                        ConvertTo-NormalizedPrivateMarkerCommandName $argument
                    if ((Test-PrivateMarkerProtectedBootstrapVariableName `
                            $referencedName) -or
                        (Test-PrivateMarkerDangerousAliasTargetName `
                            $referencedName) -or
                        $referencedName -ceq $BoundedCommandName -or
                        $DangerousFunctionNames.Contains($referencedName)) {
                        return $true
                    }
                }
                foreach ($variableName in $directArguments.VariableNames) {
                    $normalizedVariableName =
                        ConvertTo-NormalizedPrivateMarkerCommandName $variableName
                    if ((Test-PrivateMarkerProtectedBootstrapVariableName `
                            $normalizedVariableName) -or
                        $DangerousProviderVariableNames.Contains(
                            $normalizedVariableName
                        )) {
                        return $true
                    }
                }
            }
            if ($commandName -in @(
                    'get-command',
                    'get-item',
                    'set-item',
                    'set-content',
                    'set-alias',
                    'new-alias'
                )) {
                $arguments =
                    Get-PrivateMarkerStaticCommandArguments -Command $node
                if (-not $arguments.IsStatic) {
                    return $true
                }
                foreach ($argument in $arguments.Values) {
                    $referencedName =
                        ConvertTo-NormalizedPrivateMarkerCommandName $argument
                    if ($referencedName -ceq $BoundedCommandName -or
                        $DangerousFunctionNames.Contains($referencedName)) {
                        return $true
                    }
                    # custom aliasからmutation commandを呼ぶ経路を作らせない。
                    if ($commandName -in @(
                            'set-alias',
                            'new-alias',
                            'set-item',
                            'set-content'
                        ) -and
                        (Test-PrivateMarkerDangerousAliasTargetName `
                            $referencedName)) {
                        return $true
                    }
                    # Variable: provider経由のhelper path再代入もAssignmentAstを
                    # 生成しないため、Set-Item/Set-Contentの独立sinkとして扱う。
                    if ($commandName -in @(
                            'set-item',
                            'set-content'
                        ) -and
                        (Test-PrivateMarkerProtectedBootstrapVariableName `
                            $referencedName)) {
                        return $true
                    }
                }
            }
            continue
        }
        if ($node -is
                [Management.Automation.Language.TypeExpressionAst] -or
            $node -is
                [Management.Automation.Language.TypeConstraintAst]) {
            $typeName = [string]$node.TypeName.FullName
            if ($DangerousTypeNames.Contains($typeName)) {
                return $true
            }
            continue
        }
        if ($node -is [Management.Automation.Language.VariableExpressionAst]) {
            $userPath = [string]$node.VariablePath.UserPath
            if ($userPath -match '^(?i)function:') {
                $referencedName =
                    ConvertTo-NormalizedPrivateMarkerCommandName $userPath
                if ($referencedName -ceq $BoundedCommandName -or
                    $DangerousFunctionNames.Contains($referencedName)) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Test-FirstBoundedInvocationIsRawTransport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [string]$BoundedCommandName =
            'Invoke-PrivateMarkerBoundedProcess'
    )

    # 行番号や regex ではなく AST の所有関係を検証する。raw transport
    # assignment は nested helper を含まない単一の outer command でなければならない。
    $tokens = $null
    $parseErrors = $null
    $sourceAst = [Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        return $false
    }
    $normalizedBoundedName =
        ConvertTo-NormalizedPrivateMarkerCommandName $BoundedCommandName
    if ([string]::IsNullOrEmpty($normalizedBoundedName)) {
        return $false
    }

    $rawAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'rawTransportResult'
            },
            $true
        )
    )
    if ($rawAssignments.Count -ne 1 -or
        $rawAssignments[0].Right -isnot
            [Management.Automation.Language.PipelineAst]) {
        return $false
    }

    $rawPipelineElements = @($rawAssignments[0].Right.PipelineElements)
    if ($rawPipelineElements.Count -ne 1 -or
        $rawPipelineElements[0] -isnot
            [Management.Automation.Language.CommandAst]) {
        return $false
    }
    $rawOuterCommand = $rawPipelineElements[0]
    $rawOuterName = ConvertTo-NormalizedPrivateMarkerCommandName `
        $rawOuterCommand.GetCommandName()
    if ($rawOuterName -cne $normalizedBoundedName) {
        return $false
    }
    $rawNestedCalls = @(
        $rawAssignments[0].Right.FindAll(
            {
                param($node)
                return $node -is
                        [Management.Automation.Language.CommandAst] -and
                    (ConvertTo-NormalizedPrivateMarkerCommandName `
                        $node.GetCommandName()) -ceq
                        $normalizedBoundedName
            },
            $true
        )
    )
    if ($rawNestedCalls.Count -ne 1 -or
        (Test-PrivateMarkerCommandIsDeferredDefinition `
            -Node $rawOuterCommand)) {
        return $false
    }

    # production helperのdot-sourceがあるsourceでは、そのpathを作る通常代入も
    # 1件・固定AST形・dot-source前に限定する。synthetic単体caseはbootstrapを
    # 省略できるが、processSupportへ触れた時点で同じ厳格な契約を適用する。
    $eagerPreRawAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset -and
                    -not (Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Node $node)
            },
            $true
        )
    )
    $processSupportAssignments = @(
        $eagerPreRawAssignments | Where-Object {
            $_.Left -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                (ConvertTo-NormalizedPrivateMarkerCommandName `
                    $_.Left.VariablePath.UserPath) -ceq 'processsupport'
        }
    )
    $processSupportDotSources = @(
        $sourceAst.FindAll(
            {
                param($node)
                if ($node -isnot
                        [Management.Automation.Language.CommandAst] -or
                    $node.Extent.StartOffset -ge
                        $rawOuterCommand.Extent.StartOffset -or
                    (Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Node $node)) {
                    return $false
                }
                $elements = @($node.CommandElements)
                return $node.InvocationOperator.ToString() -eq 'Dot' -and
                    $elements.Count -eq 1 -and
                    $elements[0] -is
                        [Management.Automation.Language.VariableExpressionAst] -and
                    $elements[0].VariablePath.UserPath -ceq 'processSupport'
            },
            $true
        )
    )
    $allowedProcessSupportAssignment = $null
    if ($processSupportDotSources.Count -gt 0 -or
        $processSupportAssignments.Count -gt 0) {
        if ($processSupportDotSources.Count -ne 1 -or
            $processSupportAssignments.Count -ne 1 -or
            -not (Test-PrivateMarkerProcessSupportBootstrapAssignment `
                -Assignment $processSupportAssignments[0]) -or
            $processSupportAssignments[0].Extent.StartOffset -ge
                $processSupportDotSources[0].Extent.StartOffset) {
            return $false
        }
        $allowedProcessSupportAssignment = $processSupportAssignments[0]
    }
    foreach ($assignment in $eagerPreRawAssignments) {
        if ($null -ne $allowedProcessSupportAssignment -and
            [object]::ReferenceEquals(
                $assignment,
                $allowedProcessSupportAssignment
            )) {
            continue
        }
        if (Test-PrivateMarkerAssignmentTargetsProtectedBoundary `
                -Assignment $assignment) {
            return $false
        }
    }

    # helperを内包するfunctionは定義だけなら安全だが、そのfunction名・typeを
    # 多段wrapper経由でraw fixtureより前に実行すれば同じ先行呼出しになる。
    $dangerousFunctionNames =
        [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
    $functionDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        )
    )
    foreach ($definition in $functionDefinitions) {
        if ($definition.Extent.StartOffset -ge
            $rawOuterCommand.Extent.StartOffset) {
            continue
        }
        $definitionName = ConvertTo-NormalizedPrivateMarkerCommandName `
            $definition.Name
        # dot-source 済みの production helper と同名の function を先に定義すると、
        # raw assignment が偽 helper を呼び、実際の transport gateを未検証にできる。
        if ($definitionName -ceq $normalizedBoundedName) {
            return $false
        }
    }

    # class constructor / method も定義時はdeferredだが、type参照から即時実行できる。
    # function/type参照を固定点まで反復し、helperへ至る推移的wrapperを全て収集する。
    $dangerousTypeNames =
        [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
    $dangerousProviderVariableNames =
        [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
    $providerAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset
            },
            $true
        )
    )
    $typeDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [Management.Automation.Language.TypeDefinitionAst]
            },
            $true
        )
    )
    $graphChanged = $true
    while ($graphChanged) {
        $graphChanged = $false
        # provider pathをliteralで保持した変数も固定点へ含める。wrapper名が
        # 後段でdangerousになった場合は次周でFunction:wrapperを回収する。
        foreach ($assignment in $providerAssignments) {
            $assignedValue =
                Get-PrivateMarkerStaticAssignmentString -Assignment $assignment
            if ($null -eq $assignedValue) {
                continue
            }
            $referencedName =
                ConvertTo-NormalizedPrivateMarkerCommandName $assignedValue
            if (-not (Test-PrivateMarkerProtectedBootstrapVariableName `
                    $referencedName) -and
                -not (Test-PrivateMarkerDangerousAliasTargetName `
                    $referencedName) -and
                $referencedName -cne $normalizedBoundedName -and
                -not $dangerousFunctionNames.Contains($referencedName)) {
                continue
            }
            $variableName = ConvertTo-NormalizedPrivateMarkerCommandName `
                $assignment.Left.VariablePath.UserPath
            if ($dangerousProviderVariableNames.Add($variableName)) {
                $graphChanged = $true
            }
        }
        foreach ($definition in $functionDefinitions) {
            if ($definition.Extent.StartOffset -ge
                $rawOuterCommand.Extent.StartOffset) {
                continue
            }
            $definitionName =
                ConvertTo-NormalizedPrivateMarkerCommandName $definition.Name
            if ($dangerousFunctionNames.Contains($definitionName)) {
                continue
            }
            if (Test-PrivateMarkerDefinitionReachesDangerousBoundary `
                    -Definition $definition `
                    -BoundedCommandName $normalizedBoundedName `
                    -DangerousFunctionNames $dangerousFunctionNames `
                    -DangerousTypeNames $dangerousTypeNames `
                    -DangerousProviderVariableNames `
                        $dangerousProviderVariableNames) {
                [void]$dangerousFunctionNames.Add($definitionName)
                $graphChanged = $true
            }
        }
        foreach ($definition in $typeDefinitions) {
            if ($definition.Extent.StartOffset -ge
                $rawOuterCommand.Extent.StartOffset) {
                continue
            }
            $definitionName = [string]$definition.Name
            if ($dangerousTypeNames.Contains($definitionName)) {
                continue
            }
            if (Test-PrivateMarkerDefinitionReachesDangerousBoundary `
                    -Definition $definition `
                    -BoundedCommandName $normalizedBoundedName `
                    -DangerousFunctionNames $dangerousFunctionNames `
                    -DangerousTypeNames $dangerousTypeNames `
                    -DangerousProviderVariableNames `
                        $dangerousProviderVariableNames) {
                [void]$dangerousTypeNames.Add($definitionName)
                $graphChanged = $true
            }
        }
    }
    $eagerTypeReferences = @(
        $sourceAst.FindAll(
            {
                param($node)
                return ($node -is
                            [Management.Automation.Language.TypeExpressionAst] -or
                        $node -is
                            [Management.Automation.Language.TypeConstraintAst]) -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset -and
                    -not (Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Node $node)
            },
            $true
        )
    )
    foreach ($reference in $eagerTypeReferences) {
        $referencedTypeName =
            ([string]$reference.TypeName.FullName).ToLowerInvariant()
        if ($dangerousTypeNames.Contains($referencedTypeName)) {
            return $false
        }
    }

    # `${function:name}` は CommandAst を作らずに function ScriptBlock を取得できる。
    # Invoke member や Invoke-Command argument に渡された参照も eager 到達として拒否する。
    $eagerFunctionReferences = @(
        $sourceAst.FindAll(
            {
                param($node)
                if ($node -isnot
                    [Management.Automation.Language.VariableExpressionAst]) {
                    return $false
                }
                $userPath = [string]$node.VariablePath.UserPath
                return $userPath -match '^(?i)function:' -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset -and
                    -not (Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Node $node)
            },
            $true
        )
    )
    foreach ($reference in $eagerFunctionReferences) {
        $referencedName = ConvertTo-NormalizedPrivateMarkerCommandName `
            $reference.VariablePath.UserPath
        if ($referencedName -ceq $normalizedBoundedName -or
            $dangerousFunctionNames.Contains($referencedName)) {
            return $false
        }
    }

    # stringから生成したScriptBlock等はCommandAstにhelper名を残さない。
    # PSVariableIntrinsics.Set/set_Valueも含め、raw fixture前のInvoke* / Set* memberと
    # dynamic member callを独立に拒否する。
    $eagerInvokeMembers = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $rawOuterCommand.Extent.StartOffset -and
                    -not (Test-PrivateMarkerCommandIsDeferredDefinition `
                        -Node $node)
            },
            $true
        )
    )
    foreach ($memberCall in $eagerInvokeMembers) {
        $memberName = if ($memberCall.Member -is
            [Management.Automation.Language.StringConstantExpressionAst]) {
            [string]$memberCall.Member.Value
        } else {
            ''
        }
        if ([string]::IsNullOrEmpty($memberName) -or
            $memberName -match '^(?i)(?:invoke|set)') {
            return $false
        }
    }

    $eagerCommands = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [Management.Automation.Language.CommandAst]
            },
            $true
        ) |
            Where-Object {
                $_.Extent.StartOffset -lt
                    $rawOuterCommand.Extent.StartOffset -and
                -not (Test-PrivateMarkerCommandIsDeferredDefinition `
                    -Node $_)
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    foreach ($command in $eagerCommands) {
        $commandName = ConvertTo-NormalizedPrivateMarkerCommandName `
            $command.GetCommandName()
        # helper定義を読み込む唯一のbootstrap dot-sourceだけは、operator・
        # 要素数・変数名を完全一致で許可する。それ以外のinvocation operator +
        # dynamic expressionは静的に安全を証明できないため拒否する。
        if ([string]::IsNullOrEmpty($commandName)) {
            $commandElements = @($command.CommandElements)
            if ($command.InvocationOperator.ToString() -eq 'Dot' -and
                $commandElements.Count -eq 1 -and
                $commandElements[0] -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                $commandElements[0].VariablePath.UserPath -ceq
                    'processSupport') {
                continue
            }
            return $false
        }
        if ($commandName -ceq $normalizedBoundedName -or
            $dangerousFunctionNames.Contains($commandName)) {
            return $false
        }

        # raw fixture前のCopy/Move/RenameはAlias:/Function: providerへ到達できる。
        # path bindingの全形を再実装せず、ここでは操作自体をfail closedにする。
        if ($commandName -in @(
                'copy-item',
                'move-item',
                'rename-item'
            )) {
            return $false
        }

        if ($commandName -in @(
                'set-alias',
                'new-alias',
                'set-item',
                'set-content'
            )) {
            $arguments =
                Get-PrivateMarkerStaticCommandArguments -Command $command
            if (-not $arguments.IsStatic -or
                $arguments.Values.Count -lt 2) {
                return $false
            }
            # -Name/-Value の順序や positional/named 混在を仮定せず、全literalを
            # 保守的に確認する。target名のretargetも危険functionへのaliasも即時拒否する。
            foreach ($argument in $arguments.Values) {
                $aliasValue = ConvertTo-NormalizedPrivateMarkerCommandName `
                    $argument
                if ([string]::IsNullOrEmpty($aliasValue) -or
                    $aliasValue -ceq $normalizedBoundedName -or
                    $dangerousFunctionNames.Contains($aliasValue)) {
                    return $false
                }
                # custom alias経由でmutation command名を隠す経路も作成時に閉じる。
                if ($commandName -in @(
                        'set-alias',
                        'new-alias',
                        'set-item',
                        'set-content'
                    ) -and
                    (Test-PrivateMarkerDangerousAliasTargetName $aliasValue)) {
                    return $false
                }
                # Variable: provider経由のhelper path再代入もAssignmentAstを
                # 生成しないため、Set-Item/Set-Contentの独立sinkとして扱う。
                if ($commandName -in @(
                        'set-item',
                        'set-content'
                    ) -and
                    (Test-PrivateMarkerProtectedBootstrapVariableName `
                        $aliasValue)) {
                    return $false
                }
            }
            continue
        }

        # New-ItemはValueを伴わない通常の一時directory作成を許す。一方、
        # Value + variable argumentはprovider path/valueの役割を安全証明できないため拒否し、
        # literalまたは静的変数が危険境界を指す場合もfail closedにする。
        if ($commandName -eq 'new-item') {
            $directArguments =
                Get-PrivateMarkerDirectCommandArguments -Command $command
            if ($directArguments.HasDynamicArgument -or
                $directArguments.HasPipelineInput -or
                ($directArguments.HasValueParameter -and
                    $directArguments.VariableNames.Count -gt 0)) {
                return $false
            }
            foreach ($argument in $directArguments.LiteralValues) {
                $referencedName =
                    ConvertTo-NormalizedPrivateMarkerCommandName $argument
                if ((Test-PrivateMarkerProtectedBootstrapVariableName `
                        $referencedName) -or
                    (Test-PrivateMarkerDangerousAliasTargetName `
                        $referencedName) -or
                    $referencedName -ceq $normalizedBoundedName -or
                    $dangerousFunctionNames.Contains($referencedName)) {
                    return $false
                }
            }
            foreach ($variableName in $directArguments.VariableNames) {
                $normalizedVariableName =
                    ConvertTo-NormalizedPrivateMarkerCommandName $variableName
                if ((Test-PrivateMarkerProtectedBootstrapVariableName `
                        $normalizedVariableName) -or
                    $dangerousProviderVariableNames.Contains(
                        $normalizedVariableName
                    )) {
                    return $false
                }
            }
            continue
        }

        # bootstrap dot-sourceの唯一の許可変数は、raw gate前に
        # Set/New-Variable（Scope 1 wrapperやaliasを含む）で差し替えられてはならない。
        if ($commandName -in @('set-variable', 'new-variable')) {
            $arguments =
                Get-PrivateMarkerStaticCommandArguments -Command $command
            if (-not $arguments.IsStatic) {
                return $false
            }
            foreach ($argument in $arguments.Values) {
                if (Test-PrivateMarkerProtectedBootstrapVariableName `
                        $argument) {
                    return $false
                }
            }
            continue
        }

        if ($commandName -in @('get-command', 'get-item')) {
            $arguments =
                Get-PrivateMarkerStaticCommandArguments -Command $command
            if (-not $arguments.IsStatic -or
                $arguments.Values.Count -eq 0) {
                return $false
            }
            foreach ($argument in $arguments.Values) {
                $referencedName =
                    ConvertTo-NormalizedPrivateMarkerCommandName $argument
                if ($referencedName -ceq $normalizedBoundedName -or
                    $dangerousFunctionNames.Contains($referencedName)) {
                    return $false
                }
            }
            continue
        }

        # Invoke-Command は function provider の ScriptBlock などをその場で実行する。
        # 引数解決の全形を推測せず、raw fixture より前では fail closed にする。
        if ($commandName -in @('invoke-expression', 'invoke-command')) {
            return $false
        }
        if ($commandName -in @('foreach-object', 'where-object') -and
            (Test-PrivateMarkerPipelineCommandHasDynamicArgument `
                -Command $command)) {
            return $false
        }
    }
    return $true
}

function Assert-FirstBoundedInvocationValidatorRegressions {
    $cases = @(
        [pscustomobject]@{
            Name = 'direct-before'
            Expected = $false
            Source = @'
Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'scope-qualified-before'
            Expected = $false
            Source = @'
global:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-before'
            Expected = $true
            Source = @'
function Invoke-Deferred {
    Invoke-PrivateMarkerBoundedProcess
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-invoked-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-to-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Alias EarlyAlias Invoke-Early
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-to-helper-before'
            Expected = $false
            Source = @'
Set-Alias EarlyAlias Invoke-PrivateMarkerBoundedProcess
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-item-alias-to-helper-before'
            Expected = $false
            Source = @'
Set-Item Alias:EarlyAlias Invoke-PrivateMarkerBoundedProcess
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-item-function-to-helper-before'
            Expected = $false
            Source = @'
Set-Item Function:Invoke-Early { Invoke-PrivateMarkerBoundedProcess }
Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'set-content-alias-to-wrapper-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Content Alias:EarlyAlias Invoke-Early
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'new-item-dynamic-function-provider-before'
            Expected = $false
            Source = @'
$providerPath = 'Function:Invoke-PrivateMarkerBoundedProcess'
New-Item -Path $providerPath -ItemType Directory -Value { 'shadow' }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'new-item-expression-alias-provider-before'
            Expected = $false
            Source = @'
New-Item -Path ('Alias:' + 'Invoke-PrivateMarkerBoundedProcess') -Value Get-Date
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'alias-provider-assignment-shadow-before'
            Expected = $false
            Source = @'
${alias:Invoke-PrivateMarkerBoundedProcess} = 'Get-Date'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-provider-assignment-shadow-before'
            Expected = $false
            Source = @'
${function:Invoke-PrivateMarkerBoundedProcess} = { Get-Date }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'copy-function-provider-shadow-before'
            Expected = $false
            Source = @'
function Invoke-EarlyCopySource { Get-Date }
Copy-Item Function:Invoke-EarlyCopySource Function:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'move-function-provider-shadow-before'
            Expected = $false
            Source = @'
function Invoke-EarlyMoveSource { Get-Date }
Move-Item Function:Invoke-EarlyMoveSource Function:Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'rename-alias-provider-shadow-before'
            Expected = $false
            Source = @'
Set-Alias Invoke-EarlyRenameSource Get-Date
Rename-Item Alias:Invoke-EarlyRenameSource Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-fixed-assignment'
            Expected = $true
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-direct-assignment-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$processSupport = './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-plus-equals-before'
            Expected = $false
            Source = @'
$processSupport += Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-join-path-function-shadow-before'
            Expected = $false
            Source = @'
function Join-Path { './synthetic-shadow.ps1' }
$processSupport = Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-mutable-root-before'
            Expected = $false
            Source = @'
$root = './synthetic-root'
$processSupport = Microsoft.PowerShell.Management\Join-Path $root 'scripts/private-marker-process.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-set-variable-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Variable processSupport ./synthetic.ps1
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-set-item-variable-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Item Variable:processSupport './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-variable-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
New-Item -Path Variable:processSupport -Value './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-indirect-process-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$providerPath = 'Variable:processSupport'
New-Item -Path $providerPath -Value './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-indirect-root-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$providerPath = 'Variable:PSScriptRoot'
New-Item -Path $providerPath -Value './synthetic-shadow' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-composed-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$providerPrefix = 'Variable:'
$providerPath = $providerPrefix + 'processSupport'
New-Item -Path $providerPath -Value './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-splat-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$providerArguments = @{
    Path = 'Variable:processSupport'
    Value = './synthetic-shadow.ps1'
    Force = $true
}
New-Item @providerArguments
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-item-pipeline-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$mutation = { Set-Variable processSupport './synthetic-shadow.ps1' -Scope 1 }
$mutation | New-Item -Path Function:Invoke-EarlyMutation -Force
Invoke-EarlyMutation
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-variable-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
New-Variable -Name processSupport -Value './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-variable-alias-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
nv processSupport './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-set-variable-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyMutation Set-Variable
Invoke-EarlyMutation processSupport './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-new-variable-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyMutation New-Variable
Invoke-EarlyMutation processSupport './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-set-item-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyMutation Set-Item
Invoke-EarlyMutation Variable:processSupport './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-new-item-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyMutation New-Item
Invoke-EarlyMutation Variable:processSupport -Value './synthetic-shadow.ps1' -Force
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-indirect-new-item-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$mutationTarget = 'Set-Variable'
New-Item -Path Alias:Invoke-EarlyMutation -Value $mutationTarget -Force
Invoke-EarlyMutation processSupport './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-copy-item-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyMutation Copy-Item
Invoke-EarlyMutation Variable:syntheticSource Variable:processSupport
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-set-alias-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-AliasMutation Set-Alias
Invoke-AliasMutation Invoke-PrivateMarkerBoundedProcess Get-Date
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-new-alias-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-AliasMutation New-Alias
Invoke-AliasMutation Invoke-PrivateMarkerBoundedProcess Get-Date
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-invoke-expression-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyDynamic Invoke-Expression
Invoke-EarlyDynamic 'Invoke-PrivateMarkerBoundedProcess'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-invoke-command-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Alias Invoke-EarlyDynamic Invoke-Command
Invoke-EarlyDynamic -ScriptBlock { Invoke-PrivateMarkerBoundedProcess }
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-foreach-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$stored = { Invoke-PrivateMarkerBoundedProcess }
Set-Alias Invoke-EarlyDynamic ForEach-Object
1 | Invoke-EarlyDynamic $stored
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-custom-alias-where-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$stored = { Invoke-PrivateMarkerBoundedProcess; $true }
Set-Alias Invoke-EarlyDynamic Where-Object
1 | Invoke-EarlyDynamic $stored
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-scope-assignment-wrapper-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
function Set-EarlyBootstrap {
    $script:processSupport = './synthetic-shadow.ps1'
}
Set-EarlyBootstrap
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-scope-wrapper-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
function Set-EarlyBootstrap {
    Set-Variable processSupport ./synthetic.ps1 -Scope 1
}
Set-EarlyBootstrap
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-provider-scope-wrapper-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
function Set-EarlyBootstrap {
    Set-Item Variable:script:processSupport './synthetic-shadow.ps1'
}
Set-EarlyBootstrap
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-set-content-variable-provider-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
Set-Content Variable:processSupport './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-new-variable-wrapper-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
function Set-EarlyBootstrap {
    nv processSupport './synthetic-shadow.ps1' -Scope Script -Force
}
Set-EarlyBootstrap
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-psscriptroot-assignment-before'
            Expected = $false
            Source = @'
$PSScriptRoot = './synthetic-shadow'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-psvariable-set-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$ExecutionContext.SessionState.PSVariable.Set('processSupport', './synthetic-shadow.ps1')
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-psvariable-set-wrapper-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
function Set-EarlyBootstrap {
    $ExecutionContext.SessionState.PSVariable.Set('script:processSupport', './synthetic-shadow.ps1')
}
Set-EarlyBootstrap
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-psvariable-value-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
(Get-Variable processSupport).Value = './synthetic-shadow.ps1'
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'bootstrap-psvariable-set-value-before'
            Expected = $false
            Source = @'
$processSupport = Microsoft.PowerShell.Management\Join-Path $PSScriptRoot '../scripts/private-marker-process.ps1'
$helperVariable = Get-Variable processSupport
$helperVariable.set_Value('./synthetic-shadow.ps1')
. $processSupport
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'foreach-saved-scriptblock-before'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | ForEach-Object $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'where-saved-scriptblock-before'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess; $true }
1 | Where-Object $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'foreach-alias-saved-scriptblock-before'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess }
1 | % $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'where-alias-saved-scriptblock-before'
            Expected = $false
            Source = @'
$stored = { Invoke-PrivateMarkerBoundedProcess; $true }
1 | ? $stored
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'scoped-function-before'
            Expected = $false
            Source = @'
function global:Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
global:Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-function-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Get-Command Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'get-command-function-scope-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Get-Command function:Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'shadow-target-function'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
function Invoke-PrivateMarkerBoundedProcess {
    Invoke-Early
}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'retarget-target-alias'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Set-Alias Invoke-PrivateMarkerBoundedProcess Invoke-Early
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'builtin-gcm-wrapper'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(gcm Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'module-qualified-get-command'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
(Microsoft.PowerShell.Core\Get-Command Invoke-Early).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'function-scriptblock-member'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
${function:Invoke-Early}.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-command-function-ref'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
Invoke-Command -ScriptBlock ${function:Invoke-Early}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-constructor-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
[EarlyClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-inheritance-constructor-before'
            Expected = $false
            Source = @'
class EarlyBaseClass {
    EarlyBaseClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
class EarlyDerivedClass : EarlyBaseClass {}
[EarlyDerivedClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-inheritance-safe-before'
            Expected = $true
            Source = @'
class SafeBaseClass {
    SafeBaseClass() {
        Get-Date
    }
}
class SafeDerivedClass : SafeBaseClass {}
[SafeDerivedClass]::new()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-method-before'
            Expected = $false
            Source = @'
class EarlyClass {
    [void] Invoke() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
[EarlyClass]::new().Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-constructor-as-cast-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
$instance = @{} -as [EarlyClass]
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-static-instance-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
    static [EarlyClass] $Instance = [EarlyClass]::new()
    [void] Run() {
        Get-Date
    }
}
$instance = [EarlyClass]::Instance
$instance.Run()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'class-constructor-wrapper-argument-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
function Invoke-Wrapper {
    param([EarlyClass]$Instance)
    $Instance
}
Invoke-Wrapper @{}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-before'
            Expected = $false
            Source = @'
Invoke-Expression 'Invoke-PrivateMarkerBoundedProcess'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-scriptblock-member-before'
            Expected = $false
            Source = @'
[scriptblock]::Create('Invoke-PrivateMarkerBoundedProcess').Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'foreach-function-ref-before'
            Expected = $false
            Source = @'
function Invoke-Early {
    Invoke-PrivateMarkerBoundedProcess
}
1 | ForEach-Object ${function:Invoke-Early}
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-alias-before'
            Expected = $false
            Source = @'
$earlyName = 'Invoke-Early'
Set-Alias EarlyAlias $earlyName
EarlyAlias
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-invocation-before'
            Expected = $false
            Source = @'
$earlyName = 'Invoke-PrivateMarkerBoundedProcess'
& $earlyName
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'dynamic-get-command-before'
            Expected = $false
            Source = @'
$earlyName = 'Invoke-PrivateMarkerBoundedProcess'
(Get-Command $earlyName).ScriptBlock.Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-function-wrapper-before'
            Expected = $false
            Source = @'
function Invoke-Inner {
    Invoke-PrivateMarkerBoundedProcess
}
function Invoke-Outer {
    Invoke-Inner
}
Invoke-Outer
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-function-to-type-before'
            Expected = $false
            Source = @'
class EarlyClass {
    EarlyClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
function Invoke-Outer {
    [EarlyClass]::new()
}
Invoke-Outer
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-type-to-function-before'
            Expected = $false
            Source = @'
function Invoke-Inner {
    Invoke-PrivateMarkerBoundedProcess
}
class EarlyClass {
    static [void] Invoke() {
        Invoke-Inner
    }
}
[EarlyClass]::Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'transitive-type-wrapper-before'
            Expected = $false
            Source = @'
class InnerClass {
    InnerClass() {
        Invoke-PrivateMarkerBoundedProcess
    }
}
class OuterClass {
    static [void] Invoke() {
        [InnerClass]::new()
    }
}
[OuterClass]::Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'nested-function-definition-only'
            Expected = $true
            Source = @'
function Initialize-Deferred {
    function Invoke-Inner {
        Invoke-PrivateMarkerBoundedProcess
    }
}
Initialize-Deferred
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'reordered-named-alias-retarget'
            Expected = $false
            Source = @'
Set-Alias -Value Get-Date -Name Invoke-PrivateMarkerBoundedProcess
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'uninvoked-scriptblock'
            Expected = $true
            Source = @'
$unused = { Invoke-PrivateMarkerBoundedProcess }
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'nested-inner'
            Expected = $false
            Source = @'
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess -Value $(Invoke-PrivateMarkerBoundedProcess)
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-member'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerBoundedProcess }).Invoke()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-return-as-is'
            Expected = $false
            Source = @'
({ Invoke-PrivateMarkerBoundedProcess }).InvokeReturnAsIs()
$rawTransportResult = Invoke-PrivateMarkerBoundedProcess
'@
        }
    )
    foreach ($case in $cases) {
        $actual = Test-FirstBoundedInvocationIsRawTransport `
            -Source $case.Source
        if ($actual -ne $case.Expected) {
            Add-Failure "First-invocation validator regression failed: $($case.Name)."
        }
    }
}

function Assert-FirstBoundedInvocationIsRawTransport {
    $source = [IO.File]::ReadAllText($selfTestScriptPath)
    if (-not (Test-FirstBoundedInvocationIsRawTransport -Source $source)) {
        Add-Failure 'Expected raw binary transport to be the first executable bounded helper invocation.'
    }
}

# byte列はtextへ変換せず、長さと各位置の値を厳密に比較する。
function Test-ByteArraysEqual {
    param(
        [AllowNull()]
        [byte[]]$Expected,

        [AllowNull()]
        [byte[]]$Actual
    )

    if ($null -eq $Expected -or $null -eq $Actual -or
        $Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($byteIndex = 0; $byteIndex -lt $Expected.Length; $byteIndex++) {
        if ($Expected[$byteIndex] -ne $Actual[$byteIndex]) {
            return $false
        }
    }
    return $true
}

# fixtureごとに独立したGit環境を作り、scanner childの時間・出力・子孫停止を観測する。
function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [string]$ScannerPath = $scanner,
        [ValidateSet('Path', 'Root')]
        [string]$RootParameter = 'Path',
        [hashtable]$InheritedEnvironment = @{},
        [int]$MaxStdoutBytes = 16777216,
        [int]$MaxStderrBytes = 1048576,
        [string[]]$AdditionalArguments = @()
    )

    $arguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @(
        '-File',
        $ScannerPath,
        "-$RootParameter",
        $ScanPath
    ) + @($AdditionalArguments)

    $scannerIsolationRoot = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) ("bounded-playwright-ui-verification-scanner-git-" +
        [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scannerIsolationRoot | Out-Null
    try {
        $result = Invoke-PrivateMarkerBoundedProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments $arguments `
            -IsolationRoot $scannerIsolationRoot `
            -InheritedEnvironment $InheritedEnvironment `
            -TimeoutMilliseconds 30000 `
            -MaxStdoutBytes $MaxStdoutBytes `
            -MaxStderrBytes $MaxStderrBytes `
            -PassThroughGitEnvironment
        if (-not (Test-BoundedResultHealthy -Result $result)) {
            Add-Failure 'Scanner child exceeded its bounded runtime for a synthetic fixture.'
        }
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $scannerIsolationRoot) {
            Remove-Item -LiteralPath $scannerIsolationRoot -Recurse -Force
        }
    }
}

# bootstrap/process/isolation failureは、原因文字列ではなく固定code 1行だけを返す。
function Assert-FixedScannerIntegrityFailure {
    param(
        [object]$Result,
        [string]$Reason,
        [string[]]$ForbiddenValues = @()
    )

    $expected =
        "Private marker scan failed closed (integrity: $Reason)."
    $actual = if ($null -eq $Result) {
        ''
    } else {
        [string]$Result.Output.Trim()
    }
    if (-not (Test-BoundedResultHealthy -Result $Result) -or
        $Result.ExitCode -ne 2 -or
        $actual -cne $expected) {
        Add-Failure "Expected fixed redacted scanner integrity failure '$Reason'. Output: $actual"
    }
    foreach ($forbidden in $ForbiddenValues) {
        if (-not [string]::IsNullOrEmpty($forbidden) -and
            $actual.Contains($forbidden)) {
            Add-Failure "Scanner integrity failure '$Reason' exposed a private diagnostic value."
        }
    }
}

# synthetic Git操作もproduction同等のbounded process境界を必ず通す。
function Invoke-IsolatedGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$IsolationRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [hashtable]$InheritedEnvironment = @{},

        [AllowNull()]
        [byte[]]$StandardInputBytes = $null
    )

    return Invoke-PrivateMarkerBoundedProcess `
        -FileName $GitPath `
        -Arguments (@('-C', $WorkingDirectory) + $Arguments) `
        -IsolationRoot $IsolationRoot `
        -WorkingDirectory $WorkingDirectory `
        -InheritedEnvironment $InheritedEnvironment `
        -StandardInputBytes $StandardInputBytes `
        -TimeoutMilliseconds 20000
}

# final equality再検証の狭い競合窓を再現するため、index swapをmarkerで同期する。
function Start-SynchronizedIndexMutator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReadyPath,

        [Parameter(Mandatory = $true)]
        [string]$ReleasePath,

        [Parameter(Mandatory = $true)]
        [string]$SwapPath,

        [Parameter(Mandatory = $true)]
        [string]$IndexPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    $escapedReady = $ReadyPath.Replace("'", "''")
    $escapedRelease = $ReleasePath.Replace("'", "''")
    $escapedSwap = $SwapPath.Replace("'", "''")
    $escapedIndex = $IndexPath.Replace("'", "''")
    $escapedBackup = $BackupPath.Replace("'", "''")
    $mutatorScript = @"
`$readyObserved = `$false
for (`$attempt = 0; `$attempt -lt 1500; `$attempt++) {
    if ([IO.File]::Exists('$escapedReady')) {
        `$readyObserved = `$true
        break
    }
    Start-Sleep -Milliseconds 10
}
if (-not `$readyObserved) {
    exit 3
}
[IO.File]::Replace(
    '$escapedSwap',
    '$escapedIndex',
    '$escapedBackup'
)
[IO.File]::WriteAllText(
    '$escapedRelease',
    'release',
    [Text.UTF8Encoding]::new(`$false)
)
"@
    $mutatorEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($mutatorScript)
    )
    $mutatorArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $mutatorArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $mutatorArguments += @('-EncodedCommand', $mutatorEncoded)
    $mutatorInfo = New-Object Diagnostics.ProcessStartInfo
    $mutatorInfo.FileName = $currentPowerShellExecutable
    $mutatorInfo.UseShellExecute = $false
    $mutatorInfo.CreateNoWindow = $true
    $mutatorArgumentList =
        $mutatorInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $mutatorArgumentList) {
        foreach ($mutatorArgument in $mutatorArguments) {
            $mutatorInfo.ArgumentList.Add($mutatorArgument)
        }
    } else {
        $mutatorInfo.Arguments = (
            $mutatorArguments | ForEach-Object {
                ConvertTo-PrivateMarkerProcessArgument -Argument $_
            }
        ) -join ' '
    }
    return [Diagnostics.Process]::Start($mutatorInfo)
}

$tempRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("bounded-playwright-ui-verification-scan-test-" +
    [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Assert-FirstBoundedInvocationValidatorRegressions
    Assert-FirstBoundedInvocationIsRawTransport

    # この assignment は実行可能な最初の bounded helper call として固定する。
    # Windows の初回 Job gateを含め、binary stdin、partial stdout/stderr、
    # EOF、非0 exit codeをtext framingなしで往復させる。
    $rawTransportScript = @'
$stdin = [Console]::OpenStandardInput()
$readBuffer = New-Object byte[] 3
$stdout = [Console]::OpenStandardOutput()
$readCount = $stdin.Read($readBuffer, 0, $readBuffer.Length)
while ($readCount -gt 0) {
    $stdout.Write($readBuffer, 0, $readCount)
    $stdout.Flush()
    $readCount = $stdin.Read($readBuffer, 0, $readBuffer.Length)
}
$stderrBytes = [byte[]]@(255, 254, 128, 127, 13, 10, 1, 0)
$stderr = [Console]::OpenStandardError()
$stderr.Write($stderrBytes, 0, 3)
$stderr.Flush()
$stderr.Write($stderrBytes, 3, $stderrBytes.Length - 3)
$stderr.Flush()
exit 37
'@
    $rawTransportChildPath = Join-Path $tempRoot 'raw-transport-child.ps1'
    [IO.File]::WriteAllText(
        $rawTransportChildPath,
        $rawTransportScript,
        [Text.UTF8Encoding]::new($false)
    )
    $rawTransportArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $rawTransportArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $rawTransportArguments += @('-File', $rawTransportChildPath)
    $rawTransportInput = [byte[]]@(
        0, 128, 255, 1, 10, 13, 127, 254, 2, 129, 253, 3
    )
    $rawTransportResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $rawTransportArguments `
        -IsolationRoot (Join-Path $tempRoot 'raw-transport-isolation') `
        -StandardInputBytes $rawTransportInput `
        -TimeoutMilliseconds 5000 `
        -MaxStdoutBytes 64 `
        -MaxStderrBytes 64
    $expectedRawStderr = [byte[]]@(255, 254, 128, 127, 13, 10, 1, 0)
    if (-not (Test-BoundedResultHealthy -Result $rawTransportResult) -or
        $rawTransportResult.ExitCode -ne 37 -or
        -not (Test-ByteArraysEqual `
            -Expected $rawTransportInput `
            -Actual $rawTransportResult.StdoutBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedRawStderr `
            -Actual $rawTransportResult.StderrBytes)) {
        Add-Failure 'Expected the containment gate to preserve binary stdin/stdout/stderr, EOF, and exit code exactly.'
    }

    # PowerShell自身はBOMを入力として許容するため、上のechoだけでは
    # PS5.1 StreamWriterのpreamble混入を検出できない。native Gitの
    # cat-file batch protocolを完全一致で比較し、caller encodingの復元も確認する。
    $rawGitCommands = @(
        Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    )
    if ($rawGitCommands.Count -eq 0) {
        Add-Failure 'Expected native Git to be available for the raw containment-gate regression.'
    }
    else {
        $rawGitPath = $rawGitCommands[0].Source
        $rawGitRoot = Join-Path $tempRoot 'raw-git-transport'
        $rawGitIsolationRoot = Join-Path $tempRoot 'raw-git-isolation'
        New-Item -ItemType Directory -Path $rawGitRoot | Out-Null
        New-Item -ItemType Directory -Path $rawGitIsolationRoot | Out-Null

        $rawGitInitResult = Invoke-IsolatedGit `
            -GitPath $rawGitPath `
            -WorkingDirectory $rawGitRoot `
            -IsolationRoot $rawGitIsolationRoot `
            -Arguments @('init', '-q')
        if (-not (Test-BoundedResultHealthy -Result $rawGitInitResult) -or
            $rawGitInitResult.ExitCode -ne 0) {
            Add-Failure 'Expected the raw native Git transport fixture to initialize.'
        }
        else {
            $rawGitBlobBytes = [byte[]]@(0, 128, 255, 10, 13, 1, 2)
            [IO.File]::WriteAllBytes(
                (Join-Path $rawGitRoot 'blob.bin'),
                $rawGitBlobBytes
            )
            $rawGitHashResult = Invoke-IsolatedGit `
                -GitPath $rawGitPath `
                -WorkingDirectory $rawGitRoot `
                -IsolationRoot $rawGitIsolationRoot `
                -Arguments @('hash-object', '-w', '--', 'blob.bin')
            $rawGitObjectId = [Text.Encoding]::ASCII.GetString(
                $rawGitHashResult.StdoutBytes
            ).Trim()
            if (-not (Test-BoundedResultHealthy -Result $rawGitHashResult) -or
                $rawGitHashResult.ExitCode -ne 0 -or
                $rawGitObjectId -notmatch
                    '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
                Add-Failure 'Expected the raw native Git transport fixture to create a blob object.'
            }
            else {
                $inputCodePageBefore = [Console]::InputEncoding.CodePage
                $inputPreambleBefore = [Convert]::ToBase64String(
                    [Console]::InputEncoding.GetPreamble()
                )
                $rawGitBatchInput = [Text.Encoding]::ASCII.GetBytes(
                    "$rawGitObjectId`n"
                )
                $rawGitBatchResult = Invoke-IsolatedGit `
                    -GitPath $rawGitPath `
                    -WorkingDirectory $rawGitRoot `
                    -IsolationRoot $rawGitIsolationRoot `
                    -Arguments @('cat-file', '--batch') `
                    -StandardInputBytes $rawGitBatchInput
                $rawGitHeaderBytes = [Text.Encoding]::ASCII.GetBytes(
                    "$rawGitObjectId blob $($rawGitBlobBytes.Length)`n"
                )
                $expectedRawGitOutput = [byte[]](
                    @($rawGitHeaderBytes) +
                    @($rawGitBlobBytes) +
                    @(10)
                )
                if (-not (Test-BoundedResultHealthy `
                        -Result $rawGitBatchResult) -or
                    $rawGitBatchResult.ExitCode -ne 0 -or
                    $rawGitBatchResult.StderrBytes.Length -ne 0 -or
                    -not (Test-ByteArraysEqual `
                        -Expected $expectedRawGitOutput `
                        -Actual $rawGitBatchResult.StdoutBytes)) {
                    Add-Failure 'Expected native git cat-file batch transport to remain byte-exact without a UTF-8 preamble.'
                }
                if ([Console]::InputEncoding.CodePage -ne
                        $inputCodePageBefore -or
                    [Convert]::ToBase64String(
                        [Console]::InputEncoding.GetPreamble()
                    ) -ne $inputPreambleBefore) {
                    Add-Failure 'Expected the raw input transport to restore the caller console input encoding exactly.'
                }

                if ($runtimeIsWindows) {
                    # 外側のdirect suspended gateでJobへ入れたPowerShell childから
                    # native Gitを再度起動し、reuse-owned-Job側のPS5.1
                    # ProcessStartInfo/StreamWriter経路もBOMなしであることを固定する。
                    $nestedRawGitScript = @'
param(
    [string]$ProcessSupport,
    [string]$GitPath,
    [string]$WorkingDirectory,
    [string]$IsolationRoot,
    [string]$ObjectId
)
. $ProcessSupport
if (-not [BoundedPlaywrightUiVerification.PrivateMarkerJob]::IsCurrentProcessInOwnedJob()) {
    exit 90
}
New-Item -ItemType Directory -Path $IsolationRoot -Force | Out-Null
$codePageBefore = [Console]::InputEncoding.CodePage
$preambleBefore = [Convert]::ToBase64String(
    [Console]::InputEncoding.GetPreamble()
)
$batchInput = [Text.Encoding]::ASCII.GetBytes("$ObjectId`n")
$result = Invoke-PrivateMarkerBoundedProcess `
    -FileName $GitPath `
    -Arguments @('-C', $WorkingDirectory, 'cat-file', '--batch') `
    -IsolationRoot $IsolationRoot `
    -WorkingDirectory $WorkingDirectory `
    -StandardInputBytes $batchInput `
    -TimeoutMilliseconds 10000 `
    -MaxStdoutBytes 1024 `
    -MaxStderrBytes 1024
if ($result.ExitCode -ne 0 -or
    $result.TimedOut -or
    $result.OutputLimitExceeded -or
    -not $result.ContainmentEstablished -or
    -not $result.TreeStopped -or
    -not $result.StreamsDrained -or
    $result.StderrBytes.Length -ne 0) {
    exit 91
}
if ([Console]::InputEncoding.CodePage -ne $codePageBefore -or
    [Convert]::ToBase64String(
        [Console]::InputEncoding.GetPreamble()
    ) -ne $preambleBefore) {
    exit 92
}
$stdout = [Console]::OpenStandardOutput()
try {
    $stdout.Write($result.StdoutBytes, 0, $result.StdoutBytes.Length)
    $stdout.Flush()
}
finally {
    $stdout.Dispose()
}
exit 0
'@
                    $nestedRawGitChildPath = Join-Path `
                        $tempRoot `
                        'nested-raw-git-child.ps1'
                    [IO.File]::WriteAllText(
                        $nestedRawGitChildPath,
                        $nestedRawGitScript,
                        [Text.UTF8Encoding]::new($false)
                    )
                    $nestedRawGitIsolationRoot = Join-Path `
                        $tempRoot `
                        'nested-raw-git-isolation'
                    $nestedRawGitArguments = @('-NoProfile')
                    if ($PSVersionTable.PSVersion.Major -le 5) {
                        $nestedRawGitArguments += @(
                            '-ExecutionPolicy',
                            'Bypass'
                        )
                    }
                    $nestedRawGitArguments += @(
                        '-File',
                        $nestedRawGitChildPath,
                        $processSupport,
                        $rawGitPath,
                        $rawGitRoot,
                        $nestedRawGitIsolationRoot,
                        $rawGitObjectId
                    )
                    $nestedRawGitResult =
                        Invoke-PrivateMarkerBoundedProcess `
                            -FileName $currentPowerShellExecutable `
                            -Arguments $nestedRawGitArguments `
                            -IsolationRoot (
                                Join-Path `
                                    $tempRoot `
                                    'nested-raw-git-outer-isolation'
                            ) `
                            -TimeoutMilliseconds 15000 `
                            -MaxStdoutBytes 1024 `
                            -MaxStderrBytes 1024
                    if (-not (Test-BoundedResultHealthy `
                            -Result $nestedRawGitResult) -or
                        $nestedRawGitResult.ExitCode -ne 0 -or
                        $nestedRawGitResult.StderrBytes.Length -ne 0 -or
                        -not (Test-ByteArraysEqual `
                            -Expected $expectedRawGitOutput `
                            -Actual $nestedRawGitResult.StdoutBytes)) {
                        Add-Failure 'Expected the reuse-owned Windows Job path to preserve native Git batch bytes and restore PS5.1 input encoding.'
                    }
                }
            }
        }
    }

    # A delayed grandchild sentinel distinguishes true tree cleanup from a
    # parent-only kill. The grandchild also keeps the redirected pipe open.
    # helper/bootstrap/process/isolation の例外には絶対pathが含まれ得る。
    # disposable scanner copyで各failureを強制し、固定1行・exit 2以外を拒否する。
    $diagnosticFixtureRoot = Join-Path $tempRoot 'diagnostic-boundaries'
    $diagnosticScanRoot = Join-Path $diagnosticFixtureRoot 'scan-target'
    New-Item -ItemType Directory -Path $diagnosticScanRoot -Force |
        Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $diagnosticScanRoot 'clean.md'),
        'synthetic clean diagnostic fixture',
        [Text.UTF8Encoding]::new($false)
    )
    $scannerSource = [IO.File]::ReadAllText($scanner)
    $processSupportSource = [IO.File]::ReadAllText($processSupport)

    if (-not (Test-PrivateMarkerMillisecondWaitContract `
            -Source $processSupportSource)) {
        Add-Failure '[timeout/millisecond-structure-contract] Expected an unrounded deadline-to-Win32 wait path.'
    }

    # caller/helperの丸めとcomment/string decoyが構造検査をすり抜けないことも自己検証する。
    $millisecondCallerAnchor = '$nativeChild.WaitForExit($remaining)'
    $millisecondRoundedCaller =
        '$nativeChild.WaitForExit(([int]([Math]::Ceiling(' +
        '$remaining / 1000.0) * 1000)))'
    $millisecondHelperAnchor = '    return [int]$remaining'
    $millisecondRoundedHelper =
        '    return [int]([Math]::Ceiling($remaining / 1000.0) * 1000)'
    $millisecondWaitBodyAnchor =
        'return WaitForSingleObject(processHandle, (uint)milliseconds) =='
    $millisecondRoundedWaitBody =
        'return WaitForSingleObject(processHandle, ' +
        '(uint)(Math.Ceiling(milliseconds / 1000.0) * 1000)) =='
    $millisecondExactWaitMethod = @'
    public bool WaitForExit(int milliseconds)
    {
        return WaitForSingleObject(processHandle, (uint)milliseconds) ==
            WaitObject0;
    }
'@
    $millisecondLineEnding = if ($processSupportSource.Contains("`r`n")) {
        "`r`n"
    } else {
        "`n"
    }
    $roundedCallerSource = $processSupportSource.Replace(
        $millisecondCallerAnchor,
        $millisecondRoundedCaller
    )
    $roundedCSharpWaitSource = $processSupportSource.Replace(
        $millisecondWaitBodyAnchor,
        $millisecondRoundedWaitBody
    )
    $csharpCommentDecoySource =
        $roundedCSharpWaitSource + $millisecondLineEnding +
        '<#' + $millisecondLineEnding +
        $millisecondExactWaitMethod + $millisecondLineEnding +
        '#>'
    $csharpStringDecoySource =
        $roundedCSharpWaitSource + $millisecondLineEnding +
        "`$millisecondWaitMethodDecoy = @'" + $millisecondLineEnding +
        $millisecondExactWaitMethod + $millisecondLineEnding +
        "'@"
    $millisecondRegionStartAnchor =
        '        $remaining = if ($null -eq $cleanupClock) {'
    $millisecondRegionEndAnchor =
        '                $nativeChild.WaitForExit($remaining)'
    $millisecondRegionStartIndex = $processSupportSource.IndexOf(
        $millisecondRegionStartAnchor,
        [StringComparison]::Ordinal
    )
    $millisecondRegionEndIndex = $processSupportSource.IndexOf(
        $millisecondRegionEndAnchor,
        [Math]::Max(0, $millisecondRegionStartIndex),
        [StringComparison]::Ordinal
    )
    $millisecondOriginalWaitRegion = ''
    if ($millisecondRegionStartIndex -ge 0 -and
        $millisecondRegionEndIndex -ge $millisecondRegionStartIndex) {
        $millisecondOriginalWaitRegion = $processSupportSource.Substring(
            $millisecondRegionStartIndex,
            $millisecondRegionEndIndex +
                $millisecondRegionEndAnchor.Length -
                $millisecondRegionStartIndex
        )
    }
    $millisecondStreamsAnchor =
        '        $streamsCompleted = $stdinClosed -and $stdoutClosed -and $stderrClosed'
    $millisecondRoundedReassignment =
        '        $remaining = [int]([Math]::Ceiling(' +
        '$remaining / 1000.0) * 1000)'
    $commentDecoySource = $processSupportSource
    $stringDecoySource = $processSupportSource
    $extraWaitSource = $processSupportSource
    if (-not [string]::IsNullOrEmpty($millisecondOriginalWaitRegion)) {
        # 期待region全文をdecoyへ残しつつ、実行側だけ再代入するhostile sourceを作る。
        $commentDecoyInsertion =
            '        <#' + $millisecondLineEnding +
            $millisecondOriginalWaitRegion + $millisecondLineEnding +
            '        #>' + $millisecondLineEnding +
            $millisecondRoundedReassignment + $millisecondLineEnding +
            $millisecondStreamsAnchor
        $commentDecoySource = $processSupportSource.Replace(
            $millisecondStreamsAnchor,
            $commentDecoyInsertion
        )
        $stringDecoyInsertion =
            "        `$millisecondWaitDecoy = @'" +
            $millisecondLineEnding +
            $millisecondOriginalWaitRegion + $millisecondLineEnding +
            "'@" + $millisecondLineEnding +
            $millisecondRoundedReassignment + $millisecondLineEnding +
            $millisecondStreamsAnchor
        $stringDecoySource = $processSupportSource.Replace(
            $millisecondStreamsAnchor,
            $stringDecoyInsertion
        )
        $extraWaitInsertion =
            '                [void]$nativeChild.WaitForExit(' +
            $millisecondLineEnding +
            '                    [int]([Math]::Ceiling(' +
            '$remaining / 1000.0) * 1000)' +
            $millisecondLineEnding +
            '                )' + $millisecondLineEnding +
            $millisecondRegionEndAnchor
        $extraWaitSource = $processSupportSource.Replace(
            $millisecondRegionEndAnchor,
            $extraWaitInsertion
        )
    }
    $millisecondContractMutations = @(
        [pscustomobject]@{
            Label = '[timeout/millisecond-caller-rounding-mutation]'
            Source = $roundedCallerSource
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-helper-rounding-mutation]'
            Source = $processSupportSource.Replace(
                $millisecondHelperAnchor,
                $millisecondRoundedHelper
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-comment-decoy-mutation]'
            Source = $commentDecoySource
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-string-decoy-mutation]'
            Source = $stringDecoySource
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-csharp-comment-decoy-mutation]'
            Source = $csharpCommentDecoySource
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-csharp-string-decoy-mutation]'
            Source = $csharpStringDecoySource
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-extra-wait-mutation]'
            Source = $extraWaitSource
        }
    )
    foreach ($millisecondContractMutation in $millisecondContractMutations) {
        if ($millisecondContractMutation.Source -ceq $processSupportSource -or
            (Test-PrivateMarkerMillisecondWaitContract `
                -Source $millisecondContractMutation.Source)) {
            Add-Failure (
                "$($millisecondContractMutation.Label) " +
                'Expected the millisecond wait contract to reject rounding or decoy drift.'
            )
        }
    }

    $diagnosticInjectionAnchor =
        'if ([string]::IsNullOrWhiteSpace($Path)) {'
    if (-not $scannerSource.Contains($diagnosticInjectionAnchor)) {
        Add-Failure 'Expected the diagnostic scanner injection anchor to remain stable.'
    }
    else {
        $removeFailureInjection = @'
function Remove-Item {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force
    )
    throw 'synthetic isolation cleanup failure at __PRIVATE_DIAGNOSTIC_PATH__'
}
if ([string]::IsNullOrWhiteSpace($Path)) {
'@
        $diagnosticCases = @(
            [pscustomobject]@{
                Name = 'missing-helper'
                Reason = 'process-boundary-bootstrap'
                HelperSource = $null
                ScannerSource = $scannerSource
            },
            [pscustomobject]@{
                Name = 'helper-exception'
                Reason = 'process-boundary'
                HelperSource = $processSupportSource + @'

function Invoke-PrivateMarkerBoundedProcess {
    throw 'synthetic helper failure at __PRIVATE_DIAGNOSTIC_PATH__'
}
'@
                ScannerSource = $scannerSource
            },
            [pscustomobject]@{
                Name = 'isolation-create'
                Reason = 'git-isolation-create'
                HelperSource = $processSupportSource
                ScannerSource = $scannerSource.Replace(
                    $diagnosticInjectionAnchor,
                    @'
function New-Item {
    [CmdletBinding()]
    param(
        [string]$ItemType,
        [string]$Path
    )
    throw 'synthetic isolation create failure at __PRIVATE_DIAGNOSTIC_PATH__'
}
if ([string]::IsNullOrWhiteSpace($Path)) {
'@
                )
            },
            [pscustomobject]@{
                Name = 'isolation-cleanup'
                Reason = 'git-isolation-cleanup'
                HelperSource = $processSupportSource
                ScannerSource = $scannerSource.Replace(
                    $diagnosticInjectionAnchor,
                    $removeFailureInjection
                )
            },
            [pscustomobject]@{
                Name = 'helper-and-isolation-cleanup'
                # 最初のprocess-boundary診断だけを残し、finallyの再入は抑止する。
                Reason = 'process-boundary'
                HelperSource = $processSupportSource + @'

function Invoke-PrivateMarkerBoundedProcess {
    throw 'synthetic helper failure at __PRIVATE_DIAGNOSTIC_PATH__'
}
'@
                ScannerSource = $scannerSource.Replace(
                    $diagnosticInjectionAnchor,
                    $removeFailureInjection
                )
            }
        )
        foreach ($diagnosticCase in $diagnosticCases) {
            $caseRoot = Join-Path `
                $diagnosticFixtureRoot `
                $diagnosticCase.Name
            New-Item -ItemType Directory -Path $caseRoot -Force |
                Out-Null
            $caseScanner = Join-Path $caseRoot 'scan-private-markers.ps1'
            $privateDiagnosticPath = Join-Path `
                $caseRoot `
                'private-diagnostic-never-emit'
            $escapedPrivateDiagnosticPath =
                $privateDiagnosticPath.Replace("'", "''")
            $caseScannerSource = $diagnosticCase.ScannerSource.Replace(
                '__PRIVATE_DIAGNOSTIC_PATH__',
                $escapedPrivateDiagnosticPath
            )
            [IO.File]::WriteAllText(
                $caseScanner,
                $caseScannerSource,
                [Text.UTF8Encoding]::new($true)
            )
            Copy-Item `
                -LiteralPath $scanConfig `
                -Destination (
                    Join-Path $caseRoot 'private-scan-config.ps1'
                )
            if ($null -ne $diagnosticCase.HelperSource) {
                $caseHelperSource = $diagnosticCase.HelperSource.Replace(
                    '__PRIVATE_DIAGNOSTIC_PATH__',
                    $escapedPrivateDiagnosticPath
                )
                [IO.File]::WriteAllText(
                    (Join-Path $caseRoot 'private-marker-process.ps1'),
                    $caseHelperSource,
                    [Text.UTF8Encoding]::new($true)
                )
            }
            $diagnosticResult = Invoke-Scanner `
                -ScanPath $diagnosticScanRoot `
                -ScannerPath $caseScanner
            Assert-FixedScannerIntegrityFailure `
                -Result $diagnosticResult `
                -Reason $diagnosticCase.Reason `
                -ForbiddenValues @(
                    $root,
                    $tempRoot,
                    $caseRoot,
                    $caseScanner,
                    $privateDiagnosticPath
                )
        }
    }

    $timeoutIsolationRoot = Join-Path $tempRoot 'timeout-isolation'
    $timeoutSentinel = Join-Path $tempRoot 'grandchild-survived-timeout'
    $timeoutTargetStarted = Join-Path $tempRoot 'timeout-target-started'
    $timeoutGrandchildStarted =
        Join-Path $tempRoot 'timeout-grandchild-started'
    $timeoutSurvivalRelease =
        Join-Path $tempRoot 'timeout-survival-release'
    $escapedTimeoutSentinel = $timeoutSentinel.Replace("'", "''")
    $escapedTimeoutTargetStarted =
        $timeoutTargetStarted.Replace("'", "''")
    $escapedTimeoutGrandchildStarted =
        $timeoutGrandchildStarted.Replace("'", "''")
    $escapedTimeoutSurvivalRelease =
        $timeoutSurvivalRelease.Replace("'", "''")
    # runtime/tree cleanupはsub-second精度と分離し、両OSでtarget/grandchild開始後に
    # release sentinelを使う。host起動速度ではなくcleanup後の生存だけを判定する。
    $timeoutMilliseconds = 4000
    # POSIX/reused Jobは4秒operation後に最大10秒cleanupを持つため、総guardも包絡する。
    $timeoutElapsedLimitMilliseconds =
        if ($runtimeIsWindows) { 10000 } else { 15000 }
    $grandchildScript = @'
[System.IO.File]::WriteAllText('__GRANDCHILD_STARTED__', 'started')
$releaseWait = [System.Diagnostics.Stopwatch]::StartNew()
while (-not [System.IO.File]::Exists('__SURVIVAL_RELEASE__') -and
    $releaseWait.ElapsedMilliseconds -lt 25000) {
    Start-Sleep -Milliseconds 25
}
if ([System.IO.File]::Exists('__SURVIVAL_RELEASE__')) {
    [System.IO.File]::WriteAllText('__SURVIVAL_SENTINEL__', 'survived')
}
'@
    $grandchildScript = $grandchildScript.Replace(
        '__GRANDCHILD_STARTED__',
        $escapedTimeoutGrandchildStarted
    )
    $grandchildScript = $grandchildScript.Replace(
        '__SURVIVAL_RELEASE__',
        $escapedTimeoutSurvivalRelease
    )
    $grandchildScript = $grandchildScript.Replace(
        '__SURVIVAL_SENTINEL__',
        $escapedTimeoutSentinel
    )
    $grandchildEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($grandchildScript)
    )
    $escapedPowerShellExecutable = $currentPowerShellExecutable.Replace("'", "''")
    $parentScript = @"
[System.IO.File]::WriteAllText('$escapedTimeoutTargetStarted', 'started')
& '$escapedPowerShellExecutable' -NoProfile -EncodedCommand '$grandchildEncoded'
Start-Sleep -Seconds 30
"@
    $parentEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($parentScript)
    )
    $timeoutArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $timeoutArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $timeoutArguments += @('-EncodedCommand', $parentEncoded)
    $beforeTimeoutEnvironment = Get-ProcessEnvironmentSnapshot
    $timeoutStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $timeoutArguments `
        -IsolationRoot $timeoutIsolationRoot `
        -TimeoutMilliseconds $timeoutMilliseconds
    $timeoutStopwatch.Stop()
    # aggregate診断へ潰さず、公開して安全な固定labelで失敗境界を一意にする。
    if (-not $timeoutResult.TimedOut) {
        Add-Failure '[timeout/timed-out] Expected the bounded child operation to time out.'
    }
    if (-not $timeoutResult.ContainmentEstablished) {
        Add-Failure '[timeout/containment-established] Expected containment before target execution.'
    }
    if (-not $timeoutResult.TreeStopped) {
        Add-Failure '[timeout/tree-stopped] Expected timeout cleanup to stop the process tree.'
    }
    if (-not $timeoutResult.StreamsDrained) {
        Add-Failure '[timeout/streams-drained] Expected timeout cleanup to drain both streams.'
    }
    if ($timeoutStopwatch.ElapsedMilliseconds -ge
        $timeoutElapsedLimitMilliseconds) {
        Add-Failure '[timeout/elapsed-hang-guard] Expected the bounded timeout fixture to return within its finite hang guard.'
    }
    if (-not (Test-Path -LiteralPath $timeoutTargetStarted)) {
        Add-Failure '[timeout/target-started] Expected the bounded child regression to start its contained target.'
    }
    if (-not (Test-Path -LiteralPath $timeoutGrandchildStarted)) {
        Add-Failure '[timeout/grandchild-started] Expected the bounded child regression to start its contained grandchild.'
    }
    # cleanup後にだけreleaseし、生き残ったgrandchildを即時に可視化する。
    [IO.File]::WriteAllText($timeoutSurvivalRelease, 'release')
    for ($attempt = 0; $attempt -lt 25 -and
        -not (Test-Path -LiteralPath $timeoutSentinel); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath $timeoutSentinel) {
        Add-Failure '[timeout/sentinel-not-written] Expected timeout cleanup to kill the grandchild before its delayed sentinel write.'
    }
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeTimeoutEnvironment `
        -Context 'Bounded child timeout'

    # prep開始後の遅延もoperation deadlineへ含め、期限切れ後はtargetを起動しない。
    $preLaunchSentinel = Join-Path $tempRoot 'prelaunch-target-started'
    $escapedPreLaunchSentinel = $preLaunchSentinel.Replace("'", "''")
    $preLaunchScript = @"
[IO.File]::WriteAllText('$escapedPreLaunchSentinel', 'started')
"@
    $preLaunchEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($preLaunchScript)
    )
    $preLaunchArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $preLaunchArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $preLaunchArguments += @('-EncodedCommand', $preLaunchEncoded)
    # target非起動が意味論oracle。elapsedはhost負荷と分離した有限hang guardに限定する。
    $preLaunchElapsedLimitMilliseconds = 5000
    $preLaunchClock = [Diagnostics.Stopwatch]::StartNew()
    $preLaunchResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $preLaunchArguments `
        -IsolationRoot (Join-Path $tempRoot 'prelaunch-isolation') `
        -TimeoutMilliseconds 100 `
        -ForcePreLaunchDelayMilliseconds 250
    $preLaunchClock.Stop()
    if (-not $preLaunchResult.TimedOut) {
        Add-Failure '[prelaunch/timed-out] Expected preparation to consume the operation deadline.'
    }
    if ($preLaunchResult.ContainmentEstablished) {
        Add-Failure '[prelaunch/containment-not-established] Expected expiry before containment.'
    }
    if (-not $preLaunchResult.TreeStopped) {
        Add-Failure '[prelaunch/tree-stopped] Expected the prelaunch timeout result to confirm a stopped tree.'
    }
    if (-not $preLaunchResult.StreamsDrained) {
        Add-Failure '[prelaunch/streams-drained] Expected the prelaunch timeout result to confirm drained streams.'
    }
    if ($preLaunchClock.ElapsedMilliseconds -ge
        $preLaunchElapsedLimitMilliseconds) {
        Add-Failure '[prelaunch/elapsed-hang-guard] Expected the prelaunch fixture to return within its finite hang guard.'
    }
    if (Test-Path -LiteralPath $preLaunchSentinel) {
        Add-Failure '[prelaunch/target-not-started] Expected expiry before target launch.'
    }

    # The direct child can exit before a grandchild that inherited stdout. A
    # kill-on-close job/process group must remain addressable after that exit;
    # otherwise stream draining times out and the delayed sentinel survives.
    $detachedSentinel = Join-Path $tempRoot 'detached-grandchild-survived'
    $escapedDetachedSentinel = $detachedSentinel.Replace("'", "''")
    $detachedGrandchildScript = @"
Start-Sleep -Milliseconds 1500
[System.IO.File]::WriteAllText('$escapedDetachedSentinel', 'survived')
[Console]::Out.Write('late-output')
"@
    $detachedGrandchildEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($detachedGrandchildScript)
    )
    $detachedParentScript = @"
`$startInfo = New-Object System.Diagnostics.ProcessStartInfo
`$startInfo.FileName = '$escapedPowerShellExecutable'
`$startInfo.Arguments = '-NoProfile -EncodedCommand $detachedGrandchildEncoded'
`$startInfo.UseShellExecute = `$false
`$startInfo.CreateNoWindow = `$true
`$child = [System.Diagnostics.Process]::Start(`$startInfo)
`$child.Dispose()
"@
    $detachedParentEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($detachedParentScript)
    )
    $detachedArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $detachedArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $detachedArguments += @('-EncodedCommand', $detachedParentEncoded)
    $detachedResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $detachedArguments `
        -IsolationRoot (Join-Path $tempRoot 'detached-isolation') `
        -TimeoutMilliseconds 5000 `
        -DrainTimeoutMilliseconds 3000 `
        -ForceNativePosixSessionGate:(-not $runtimeIsWindows)
    if ($detachedResult.TimedOut -or
        -not $detachedResult.ContainmentEstablished -or
        -not $detachedResult.TreeStopped -or
        -not $detachedResult.StreamsDrained) {
        Add-Failure 'Expected parent-first exit cleanup to stop the pipe-owning grandchild and drain both streams.'
    }
    for ($attempt = 0; $attempt -lt 25 -and
        -not (Test-Path -LiteralPath $detachedSentinel); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath $detachedSentinel) {
        Add-Failure 'Expected parent-first exit cleanup to kill the grandchild before its delayed sentinel write.'
    }

    # Repeat the zero-wait spawn pattern so the Windows suspended launch and
    # POSIX process group prove the race is closed rather than merely rare.
    $immediateRaceSentinels =
        New-Object System.Collections.Generic.List[string]
    for ($raceAttempt = 1; $raceAttempt -le 10; $raceAttempt++) {
        $raceSentinel = Join-Path `
            $tempRoot `
            "immediate-grandchild-survived-$raceAttempt"
        $immediateRaceSentinels.Add($raceSentinel) | Out-Null
        $escapedRaceSentinel = $raceSentinel.Replace("'", "''")
        $raceGrandchildScript = @"
Start-Sleep -Milliseconds 1000
[IO.File]::WriteAllText('$escapedRaceSentinel', 'survived')
"@
        $raceGrandchildEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($raceGrandchildScript)
        )
        $raceParentScript = @"
`$startInfo = New-Object Diagnostics.ProcessStartInfo
`$startInfo.FileName = '$escapedPowerShellExecutable'
`$startInfo.Arguments = '-NoProfile -EncodedCommand $raceGrandchildEncoded'
`$startInfo.UseShellExecute = `$false
`$startInfo.CreateNoWindow = `$true
`$child = [Diagnostics.Process]::Start(`$startInfo)
`$child.Dispose()
"@
        $raceParentEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($raceParentScript)
        )
        $raceArguments = @('-NoProfile')
        if ($PSVersionTable.PSVersion.Major -le 5 -and
            $runtimeIsWindows) {
            $raceArguments += @('-ExecutionPolicy', 'Bypass')
        }
        $raceArguments += @('-EncodedCommand', $raceParentEncoded)
        $raceResult = Invoke-PrivateMarkerBoundedProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments $raceArguments `
            -IsolationRoot (
                Join-Path $tempRoot "immediate-race-isolation-$raceAttempt"
            ) `
            -TimeoutMilliseconds 5000 `
            -DrainTimeoutMilliseconds 3000 `
            -ForceNativePosixSessionGate:(
                -not $runtimeIsWindows -and $raceAttempt -eq 1
            )
        if ($raceResult.TimedOut -or
            -not $raceResult.ContainmentEstablished -or
            -not $raceResult.TreeStopped -or
            -not $raceResult.StreamsDrained) {
            Add-Failure "Expected immediate-spawn race attempt $raceAttempt to stop its full process tree."
        }
    }
    Start-Sleep -Milliseconds 1300
    foreach ($raceSentinel in $immediateRaceSentinels) {
        if (Test-Path -LiteralPath $raceSentinel) {
            Add-Failure 'Expected all 10 immediate-spawn process-tree attempts to suppress delayed sentinels.'
            break
        }
    }
    if (-not $runtimeIsWindows) {
        # kill(2) returns -1 for both ESRCH and EPERM. Only ESRCH is a
        # successful "already gone" cleanup state; permission and other
        # failures must keep TreeStopped false.
        if (-not [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::
                IsSuccessfulResult(0, 0) -or
            -not [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::
                IsSuccessfulResult(-1, 3) -or
            [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::
                IsSuccessfulResult(-1, 1) -or
            [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::
                IsSuccessfulResult(-1, 13)) {
            Add-Failure 'Expected POSIX group cleanup to accept success/ESRCH and reject EPERM/EACCES.'
        }

        # external setsidのargvはBusyBox/util-linux共通のoption-free operand形に固定する。
        $portableSetsidArguments = @(
            Get-PrivateMarkerPosixSetsidArguments `
                -PowerShellExecutable '/synthetic/pwsh' `
                -EncodedCommand 'synthetic-payload'
        )
        if (($portableSetsidArguments -join '|') -ne
                '/synthetic/pwsh|-NoProfile|-EncodedCommand|synthetic-payload' -or
            @($portableSetsidArguments | Where-Object { $_ -eq '--' }).Count -ne 0) {
            Add-Failure 'Expected POSIX setsid arguments to use the option-free BusyBox-compatible operand form.'
        }

        # session確立後・ready公開前に期限が切れた場合もtargetをreleaseしない。
        foreach ($gateMode in @(
            @{ Name = 'native'; ForceNative = $true },
            @{ Name = 'default'; ForceNative = $false }
        )) {
            $gateDeadlineSentinel = Join-Path `
                $tempRoot `
                "posix-gate-target-started-$($gateMode.Name)"
            $escapedGateDeadlineSentinel =
                $gateDeadlineSentinel.Replace("'", "''")
            $gateDeadlineScript = @"
[IO.File]::WriteAllText('$escapedGateDeadlineSentinel', 'started')
"@
            $gateDeadlineEncoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($gateDeadlineScript)
            )
            $gateDeadlineClock = [Diagnostics.Stopwatch]::StartNew()
            $gateDeadlineResult = Invoke-PrivateMarkerBoundedProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $gateDeadlineEncoded
                ) `
                -IsolationRoot (
                    Join-Path `
                        $tempRoot `
                        "posix-gate-deadline-$($gateMode.Name)"
                ) `
                -TimeoutMilliseconds 100 `
                -ForcePosixGateDelayMilliseconds 250 `
                -ForceNativePosixSessionGate:(
                    [bool]$gateMode.ForceNative
                )
            $gateDeadlineClock.Stop()
            if (-not $gateDeadlineResult.TimedOut -or
                $gateDeadlineResult.ContainmentEstablished -or
                -not $gateDeadlineResult.TreeStopped -or
                -not $gateDeadlineResult.StreamsDrained -or
                $gateDeadlineClock.ElapsedMilliseconds -ge 2000 -or
                (Test-Path -LiteralPath $gateDeadlineSentinel)) {
                Add-Failure "Expected $($gateMode.Name) POSIX gate timeout to suppress target release."
            }
        }
    }

    # The raw budget includes every serialized byte, including a visible prefix
    # and the platform's real newline (CRLF on Windows, LF on POSIX).
    $exactBudgetScript = @'
$prefixBytes = [System.Text.Encoding]::UTF8.GetBytes('scan-prefix:')
$newlineBytes = [System.Text.Encoding]::UTF8.GetBytes([Environment]::NewLine)
$fillLength = 128 - $prefixBytes.Length - $newlineBytes.Length
$fillBytes = [System.Text.Encoding]::UTF8.GetBytes(('x' * $fillLength))
$stream = [Console]::OpenStandardOutput()
$stream.Write($prefixBytes, 0, $prefixBytes.Length)
$stream.Write($fillBytes, 0, $fillBytes.Length)
$stream.Write($newlineBytes, 0, $newlineBytes.Length)
$stream.Flush()
'@
    $exactBudgetEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($exactBudgetScript)
    )
    $exactBudgetArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $exactBudgetArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $exactBudgetArguments += @('-EncodedCommand', $exactBudgetEncoded)
    $exactBudgetResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $exactBudgetArguments `
        -IsolationRoot (Join-Path $tempRoot 'exact-budget-isolation') `
        -TimeoutMilliseconds 5000 `
        -MaxStdoutBytes 128 `
        -MaxStderrBytes 65536
    if (-not (Test-BoundedResultHealthy -Result $exactBudgetResult) -or
        $exactBudgetResult.ExitCode -ne 0 -or
        $exactBudgetResult.StdoutBytes.Length -ne 128) {
        Add-Failure 'Expected prefix plus the platform newline to fit an exact 128-byte raw stdout budget.'
    }

    # A child that floods stdout must be stopped by the byte cap before the
    # runtime timeout, and retained output must never exceed the configured cap.
    $limitScript = @'
[Console]::Out.Write(('x' * 4096))
Start-Sleep -Seconds 30
'@
    $limitEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($limitScript)
    )
    $limitArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $limitArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $limitArguments += @('-EncodedCommand', $limitEncoded)
    $limitResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $limitArguments `
        -IsolationRoot (Join-Path $tempRoot 'limit-isolation') `
        -TimeoutMilliseconds 5000 `
        -MaxStdoutBytes 128 `
        -MaxStderrBytes 128
    if (-not $limitResult.OutputLimitExceeded -or
        $limitResult.TimedOut -or
        -not $limitResult.ContainmentEstablished -or
        -not $limitResult.TreeStopped -or
        -not $limitResult.StreamsDrained -or
        $limitResult.StdoutBytes.Length -gt 128) {
        Add-Failure 'Expected stdout byte overflow to stop the child tree and stay within the configured output cap.'
    }

    # Git境界はambient cloneとcaller overrideを最後に捨て、固定allowlistだけを渡す。
    # probeは値を出さず、隔離directoryとGit hardeningのbooleanだけを返す。
    $gitBoundaryScript = @'
$protocolDenied = $false
for ($index = 0; $index -lt [int]$env:GIT_CONFIG_COUNT; $index++) {
    if ([Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_$index") -eq 'protocol.allow' -and
        [Environment]::GetEnvironmentVariable("GIT_CONFIG_VALUE_$index") -eq 'never') {
        $protocolDenied = $true
    }
}
[Console]::Out.Write(
    (($null -eq [Environment]::GetEnvironmentVariable(
        'PRIVATE_MARKER_AMBIENT_SENTINEL')).ToString()) + '|' +
    (($null -eq [Environment]::GetEnvironmentVariable(
        'PRIVATE_MARKER_INHERITED_SENTINEL')).ToString()) + '|' +
    (($env:HOME -ne 'hostile-home').ToString()) + '|' +
    (($env:PATH -ne 'hostile-path').ToString()) + '|' +
    ([IO.Directory]::Exists($env:HOME).ToString()) + '|' +
    ([IO.Directory]::Exists($env:TEMP).ToString()) + '|' +
    ((-not [string]::IsNullOrWhiteSpace($env:PATH)).ToString()) + '|' +
    (($env:GIT_NO_REPLACE_OBJECTS -eq '1').ToString()) + '|' +
    (($env:GIT_NO_LAZY_FETCH -eq '1').ToString()) + '|' +
    $protocolDenied.ToString()
)
'@
    $gitBoundaryEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($gitBoundaryScript)
    )
    $gitBoundaryArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $gitBoundaryArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $gitBoundaryArguments += @('-EncodedCommand', $gitBoundaryEncoded)
    $ambientSentinelName = 'PRIVATE_MARKER_AMBIENT_SENTINEL'
    $originalAmbientSentinel =
        [Environment]::GetEnvironmentVariable(
            $ambientSentinelName,
            [EnvironmentVariableTarget]::Process
        )
    try {
        [Environment]::SetEnvironmentVariable(
            $ambientSentinelName,
            'synthetic-ambient',
            [EnvironmentVariableTarget]::Process
        )
        $gitBoundaryResult = Invoke-PrivateMarkerBoundedProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments $gitBoundaryArguments `
            -IsolationRoot (Join-Path $tempRoot 'git-boundary-isolation') `
            -InheritedEnvironment @{
                PRIVATE_MARKER_INHERITED_SENTINEL = 'synthetic-inherited'
                HOME = 'hostile-home'
                PATH = 'hostile-path'
                GIT_NO_REPLACE_OBJECTS = '0'
                GIT_NO_LAZY_FETCH = '0'
            } `
            -TimeoutMilliseconds 5000 `
            -MaxStdoutBytes 256 `
            -MaxStderrBytes 65536
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            $ambientSentinelName,
            $originalAmbientSentinel,
            [EnvironmentVariableTarget]::Process
        )
    }
    $gitBoundaryText = [Text.Encoding]::UTF8.GetString(
        $gitBoundaryResult.StdoutBytes
    )
    if (-not (Test-BoundedResultHealthy -Result $gitBoundaryResult) -or
        $gitBoundaryResult.ExitCode -ne 0 -or
        $gitBoundaryText -ne
            'True|True|True|True|True|True|True|True|True|True') {
        Add-Failure "Expected the child-only Git environment to use only the fixed safe allowlist (exit $($gitBoundaryResult.ExitCode), stdout '$gitBoundaryText', timeout $($gitBoundaryResult.TimedOut), limit $($gitBoundaryResult.OutputLimitExceeded), containment $($gitBoundaryResult.ContainmentEstablished), tree $($gitBoundaryResult.TreeStopped), streams $($gitBoundaryResult.StreamsDrained))."
    }

    if ($runtimeIsWindows) {
        # CreateProcessWでsuspendしたtargetをJobへ割り当て、resumeした後も
        # target自身が同じJobに所属していることをprocess内から検証する。
        $jobIdentityScript = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SyntheticJobIdentityProbe
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(
        IntPtr process,
        IntPtr job,
        out bool result
    );
    public static bool IsInJob()
    {
        bool result;
        return IsProcessInJob(
            GetCurrentProcess(),
            IntPtr.Zero,
            out result
        ) && result;
    }
}
"@
[Console]::Out.Write(
    [SyntheticJobIdentityProbe]::IsInJob().ToString()
)
'@
        $jobIdentityEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($jobIdentityScript)
        )
        $jobIdentityResult = Invoke-PrivateMarkerBoundedProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                $jobIdentityEncoded
            ) `
            -IsolationRoot (Join-Path $tempRoot 'job-identity-isolation') `
            -TimeoutMilliseconds 10000 `
            -MaxStdoutBytes 64 `
            -MaxStderrBytes 65536
        $jobIdentityText = [Text.Encoding]::UTF8.GetString(
            $jobIdentityResult.StdoutBytes
        )
        if (-not (Test-BoundedResultHealthy -Result $jobIdentityResult) -or
            $jobIdentityResult.ExitCode -ne 0 -or
            $jobIdentityText -ne 'True') {
            Add-Failure "Expected the actual gated target process to inherit the assigned Windows Job (exit $($jobIdentityResult.ExitCode), stdout '$jobIdentityText', timeout $($jobIdentityResult.TimedOut), limit $($jobIdentityResult.OutputLimitExceeded), tree $($jobIdentityResult.TreeStopped), streams $($jobIdentityResult.StreamsDrained))."
        }

        # C#側のpipe/environment prepとJob assignも期限へ含め、resume直前の期限切れでは
        # suspended targetを一度も実行せずcleanup slackだけで回収する。
        $resumeDeadlineSentinel =
            Join-Path $tempRoot 'windows-resume-deadline-target-started'
        $escapedResumeDeadlineSentinel =
            $resumeDeadlineSentinel.Replace("'", "''")
        $resumeDeadlineScript = @"
[IO.File]::WriteAllText('$escapedResumeDeadlineSentinel', 'started')
"@
        $resumeDeadlineEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($resumeDeadlineScript)
        )
        $resumeDeadlineClock = [Diagnostics.Stopwatch]::StartNew()
        $resumeDeadlineResult = Invoke-PrivateMarkerBoundedProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                $resumeDeadlineEncoded
            ) `
            -IsolationRoot (
                Join-Path $tempRoot 'windows-resume-deadline-isolation'
            ) `
            -TimeoutMilliseconds 100 `
            -ForceWindowsLaunchFailure 'deadline-before-resume'
        $resumeDeadlineClock.Stop()
        if (-not $resumeDeadlineResult.TimedOut -or
            $resumeDeadlineResult.ContainmentEstablished -or
            -not $resumeDeadlineResult.TreeStopped -or
            -not $resumeDeadlineResult.StreamsDrained -or
            $resumeDeadlineClock.ElapsedMilliseconds -ge 2000 -or
            (Test-Path -LiteralPath $resumeDeadlineSentinel)) {
            Add-Failure 'Expected the Windows operation deadline to expire before ResumeThread without running the target.'
        }

        # Job 割当前とresume前のsynthetic failureはtargetを一度も実行せず、
        # cleanup APIの確認後にPIDを有限時間でprocess tableから除去する。
        foreach ($launchFailureMode in @('assign', 'resume')) {
            $launchFailureSentinel = Join-Path `
                $tempRoot `
                "windows-launch-failure-$launchFailureMode"
            $escapedLaunchFailureSentinel =
                $launchFailureSentinel.Replace("'", "''")
            $launchFailureScript = @"
[IO.File]::WriteAllText('$escapedLaunchFailureSentinel', 'ran')
"@
            $launchFailureEncoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($launchFailureScript)
            )
            $launchFailureStopwatch =
                [Diagnostics.Stopwatch]::StartNew()
            $launchFailureObserved = $false
            try {
                [void](Invoke-PrivateMarkerBoundedProcess `
                    -FileName $currentPowerShellExecutable `
                    -Arguments @(
                        '-NoProfile',
                        '-ExecutionPolicy',
                        'Bypass',
                        '-EncodedCommand',
                        $launchFailureEncoded
                    ) `
                    -IsolationRoot (
                        Join-Path `
                            $tempRoot `
                            "windows-launch-$launchFailureMode-isolation"
                    ) `
                    -TimeoutMilliseconds 10000 `
                    -ForceWindowsLaunchFailure $launchFailureMode)
            }
            catch {
                $launchFailureObserved = $true
            }
            $launchFailureStopwatch.Stop()
            $launchFailureProcessId =
                [BoundedPlaywrightContainedProcess]::
                    LastSyntheticFailureProcessId
            $launchFailureProcessGone = $false
            if ($launchFailureProcessId -gt 0) {
                # API結果の確認に加え、kernel process tableからの消失を
                # 最大1秒だけ再確認し、handleだけ閉じた誤実装を検出する。
                for ($pidCheckAttempt = 0;
                    $pidCheckAttempt -lt 20;
                    $pidCheckAttempt++) {
                    if ($null -eq (Get-Process `
                        -Id $launchFailureProcessId `
                        -ErrorAction SilentlyContinue)) {
                        $launchFailureProcessGone = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 100
            if (-not $launchFailureObserved -or
                $launchFailureProcessId -le 0 -or
                -not $launchFailureProcessGone -or
                $launchFailureStopwatch.ElapsedMilliseconds -ge 6000 -or
                (Test-Path -LiteralPath $launchFailureSentinel)) {
                Add-Failure "Expected $launchFailureMode launch failure to remove its PID without resuming the suspended target."
            }
        }

        # 起動後の最初のJob closeだけを失敗させる。handleを保持したまま
        # direct TerminateProcess、有限wait、同じJob close再試行へ進むことを実測する。
        # exact timeout化後も子processのstarted通知を確実に観測できるよう、このfixtureだけ2秒にする。
        $closeFailureSentinel = Join-Path `
            $tempRoot `
            'windows-close-once-started'
        $escapedCloseFailureSentinel =
            $closeFailureSentinel.Replace("'", "''")
        $closeFailureScript = @"
[IO.File]::WriteAllText('$escapedCloseFailureSentinel', 'started')
Start-Sleep -Seconds 30
"@
        $closeFailureEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($closeFailureScript)
        )
        $closeFailureStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $closeFailureObserved = $false
        try {
            [void](Invoke-PrivateMarkerBoundedProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-EncodedCommand',
                    $closeFailureEncoded
                ) `
                -IsolationRoot (
                    Join-Path $tempRoot 'windows-close-once-isolation'
                ) `
                -TimeoutMilliseconds 2000 `
                -ForceWindowsLaunchFailure 'close-once')
        }
        catch {
            $closeFailureObserved = $true
        }
        $closeFailureStopwatch.Stop()
        $closeFailureProcessId =
            [BoundedPlaywrightContainedProcess]::LastSyntheticFailureProcessId
        $closeFailureProcessGone = $false
        if ($closeFailureProcessId -gt 0) {
            for ($pidCheckAttempt = 0;
                $pidCheckAttempt -lt 20;
                $pidCheckAttempt++) {
                if ($null -eq (Get-Process `
                    -Id $closeFailureProcessId `
                    -ErrorAction SilentlyContinue)) {
                    $closeFailureProcessGone = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        }
        if (-not $closeFailureObserved -or
            -not (Test-Path -LiteralPath $closeFailureSentinel) -or
            $closeFailureProcessId -le 0 -or
            -not $closeFailureProcessGone -or
            [BoundedPlaywrightContainedProcess]::
                LastSyntheticTerminateAttemptCount -lt 1 -or
            [BoundedPlaywrightContainedProcess]::
                LastSyntheticCloseAttemptCount -lt 2 -or
            $closeFailureStopwatch.ElapsedMilliseconds -ge 7000) {
            Add-Failure 'Expected one synthetic Job close failure to preserve ownership, terminate the direct child, wait finitely, and retry close.'
        }
    }

    # The ambient OS variable is untrusted. A fresh child must derive the same
    # kernel branch from .NET even when OS is forged to the opposite platform.
    $forgedOsValue = if ($runtimeIsWindows) {
        'synthetic-posix'
    } else {
        'Windows_NT'
    }
    $escapedProcessSupport = $processSupport.Replace("'", "''")
    $escapedForgedOsValue = $forgedOsValue.Replace("'", "''")
    $platformProbeScript = @"
[Environment]::SetEnvironmentVariable(
    'OS',
    '$escapedForgedOsValue',
    [EnvironmentVariableTarget]::Process
)
. '$escapedProcessSupport'
[Console]::Out.Write(
    `$script:privateMarkerIsWindows.ToString()
)
"@
    $platformProbeEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($platformProbeScript)
    )
    $platformProbeArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and $runtimeIsWindows) {
        $platformProbeArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $platformProbeArguments += @(
        '-EncodedCommand',
        $platformProbeEncoded
    )
    $platformProbeResult = Invoke-PrivateMarkerBoundedProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $platformProbeArguments `
        -IsolationRoot (Join-Path `
            $tempRoot `
            'platform-probe-isolation') `
        -TimeoutMilliseconds 10000 `
        -MaxStdoutBytes 32 `
        -MaxStderrBytes 65536
    $platformProbeText = [Text.Encoding]::UTF8.GetString(
        $platformProbeResult.StdoutBytes
    )
    if (-not (Test-BoundedResultHealthy -Result $platformProbeResult) -or
        $platformProbeResult.ExitCode -ne 0 -or
        $platformProbeText -ne $runtimeIsWindows.ToString()) {
        Add-Failure "Expected runtime platform detection to ignore a forged OS variable (exit $($platformProbeResult.ExitCode), stdout '$platformProbeText')."
    }

    # The spaced directory also exercises the PS5.1 native argument fallback.
    $cleanRoot = Join-Path $tempRoot 'clean fixture'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRoot 'README.md') -Value @(
        '# Clean synthetic fixture'
        'A completion notice is a claim, not evidence. Verify artifacts first.'
        'Contact support@example.com for this synthetic fixture.'
        'Never send a Bearer token to an external service.'
    ) -Encoding UTF8

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode): $($cleanResult.Output.Trim())"
    }
    $rootAliasResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -RootParameter 'Root'
    if ($rootAliasResult.ExitCode -ne 0) {
        Add-Failure "Expected the legacy -Root alias to pass, but scanner exited $($rootAliasResult.ExitCode): $($rootAliasResult.Output.Trim())"
    }

    # lower-only seamで全scan工程の時計を1msにし、最終success出力より前に
    # 固定codeだけでfail-closedすることを実測する。
    $scanDeadlineResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '1')
    if ($scanDeadlineResult.ExitCode -ne 2 -or
        $scanDeadlineResult.TimedOut -or
        $scanDeadlineResult.Output.Trim() -cne
            'Private marker scan failed closed (integrity: scan-deadline).' -or
        $scanDeadlineResult.Output -match 'Private marker scan passed') {
        Add-Failure "Expected the lower-only scan-wide deadline to fail before final success output. Output: $($scanDeadlineResult.Output.Trim())"
    }

    # public deadlineの範囲外・非整数はparameter binderへ漏らさず、stdoutの
    # 固定1行・empty stderr・exit 2へ統一する。
    foreach ($invalidDeadline in @('0', '120001', 'not-an-integer')) {
        $invalidDeadlineResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -AdditionalArguments @(
                '-ScanDeadlineMilliseconds',
                $invalidDeadline
            )
        $invalidDeadlineStdout = [Text.Encoding]::UTF8.GetString(
            $invalidDeadlineResult.StdoutBytes
        )
        $expectedInvalidDeadlineStdout =
            'Private marker scan failed closed (integrity: scan-deadline-parameter).' +
            [Environment]::NewLine
        if (-not (Test-BoundedResultHealthy `
                -Result $invalidDeadlineResult) -or
            $invalidDeadlineResult.ExitCode -ne 2 -or
            $invalidDeadlineStdout -cne $expectedInvalidDeadlineStdout -or
            $invalidDeadlineResult.StderrBytes.Length -ne 0) {
            Add-Failure "Expected invalid scan deadline '$invalidDeadline' to produce one fixed stdout line, empty stderr, and exit 2."
        }
    }

    # hostileな不存在Pathは固定codeで失敗させ、生pathとUnicode方向制御を漏らさない。
    # stdout/stderrの双方をbyte cap内に保つところまで回帰で固定する。
    $hostileDirectionControl = [char]0x202E
    $hostileLineSeparator = [char]0x2028
    $hostileMissingPath = Join-Path $tempRoot (
        'missing-' + $hostileDirectionControl + $hostileLineSeparator + 'leaf'
    )
    $hostileMissingResult = Invoke-Scanner `
        -ScanPath $hostileMissingPath `
        -MaxStdoutBytes 256 `
        -MaxStderrBytes 65536
    $hostileMissingStdout = [System.Text.Encoding]::UTF8.GetString(
        $hostileMissingResult.StdoutBytes
    )
    $hostileMissingStderr = [System.Text.Encoding]::UTF8.GetString(
        $hostileMissingResult.StderrBytes
    )
    $hostileMissingDiagnostic = $hostileMissingStdout.TrimEnd(
        [char[]]@(13, 10)
    )
    if (-not (Test-BoundedResultHealthy -Result $hostileMissingResult) -or
        $hostileMissingResult.ExitCode -ne 2 -or
        $hostileMissingDiagnostic -ne
            'Private marker scan failed closed (integrity: scan-root-missing).' -or
        $hostileMissingResult.StdoutBytes.Length -gt 256 -or
        $hostileMissingResult.StderrBytes.Length -gt 65536 -or
        $hostileMissingStdout.Contains($hostileMissingPath) -or
        $hostileMissingStderr.Contains($hostileMissingPath) -or
        $hostileMissingStdout.Contains([string]$hostileDirectionControl) -or
        $hostileMissingStderr.Contains([string]$hostileDirectionControl) -or
        $hostileMissingStdout.Contains([string]$hostileLineSeparator) -or
        $hostileMissingStderr.Contains([string]$hostileLineSeparator)) {
        Add-Failure 'Expected a hostile nonexistent path to produce only the bounded fixed scan-root-missing diagnostic.'
    }

    # launcher自体へ偽OSを渡すとPowerShell host初期化を壊すため、scanner process内で
    # 設定してからproduction entrypointを呼ぶsynthetic wrapperで判定分岐だけを検証する。
    $forgedOsScannerWrapper =
        Join-Path $tempRoot 'forged-os-scanner-wrapper.ps1'
    $escapedScannerPath = $scanner.Replace("'", "''")
    $forgedOsScannerWrapperScript = @"
param([string]`$Path)
[Environment]::SetEnvironmentVariable(
    'OS',
    '$escapedForgedOsValue',
    [EnvironmentVariableTarget]::Process
)
& '$escapedScannerPath' -Path `$Path
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText(
        $forgedOsScannerWrapper,
        $forgedOsScannerWrapperScript,
        [Text.UTF8Encoding]::new($false)
    )
    $forgedOsScannerResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -ScannerPath $forgedOsScannerWrapper
    if ($forgedOsScannerResult.ExitCode -ne 0) {
        Add-Failure "Expected scanner platform selection to ignore a forged OS variable. Output: $($forgedOsScannerResult.Output.Trim())"
    }

    $markerRoot = Join-Path $tempRoot 'marker'
    New-Item -ItemType Directory -Path $markerRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'
    Set-Content -LiteralPath (Join-Path $markerRoot 'leak.txt') -Value "synthetic marker: $syntheticMarker" -Encoding UTF8

    $markerResult = Invoke-Scanner -ScanPath $markerRoot
    if ($markerResult.ExitCode -eq 0) {
        Add-Failure 'Expected synthetic marker fixture to fail, but scanner exited 0.'
    }
    if ($markerResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure "Expected synthetic marker output to name github-classic-token-prefix. Output: $($markerResult.Output.Trim())"
    }

    # Encoding regression: a marker directly after a multi-byte character must
    # still be detected when the scanner runs under Windows PowerShell 5.1.
    # Without an explicit UTF-8 read, 5.1 decodes BOM-less UTF-8 as ANSI and a
    # misread multi-byte character swallows the following ASCII bytes
    # (measured false negative). The fixture is written BOM-less on purpose;
    # the character is built from a code point to keep this file ASCII-only.
    $encodingRoot = Join-Path $tempRoot 'multibyte-adjacent'
    New-Item -ItemType Directory -Path $encodingRoot | Out-Null
    $multiByteContent = 'token after multi-byte char: ' + [char]0x3042 + $syntheticMarker
    [System.IO.File]::WriteAllText((Join-Path $encodingRoot 'leak.md'), $multiByteContent, [System.Text.UTF8Encoding]::new($false))
    $encodingResult = Invoke-Scanner -ScanPath $encodingRoot
    if ($encodingResult.ExitCode -eq 0) {
        Add-Failure 'Expected multi-byte-adjacent marker fixture to fail, but scanner exited 0.'
    }
    if ($encodingResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure "Expected multi-byte-adjacent output to name github-classic-token-prefix. Output: $($encodingResult.Output.Trim())"
    }

    # `.env`はGetExtension上の扱いが特殊で、POSIXではhiddenにもなる。
    # 非Git fallbackでも`-Force`とsensitive-name判定を通ることを固定する。
    $dotfileRoot = Join-Path $tempRoot 'dotfile'
    New-Item -ItemType Directory -Path $dotfileRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $dotfileRoot '.env') -Value "value: $syntheticMarker" -Encoding UTF8
    $dotfileResult = Invoke-Scanner -ScanPath $dotfileRoot
    if ($dotfileResult.Output -notmatch 'working-tree') {
        Add-Failure "Expected .env fixture to use working-tree mode. Output: $($dotfileResult.Output.Trim())"
    }
    if ($dotfileResult.ExitCode -eq 0) {
        Add-Failure 'Expected .env dotfile fixture to fail, but scanner exited 0.'
    }
    if ($dotfileResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure "Expected .env dotfile output to name github-classic-token-prefix. Output: $($dotfileResult.Output.Trim())"
    }
    if ($dotfileResult.Output -notmatch '\.env') {
        Add-Failure "Expected .env dotfile output to name .env. Output: $($dotfileResult.Output.Trim())"
    }
    if ($dotfileResult.Output.Contains($syntheticMarker)) {
        Add-Failure 'Expected .env dotfile finding to stay redacted, but the raw marker leaked into output.'
    }

    # The working-tree fallback must use POSIX-aware exclusion boundaries and
    # emit a normalized relative path. A real finding outside excluded trees
    # proves the scan ran; marker files inside those trees must remain absent.
    $boundaryRoot = Join-Path $tempRoot 'working-tree-boundaries'
    $boundaryLeakDirectory = Join-Path $boundaryRoot (Join-Path 'nested' 'deep')
    New-Item -ItemType Directory -Path $boundaryLeakDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $boundaryLeakDirectory 'leak.md') -Value "value: $syntheticMarker" -Encoding UTF8

    foreach ($excludedDirectoryName in $expectedExcludedDirectoryNames) {
        if ($excludedDirectoryName -eq '.git') {
            continue
        }
        $excludedDirectory = Join-Path $boundaryRoot $excludedDirectoryName
        New-Item -ItemType Directory -Path $excludedDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $excludedDirectory 'ignored.md') -Value "value: $syntheticMarker" -Encoding UTF8
    }
    $nestedGitDirectory = Join-Path $boundaryRoot (Join-Path 'neutral' '.git')
    New-Item -ItemType Directory -Path $nestedGitDirectory -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $nestedGitDirectory 'ignored.md') `
        -Value "value: $syntheticMarker" `
        -Encoding UTF8
    $nestedGitFileDirectory = Join-Path $boundaryRoot 'neutral-file'
    New-Item `
        -ItemType Directory `
        -Path $nestedGitFileDirectory `
        -Force | Out-Null
    $nestedGitFileMarker = ('g' + 'hp_') +
        'synthetic_nested_git_file'
    Set-Content `
        -LiteralPath (Join-Path $nestedGitFileDirectory '.git') `
        -Value "gitdir: $nestedGitFileMarker" `
        -Encoding UTF8
    # POSIXでは大小文字が異なる `.GIT` は通常のdirectory/fileである。
    # Windowsでは同じfilesystem entry名としてlowercase `.git` と同様に除外する。
    $upperGitDirectory = Join-Path `
        (Join-Path $boundaryRoot 'ordinary-upper-directory') `
        '.GIT'
    New-Item -ItemType Directory -Path $upperGitDirectory -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $upperGitDirectory 'ordinary.md') `
        -Value "value: $syntheticMarker" `
        -Encoding UTF8
    $upperGitFileDirectory = Join-Path `
        $boundaryRoot `
        'ordinary-upper-file'
    New-Item `
        -ItemType Directory `
        -Path $upperGitFileDirectory `
        -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $upperGitFileDirectory '.GIT') `
        -Value "value: $syntheticMarker" `
        -Encoding UTF8

    $boundaryResult = Invoke-Scanner -ScanPath $boundaryRoot
    if ($boundaryResult.Output -notmatch 'working-tree') {
        Add-Failure "Expected exclusion fixture to use working-tree mode. Output: $($boundaryResult.Output.Trim())"
    }
    if ($boundaryResult.ExitCode -eq 0) {
        Add-Failure 'Expected the non-excluded nested marker to fail the working-tree scan, but scanner exited 0.'
    }
    if ($boundaryResult.Output -notmatch 'nested/deep/leak\.md') {
        Add-Failure "Expected normalized relative path nested/deep/leak.md. Output: $($boundaryResult.Output.Trim())"
    }
    if ($boundaryResult.Output.Contains($boundaryRoot)) {
        Add-Failure "Expected working-tree findings to omit the absolute fixture root. Output: $($boundaryResult.Output.Trim())"
    }
    $excludedOutputPattern = (
        @($expectedExcludedDirectoryNames | ForEach-Object {
            [regex]::Escape($_)
        }) -join '|'
    )
    $boundaryRegexOptions = if ($runtimeIsWindows) {
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    } else {
        [Text.RegularExpressions.RegexOptions]::None
    }
    if ([regex]::IsMatch(
            $boundaryResult.Output,
            "($excludedOutputPattern)[\\/]ignored\.md",
            $boundaryRegexOptions
        ) -or
        [regex]::IsMatch(
            $boundaryResult.Output,
            'neutral-file[\\/]\.git',
            $boundaryRegexOptions
        )) {
        Add-Failure "Expected repo-specific excluded directories and nested .git metadata to stay excluded. Output: $($boundaryResult.Output.Trim())"
    }
    $upperGitDirectoryPattern =
        'ordinary-upper-directory[\\/]\.GIT[\\/]ordinary\.md'
    $upperGitFilePattern = 'ordinary-upper-file[\\/]\.GIT'
    $upperGitDirectoryFound = [regex]::IsMatch(
        $boundaryResult.Output,
        $upperGitDirectoryPattern,
        [Text.RegularExpressions.RegexOptions]::None
    )
    $upperGitFileFound = [regex]::IsMatch(
        $boundaryResult.Output,
        $upperGitFilePattern,
        [Text.RegularExpressions.RegexOptions]::None
    )
    if ($runtimeIsWindows -and
        ($upperGitDirectoryFound -or $upperGitFileFound)) {
        Add-Failure "Expected Windows .GIT paths to follow case-insensitive .git exclusion semantics. Output: $($boundaryResult.Output.Trim())"
    }
    if (-not $runtimeIsWindows -and
        (-not $upperGitDirectoryFound -or -not $upperGitFileFound)) {
        Add-Failure "Expected POSIX .GIT directory and file paths to be scanned as ordinary entries. Output: $($boundaryResult.Output.Trim())"
    }

    # scan root直下の`.git`はfallback除外対象ではない。directory/fileの
    # どちらでもvalid repositoryを確立できなければ、固定診断だけでfail-closeする。
    $expectedGitMetadataDiagnostic =
        'Private marker scan failed closed (integrity: git-probe).'
    foreach ($metadataKind in @('directory', 'file')) {
        $metadataRoot = Join-Path `
            $tempRoot `
            "invalid-git-metadata-$metadataKind"
        New-Item -ItemType Directory -Path $metadataRoot -Force | Out-Null
        $metadataPath = Join-Path $metadataRoot '.git'
        if ($metadataKind -eq 'directory') {
            New-Item `
                -ItemType Directory `
                -Path $metadataPath `
                -Force | Out-Null
        } else {
            [IO.File]::WriteAllText(
                $metadataPath,
                'gitdir: ../synthetic-missing-git-directory',
                [Text.UTF8Encoding]::new($false)
            )
        }
        Set-Content `
            -LiteralPath (Join-Path $metadataRoot 'README.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8
        $metadataResult = Invoke-Scanner -ScanPath $metadataRoot
        if ($metadataResult.ExitCode -ne 2 -or
            $metadataResult.Output.Trim() -cne
                $expectedGitMetadataDiagnostic) {
            Add-Failure "Expected invalid root-level .git $metadataKind metadata to fail closed with the fixed diagnostic. Output: $($metadataResult.Output.Trim())"
        }
    }

    # scan root自身にmetadataが無くても、親階層の`.git`をGit probe失敗後に
    # 見落としてはならない。directory/fileの両形をchild rootから固定する。
    foreach ($metadataKind in @('directory', 'file')) {
        $ancestorMetadataParent = Join-Path `
            $tempRoot `
            "invalid-ancestor-git-metadata-$metadataKind"
        $ancestorScanRoot = Join-Path $ancestorMetadataParent 'scan-root'
        New-Item `
            -ItemType Directory `
            -Path $ancestorScanRoot `
            -Force | Out-Null
        $ancestorMetadataPath = Join-Path $ancestorMetadataParent '.git'
        if ($metadataKind -eq 'directory') {
            New-Item `
                -ItemType Directory `
                -Path $ancestorMetadataPath `
                -Force | Out-Null
        } else {
            [IO.File]::WriteAllText(
                $ancestorMetadataPath,
                'gitdir: ../synthetic-missing-git-directory',
                [Text.UTF8Encoding]::new($false)
            )
        }
        Set-Content `
            -LiteralPath (Join-Path $ancestorScanRoot 'README.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8

        $ancestorMetadataResult = Invoke-Scanner `
            -ScanPath $ancestorScanRoot
        if ($ancestorMetadataResult.ExitCode -ne 2 -or
            $ancestorMetadataResult.Output.Trim() -cne
                $expectedGitMetadataDiagnostic) {
            Add-Failure "Expected invalid ancestor .git $metadataKind metadata to fail closed with the fixed diagnostic. Output: $($ancestorMetadataResult.Output.Trim())"
        }
    }

    if ($runtimeIsWindows) {
        # Test-Path は target が消えた junction を false と返す。親directoryの
        # 非再帰列挙で `.git` entry 自体を認識し、fallbackへ降格しないことを固定する。
        $danglingGitRoot = Join-Path $tempRoot 'dangling-git-marker'
        $danglingGitTarget = Join-Path $tempRoot 'deleted-git-target'
        $danglingGitMarker = Join-Path $danglingGitRoot '.git'
        New-Item -ItemType Directory -Path $danglingGitRoot | Out-Null
        New-Item -ItemType Directory -Path $danglingGitTarget | Out-Null
        try {
            New-Item `
                -ItemType Junction `
                -Path $danglingGitMarker `
                -Target $danglingGitTarget | Out-Null
            [IO.Directory]::Delete($danglingGitTarget)
            $danglingGitResult = Invoke-Scanner -ScanPath $danglingGitRoot
            if ($danglingGitResult.ExitCode -ne 2 -or
                $danglingGitResult.Output.Trim() -cne
                    $expectedGitMetadataDiagnostic) {
                Add-Failure "Expected a dangling .git junction to block working-tree fallback. Output: $($danglingGitResult.Output.Trim())"
            }
        }
        finally {
            $danglingGitEntry = Get-ChildItem `
                -LiteralPath $danglingGitRoot `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ceq '.git' } |
                Select-Object -First 1
            if ($null -ne $danglingGitEntry) {
                $danglingGitEntry.Delete()
            }
        }
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    # Fixtures are synthetic placeholders only; no real secrets are used.
    $prefixCases = @(
        @{ Rule = 'openai-api-key-prefix';            Marker = ('s' + 'k-') + 'SyntheticOpenAI000000000000' }
        @{ Rule = 'aws-access-key-id';                Marker = ('A' + 'KIA') + 'EXAMPLE0000000000000' }
        @{ Rule = 'gcp-api-key-prefix';               Marker = ('AIza') + 'Synthetic0000000000000000000000000000' }
        @{ Rule = 'slack-user-token-prefix';          Marker = ('xo' + 'xp-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-legacy-app-token-prefix';    Marker = ('xo' + 'xa-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-app-level-token-prefix';     Marker = ('xa' + 'pp-') + 'synthetic-placeholder' }
        @{ Rule = 'stripe-live-secret-key';           Marker = ('s' + 'k') + '_live_SyntheticPlaceholder0000' }
        @{ Rule = 'pem-private-key-block';            Marker = '-----' + ('BEGIN ' + 'OPENSSH PRIVATE KEY') + '-----' }
    )

    foreach ($case in $prefixCases) {
        $prefixRoot = Join-Path $tempRoot ('prefix-' + $case.Rule)
        New-Item -ItemType Directory -Path $prefixRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $prefixRoot 'leak.txt') -Value "synthetic marker: $($case.Marker)" -Encoding UTF8

        $prefixResult = Invoke-Scanner -ScanPath $prefixRoot
        if ($prefixResult.ExitCode -eq 0) {
            Add-Failure "Expected $($case.Rule) fixture to fail, but scanner exited 0."
        }
        if ($prefixResult.Output -notmatch [regex]::Escape($case.Rule)) {
            Add-Failure "Expected output to name $($case.Rule). Output: $($prefixResult.Output.Trim())"
        }
        # Preserve redaction: the raw marker value must never appear in output.
        if ($prefixResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected $($case.Rule) finding to be redacted, but the raw marker leaked into output."
        }
        if ($prefixResult.Output -notmatch '<redacted>') {
            Add-Failure "Expected $($case.Rule) finding to report '<redacted>'. Output: $($prefixResult.Output.Trim())"
        }
    }

    # windows-absolute-path: private-looking paths should be findings.
    # Split the literal so this test file does not make the scanner flag itself.
    $winPathRealRoot = Join-Path $tempRoot 'winpath-real'
    New-Item -ItemType Directory -Path $winPathRealRoot | Out-Null
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    Set-Content -LiteralPath (Join-Path $winPathRealRoot 'doc.md') -Value "See $realWinPath for details." -Encoding UTF8
    $winPathRealResult = Invoke-Scanner -ScanPath $winPathRealRoot
    if ($winPathRealResult.ExitCode -eq 0) {
        Add-Failure 'Expected real-looking Windows path fixture to fail, but scanner exited 0.'
    }
    if ($winPathRealResult.Output -notmatch 'windows-absolute-path') {
        Add-Failure "Expected real Windows path output to name windows-absolute-path. Output: $($winPathRealResult.Output.Trim())"
    }

    # windows-absolute-path: documented placeholders should not be findings.
    $winPathDocRoot = Join-Path $tempRoot 'winpath-doc'
    New-Item -ItemType Directory -Path $winPathDocRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $winPathDocRoot 'doc.md') -Value @'
Use a placeholder path such as C:\path\to\repo in examples.
You can also write C:\Users\<name>\project to describe a user directory.
'@ -Encoding UTF8
    $winPathDocResult = Invoke-Scanner -ScanPath $winPathDocRoot
    if ($winPathDocResult.ExitCode -ne 0) {
        Add-Failure "Expected placeholder Windows path doc to pass, but scanner exited $($winPathDocResult.ExitCode): $($winPathDocResult.Output.Trim())"
    }

    # 034固有契約: このリポジトリ自身だけを許可し、別リポジトリは検出する。
    # fixture自体がURL検査へ混入しないよう、値は断片から合成する。
    $urlBase = 'https://' + 'github.com/'
    $allowedUrlRoot = Join-Path $tempRoot 'url-allowed'
    New-Item -ItemType Directory -Path $allowedUrlRoot | Out-Null
    $allowedUrl = $urlBase +
        'h8nc4y/bounded-playwright-ui-verification'
    Set-Content -LiteralPath (Join-Path $allowedUrlRoot 'doc.md') -Value "Related: $allowedUrl" -Encoding UTF8
    $allowedUrlResult = Invoke-Scanner -ScanPath $allowedUrlRoot
    if ($allowedUrlResult.ExitCode -ne 0) {
        Add-Failure "Expected the own repository URL to pass, but scanner exited $($allowedUrlResult.ExitCode): $($allowedUrlResult.Output.Trim())"
    }

    $foreignUrlRoot = Join-Path $tempRoot 'url-foreign'
    New-Item -ItemType Directory -Path $foreignUrlRoot | Out-Null
    $foreignUrl = $urlBase + 'h8nc4y/synthetic-other-repository'
    Set-Content -LiteralPath (Join-Path $foreignUrlRoot 'doc.md') -Value "See $foreignUrl" -Encoding UTF8
    $foreignUrlResult = Invoke-Scanner -ScanPath $foreignUrlRoot
    if ($foreignUrlResult.ExitCode -eq 0) {
        Add-Failure 'Expected non-allowlisted repository URL to fail, but scanner exited 0.'
    }
    if ($foreignUrlResult.Output -notmatch 'non-allowlisted-github-repo-url') {
        Add-Failure "Expected foreign URL output to name non-allowlisted-github-repo-url. Output: $($foreignUrlResult.Output.Trim())"
    }

    # A marker-dense line must retain a bounded useful report rather than
    # allocating or emitting one row for every URL.
    $denseUrlRoot = Join-Path $tempRoot 'url-dense'
    New-Item -ItemType Directory -Path $denseUrlRoot | Out-Null
    $denseUrls = 1..150 | ForEach-Object {
        $urlBase + "synthetic-owner/synthetic-repo-$_"
    }
    [IO.File]::WriteAllText(
        (Join-Path $denseUrlRoot 'dense.md'),
        ($denseUrls -join ' '),
        [Text.UTF8Encoding]::new($false)
    )
    $denseUrlResult = Invoke-Scanner -ScanPath $denseUrlRoot
    if ($denseUrlResult.ExitCode -eq 0 -or
        $denseUrlResult.OutputLimitExceeded -or
        $denseUrlResult.Output -notmatch
        'Additional findings omitted after 100 entries\.') {
        Add-Failure "Expected dense URL findings to fail with a bounded truncation notice. Output: $($denseUrlResult.Output.Trim())"
    }

    # Exercise production budget branches with lower constants in a disposable
    # scanner copy. This keeps the fixture fast while proving that zero-byte
    # files, non-text entries, line objects, and allowlisted regex matches all
    # have independent finite caps.
    $budgetScannerDirectory = Join-Path $tempRoot 'budget-scanner'
    New-Item `
        -ItemType Directory `
        -Path $budgetScannerDirectory `
        -Force | Out-Null
    $budgetScanner = Join-Path `
        $budgetScannerDirectory `
        'scan-private-markers.ps1'
    Copy-Item `
        -LiteralPath $processSupport `
        -Destination (Join-Path `
            $budgetScannerDirectory `
            'private-marker-process.ps1')
    Copy-Item `
        -LiteralPath $scanConfig `
        -Destination (Join-Path `
            $budgetScannerDirectory `
            'private-scan-config.ps1')
    $budgetScannerSource = [IO.File]::ReadAllText($scanner)
    $budgetReplacements = [ordered]@{
        '$maxScanTargets = 8192' = '$maxScanTargets = 4'
        '$maxWorkingTreeEntries = 32768' =
            '$maxWorkingTreeEntries = 5'
        '$maxScanLines = 1000000' = '$maxScanLines = 3'
        '$maxRegexMatches = 100000' = '$maxRegexMatches = 5'
        '$maxFindingOutputBytes = 16384' =
            '$maxFindingOutputBytes = 512'
        '$maxLocalMarkerBytes = 262144' =
            '$maxLocalMarkerBytes = 64'
        '$maxLocalMarkers = 256' = '$maxLocalMarkers = 2'
        '$maxLocalMarkerCharacters = 4096' =
            '$maxLocalMarkerCharacters = 8'
    }
    foreach ($budgetNeedle in $budgetReplacements.Keys) {
        if (-not $budgetScannerSource.Contains($budgetNeedle)) {
            throw "Cannot locate scanner budget constant: $budgetNeedle"
        }
        $budgetScannerSource = $budgetScannerSource.Replace(
            $budgetNeedle,
            $budgetReplacements[$budgetNeedle]
        )
    }
    [IO.File]::WriteAllText(
        $budgetScanner,
        $budgetScannerSource,
        # scanner本体はPS5.1でも日本語意図コメントを正しくparseできるようBOM付き。
        [Text.UTF8Encoding]::new($true)
    )
    $originalScanner = $scanner
    try {
        $scanner = $budgetScanner

        $zeroTargetRoot = Join-Path $tempRoot 'zero-target-budget'
        New-Item -ItemType Directory -Path $zeroTargetRoot | Out-Null
        1..5 | ForEach-Object {
            [IO.File]::WriteAllBytes(
                (Join-Path $zeroTargetRoot "empty-$_.md"),
                [byte[]]@()
            )
        }
        $zeroTargetResult = Invoke-Scanner -ScanPath $zeroTargetRoot
        if ($zeroTargetResult.ExitCode -ne 2 -or
            $zeroTargetResult.Output -notmatch
            'integrity: scan-target-count') {
            Add-Failure "Expected zero-byte target count to fail closed at its budget. Output: $($zeroTargetResult.Output.Trim())"
        }

        $entryBudgetRoot = Join-Path $tempRoot 'entry-budget'
        New-Item -ItemType Directory -Path $entryBudgetRoot | Out-Null
        1..6 | ForEach-Object {
            [IO.File]::WriteAllBytes(
                (Join-Path $entryBudgetRoot "binary-$_.bin"),
                [byte[]]@(0)
            )
        }
        $entryBudgetResult = Invoke-Scanner -ScanPath $entryBudgetRoot
        if ($entryBudgetResult.ExitCode -ne 2 -or
            $entryBudgetResult.Output -notmatch
            'integrity: working-tree-entry-budget') {
            Add-Failure "Expected fallback entry enumeration to fail closed at its budget. Output: $($entryBudgetResult.Output.Trim())"
        }

        $lineBudgetRoot = Join-Path $tempRoot 'line-budget'
        New-Item -ItemType Directory -Path $lineBudgetRoot | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $lineBudgetRoot 'lines.md'),
            "one`ntwo`nthree`nfour",
            [Text.UTF8Encoding]::new($false)
        )
        $lineBudgetResult = Invoke-Scanner -ScanPath $lineBudgetRoot
        if ($lineBudgetResult.ExitCode -ne 2 -or
            $lineBudgetResult.Output -notmatch
            'integrity: scan-line-budget') {
            Add-Failure "Expected streaming line scan to fail closed at its budget. Output: $($lineBudgetResult.Output.Trim())"
        }

        $regexBudgetRoot = Join-Path $tempRoot 'regex-budget'
        New-Item -ItemType Directory -Path $regexBudgetRoot | Out-Null
        $allowedBudgetUrl = $urlBase +
            'h8nc4y/bounded-playwright-ui-verification'
        [IO.File]::WriteAllText(
            (Join-Path $regexBudgetRoot 'urls.md'),
            ((1..6 | ForEach-Object { $allowedBudgetUrl }) -join ' '),
            [Text.UTF8Encoding]::new($false)
        )
        $regexBudgetResult = Invoke-Scanner -ScanPath $regexBudgetRoot
        if ($regexBudgetResult.ExitCode -ne 2 -or
            $regexBudgetResult.Output -notmatch
            'integrity: scan-regex-match-budget') {
            Add-Failure "Expected lazy regex matching to fail closed at its budget. Output: $($regexBudgetResult.Output.Trim())"
        }

        # 実OS newlineを含むreport payloadを512/513 bytesへ隣接させる。
        # cap内は全payloadを一度だけ返し、1 byte超過はpartial tableを
        # 一切返さず固定integrity codeへ縮退する。
        $findingPayloadPlan = {
            param(
                [int]$TargetBytes,
                [string]$FixtureRoot
            )

            $reportNewline = [Environment]::NewLine
            $reportPrefix =
                'Private marker scan failed (scan target: working-tree):'
            $reportHeader = "File`tLine`tRule`tMatch"
            $findingRule = 'github-classic-token-prefix'
            $findingMatch = '<redacted>'
            $baseBytes = [Text.Encoding]::UTF8.GetByteCount(
                $reportPrefix +
                $reportNewline +
                $reportHeader +
                $reportNewline
            )
            $firstLength = 0
            $secondLength = 220
            for ($candidateLength = 6;
                $candidateLength -le 220;
                $candidateLength++) {
                $candidateBytes = $baseBytes +
                    [Text.Encoding]::UTF8.GetByteCount(
                        ('x' * $candidateLength) +
                        "`t1`t$findingRule`t$findingMatch" +
                        $reportNewline
                    ) +
                    [Text.Encoding]::UTF8.GetByteCount(
                        ('y' * $secondLength) +
                        "`t1`t$findingRule`t$findingMatch" +
                        $reportNewline
                    )
                if ($candidateBytes -eq $TargetBytes) {
                    $firstLength = $candidateLength
                    break
                }
            }
            if ($firstLength -eq 0) {
                throw "Cannot construct $TargetBytes-byte finding payload."
            }

            New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
            $firstName =
                'a-' + ('x' * ($firstLength - 6)) + '.txt'
            $secondName =
                'b-' + ('y' * ($secondLength - 6)) + '.txt'
            [IO.File]::WriteAllText(
                (Join-Path $FixtureRoot $firstName),
                ('g' + 'hp_') + 'finding_output_boundary',
                [Text.UTF8Encoding]::new($false)
            )
            [IO.File]::WriteAllText(
                (Join-Path $FixtureRoot $secondName),
                ('g' + 'hp_') + 'finding_output_boundary',
                [Text.UTF8Encoding]::new($false)
            )
        }

        $findingBoundaryRoot = Join-Path `
            $tempRoot `
            'finding-output-boundary'
        & $findingPayloadPlan 512 $findingBoundaryRoot
        $findingBoundaryResult = Invoke-Scanner `
            -ScanPath $findingBoundaryRoot
        if ($findingBoundaryResult.ExitCode -eq 0 -or
            $findingBoundaryResult.StdoutBytes.Length -ne 512 -or
            $findingBoundaryResult.StderrBytes.Length -ne 0 -or
            $findingBoundaryResult.Output -match
                'integrity: finding-output-budget') {
            Add-Failure 'Expected one exact 512-byte finding report including the actual OS newline.'
        }

        $findingOverRoot = Join-Path $tempRoot 'finding-output-over'
        & $findingPayloadPlan 513 $findingOverRoot
        $findingOverResult = Invoke-Scanner -ScanPath $findingOverRoot
        if ($findingOverResult.ExitCode -ne 2 -or
            $findingOverResult.Output -notmatch
                'integrity: finding-output-budget' -or
            $findingOverResult.Output -match "File`tLine`tRule`tMatch") {
            Add-Failure 'Expected a 513-byte finding report to fail closed without a partial table.'
        }

        $markerCountBudgetRoot = Join-Path `
            $tempRoot `
            'marker-count-budget'
        New-Item `
            -ItemType Directory `
            -Path $markerCountBudgetRoot | Out-Null
        $markerCountBudgetResult = Invoke-Scanner `
            -ScanPath $markerCountBudgetRoot `
            -InheritedEnvironment @{
                BOUNDED_PLAYWRIGHT_UI_VERIFICATION_PRIVATE_MARKERS =
                    "one`ntwo`nthree"
            }
        if ($markerCountBudgetResult.ExitCode -ne 2 -or
            $markerCountBudgetResult.Output -notmatch
            'integrity: local-marker-count') {
            Add-Failure "Expected streaming environment markers to fail closed at their count budget. Output: $($markerCountBudgetResult.Output.Trim())"
        }

        $markerLengthBudgetRoot = Join-Path `
            $tempRoot `
            'marker-length-budget'
        New-Item `
            -ItemType Directory `
            -Path $markerLengthBudgetRoot | Out-Null
        $markerLengthBudgetResult = Invoke-Scanner `
            -ScanPath $markerLengthBudgetRoot `
            -InheritedEnvironment @{
                BOUNDED_PLAYWRIGHT_UI_VERIFICATION_PRIVATE_MARKERS =
                    '123456789'
            }
        if ($markerLengthBudgetResult.ExitCode -ne 2 -or
            $markerLengthBudgetResult.Output -notmatch
            'integrity: local-marker-length') {
            Add-Failure "Expected one local marker to fail closed at its character budget. Output: $($markerLengthBudgetResult.Output.Trim())"
        }

        $markerSizeBudgetRoot = Join-Path `
            $tempRoot `
            'marker-size-budget'
        New-Item `
            -ItemType Directory `
            -Path $markerSizeBudgetRoot | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path `
                $markerSizeBudgetRoot `
                '.private-markers.local'),
            ('x' * 65),
            [Text.UTF8Encoding]::new($false)
        )
        $markerSizeBudgetResult = Invoke-Scanner `
            -ScanPath $markerSizeBudgetRoot
        if ($markerSizeBudgetResult.ExitCode -ne 2 -or
            $markerSizeBudgetResult.Output -notmatch
            'integrity: local-marker-type') {
            Add-Failure "Expected local marker bytes to fail closed at their size budget. Output: $($markerSizeBudgetResult.Output.Trim())"
        }
    }
    finally {
        $scanner = $originalScanner
    }

    # Unicode format and logical line-separator characters can reorder or forge
    # log text even though Char.IsControl does not classify them as controls.
    $unicodePathRoot = Join-Path $tempRoot 'unicode-display-path'
    New-Item -ItemType Directory -Path $unicodePathRoot | Out-Null
    $unicodePathName = 'format' + [char]0x202E +
        'line' + [char]0x2028 + 'name.md'
    $unicodePathMarker = ('g' + 'hp_') +
        'synthetic_unicode_display'
    [IO.File]::WriteAllText(
        (Join-Path $unicodePathRoot $unicodePathName),
        "synthetic marker: $unicodePathMarker",
        [Text.UTF8Encoding]::new($false)
    )
    $unicodePathResult = Invoke-Scanner -ScanPath $unicodePathRoot
    if ($unicodePathResult.ExitCode -eq 0 -or
        $unicodePathResult.Output -notmatch
        'format\\u202eline\\u2028name\.md' -or
        $unicodePathResult.Output.Contains([string][char]0x202E) -or
        $unicodePathResult.Output.Contains([string][char]0x2028)) {
        Add-Failure "Expected Unicode format/separator characters in displayed paths to be escaped. Output: $($unicodePathResult.Output.Trim())"
    }

    $localMarkerRoot = Join-Path $tempRoot 'local-marker'
    New-Item -ItemType Directory -Path $localMarkerRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $localMarkerRoot '.private-markers.local') -Value 'local-only-marker' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $localMarkerRoot 'leak.txt') -Value 'synthetic local-only-marker fixture' -Encoding UTF8

    $localMarkerResult = Invoke-Scanner -ScanPath $localMarkerRoot
    if ($localMarkerResult.ExitCode -eq 0) {
        Add-Failure 'Expected local marker fixture to fail, but scanner exited 0.'
    }
    if ($localMarkerResult.Output -notmatch 'local-private-marker-1') {
        Add-Failure "Expected local marker output to name local-private-marker-1. Output: $($localMarkerResult.Output.Trim())"
    }

    # Gitのforward-slash pathを全OSで保持し、nested fileとdotfileを同時に走査する。
    # Windows限定separator変換とUnix側`-Force`漏れを同じfixtureで検出する。
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand) {
        $gitRoot = Join-Path $tempRoot 'git-tracked'
        $gitIsolationRoot = Join-Path $tempRoot 'git-isolation'
        $ambientHooksRoot = Join-Path $tempRoot 'ambient-hooks'
        $ambientFilterRoot = Join-Path $tempRoot 'ambient-filter'
        $ambientGitDirectory = Join-Path $tempRoot 'ambient-git-dir'
        $ambientWorkTree = Join-Path $tempRoot 'ambient-work-tree'
        $ambientObjectDirectory = Join-Path $tempRoot 'ambient-objects'
        $ambientIndexFile = Join-Path $tempRoot 'ambient-index'
        $ambientHome = Join-Path $tempRoot 'ambient-home'
        $ambientXdg = Join-Path $tempRoot 'ambient-xdg'
        $ambientExecPath = Join-Path $tempRoot 'ambient-git-exec'
        $hookSentinel = Join-Path $tempRoot 'ambient-hook-fired'
        $filterSentinel = Join-Path $tempRoot 'ambient-filter-fired'
        $traceSentinel = Join-Path $tempRoot 'ambient-trace-fired'
        foreach ($directory in @(
            $gitRoot,
            $ambientHooksRoot,
            $ambientFilterRoot,
            $ambientGitDirectory,
            $ambientWorkTree,
            $ambientObjectDirectory,
            $ambientHome,
            $ambientXdg,
            $ambientExecPath
        )) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }

        # Inject harmless ambient hook/filter commands and repository redirects
        # as an adversarial regression. The isolated wrapper must suppress all
        # of them, and must restore the caller's exact environment afterward.
        $hookPath = Join-Path $ambientHooksRoot 'post-index-change'
        $hookContent = @'
#!/bin/sh
printf '%s\n' 'hook-fired' > "$MARKDOWN_MERGE_TEST_HOOK_SENTINEL"
'@
        [System.IO.File]::WriteAllText($hookPath, $hookContent, [System.Text.UTF8Encoding]::new($false))
        $filterPath = Join-Path $ambientFilterRoot 'clean-filter'
        $filterContent = @'
#!/bin/sh
printf '%s\n' 'filter-fired' > "$MARKDOWN_MERGE_TEST_FILTER_SENTINEL"
cat
'@
        [System.IO.File]::WriteAllText($filterPath, $filterContent, [System.Text.UTF8Encoding]::new($false))
        $ambientAttributes = Join-Path $ambientFilterRoot 'global-attributes'
        [System.IO.File]::WriteAllText(
            $ambientAttributes,
            "*.md filter=handoff-test`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $chmodCommand = Get-Command chmod -ErrorAction SilentlyContinue
        if ($null -ne $chmodCommand) {
            $chmodIsolationRoot = Join-Path $tempRoot 'chmod-isolation'
            $chmodResult = Invoke-PrivateMarkerBoundedProcess `
                -FileName $chmodCommand.Source `
                -Arguments @('+x', $hookPath, $filterPath) `
                -IsolationRoot $chmodIsolationRoot `
                -TimeoutMilliseconds 10000
            if ($chmodResult.ExitCode -ne 0 -or
                $chmodResult.TimedOut -or
                -not $chmodResult.ContainmentEstablished -or
                -not $chmodResult.TreeStopped -or
                -not $chmodResult.StreamsDrained) {
                Add-Failure "Expected bounded synthetic hook/filter chmod to exit 0. Output: $($chmodResult.Output.Trim())"
            }
        }

        $beforeFixtureEnvironment = Get-ProcessEnvironmentSnapshot
        $ambientHooksGitPath = $ambientHooksRoot.Replace([string][char]92, '/')
        $ambientAttributesGitPath = $ambientAttributes.Replace([string][char]92, '/')
        $filterGitPath = $filterPath.Replace([string][char]92, '/')
        $adversarialEnvironment = @{
            GIT_CONFIG_COUNT = '4'
            GIT_CONFIG_KEY_0 = 'core.hooksPath'
            GIT_CONFIG_VALUE_0 = $ambientHooksGitPath
            GIT_CONFIG_KEY_1 = 'core.attributesFile'
            GIT_CONFIG_VALUE_1 = $ambientAttributesGitPath
            GIT_CONFIG_KEY_2 = 'filter.handoff-test.clean'
            GIT_CONFIG_VALUE_2 = "sh `"$filterGitPath`""
            GIT_CONFIG_KEY_3 = 'filter.handoff-test.required'
            GIT_CONFIG_VALUE_3 = 'true'
            GIT_CONFIG_NOSYSTEM = '0'
            GIT_ATTR_NOSYSTEM = '0'
            GIT_CONFIG_GLOBAL = $ambientAttributesGitPath
            GIT_CONFIG_SYSTEM = $ambientAttributesGitPath
            GIT_DIR = $ambientGitDirectory
            GIT_WORK_TREE = $ambientWorkTree
            GIT_INDEX_FILE = $ambientIndexFile
            GIT_OBJECT_DIRECTORY = $ambientObjectDirectory
            GIT_ALTERNATE_OBJECT_DIRECTORIES = $ambientObjectDirectory
            GIT_EXEC_PATH = $ambientExecPath
            GIT_TRACE2_EVENT = $traceSentinel.Replace([string][char]92, '/')
            GIT_NO_REPLACE_OBJECTS = '0'
            GIT_NO_LAZY_FETCH = '0'
            GIT_MARKDOWN_MERGE_PRESENT_EMPTY = ''
            MARKDOWN_MERGE_TEST_HOOK_SENTINEL = $hookSentinel
            MARKDOWN_MERGE_TEST_FILTER_SENTINEL = $filterSentinel
            HOME = $ambientHome
            USERPROFILE = $ambientHome
            XDG_CONFIG_HOME = $ambientXdg
        }

        function Invoke-CheckedFixtureGit {
            param(
                [string]$FixtureRoot,
                [string[]]$Arguments,
                [string]$Context
            )

            $result = Invoke-IsolatedGit `
                -GitPath $gitCommand.Source `
                -WorkingDirectory $FixtureRoot `
                -IsolationRoot $gitIsolationRoot `
                -Arguments $Arguments `
                -InheritedEnvironment $adversarialEnvironment
            if ($result.ExitCode -ne 0 -or
                -not (Test-BoundedResultHealthy -Result $result)) {
                Add-Failure "$Context failed with exit $($result.ExitCode). Output: $($result.Output.Trim())"
            }
            return $result
        }

        function New-CheckedGitFixture {
            param([string]$Name)

            $fixtureRoot = Join-Path $tempRoot $Name
            New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
            [void](Invoke-CheckedFixtureGit `
                -FixtureRoot $fixtureRoot `
                -Arguments @('init', '--quiet') `
                -Context "Initialize $Name")
            return $fixtureRoot
        }

        # `git worktree add`が作る正常な`.git` fileを実物で通し、外部gitdirを
        # Git自身に解決させてもscan root・index・worktree unionが維持されることを確認する。
        $linkedMainRoot =
            New-CheckedGitFixture -Name 'linked-worktree-main'
        $linkedTrackedPath = Join-Path $linkedMainRoot 'linked.md'
        [IO.File]::WriteAllText(
            $linkedTrackedPath,
            'synthetic clean linked worktree content',
            [Text.UTF8Encoding]::new($false)
        )
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $linkedMainRoot `
            -Arguments @('add', '--', 'linked.md') `
            -Context 'Stage linked worktree base')
        $linkedSyntheticEmail = 'synthetic' + '@example.invalid'
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $linkedMainRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic',
                '-c',
                "user.email=$linkedSyntheticEmail",
                'commit',
                '--quiet',
                '-m',
                'synthetic linked worktree base'
            ) `
            -Context 'Commit linked worktree base')
        $linkedWorktreeRoot =
            Join-Path $tempRoot 'linked-worktree-checkout'
        $linkedAddResult = Invoke-CheckedFixtureGit `
            -FixtureRoot $linkedMainRoot `
            -Arguments @(
                'worktree',
                'add',
                '--quiet',
                '--detach',
                $linkedWorktreeRoot,
                'HEAD'
            ) `
            -Context 'Create linked worktree Gitfile fixture'
        $linkedGitfile = Join-Path $linkedWorktreeRoot '.git'
        if ($linkedAddResult.ExitCode -eq 0 -and
            (Test-Path -LiteralPath $linkedGitfile -PathType Leaf)) {
            $linkedMarker = ('g' + 'hp_') +
                'synthetic_linked_worktree_placeholder'
            [IO.File]::WriteAllText(
                (Join-Path $linkedWorktreeRoot 'linked.md'),
                "linked worktree marker: $linkedMarker",
                [Text.UTF8Encoding]::new($false)
            )
            $linkedScanResult =
                Invoke-Scanner -ScanPath $linkedWorktreeRoot
            if (-not (Test-BoundedResultHealthy `
                    -Result $linkedScanResult) -or
                $linkedScanResult.ExitCode -ne 1 -or
                $linkedScanResult.Output -notmatch
                    'git-index\+working-tree' -or
                $linkedScanResult.Output -notmatch
                    'linked\.md \[worktree\]' -or
                $linkedScanResult.Output.Contains($linkedMarker) -or
                $linkedScanResult.Output.Contains($linkedWorktreeRoot)) {
                Add-Failure "Expected a normal linked-worktree Gitfile to scan its unstaged worktree marker with a redacted relative path. Output: $($linkedScanResult.Output.Trim())"
            }
        } else {
            Add-Failure 'Expected git worktree add to create a normal .git file fixture.'
        }

        $gitInitResult = Invoke-IsolatedGit `
            -GitPath $gitCommand.Source `
            -WorkingDirectory $gitRoot `
            -IsolationRoot $gitIsolationRoot `
            -Arguments @('init', '--quiet') `
            -InheritedEnvironment $adversarialEnvironment
        if ($gitInitResult.ExitCode -ne 0 -or
            $gitInitResult.TimedOut -or
            -not $gitInitResult.ContainmentEstablished -or
            -not $gitInitResult.TreeStopped -or
            -not $gitInitResult.StreamsDrained) {
            Add-Failure "Expected isolated git init to exit 0. Output: $($gitInitResult.Output.Trim())"
        }
        Assert-ProcessEnvironmentUnchanged `
            -Expected $beforeFixtureEnvironment `
            -Context 'Isolated git init'

        # Preserve a valid clean alternate index. A later public-entrypoint
        # regression passes only GIT_INDEX_FILE; if the scanner trusts ambient
        # Git state, the real staged markers disappear and the test false-passes.
        $emptyIndexResult = Invoke-IsolatedGit `
            -GitPath $gitCommand.Source `
            -WorkingDirectory $gitRoot `
            -IsolationRoot $gitIsolationRoot `
            -Arguments @('read-tree', '--empty') `
            -InheritedEnvironment $adversarialEnvironment
        if ($emptyIndexResult.ExitCode -ne 0 -or
            -not (Test-BoundedResultHealthy -Result $emptyIndexResult)) {
            Add-Failure "Expected isolated empty index creation to exit 0. Output: $($emptyIndexResult.Output.Trim())"
        } else {
            Copy-Item `
                -LiteralPath (Join-Path $gitRoot '.git/index') `
                -Destination $ambientIndexFile `
                -Force
        }

        $nestedDirectory = Join-Path $gitRoot (Join-Path 'sub' 'deep')
        New-Item -ItemType Directory -Path $nestedDirectory -Force | Out-Null
        $nestedMarker = ('g' + 'hp_') + 'synthetic_nested_placeholder'
        Set-Content -LiteralPath (Join-Path $nestedDirectory 'leak.md') -Value "synthetic marker: $nestedMarker" -Encoding UTF8

        $dotfileMarker = ('xo' + 'xb-') + 'synthetic_dotfile_placeholder'
        Set-Content -LiteralPath (Join-Path $gitRoot '.editorconfig') -Value "synthetic marker: $dotfileMarker" -Encoding UTF8

        $trackedTextNames = @(
            'leak.env',
            'leak.pem',
            'leak.key',
            '.env',
            '.env.local',
            'NOTICE',
            '.hidden'
        )
        foreach ($trackedTextName in $trackedTextNames) {
            Set-Content `
                -LiteralPath (Join-Path $gitRoot $trackedTextName) `
                -Value "synthetic marker: $nestedMarker" `
                -Encoding UTF8
        }

        $gitAddResult = Invoke-IsolatedGit `
            -GitPath $gitCommand.Source `
            -WorkingDirectory $gitRoot `
            -IsolationRoot $gitIsolationRoot `
            -Arguments @('add', '-A') `
            -InheritedEnvironment $adversarialEnvironment
        if ($gitAddResult.ExitCode -ne 0 -or
            $gitAddResult.TimedOut -or
            -not $gitAddResult.ContainmentEstablished -or
            -not $gitAddResult.TreeStopped -or
            -not $gitAddResult.StreamsDrained) {
            Add-Failure "Expected isolated git add to exit 0. Output: $($gitAddResult.Output.Trim())"
        }
        Assert-ProcessEnvironmentUnchanged `
            -Expected $beforeFixtureEnvironment `
            -Context 'Isolated git add'

        # The scanner's own Git probes receive the same hostile clone and must
        # still inspect only the explicit temp repository.
        $gitResult = Invoke-Scanner `
            -ScanPath $gitRoot `
            -InheritedEnvironment $adversarialEnvironment
        Assert-ProcessEnvironmentUnchanged `
            -Expected $beforeFixtureEnvironment `
            -Context 'Isolated scanner child'

        if (Test-Path -LiteralPath $hookSentinel) {
            Add-Failure 'Expected isolated git fixture to suppress the injected ambient hook, but its sentinel was created.'
        }
        if (Test-Path -LiteralPath $filterSentinel) {
            Add-Failure 'Expected isolated git fixture to suppress the injected ambient clean filter, but its sentinel was created.'
        }
        if (Test-Path -LiteralPath $traceSentinel) {
            Add-Failure 'Expected isolated git fixture to suppress the injected trace output, but its sentinel was created.'
        }

        if ($null -eq $gitResult) {
            Add-Failure 'Expected the isolated scanner child to return a result.'
        } else {
            if ($gitResult.Output -notmatch
                'git-index\+working-tree') {
                Add-Failure "Expected the git fixture to scan the index and complete working tree. Output: $($gitResult.Output.Trim())"
            }
            if ($gitResult.ExitCode -eq 0) {
                Add-Failure 'Expected git-tracked nested and dotfile markers to fail the scan, but scanner exited 0.'
            }
            if ($gitResult.Output -notmatch 'sub/deep/leak\.md') {
                Add-Failure "Expected git-tracked output to list sub/deep/leak.md. Output: $($gitResult.Output.Trim())"
            }
            if ($gitResult.Output -notmatch '\.editorconfig') {
                Add-Failure "Expected git-tracked output to list .editorconfig. Output: $($gitResult.Output.Trim())"
            }
            foreach ($trackedTextName in $trackedTextNames) {
                if ($gitResult.Output -notmatch
                    [regex]::Escape($trackedTextName)) {
                    Add-Failure "Expected tracked regular text path $trackedTextName to be scanned. Output: $($gitResult.Output.Trim())"
                }
            }
            if ($gitResult.Output.Contains($nestedMarker) -or
                $gitResult.Output.Contains($dotfileMarker)) {
                Add-Failure 'Expected git-tracked findings to stay redacted, but a raw marker leaked into output.'
            }
        }

        # GIT_INDEX_FILE alone is a direct false-pass regression: the alternate
        # index is valid and empty, while the explicit repository index contains
        # both markers. The public scanner must ignore the ambient redirect.
        $ambientIndexOnlyResult = Invoke-Scanner `
            -ScanPath $gitRoot `
            -InheritedEnvironment @{
                GIT_INDEX_FILE = $ambientIndexFile
            }
        if ($ambientIndexOnlyResult.ExitCode -eq 0 -or
            $ambientIndexOnlyResult.Output -notmatch 'sub/deep/leak\.md' -or
            $ambientIndexOnlyResult.Output -notmatch '\.editorconfig') {
            Add-Failure "Expected the public scanner to ignore ambient GIT_INDEX_FILE. Output: $($ambientIndexOnlyResult.Output.Trim())"
        }

        # Passing a repository subdirectory as the scan root must fail closed.
        # It must never fall back to a partial working-tree scan.
        $rootMismatchResult = Invoke-Scanner -ScanPath (Join-Path $gitRoot 'sub')
        if ($rootMismatchResult.ExitCode -ne 2 -or
            $rootMismatchResult.Output -notmatch 'integrity: git-root-mismatch') {
            Add-Failure "Expected repository root mismatch to fail closed. Output: $($rootMismatchResult.Output.Trim())"
        }

        # Normalize the original fixture before exercising index/worktree union
        # states with one dedicated path.
        Set-Content `
            -LiteralPath (Join-Path $nestedDirectory 'leak.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath (Join-Path $gitRoot '.editorconfig') `
            -Value 'root = true' `
            -Encoding UTF8
        foreach ($trackedTextName in $trackedTextNames) {
            Set-Content `
                -LiteralPath (Join-Path $gitRoot $trackedTextName) `
                -Value 'synthetic clean content' `
                -Encoding UTF8
        }
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $gitRoot `
            -Arguments @('add', '-A') `
            -Context 'Stage normalized union fixture')

        # 019はtracked-onlyに狭めない。Git repository内のuntracked textも
        # repo固有のfull-working-tree契約として検出する。
        $untrackedPath = Join-Path $gitRoot 'untracked-marker.md'
        $untrackedMarker = ('g' + 'hp_') +
            'synthetic_untracked_placeholder'
        Set-Content `
            -LiteralPath $untrackedPath `
            -Value "untracked marker: $untrackedMarker" `
            -Encoding UTF8
        $untrackedResult = Invoke-Scanner -ScanPath $gitRoot
        if ($untrackedResult.ExitCode -eq 0 -or
            $untrackedResult.Output -notmatch
                'git-index\+working-tree' -or
            $untrackedResult.Output -notmatch
                'untracked-marker\.md') {
            Add-Failure "Expected untracked working-tree text to be scanned. Output: $($untrackedResult.Output.Trim())"
        }
        if ($untrackedResult.Output.Contains($untrackedMarker)) {
            Add-Failure 'Expected the untracked working-tree finding to stay redacted.'
        }
        Remove-Item -LiteralPath $untrackedPath -Force

        $unionPath = Join-Path $gitRoot 'union.md'
        $unionMarker = ('g' + 'hp_') + 'synthetic_union_placeholder'
        Set-Content `
            -LiteralPath $unionPath `
            -Value "staged marker: $unionMarker" `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $gitRoot `
            -Arguments @('add', '--', 'union.md') `
            -Context 'Stage index-only marker')
        Set-Content `
            -LiteralPath $unionPath `
            -Value 'synthetic clean worktree content' `
            -Encoding UTF8
        $indexOnlyResult = Invoke-Scanner -ScanPath $gitRoot
        if ($indexOnlyResult.ExitCode -eq 0 -or
            $indexOnlyResult.Output -notmatch 'union\.md \[index\]') {
            Add-Failure "Expected staged-only index bytes to be scanned. Output: $($indexOnlyResult.Output.Trim())"
        }

        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $gitRoot `
            -Arguments @('add', '--', 'union.md') `
            -Context 'Stage clean union content')
        Set-Content `
            -LiteralPath $unionPath `
            -Value "worktree marker: $unionMarker" `
            -Encoding UTF8
        $worktreeOnlyResult = Invoke-Scanner -ScanPath $gitRoot
        if ($worktreeOnlyResult.ExitCode -eq 0 -or
            $worktreeOnlyResult.Output -notmatch 'union\.md \[worktree\]') {
            Add-Failure "Expected unstaged worktree bytes to be scanned. Output: $($worktreeOnlyResult.Output.Trim())"
        }

        Set-Content `
            -LiteralPath $unionPath `
            -Value "missing worktree marker: $unionMarker" `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $gitRoot `
            -Arguments @('add', '--', 'union.md') `
            -Context 'Stage missing-worktree marker')
        Remove-Item -LiteralPath $unionPath -Force
        $missingWorktreeResult = Invoke-Scanner -ScanPath $gitRoot
        if ($missingWorktreeResult.ExitCode -eq 0 -or
            $missingWorktreeResult.Output -notmatch
            'union\.md \[index; worktree missing\]') {
            Add-Failure "Expected a missing worktree file to retain index scanning. Output: $($missingWorktreeResult.Output.Trim())"
        }

        # Replace the real index atomically after the first raw stage listing
        # has completed. A test-only scanner copy pauses at that exact boundary
        # so the fixture proves the final byte comparison without scheduler
        # timing assumptions or production-only sleeps.
        $driftRoot = New-CheckedGitFixture -Name 'index-drift'
        for ($driftFileIndex = 0; $driftFileIndex -lt 24; $driftFileIndex++) {
            $driftFileName = 'drift-{0:d2}.md' -f $driftFileIndex
            $driftContent = ('x' * 32768) + "-$driftFileIndex"
            [IO.File]::WriteAllText(
                (Join-Path $driftRoot $driftFileName),
                $driftContent,
                [Text.UTF8Encoding]::new($false)
            )
        }
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $driftRoot `
            -Arguments @('add', '-A') `
            -Context 'Stage clean drift index')
        $driftIndexPath = Join-Path $driftRoot '.git/index'
        $cleanIndexTemplate = Join-Path $driftRoot '.git/clean-index-template'
        $changedIndexTemplate = Join-Path `
            $driftRoot `
            '.git/changed-index-template'
        [IO.File]::Copy($driftIndexPath, $cleanIndexTemplate, $true)
        $driftMarker = ('g' + 'hp_') + 'synthetic_index_drift'
        [IO.File]::WriteAllText(
            (Join-Path $driftRoot 'drift-00.md'),
            "mutated index marker: $driftMarker",
            [Text.UTF8Encoding]::new($false)
        )
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $driftRoot `
            -Arguments @('add', '--', 'drift-00.md') `
            -Context 'Stage changed drift index')
        [IO.File]::Copy($driftIndexPath, $changedIndexTemplate, $true)
        [IO.File]::WriteAllText(
            (Join-Path $driftRoot 'drift-00.md'),
            ('x' * 32768) + '-0',
            [Text.UTF8Encoding]::new($false)
        )

        [IO.File]::Copy($cleanIndexTemplate, $driftIndexPath, $true)
        $swapIndexPath = Join-Path $driftRoot '.git/index-swap'
        $backupIndexPath = Join-Path $driftRoot '.git/index-backup'
        [IO.File]::Copy($changedIndexTemplate, $swapIndexPath, $true)
        if ([IO.File]::Exists($backupIndexPath)) {
            [IO.File]::Delete($backupIndexPath)
        }

        # Instrument only a disposable scanner copy. The production scanner
        # has no synchronization hooks or caller-controlled delay surface.
        $driftScannerDirectory = Join-Path $tempRoot 'drift-scanner'
        New-Item `
            -ItemType Directory `
            -Path $driftScannerDirectory `
            -Force | Out-Null
        $instrumentedScanner = Join-Path `
            $driftScannerDirectory `
            'scan-private-markers.ps1'
        Copy-Item `
            -LiteralPath $processSupport `
            -Destination (Join-Path `
                $driftScannerDirectory `
                'private-marker-process.ps1')
        Copy-Item `
            -LiteralPath $scanConfig `
            -Destination (Join-Path `
                $driftScannerDirectory `
                'private-scan-config.ps1')
        $driftReadyPath = Join-Path $tempRoot 'index-drift-ready'
        $driftReleasePath = Join-Path $tempRoot 'index-drift-release'
        $driftAnchor = @'
if ($usingGitIndex) {
    $scanMode = 'git-index+working-tree'
'@
        $driftScannerSource = [IO.File]::ReadAllText($scanner)
        $driftAnchorOffset = $driftScannerSource.IndexOf(
            $driftAnchor,
            [StringComparison]::Ordinal
        )
        if ($driftAnchorOffset -lt 0 -or
            $driftScannerSource.IndexOf(
                $driftAnchor,
                $driftAnchorOffset + $driftAnchor.Length,
                [StringComparison]::Ordinal
            ) -ge 0) {
            throw 'Cannot locate the unique index-drift synchronization anchor.'
        }
        $driftSyncInjection = @'
# Test-copy only: publish that snapshot construction and its first raw index
# recheck are complete, then pause before content matching. The production
# scanner has no synchronization surface.
[IO.File]::WriteAllText(
    '__DRIFT_READY__',
    'ready',
    [Text.UTF8Encoding]::new($false)
)
$driftReleased = $false
for ($driftSyncAttempt = 0;
    $driftSyncAttempt -lt 1500;
    $driftSyncAttempt++) {
    if ([IO.File]::Exists('__DRIFT_RELEASE__')) {
        $driftReleased = $true
        break
    }
    Start-Sleep -Milliseconds 10
}
if (-not $driftReleased) {
    Stop-ScanIntegrityFailure -Reason 'test-index-drift-sync'
}

'@
        $driftSyncInjection = $driftSyncInjection.Replace(
            '__DRIFT_READY__',
            $driftReadyPath.Replace("'", "''")
        ).Replace(
            '__DRIFT_RELEASE__',
            $driftReleasePath.Replace("'", "''")
        )
        $driftScannerSource = $driftScannerSource.Replace(
            $driftAnchor,
            $driftSyncInjection + $driftAnchor
        )
        [IO.File]::WriteAllText(
            $instrumentedScanner,
            $driftScannerSource,
            # instrumentation copyも本体と同じPS5.1 encoding契約を維持する。
            [Text.UTF8Encoding]::new($true)
        )

        # The mutator starts first but cannot replace the index until the
        # instrumented scanner publishes its post-snapshot signal.
        $escapedDriftReady = $driftReadyPath.Replace("'", "''")
        $escapedDriftRelease = $driftReleasePath.Replace("'", "''")
        $escapedSwapIndex = $swapIndexPath.Replace("'", "''")
        $escapedDriftIndex = $driftIndexPath.Replace("'", "''")
        $escapedBackupIndex = $backupIndexPath.Replace("'", "''")
        $mutatorScript = @"
`$readyObserved = `$false
for (`$attempt = 0; `$attempt -lt 1500; `$attempt++) {
    if ([IO.File]::Exists('$escapedDriftReady')) {
        `$readyObserved = `$true
        break
    }
    Start-Sleep -Milliseconds 10
}
if (-not `$readyObserved) {
    exit 3
}
[IO.File]::Replace(
    '$escapedSwapIndex',
    '$escapedDriftIndex',
    '$escapedBackupIndex'
)
[IO.File]::WriteAllText(
    '$escapedDriftRelease',
    'release',
    [Text.UTF8Encoding]::new(`$false)
)
"@
        $mutatorEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($mutatorScript)
        )
        $mutatorArguments = @('-NoProfile')
        if ($PSVersionTable.PSVersion.Major -le 5 -and
            $runtimeIsWindows) {
            $mutatorArguments += @('-ExecutionPolicy', 'Bypass')
        }
        $mutatorArguments += @('-EncodedCommand', $mutatorEncoded)
        $mutatorInfo = New-Object Diagnostics.ProcessStartInfo
        $mutatorInfo.FileName = $currentPowerShellExecutable
        $mutatorInfo.UseShellExecute = $false
        $mutatorInfo.CreateNoWindow = $true
        $mutatorArgumentList =
            $mutatorInfo.PSObject.Properties['ArgumentList']
        if ($null -ne $mutatorArgumentList) {
            foreach ($mutatorArgument in $mutatorArguments) {
                $mutatorInfo.ArgumentList.Add($mutatorArgument)
            }
        } else {
            $mutatorInfo.Arguments = (
                $mutatorArguments | ForEach-Object {
                    ConvertTo-PrivateMarkerProcessArgument -Argument $_
                }
            ) -join ' '
        }
        $mutator = [Diagnostics.Process]::Start($mutatorInfo)
        $originalScanner = $scanner
        try {
            $scanner = $instrumentedScanner
            $driftResult = Invoke-Scanner -ScanPath $driftRoot
            if (-not $mutator.WaitForExit(20000)) {
                $mutator.Kill()
                [void]$mutator.WaitForExit(5000)
                Add-Failure 'Expected the bounded index mutator to exit.'
            } elseif ($mutator.ExitCode -ne 0) {
                Add-Failure 'Expected the atomic index mutation to succeed.'
            }
        }
        finally {
            $scanner = $originalScanner
            $mutator.Dispose()
        }
        [IO.File]::Copy($cleanIndexTemplate, $driftIndexPath, $true)
        if ($driftResult.ExitCode -ne 2 -or
            $driftResult.Output -notmatch 'integrity: git-index-drift') {
            Add-Failure 'Expected an actual staged-index mutation to be caught by the final raw metadata comparison.'
        }

        # CE_INTENT_TO_ADD can change while mode/OID/stage/path bytes remain
        # identical. Swap an actual normal empty-file index for its ITA form
        # after the first stage recheck; only the final raw debug comparison can
        # detect this flags-only mutation.
        $flagDriftRoot = New-CheckedGitFixture -Name 'index-flag-drift'
        $flagDriftWorktreePath = Join-Path $flagDriftRoot 'intent.md'
        [IO.File]::WriteAllBytes($flagDriftWorktreePath, [byte[]]@())
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $flagDriftRoot `
            -Arguments @('add', '--', 'intent.md') `
            -Context 'Stage normal empty flag-drift entry')
        $flagDriftIndexPath = Join-Path $flagDriftRoot '.git/index'
        $normalFlagIndexTemplate = Join-Path `
            $flagDriftRoot `
            '.git/normal-flag-index-template'
        $intentFlagIndexTemplate = Join-Path `
            $flagDriftRoot `
            '.git/intent-flag-index-template'
        [IO.File]::Copy(
            $flagDriftIndexPath,
            $normalFlagIndexTemplate,
            $true
        )
        $normalFlagStage = Invoke-CheckedFixtureGit `
            -FixtureRoot $flagDriftRoot `
            -Arguments @('ls-files', '-z', '--stage', '--') `
            -Context 'Read normal flag-drift stage bytes'
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $flagDriftRoot `
            -Arguments @('rm', '--cached', '--', 'intent.md') `
            -Context 'Remove normal empty entry before ITA')
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $flagDriftRoot `
            -Arguments @('add', '--intent-to-add', '--', 'intent.md') `
            -Context 'Create flags-only ITA entry')
        $intentFlagStage = Invoke-CheckedFixtureGit `
            -FixtureRoot $flagDriftRoot `
            -Arguments @('ls-files', '-z', '--stage', '--') `
            -Context 'Read ITA flag-drift stage bytes'
        if ([Convert]::ToBase64String($normalFlagStage.StdoutBytes) -cne
            [Convert]::ToBase64String($intentFlagStage.StdoutBytes)) {
            Add-Failure 'Expected normal empty and ITA stage metadata bytes to be identical for the flags-only drift fixture.'
        }
        [IO.File]::Copy(
            $flagDriftIndexPath,
            $intentFlagIndexTemplate,
            $true
        )
        [IO.File]::Copy(
            $normalFlagIndexTemplate,
            $flagDriftIndexPath,
            $true
        )
        $flagSwapIndexPath = Join-Path `
            $flagDriftRoot `
            '.git/index-flag-swap'
        $flagBackupIndexPath = Join-Path `
            $flagDriftRoot `
            '.git/index-flag-backup'
        [IO.File]::Copy(
            $intentFlagIndexTemplate,
            $flagSwapIndexPath,
            $true
        )
        foreach ($signalPath in @(
            $driftReadyPath,
            $driftReleasePath,
            $flagBackupIndexPath
        )) {
            [IO.File]::Delete($signalPath)
        }
        $flagMutator = Start-SynchronizedIndexMutator `
            -ReadyPath $driftReadyPath `
            -ReleasePath $driftReleasePath `
            -SwapPath $flagSwapIndexPath `
            -IndexPath $flagDriftIndexPath `
            -BackupPath $flagBackupIndexPath
        $originalScanner = $scanner
        try {
            $scanner = $instrumentedScanner
            $flagDriftResult = Invoke-Scanner -ScanPath $flagDriftRoot
            if (-not $flagMutator.WaitForExit(20000)) {
                $flagMutator.Kill()
                [void]$flagMutator.WaitForExit(5000)
                Add-Failure 'Expected the bounded flag mutator to exit.'
            } elseif ($flagMutator.ExitCode -ne 0) {
                Add-Failure 'Expected the atomic flags-only mutation to succeed.'
            }
        }
        finally {
            $scanner = $originalScanner
            $flagMutator.Dispose()
        }
        [IO.File]::Copy(
            $normalFlagIndexTemplate,
            $flagDriftIndexPath,
            $true
        )
        if ($flagDriftResult.ExitCode -ne 2 -or
            $flagDriftResult.Output -notmatch
            'integrity: git-index-drift') {
            Add-Failure 'Expected a flags-only index mutation to be caught by the final raw debug comparison.'
        }

        # A tracked local marker configuration is itself a publication leak
        # boundary, regardless of whether its contents look sensitive.
        $trackedLocalRoot = New-CheckedGitFixture -Name 'tracked-local-marker'
        Set-Content `
            -LiteralPath (Join-Path $trackedLocalRoot '.private-markers.local') `
            -Value 'synthetic-local-only-rule' `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $trackedLocalRoot `
            -Arguments @('add', '-f', '--', '.private-markers.local') `
            -Context 'Force-add local marker configuration')
        $trackedLocalResult = Invoke-Scanner -ScanPath $trackedLocalRoot
        if ($trackedLocalResult.ExitCode -ne 2 -or
            $trackedLocalResult.Output -notmatch
            'integrity: git-index-local-marker') {
            Add-Failure "Expected tracked local marker configuration to fail closed. Output: $($trackedLocalResult.Output.Trim())"
        }

        # Intent-to-add entries carry CE_INTENT_TO_ADD even though current Git
        # exposes the normal empty-blob OID. Reject both the present `.A` and
        # missing `.D` worktree states from the direct extended flag.
        $intentRoot = New-CheckedGitFixture -Name 'intent-to-add'
        Set-Content `
            -LiteralPath (Join-Path $intentRoot 'intent.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $intentRoot `
            -Arguments @('add', '--intent-to-add', '--', 'intent.md') `
            -Context 'Create intent-to-add entry')
        $intentResult = Invoke-Scanner -ScanPath $intentRoot
        if ($intentResult.ExitCode -ne 2 -or
            $intentResult.Output -notmatch
            'integrity: git-index-intent-to-add') {
            Add-Failure "Expected intent-to-add index entry to fail closed. Output: $($intentResult.Output.Trim())"
        }
        [IO.File]::Delete((Join-Path $intentRoot 'intent.md'))
        $missingIntentResult = Invoke-Scanner -ScanPath $intentRoot
        if ($missingIntentResult.ExitCode -ne 2 -or
            $missingIntentResult.Output -notmatch
            'integrity: git-index-intent-to-add') {
            Add-Failure "Expected missing intent-to-add index entry to fail closed. Output: $($missingIntentResult.Output.Trim())"
        }

        # A genuinely staged empty file has the same blob OID but not the
        # extended flag, so the direct flag parser must not reject it.
        $stagedEmptyRoot = New-CheckedGitFixture -Name 'staged-empty'
        [IO.File]::WriteAllBytes(
            (Join-Path $stagedEmptyRoot 'empty.md'),
            [byte[]]@()
        )
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $stagedEmptyRoot `
            -Arguments @('add', '--', 'empty.md') `
            -Context 'Stage genuine empty file')
        $stagedEmptyResult = Invoke-Scanner -ScanPath $stagedEmptyRoot
        if ($stagedEmptyResult.ExitCode -ne 0) {
            Add-Failure "Expected a genuine staged empty file to pass. Output: $($stagedEmptyResult.Output.Trim())"
        }

        # A gitlink has no text blob at the path and may hide a nested external
        # repository. A synthetic info-only cache entry avoids any network.
        $gitlinkRoot = New-CheckedGitFixture -Name 'gitlink'
        $syntheticCommitOid = ('1' * 40)
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $gitlinkRoot `
            -Arguments @(
                'update-index',
                '--add',
                '--info-only',
                '--cacheinfo',
                "160000,$syntheticCommitOid,vendor"
            ) `
            -Context 'Create synthetic gitlink entry')
        $gitlinkResult = Invoke-Scanner -ScanPath $gitlinkRoot
        if ($gitlinkResult.ExitCode -ne 2 -or
            $gitlinkResult.Output -notmatch 'integrity: git-index-gitlink') {
            Add-Failure "Expected gitlink index entry to fail closed. Output: $($gitlinkResult.Output.Trim())"
        }

        # Index-mode symlinks are scanned from their raw immutable blob only
        # when no worktree link exists, so no external target is followed.
        $indexLinkRoot = New-CheckedGitFixture -Name 'index-symlink'
        $linkSource = Join-Path $indexLinkRoot 'link-source.bin'
        $linkMarker = ('g' + 'hp_') + 'synthetic_link_target'
        [IO.File]::WriteAllText(
            $linkSource,
            "synthetic/$linkMarker",
            [Text.UTF8Encoding]::new($false)
        )
        $linkHashResult = Invoke-CheckedFixtureGit `
            -FixtureRoot $indexLinkRoot `
            -Arguments @('hash-object', '-w', '--', 'link-source.bin') `
            -Context 'Create synthetic symlink blob'
        $linkOid = [Text.Encoding]::ASCII.GetString(
            $linkHashResult.StdoutBytes
        ).Trim()
        if ($linkOid -notmatch '^[0-9a-f]{40,64}$') {
            Add-Failure 'Expected a valid object ID for the synthetic symlink blob.'
        } else {
            [void](Invoke-CheckedFixtureGit `
                -FixtureRoot $indexLinkRoot `
                -Arguments @(
                    'update-index',
                    '--add',
                    '--cacheinfo',
                    "120000,$linkOid,synthetic-link.md"
                ) `
                -Context 'Create synthetic index symlink')
            $indexLinkResult = Invoke-Scanner -ScanPath $indexLinkRoot
            if ($indexLinkResult.ExitCode -eq 0 -or
                $indexLinkResult.Output -notmatch
                'synthetic-link\.md \[index symlink; worktree missing\]') {
                Add-Failure "Expected missing worktree symlink to scan its index blob. Output: $($indexLinkResult.Output.Trim())"
            }
        }

        # A reparse/symlink directory in a tracked worktree path must be
        # rejected before its external leaf is opened.
        $reparseRoot = New-CheckedGitFixture -Name 'reparse-ancestor'
        $trackedDirectory = Join-Path $reparseRoot 'linked'
        New-Item -ItemType Directory -Path $trackedDirectory | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $reparseRoot `
            -Arguments @('add', '--', 'linked/leak.md') `
            -Context 'Stage reparse ancestor fixture')
        $externalDirectory = Join-Path $tempRoot 'reparse-external-target'
        Move-Item `
            -LiteralPath $trackedDirectory `
            -Destination $externalDirectory
        $externalMarker = ('g' + 'hp_') + 'synthetic_external_target'
        Set-Content `
            -LiteralPath (Join-Path $externalDirectory 'leak.md') `
            -Value "external marker: $externalMarker" `
            -Encoding UTF8
        try {
            if ($runtimeIsWindows) {
                New-Item `
                    -ItemType Junction `
                    -Path $trackedDirectory `
                    -Target $externalDirectory |
                    Out-Null
            } else {
                New-Item `
                    -ItemType SymbolicLink `
                    -Path $trackedDirectory `
                    -Target $externalDirectory |
                    Out-Null
            }
            $reparseResult = Invoke-Scanner -ScanPath $reparseRoot
            if ($reparseResult.ExitCode -ne 2 -or
                $reparseResult.Output -notmatch
                'integrity: worktree-reparse-path' -or
                $reparseResult.Output.Contains($externalMarker)) {
                Add-Failure "Expected a reparse ancestor to fail before external content is read. Output: $($reparseResult.Output.Trim())"
            }
        }
        catch {
            Add-Failure 'Expected the synthetic reparse ancestor fixture to be creatable.'
        }

        # Replace refs can redirect cat-file away from the exact staged object.
        # The hermetic child environment must force the original marker blob.
        $replaceRoot = New-CheckedGitFixture -Name 'replace-object'
        $replacePath = Join-Path $replaceRoot 'replace.md'
        $replaceMarker = ('g' + 'hp_') + 'synthetic_replace_original'
        Set-Content `
            -LiteralPath $replacePath `
            -Value "original marker: $replaceMarker" `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $replaceRoot `
            -Arguments @('add', '--', 'replace.md') `
            -Context 'Stage replace-ref marker')
        $originalOidResult = Invoke-CheckedFixtureGit `
            -FixtureRoot $replaceRoot `
            -Arguments @('rev-parse', ':replace.md') `
            -Context 'Resolve original marker object'
        $originalOid = [Text.Encoding]::ASCII.GetString(
            $originalOidResult.StdoutBytes
        ).Trim()
        $cleanBlobPath = Join-Path $replaceRoot 'clean-source.bin'
        [IO.File]::WriteAllText(
            $cleanBlobPath,
            'synthetic clean replacement',
            [Text.UTF8Encoding]::new($false)
        )
        $cleanOidResult = Invoke-CheckedFixtureGit `
            -FixtureRoot $replaceRoot `
            -Arguments @('hash-object', '-w', '--', 'clean-source.bin') `
            -Context 'Create clean replacement object'
        $cleanOid = [Text.Encoding]::ASCII.GetString(
            $cleanOidResult.StdoutBytes
        ).Trim()
        if ($originalOid -notmatch '^[0-9a-f]{40,64}$' -or
            $cleanOid -notmatch '^[0-9a-f]{40,64}$') {
            Add-Failure 'Expected valid object IDs for the replace-ref regression.'
        } else {
            $replaceRefs = Join-Path $replaceRoot '.git/refs/replace'
            New-Item -ItemType Directory -Path $replaceRefs -Force | Out-Null
            [IO.File]::WriteAllText(
                (Join-Path $replaceRefs $originalOid),
                "$cleanOid`n",
                [Text.UTF8Encoding]::new($false)
            )
            Remove-Item -LiteralPath $replacePath -Force
            $replaceResult = Invoke-Scanner -ScanPath $replaceRoot
            if ($replaceResult.ExitCode -eq 0 -or
                $replaceResult.Output -notmatch
                'replace\.md \[index; worktree missing\]') {
                Add-Failure "Expected replace refs to be disabled while scanning the original index blob. Output: $($replaceResult.Output.Trim())"
            }
        }

        # A corrupted index must stop at the Git boundary. Do not treat a
        # failed ls-files parse as an empty repository.
        $corruptRoot = New-CheckedGitFixture -Name 'corrupt-index'
        Set-Content `
            -LiteralPath (Join-Path $corruptRoot 'tracked.md') `
            -Value 'synthetic clean content' `
            -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $corruptRoot `
            -Arguments @('add', '--', 'tracked.md') `
            -Context 'Stage corrupt-index fixture')
        [IO.File]::WriteAllBytes(
            (Join-Path $corruptRoot '.git/index'),
            [byte[]](1, 2, 3, 4, 5, 6, 7)
        )
        $corruptResult = Invoke-Scanner -ScanPath $corruptRoot
        if ($corruptResult.ExitCode -ne 2 -or
            $corruptResult.Output -notmatch 'integrity: git-index-list') {
            Add-Failure "Expected a corrupt index to fail closed. Output: $($corruptResult.Output.Trim())"
        }

        # Build an actual unmerged index so stages 1-3 cannot be mistaken for a
        # normal stage-0 path.
        $conflictRoot = New-CheckedGitFixture -Name 'unmerged-index'
        $conflictPath = Join-Path $conflictRoot 'conflict.md'
        $syntheticEmail = 'synthetic' + '@example.invalid'
        Set-Content -LiteralPath $conflictPath -Value 'base' -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -Context 'Stage conflict base')
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic',
                '-c',
                "user.email=$syntheticEmail",
                'commit',
                '--quiet',
                '-m',
                'base'
            ) `
            -Context 'Commit conflict base')
        $branchResult = Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('branch', '--show-current') `
            -Context 'Resolve default branch'
        $defaultBranch = [Text.Encoding]::UTF8.GetString(
            $branchResult.StdoutBytes
        ).Trim()
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('checkout', '--quiet', '-b', 'synthetic-side') `
            -Context 'Create conflict side branch')
        Set-Content -LiteralPath $conflictPath -Value 'side' -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -Context 'Stage conflict side')
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic',
                '-c',
                "user.email=$syntheticEmail",
                'commit',
                '--quiet',
                '-m',
                'side'
            ) `
            -Context 'Commit conflict side')
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('checkout', '--quiet', $defaultBranch) `
            -Context 'Return to default branch')
        Set-Content -LiteralPath $conflictPath -Value 'main' -Encoding UTF8
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -Context 'Stage conflict main')
        [void](Invoke-CheckedFixtureGit `
            -FixtureRoot $conflictRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic',
                '-c',
                "user.email=$syntheticEmail",
                'commit',
                '--quiet',
                '-m',
                'main'
            ) `
            -Context 'Commit conflict main')
        $mergeResult = Invoke-IsolatedGit `
            -GitPath $gitCommand.Source `
            -WorkingDirectory $conflictRoot `
            -IsolationRoot $gitIsolationRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic',
                '-c',
                "user.email=$syntheticEmail",
                'merge',
                '--no-edit',
                'synthetic-side'
            ) `
            -InheritedEnvironment $adversarialEnvironment
        if ($mergeResult.ExitCode -eq 0 -or
            -not (Test-BoundedResultHealthy -Result $mergeResult)) {
            Add-Failure "Expected the synthetic branch merge to produce an unmerged index. Output: $($mergeResult.Output.Trim())"
        } else {
            $unmergedResult = Invoke-CheckedFixtureGit `
                -FixtureRoot $conflictRoot `
                -Arguments @('ls-files', '--unmerged', '--') `
                -Context 'Inspect synthetic unmerged index'
            if ($unmergedResult.StdoutBytes.Length -eq 0) {
                Add-Failure "Expected merge failure to leave unmerged index stages. Merge output: $($mergeResult.Output.Trim())"
            } else {
                $conflictResult = Invoke-Scanner -ScanPath $conflictRoot
                if ($conflictResult.ExitCode -ne 2 -or
                    $conflictResult.Output -notmatch
                    'integrity: git-index-conflict') {
                    Add-Failure "Expected an unmerged index to fail closed. Output: $($conflictResult.Output.Trim())"
                }
            }
        }

        if (-not $runtimeIsWindows) {
            # POSIX permits control characters in file names. Findings must
            # escape them so a path cannot forge extra CI log lines.
            $controlRoot = New-CheckedGitFixture -Name 'control-path'
            $controlName = 'control' + [char]10 + 'name.md'
            $controlMarker = ('g' + 'hp_') + 'synthetic_control_path'
            Set-Content `
                -LiteralPath (Join-Path $controlRoot $controlName) `
                -Value "synthetic marker: $controlMarker" `
                -Encoding UTF8
            [void](Invoke-CheckedFixtureGit `
                -FixtureRoot $controlRoot `
                -Arguments @('add', '-A') `
                -Context 'Stage control-character path')
            $controlResult = Invoke-Scanner -ScanPath $controlRoot
            if ($controlResult.ExitCode -eq 0 -or
                $controlResult.Output -notmatch
                'control\\u000aname\.md') {
                Add-Failure "Expected control characters in displayed paths to be escaped. Output: $($controlResult.Output.Trim())"
            }

            # Feed three malformed ls-files byte streams through the public
            # entrypoint. The fake executable is a local synthetic fixture;
            # no repository content or external command is consulted.
            $fakeGitDirectory = Join-Path $tempRoot 'fake-git-bin'
            $fakeGitRoot = Join-Path $tempRoot 'fake-git-root'
            New-Item -ItemType Directory -Path $fakeGitDirectory | Out-Null
            New-Item -ItemType Directory -Path $fakeGitRoot | Out-Null
            $fakeGitPath = Join-Path $fakeGitDirectory 'git'
            $fakeGitScript = @'
#!/bin/sh
IFS= read -r fake_root < "${0}.root" || exit 90
IFS= read -r fake_mode < "${0}.mode" || exit 91
case "$*" in
  *"rev-parse --show-toplevel"*)
    printf '%s\n' "$fake_root"
    ;;
  *"ls-files -z --stage --debug"*)
    case "$fake_mode" in
      header)
        printf 'bad-header\tfile.md\0  ctime: 0:0\n  mtime: 0:0\n  dev: 0\tino: 0\n  uid: 0\tgid: 0\n  size: 0\tflags: 0\n'
        ;;
      path)
        printf '100644 1111111111111111111111111111111111111111 0\t../escape.md\0  ctime: 0:0\n  mtime: 0:0\n  dev: 0\tino: 0\n  uid: 0\tgid: 0\n  size: 0\tflags: 0\n'
        ;;
    esac
    ;;
  *"ls-files -z --stage"*)
    case "$fake_mode" in
      nul)
        printf '100644 1111111111111111111111111111111111111111 0\tfile.md'
        ;;
      header)
        printf 'bad-header\tfile.md\0'
        ;;
      path)
        printf '100644 1111111111111111111111111111111111111111 0\t../escape.md\0'
        ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
'@
            [IO.File]::WriteAllText(
                $fakeGitPath,
                $fakeGitScript,
                [Text.UTF8Encoding]::new($false)
            )
            $fakeGitRootControl = $fakeGitPath + '.root'
            $fakeGitModeControl = $fakeGitPath + '.mode'
            [IO.File]::WriteAllText(
                $fakeGitRootControl,
                $fakeGitRoot + "`n",
                [Text.UTF8Encoding]::new($false)
            )
            $fakeChmodResult = Invoke-PrivateMarkerBoundedProcess `
                -FileName $chmodCommand.Source `
                -Arguments @('+x', $fakeGitPath) `
                -IsolationRoot (Join-Path $tempRoot 'fake-git-chmod') `
                -TimeoutMilliseconds 10000
            if ($fakeChmodResult.ExitCode -ne 0 -or
                -not (Test-BoundedResultHealthy -Result $fakeChmodResult)) {
                Add-Failure 'Expected the synthetic fake Git fixture to be executable.'
            } else {
                $fakePath = $fakeGitDirectory +
                    [IO.Path]::PathSeparator +
                    $env:PATH
                foreach ($malformedCase in @(
                    @{
                        Mode = 'nul'
                        Reason = 'git-index-nul'
                    },
                    @{
                        Mode = 'header'
                        Reason = 'git-index-header'
                    },
                    @{
                        Mode = 'path'
                        Reason = 'git-index-path'
                    }
                )) {
                    [IO.File]::WriteAllText(
                        $fakeGitModeControl,
                        [string]$malformedCase.Mode + "`n",
                        [Text.UTF8Encoding]::new($false)
                    )
                    $malformedResult = Invoke-Scanner `
                        -ScanPath $fakeGitRoot `
                        -InheritedEnvironment @{
                            PATH = $fakePath
                        }
                    if ($malformedResult.ExitCode -ne 2 -or
                        $malformedResult.Output -notmatch
                        ("integrity: " +
                            [regex]::Escape($malformedCase.Reason))) {
                        Add-Failure "Expected malformed $($malformedCase.Mode) index output to fail closed. Output: $($malformedResult.Output.Trim())"
                    }
                }
            }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Private marker scan self-test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host 'Private marker scan self-test passed.'
exit 0
