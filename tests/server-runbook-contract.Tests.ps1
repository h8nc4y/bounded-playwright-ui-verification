param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Add-ContractViolation {
  param(
    [System.Collections.Generic.List[string]]$Violations,
    [string]$Message
  )

  $Violations.Add($Message) | Out-Null
}

function Get-StrictUtf8LfFileText {
  param(
    [string]$Path,
    [string]$Description
  )

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) {
    throw "$Description must not be empty."
  }
  if ($bytes.Length -ge 3 -and
    $bytes[0] -eq 0xEF -and
    $bytes[1] -eq 0xBB -and
    $bytes[2] -eq 0xBF) {
    throw "$Description must use UTF-8 without BOM."
  }
  if ($bytes -contains 0x00) {
    throw "$Description must not contain NUL."
  }
  if ($bytes -contains 0x0D) {
    throw "$Description must use LF without CR."
  }
  if ($bytes[$bytes.Length - 1] -ne 0x0A) {
    throw "$Description must end with one LF."
  }
  try {
    return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  } catch {
    throw "$Description must be strict UTF-8."
  }
}

function Test-OrdinalStringEquals {
  param(
    [AllowNull()][string]$Left,
    [AllowNull()][string]$Right
  )

  return [string]::Equals(
    $Left,
    $Right,
    [System.StringComparison]::Ordinal
  )
}

function Test-IdentifierEquals {
  param(
    [AllowNull()][string]$Left,
    [AllowNull()][string]$Right
  )

  return [string]::Equals(
    $Left,
    $Right,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Test-IdentifierInSet {
  param(
    [AllowNull()][string]$Value,
    [string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    if (Test-IdentifierEquals $Value $candidate) {
      return $true
    }
  }
  return $false
}

function Test-OrdinalStringInSet {
  param(
    [AllowNull()][string]$Value,
    [string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    if (Test-OrdinalStringEquals $Value $candidate) {
      return $true
    }
  }
  return $false
}

function Get-CommonMarkFenceScan {
  param([string]$Markdown)

  $blocks = New-Object System.Collections.Generic.List[object]
  $activeFence = $null
  $unclosedFenceCount = 0
  $ambiguousFenceLikeCount = 0
  $lineStart = 0

  # CommonMarkのfenced code基本形をline単位でparseし、fence文字・長さ・indentを追跡する。
  while ($lineStart -lt $Markdown.Length) {
    $newlineIndex = $Markdown.IndexOf(
      "`n",
      $lineStart,
      [System.StringComparison]::Ordinal
    )
    if ($newlineIndex -lt 0) {
      $lineEnd = $Markdown.Length
      $nextLineStart = $Markdown.Length
    } else {
      $lineEnd = $newlineIndex
      $nextLineStart = $newlineIndex + 1
    }
    $line = $Markdown.Substring($lineStart, $lineEnd - $lineStart)

    $indent = 0
    while ($indent -lt $line.Length -and $line[$indent] -eq " ") {
      $indent++
    }
    $candidateFence = $null
    $candidateLength = 0
    if ($indent -le 3 -and $indent -lt $line.Length -and
      ($line[$indent] -eq '`' -or $line[$indent] -eq '~')) {
      $candidateFence = $line[$indent]
      $cursor = $indent
      while ($cursor -lt $line.Length -and
        $line[$cursor] -eq $candidateFence) {
        $cursor++
      }
      $candidateLength = $cursor - $indent
    }

    $recognizedFenceLine = $false
    if ($null -eq $activeFence) {
      if ($candidateLength -ge 3) {
        $info = $line.Substring($indent + $candidateLength)
        # backtick fenceのinfo内backtickはCommonMark openingにならない。
        if ($candidateFence -ne '`' -or
          $info.IndexOf('`') -lt 0) {
          $activeFence = [pscustomobject]@{
            Character = $candidateFence
            Length = $candidateLength
            Indent = $indent
            Info = $info.Trim()
            OpenOffset = $lineStart
            OpenLine = $line
            ContentStart = $nextLineStart
          }
          $recognizedFenceLine = $true
        }
      }
    } elseif (
      $candidateFence -eq $activeFence.Character -and
      $candidateLength -ge $activeFence.Length
    ) {
      $remainder = $line.Substring($indent + $candidateLength)
      if ($remainder.Trim([char[]]@([char]" ", [char]"`t")).Length -eq 0) {
        $blocks.Add([pscustomobject]@{
          Character = $activeFence.Character
          Length = $activeFence.Length
          Indent = $activeFence.Indent
          Info = $activeFence.Info
          OpenOffset = $activeFence.OpenOffset
          OpenLine = $activeFence.OpenLine
          CloseOffset = $lineStart
          CloseLine = $line
          Content = $Markdown.Substring(
            $activeFence.ContentStart,
            $lineStart - $activeFence.ContentStart
          )
        }) | Out-Null
        $activeFence = $null
        $recognizedFenceLine = $true
      }
    }
    # container prefixや過剰indent等の曖昧なfence-like行も見逃さずfail-closedにする。
    if (-not $recognizedFenceLine -and
      [regex]::IsMatch($line, '`{3,}|~{3,}')) {
      $ambiguousFenceLikeCount++
    }

    $lineStart = $nextLineStart
  }

  if ($null -ne $activeFence) {
    $unclosedFenceCount = 1
  }
  return [pscustomobject]@{
    Blocks = @($blocks.ToArray())
    UnclosedFenceCount = $unclosedFenceCount
    AmbiguousFenceLikeCount = $ambiguousFenceLikeCount
  }
}

function Get-PureExpression {
  param([System.Management.Automation.Language.Ast]$Ast)

  if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) {
    return $Ast.Expression
  }
  if ($Ast -isnot [System.Management.Automation.Language.PipelineAst] -or
    $Ast.PipelineElements.Count -ne 1 -or
    $Ast.PipelineElements[0] -isnot
      [System.Management.Automation.Language.CommandExpressionAst]) {
    return $null
  }
  return $Ast.PipelineElements[0].Expression
}

function Get-NormalizedVariableName {
  param([System.Management.Automation.Language.VariableExpressionAst]$Ast)

  if ($null -eq $Ast) {
    return $null
  }
  $name = $Ast.VariablePath.UserPath
  if ($name -match '^(?i:variable):(?<name>.+)$') {
    $name = $Matches["name"]
  }
  if ($name -match '^(?i:global|local|script|private):(?<name>.+)$') {
    return $Matches["name"]
  }
  return $name
}

function Test-VariableExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Name,
    [bool]$Splatted = $false
  )

  return (
    $Ast -is [System.Management.Automation.Language.VariableExpressionAst] -and
    (Test-IdentifierEquals (Get-NormalizedVariableName $Ast) $Name) -and
    $Ast.Splatted -eq $Splatted
  )
}

function Test-StringExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Value
  )

  return (
    $Ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    (Test-OrdinalStringEquals $Ast.Value $Value)
  )
}

function Test-MemberExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Variable,
    [string]$Member
  )

  return (
    $Ast -is [System.Management.Automation.Language.MemberExpressionAst] -and
    -not $Ast.Static -and
    (Test-VariableExpression -Ast $Ast.Expression -Name $Variable) -and
    (Test-IdentifierEquals $Ast.Member.Value $Member)
  )
}

function Test-InvokeMemberExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Variable,
    [string]$Member,
    [string[]]$ArgumentTexts = @()
  )

  if ($Ast -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
    $Ast.Static -or
    -not (Test-VariableExpression -Ast $Ast.Expression -Name $Variable) -or
    -not (Test-IdentifierEquals $Ast.Member.Value $Member) -or
    $Ast.Arguments.Count -ne $ArgumentTexts.Count) {
    return $false
  }
  for ($index = 0; $index -lt $ArgumentTexts.Count; $index++) {
    if (-not (Test-OrdinalStringEquals `
        $Ast.Arguments[$index].Extent.Text `
        $ArgumentTexts[$index])) {
      return $false
    }
  }
  return $true
}

function Get-DirectAssignments {
  param(
    [System.Management.Automation.Language.StatementBlockAst]$Block,
    [string]$Variable
  )

  return @($Block.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name $Variable)
  })
}

function Get-CommandParameterArgument {
  param(
    [System.Management.Automation.Language.CommandAst]$Command,
    [string]$Name
  )

  for ($index = 1; $index -lt $Command.CommandElements.Count; $index++) {
    $element = $Command.CommandElements[$index]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
      (Test-IdentifierEquals $element.ParameterName $Name)) {
      if ($index + 1 -ge $Command.CommandElements.Count -or
        $Command.CommandElements[$index + 1] -is
          [System.Management.Automation.Language.CommandParameterAst]) {
        return $null
      }
      return $Command.CommandElements[$index + 1]
    }
  }
  return $null
}

function Get-HashtableValueExpression {
  param(
    [System.Management.Automation.Language.HashtableAst]$Hashtable,
    [string]$Key
  )

  foreach ($pair in $Hashtable.KeyValuePairs) {
    if (Test-StringExpression -Ast $pair.Item1 -Value $Key) {
      return Get-PureExpression -Ast $pair.Item2
    }
  }
  return $null
}

function Test-NullComparison {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [System.Management.Automation.Language.TokenKind]$Operator,
    [string]$Variable
  )

  return (
    $Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $Ast.Operator -eq $Operator -and
    (Test-VariableExpression -Ast $Ast.Left -Name "null") -and
    (Test-VariableExpression -Ast $Ast.Right -Name $Variable)
  )
}

function Test-ServerHandleUnavailableExpression {
  param([System.Management.Automation.Language.Ast]$Ast)

  # PowerShellの-orは左結合なので、3条件の順序と短絡論理をASTで固定する。
  return (
    $Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $Ast.Operator -eq [System.Management.Automation.Language.TokenKind]::Or -and
    $Ast.Left -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $Ast.Left.Operator -eq [System.Management.Automation.Language.TokenKind]::Or -and
    (Test-NullComparison `
      $Ast.Left.Left `
      ([System.Management.Automation.Language.TokenKind]::Ieq) `
      "serverHandle") -and
    (Test-MemberExpression $Ast.Left.Right "serverHandle" "IsInvalid") -and
    (Test-MemberExpression $Ast.Right "serverHandle" "IsClosed")
  )
}

function Test-NotVariableCondition {
  param(
    [System.Management.Automation.Language.PipelineBaseAst]$Condition,
    [string]$Variable
  )

  $expression = Get-PureExpression -Ast $Condition
  return (
    $expression -is [System.Management.Automation.Language.UnaryExpressionAst] -and
    $expression.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Not -and
    (Test-VariableExpression -Ast $expression.Child -Name $Variable)
  )
}

function Test-NotMemberCondition {
  param(
    [System.Management.Automation.Language.PipelineBaseAst]$Condition,
    [string]$Variable,
    [string]$Member
  )

  $expression = Get-PureExpression -Ast $Condition
  return (
    $expression -is [System.Management.Automation.Language.UnaryExpressionAst] -and
    $expression.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Not -and
    (Test-MemberExpression -Ast $expression.Child -Variable $Variable -Member $Member)
  )
}

function Test-AssignmentTargetsStorage {
  param(
    [System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
    [string]$Variable
  )

  if (Test-VariableExpression -Ast $Assignment.Left -Name $Variable) {
    return $true
  }
  if ($Assignment.Left -is [System.Management.Automation.Language.MemberExpressionAst]) {
    return Test-VariableExpression -Ast $Assignment.Left.Expression -Name $Variable
  }
  if ($Assignment.Left -is [System.Management.Automation.Language.IndexExpressionAst]) {
    return Test-VariableExpression -Ast $Assignment.Left.Target -Name $Variable
  }
  return $false
}

function Get-ArrayExpressionElements {
  param([System.Management.Automation.Language.Ast]$Ast)

  $expression = Get-PureExpression -Ast $Ast
  if ($expression -isnot [System.Management.Automation.Language.ArrayExpressionAst] -or
    $expression.SubExpression.Statements.Count -ne 1) {
    return @()
  }
  $statement = $expression.SubExpression.Statements[0]
  if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or
    $statement.PipelineElements.Count -ne 1 -or
    $statement.PipelineElements[0] -isnot
      [System.Management.Automation.Language.CommandExpressionAst] -or
    $statement.PipelineElements[0].Expression -isnot
      [System.Management.Automation.Language.ArrayLiteralAst]) {
    return @()
  }
  return @($statement.PipelineElements[0].Expression.Elements)
}

function Test-StaticNewExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$TypeName,
    [int]$ArgumentCount
  )

  return (
    $Ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $Ast.Static -and
    $Ast.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
    (Test-IdentifierEquals $Ast.Expression.TypeName.FullName $TypeName) -and
    (Test-IdentifierEquals $Ast.Member.Value "new") -and
    $Ast.Arguments.Count -eq $ArgumentCount
  )
}

function Test-CleanupStageAddPipeline {
  param([System.Management.Automation.Language.Ast]$Ast)

  if ($Ast -isnot [System.Management.Automation.Language.PipelineAst] -or
    $Ast.PipelineElements.Count -ne 2 -or
    $Ast.PipelineElements[0] -isnot
      [System.Management.Automation.Language.CommandExpressionAst] -or
    $Ast.PipelineElements[1] -isnot
      [System.Management.Automation.Language.CommandAst]) {
    return $false
  }
  $addExpression = $Ast.PipelineElements[0].Expression
  return (
    $addExpression -is
      [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $addExpression.Static -and
    (Test-VariableExpression $addExpression.Expression "cleanupStageFailures") -and
    (Test-IdentifierEquals $addExpression.Member.Value "Add") -and
    $addExpression.Arguments.Count -eq 1 -and
    (Test-MemberExpression $addExpression.Arguments[0] "_" "Exception") -and
    (Test-CommandCallText $Ast.PipelineElements[1] "Out-Null" @())
  )
}

function Test-VariableMemberComparison {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Variable,
    [string]$Member,
    [System.Management.Automation.Language.TokenKind]$Operator,
    [int]$Value
  )

  return (
    $Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $Ast.Operator -eq $Operator -and
    (Test-MemberExpression $Ast.Left $Variable $Member) -and
    $Ast.Right -is [System.Management.Automation.Language.ConstantExpressionAst] -and
    $Ast.Right.Value -eq $Value
  )
}

function Test-VariableIndexExpression {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [string]$Variable,
    [int]$Index
  )

  return (
    $Ast -is [System.Management.Automation.Language.IndexExpressionAst] -and
    (Test-VariableExpression $Ast.Target $Variable) -and
    $Ast.Index -is [System.Management.Automation.Language.ConstantExpressionAst] -and
    $Ast.Index.Value -eq $Index
  )
}

function Test-ReadOnlyStartParametersInvocation {
  param([System.Management.Automation.Language.Ast]$Ast)

  return (
    $Ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $Ast.Static -and
    (Test-VariableExpression $Ast.Expression "startParameters") -and
    (Test-IdentifierEquals $Ast.Member.Value "ContainsKey") -and
    $Ast.Arguments.Count -eq 1 -and
    $Ast.Arguments[0] -is
      [System.Management.Automation.Language.StringConstantExpressionAst]
  )
}

function Test-AstHasAncestorType {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [type]$AncestorType
  )

  $ancestor = $Ast.Parent
  while ($null -ne $ancestor) {
    if ($AncestorType.IsInstanceOfType($ancestor)) {
      return $true
    }
    $ancestor = $ancestor.Parent
  }
  return $false
}

function Test-AstIsDescendantOf {
  param(
    [System.Management.Automation.Language.Ast]$Ast,
    [System.Management.Automation.Language.Ast]$Ancestor
  )

  $parent = $Ast.Parent
  while ($null -ne $parent) {
    if ([object]::ReferenceEquals($parent, $Ancestor)) {
      return $true
    }
    $parent = $parent.Parent
  }
  return $false
}

function Test-CommandCallText {
  param(
    [System.Management.Automation.Language.CommandAst]$Command,
    [string]$Name,
    [string[]]$ElementTexts
  )

  if ($null -eq $Command -or
    -not (Test-IdentifierEquals $Command.GetCommandName() $Name) -or
    $Command.CommandElements.Count -ne (1 + $ElementTexts.Count)) {
    return $false
  }
  for ($index = 0; $index -lt $ElementTexts.Count; $index++) {
    if (-not (Test-OrdinalStringEquals `
        $Command.CommandElements[$index + 1].Extent.Text `
        $ElementTexts[$index])) {
      return $false
    }
  }
  return $true
}

function Test-DirectCommandAssignment {
  param(
    [System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
    [string]$CommandName,
    [string[]]$ElementTexts
  )

  if ($null -eq $Assignment -or
    $Assignment.Right -isnot [System.Management.Automation.Language.PipelineAst] -or
    $Assignment.Right.PipelineElements.Count -ne 1 -or
    $Assignment.Right.PipelineElements[0] -isnot
      [System.Management.Automation.Language.CommandAst]) {
    return $false
  }
  return Test-CommandCallText `
    $Assignment.Right.PipelineElements[0] `
    $CommandName `
    $ElementTexts
}

function Test-DirectBareRethrow {
  param([System.Management.Automation.Language.StatementBlockAst]$Block)

  return (
    $Block.Statements.Count -eq 1 -and
    $Block.Statements[0] -is [System.Management.Automation.Language.ThrowStatementAst] -and
    $null -eq $Block.Statements[0].Pipeline
  )
}

function Test-DirectStringThrow {
  param(
    [System.Management.Automation.Language.StatementBlockAst]$Block,
    [string]$Message
  )

  return (
    $Block.Statements.Count -eq 1 -and
    $Block.Statements[0] -is [System.Management.Automation.Language.ThrowStatementAst] -and
    (Test-StringExpression `
      (Get-PureExpression $Block.Statements[0].Pipeline) `
      $Message)
  )
}

function Test-ReadOnlySplatGuardThrow {
  param([System.Management.Automation.Language.ThrowStatementAst]$Throw)

  if ($null -eq $Throw.Pipeline -or
    -not (Test-StringExpression `
      (Get-PureExpression $Throw.Pipeline) `
      "Missing direct executable.") -or
    $Throw.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
    $Throw.Parent.Statements.Count -ne 1 -or
    $Throw.Parent.Parent -isnot [System.Management.Automation.Language.IfStatementAst]) {
    return $false
  }
  $guard = $Throw.Parent.Parent
  if ($guard.Clauses.Count -ne 1 -or $null -ne $guard.ElseClause) {
    return $false
  }
  $condition = Get-PureExpression -Ast $guard.Clauses[0].Item1
  return (
    $condition -is [System.Management.Automation.Language.UnaryExpressionAst] -and
    $condition.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Not -and
    (Test-ReadOnlyStartParametersInvocation $condition.Child) -and
    (Test-StringExpression $condition.Child.Arguments[0] "FilePath")
  )
}

function Test-DirectThrowVariable {
  param(
    [System.Management.Automation.Language.StatementBlockAst]$Block,
    [string]$Variable
  )

  if ($Block.Statements.Count -ne 1 -or
    $Block.Statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) {
    return $false
  }
  $expression = Get-PureExpression -Ast $Block.Statements[0].Pipeline
  return Test-VariableExpression -Ast $expression -Name $Variable
}

function Test-DirectTypedThrow {
  param(
    [System.Management.Automation.Language.StatementBlockAst]$Block,
    [string]$TypeName
  )

  $throws = @($Block.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.ThrowStatementAst]
  })
  if ($throws.Count -ne 1) {
    return $false
  }
  $calls = @($throws[0].Pipeline.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Static -and
    $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
    (Test-IdentifierEquals $node.Expression.TypeName.FullName $TypeName) -and
    (Test-IdentifierEquals $node.Member.Value "new")
  }, $true))
  return $calls.Count -eq 1
}

function Get-ServerRunbookContractViolations {
  param(
    [string]$Markdown,
    [switch]$AllowExactReadOnlyVariant,
    [switch]$SemanticProbe
  )

  $violations = New-Object System.Collections.Generic.List[string]

  # CommonMark fenceを文字・長さ・indent込みでparseし、実行可能blockを1個に閉じる。
  $fenceScan = Get-CommonMarkFenceScan -Markdown $Markdown
  $fenceBlocks = @($fenceScan.Blocks)
  if ($fenceScan.UnclosedFenceCount -ne 0 -or
    $fenceScan.AmbiguousFenceLikeCount -ne 0 -or
    $fenceBlocks.Count -ne 1) {
    Add-ContractViolation $violations "expected exactly one closed CommonMark code fence"
    return $violations.ToArray()
  }
  $workflowBlock = $fenceBlocks[0]
  $workflowHeader = "## Complete Bounded Workflow`n`n"
  $headerStart = $workflowBlock.OpenOffset - $workflowHeader.Length
  $workflowBoundaryIsExact = (
    $workflowBlock.Character -eq '`' -and
    $workflowBlock.Length -eq 3 -and
    $workflowBlock.Indent -eq 0 -and
    (Test-OrdinalStringEquals $workflowBlock.Info "powershell") -and
    (Test-OrdinalStringEquals $workflowBlock.OpenLine '```powershell') -and
    (Test-OrdinalStringEquals $workflowBlock.CloseLine '```') -and
    $headerStart -ge 0 -and
    (Test-OrdinalStringEquals `
      $Markdown.Substring($headerStart, $workflowHeader.Length) `
      $workflowHeader)
  )
  if (-not $workflowBoundaryIsExact) {
    Add-ContractViolation $violations "bounded workflow must own the exact CommonMark fence boundary"
    return $violations.ToArray()
  }

  $code = $workflowBlock.Content
  $readOnlyVariantIndex = -1
  if ($AllowExactReadOnlyVariant) {
    for (
      $variantIndex = 0;
      $variantIndex -lt $script:ExactReadOnlyServerRunbookVariants.Count;
      $variantIndex++
    ) {
      if (Test-OrdinalStringEquals `
        $code `
        $script:ExactReadOnlyServerRunbookVariants[$variantIndex]) {
        $readOnlyVariantIndex = $variantIndex
        break
      }
    }
  }
  if (-not $SemanticProbe) {
    $allowedCodes = @($script:CanonicalServerRunbookCode)
    if ($AllowExactReadOnlyVariant) {
      $allowedCodes += @($script:ExactReadOnlyServerRunbookVariants)
    }
    $exactMatches = @($allowedCodes | Where-Object {
      $null -ne $_ -and (Test-OrdinalStringEquals $_ $code)
    })
    if ($exactMatches.Count -ne 1) {
      Add-ContractViolation $violations "workflow must byte-match the canonical executable template"
      return $violations.ToArray()
    }
  }

  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $code,
    [ref]$tokens,
    [ref]$parseErrors
  )
  if ($parseErrors.Count -gt 0) {
    Add-ContractViolation $violations "complete bounded workflow must parse as PowerShell"
    return $violations.ToArray()
  }

  # rootのparam/using/named block等はEndBlock.Statements外から実行順を変えられるため閉じる。
  $cleanBlockProperty = $ast.PSObject.Properties["CleanBlock"]
  $rootCleanBlock = if ($null -ne $cleanBlockProperty) {
    $cleanBlockProperty.Value
  } else {
    $null
  }
  $rootSurfaceIsExact = (
    $null -eq $ast.ParamBlock -and
    @($ast.Attributes).Count -eq 0 -and
    @($ast.UsingStatements).Count -eq 0 -and
    $null -eq $ast.DynamicParamBlock -and
    $null -eq $ast.BeginBlock -and
    $null -eq $ast.ProcessBlock -and
    $null -eq $rootCleanBlock -and
    $null -ne $ast.EndBlock -and
    $ast.EndBlock.Unnamed -and
    $null -eq $ast.ScriptRequirements
  )
  if (-not $rootSurfaceIsExact) {
    Add-ContractViolation $violations "root ScriptBlock surface must be the unnamed canonical end block only"
  }

  # trapはStatements配列外へ退避されるため、入れ子を含むAST全体から明示的に拒否する。
  $trapStatements = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TrapStatementAst]
  }, $true))
  if ($trapStatements.Count -ne 0) {
    Add-ContractViolation $violations "workflow must not define trap handlers"
  }

  # function/class等のdefinitionはcommand解決をshadowできるため、実行例では一切許可しない。
  $shadowingDefinitions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
    $node -is [System.Management.Automation.Language.TypeDefinitionAst]
  }, $true))
  if ($shadowingDefinitions.Count -ne 0) {
    Add-ContractViolation $violations "workflow must not define functions, filters, classes, or enums"
  }

  $allCommands = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
  }, $true))
  $expectedCommandCounts = @{
    "<dynamic>" = 1
    "ConvertTo-Json" = 2
    "Get-Command" = 1
    "Get-Item" = 1
    "Invoke-WebRequest" = 1
    "Join-Path" = 5
    "New-Item" = 1
    "Out-Null" = -1
    "Resolve-Path" = 1
    "Set-Content" = 1
    "Start-Process" = 1
    "Start-Sleep" = 1
    "Test-Path" = 2
    "Write-Host" = 1
    "Write-Warning" = 1
  }
  $actualCommandCounts =
    [System.Collections.Generic.Dictionary[string, int]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )
  foreach ($command in $allCommands) {
    $commandName = $command.GetCommandName()
    $commandKey = if ($null -eq $commandName) { "<dynamic>" } else { $commandName }
    if (-not $actualCommandCounts.ContainsKey($commandKey)) {
      $actualCommandCounts[$commandKey] = 0
    }
    $actualCommandCounts[$commandKey]++
  }
  $commandSetIsExact = $actualCommandCounts.Count -eq $expectedCommandCounts.Count
  foreach ($entry in $expectedCommandCounts.GetEnumerator()) {
    $countIsValid = if ($entry.Value -eq -1) {
      $actualCommandCounts.ContainsKey($entry.Key) -and
        $actualCommandCounts[$entry.Key] -ge 1
    } else {
      $actualCommandCounts.ContainsKey($entry.Key) -and
        $actualCommandCounts[$entry.Key] -eq $entry.Value
    }
    if (-not $countIsValid) {
      $commandSetIsExact = $false
    }
  }
  if (-not $commandSetIsExact) {
    Add-ContractViolation $violations "workflow command and dynamic invocation set must be exact"
  }
  $returnOrExitSinks = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ReturnStatementAst] -or
    $node -is [System.Management.Automation.Language.ExitStatementAst]
  }, $true))
  if ($returnOrExitSinks.Count -ne 0) {
    Add-ContractViolation $violations "workflow must not add return or exit output/control sinks"
  }
  if (@($allCommands | Where-Object {
    $_.GetCommandName() -in @(
      "Get-Content",
      "Get-Process",
      "Stop-Process",
      "Set-Variable",
      "Clear-Variable",
      "Remove-Variable",
      "Set-Item",
      "Remove-Item"
    )
  }).Count -ne 0) {
    Add-ContractViolation $violations "workflow must not replay logs, re-resolve PID, or mutate audited storage dynamically"
  }
  if (@($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    ((Test-OrdinalStringEquals $node.Value "npm") -or
      $node.Value -match '\.(cmd|bat)$')
  }, $true)).Count -ne 0) {
    Add-ContractViolation $violations "workflow must not launch a task runner or shell wrapper"
  }

  # top-levelの定義からStart-Processまで、実server entryのdef-useを固定する。
  $topLevel = @($ast.EndBlock.Statements)
  $allAssignments = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
  }, $true) | Sort-Object { $_.Extent.StartOffset })

  # top-level statementと全write targetをsource順のclosed sequenceへ固定する。
  $expectedTopLevelSignatures = @(
    'AssignmentStatementAst|$runtimeIsWindows',
    'AssignmentStatementAst|$root',
    'AssignmentStatementAst|$stateDir',
    'PipelineAst|',
    'AssignmentStatementAst|$stdout',
    'AssignmentStatementAst|$stderr',
    'AssignmentStatementAst|$pidFile',
    'AssignmentStatementAst|$url',
    'AssignmentStatementAst|$serverScript',
    'AssignmentStatementAst|$nodeCommandName',
    'AssignmentStatementAst|$serverEntry',
    'AssignmentStatementAst|$serverArguments',
    'IfStatementAst|',
    'AssignmentStatementAst|$verifyUi',
    'AssignmentStatementAst|$server',
    'AssignmentStatementAst|$serverHandle',
    'AssignmentStatementAst|$serverStartTimeUtc',
    'AssignmentStatementAst|$verificationFailure',
    'AssignmentStatementAst|$cleanupFailure',
    'AssignmentStatementAst|$cleanupStageFailures',
    'AssignmentStatementAst|$cleanupResult',
    'TryStatementAst|',
    'IfStatementAst|',
    'IfStatementAst|',
    'IfStatementAst|',
    'PipelineAst|'
  )
  $topLevelSequenceIsExact = $topLevel.Count -eq
    $expectedTopLevelSignatures.Count
  if ($topLevelSequenceIsExact) {
    for ($index = 0; $index -lt $expectedTopLevelSignatures.Count; $index++) {
      $leftText = if ($topLevel[$index] -is
          [System.Management.Automation.Language.AssignmentStatementAst]) {
        $topLevel[$index].Left.Extent.Text
      } else {
        ""
      }
      $actualSignature = $topLevel[$index].GetType().Name + "|" + $leftText
      if (-not (Test-OrdinalStringEquals `
          $actualSignature `
          $expectedTopLevelSignatures[$index])) {
        $topLevelSequenceIsExact = $false
        break
      }
    }
  }
  if (-not $topLevelSequenceIsExact) {
    Add-ContractViolation $violations "top-level executable statements must match the closed workflow sequence"
  }

  $expectedAssignmentTargets = @(
    '$runtimeIsWindows',
    '$root',
    '$stateDir',
    '$stdout',
    '$stderr',
    '$pidFile',
    '$url',
    '$serverScript',
    '$nodeCommandName',
    '$serverEntry',
    '$serverArguments',
    '$verifyUi',
    '$server',
    '$serverHandle',
    '$serverStartTimeUtc',
    '$verificationFailure',
    '$cleanupFailure',
    '$cleanupStageFailures',
    '$cleanupResult',
    '$startParameters',
    '$startParameters["WindowStyle"]',
    '$server',
    '$serverHandle',
    '$serverStartTimeUtc',
    '$ready',
    '$attempt',
    '$response',
    '$ready',
    '$stderrSizeBytes',
    '$stderrSizeBytes',
    '$healthDiagnostic',
    '$verificationFailure',
    '$cleanupResult',
    '$cleanupResult',
    '$cleanupResult',
    '$cleanupFailure',
    '$cleanupFailure',
    '$cleanupResult',
    '$failures'
  )
  if ($readOnlyVariantIndex -eq 0) {
    $expectedAssignmentTargets = @(
      $expectedAssignmentTargets[0..20] +
      '$null' +
      $expectedAssignmentTargets[21..($expectedAssignmentTargets.Count - 1)]
    )
  }
  $assignmentSequenceIsExact = $allAssignments.Count -eq
    $expectedAssignmentTargets.Count
  if ($assignmentSequenceIsExact) {
    for ($index = 0; $index -lt $expectedAssignmentTargets.Count; $index++) {
      if (-not (Test-OrdinalStringEquals `
          $allAssignments[$index].Left.Extent.Text `
          $expectedAssignmentTargets[$index])) {
        $assignmentSequenceIsExact = $false
        break
      }
    }
  }
  if (-not $assignmentSequenceIsExact) {
    Add-ContractViolation $violations "all assignment and provider writes must match the closed source-order sequence"
  }

  $mutationUnaryKinds = @(
    [System.Management.Automation.Language.TokenKind]::MinusMinus,
    [System.Management.Automation.Language.TokenKind]::PlusPlus,
    [System.Management.Automation.Language.TokenKind]::PostfixMinusMinus,
    [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus
  )
  $mutationUnaryExpressions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
    $mutationUnaryKinds -contains $node.TokenKind
  }, $true))
  if ($mutationUnaryExpressions.Count -ne 1 -or
    $mutationUnaryExpressions[0].TokenKind -ne
      [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus -or
    -not (Test-VariableExpression $mutationUnaryExpressions[0].Child "attempt")) {
    Add-ContractViolation $violations "unary storage mutation must be only the bounded loop iterator"
  }

  # critical scalar初期値も固定し、closed write sequence内で安全なdef-useだけを許可する。
  $runtimeExpression = if ($topLevel.Count -gt 0) {
    Get-PureExpression $topLevel[0].Right
  } else {
    $null
  }
  $runtimeLeft = if (
    $runtimeExpression -is
      [System.Management.Automation.Language.BinaryExpressionAst]
  ) {
    $runtimeExpression.Left
  } else {
    $null
  }
  $runtimeRight = if (
    $runtimeExpression -is
      [System.Management.Automation.Language.BinaryExpressionAst]
  ) {
    $runtimeExpression.Right
  } else {
    $null
  }
  $runtimePlatformSource = if (
    $runtimeLeft -is [System.Management.Automation.Language.MemberExpressionAst]
  ) {
    $runtimeLeft.Expression
  } else {
    $null
  }
  $runtimeDefinitionIsExact = (
    $runtimeExpression -is
      [System.Management.Automation.Language.BinaryExpressionAst] -and
    $runtimeExpression.Operator -eq
      [System.Management.Automation.Language.TokenKind]::Ieq -and
    $runtimeLeft -is [System.Management.Automation.Language.MemberExpressionAst] -and
    -not $runtimeLeft.Static -and
    (Test-IdentifierEquals $runtimeLeft.Member.Value "Platform") -and
    $runtimePlatformSource -is
      [System.Management.Automation.Language.MemberExpressionAst] -and
    $runtimePlatformSource.Static -and
    $runtimePlatformSource.Expression -is
      [System.Management.Automation.Language.TypeExpressionAst] -and
    (Test-IdentifierEquals `
      $runtimePlatformSource.Expression.TypeName.FullName `
      "Environment") -and
    (Test-IdentifierEquals $runtimePlatformSource.Member.Value "OSVersion") -and
    $runtimeRight -is [System.Management.Automation.Language.MemberExpressionAst] -and
    $runtimeRight.Static -and
    $runtimeRight.Expression -is
      [System.Management.Automation.Language.TypeExpressionAst] -and
    (Test-IdentifierEquals `
      $runtimeRight.Expression.TypeName.FullName `
      "PlatformID") -and
    (Test-IdentifierEquals $runtimeRight.Member.Value "Win32NT")
  )
  $nodeCommandDefinition = if ($topLevel.Count -gt 9) {
    $topLevel[9].Right
  } else {
    $null
  }
  $nodeCommandDefinitionIsExact = (
    $nodeCommandDefinition -is
      [System.Management.Automation.Language.IfStatementAst] -and
    $nodeCommandDefinition.Clauses.Count -eq 1 -and
    (Test-VariableExpression `
      (Get-PureExpression $nodeCommandDefinition.Clauses[0].Item1) `
      "runtimeIsWindows") -and
    $nodeCommandDefinition.Clauses[0].Item2.Statements.Count -eq 1 -and
    (Test-StringExpression `
      (Get-PureExpression `
        $nodeCommandDefinition.Clauses[0].Item2.Statements[0]) `
      "node.exe") -and
    $null -ne $nodeCommandDefinition.ElseClause -and
    $nodeCommandDefinition.ElseClause.Statements.Count -eq 1 -and
    (Test-StringExpression `
      (Get-PureExpression $nodeCommandDefinition.ElseClause.Statements[0]) `
      "node")
  )
  $nullInitializerIndexes = @(14, 15, 16, 17, 18)
  $nullInitializersAreExact = $true
  foreach ($index in $nullInitializerIndexes) {
    if ($topLevel.Count -le $index -or
      -not (Test-VariableExpression `
        (Get-PureExpression $topLevel[$index].Right) `
        "null")) {
      $nullInitializersAreExact = $false
      break
    }
  }
  if (-not $runtimeDefinitionIsExact -or
    -not $nodeCommandDefinitionIsExact -or
    -not $nullInitializersAreExact -or
    $topLevel.Count -le 20 -or
    -not (Test-StringExpression `
      (Get-PureExpression $topLevel[7].Right) `
      "http://127.0.0.1:5173/") -or
    -not (Test-StaticNewExpression `
      (Get-PureExpression $topLevel[19].Right) `
      "System.Collections.Generic.List[System.Exception]" `
      0) -or
    -not (Test-StringExpression `
      (Get-PureExpression $topLevel[20].Right) `
      "Server process was not started.")) {
    Add-ContractViolation $violations "critical scalar definitions must match the closed immutable provenance"
  }

  $directRootAssignments = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name "root")
  })
  $rootAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "root"
  })
  $rootCommandShapeIsExact = $false
  if ($rootAssignments.Count -eq 1 -and
    $directRootAssignments.Count -eq 1 -and
    [object]::ReferenceEquals($rootAssignments[0], $directRootAssignments[0])) {
    $rootExpression = Get-PureExpression -Ast $directRootAssignments[0].Right
    $rootCommands = @($directRootAssignments[0].Right.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    $rootCommandShapeIsExact = (
      $rootExpression -is [System.Management.Automation.Language.MemberExpressionAst] -and
      (Test-IdentifierEquals $rootExpression.Member.Value "Path") -and
      $rootExpression.Expression -is
        [System.Management.Automation.Language.ParenExpressionAst] -and
      $rootCommands.Count -eq 1 -and
      (Test-CommandCallText $rootCommands[0] "Resolve-Path" @('"."')) -and
      (Test-AstIsDescendantOf $rootCommands[0] $directRootAssignments[0])
    )
  }
  if (-not $rootCommandShapeIsExact) {
    Add-ContractViolation $violations "root must have one immutable direct Resolve-Path definition"
  }

  # Directory creation may return its DirectoryInfo, so its only allowed sink is
  # a direct top-level pipeline into Out-Null.
  $newItemCommands = @($allCommands | Where-Object {
    Test-IdentifierEquals $_.GetCommandName() "New-Item"
  })
  $newItemSinkIsExact = $false
  if ($newItemCommands.Count -eq 1) {
    $newItemPipeline = $newItemCommands[0].Parent
    $newItemSinkIsExact = (
      (Test-CommandCallText `
        $newItemCommands[0] `
        "New-Item" `
        @("-ItemType", "Directory", "-Force", "-Path", '$stateDir')) -and
      $newItemPipeline -is [System.Management.Automation.Language.PipelineAst] -and
      $topLevel -contains $newItemPipeline -and
      $newItemPipeline.PipelineElements.Count -eq 2 -and
      [object]::ReferenceEquals(
        $newItemPipeline.PipelineElements[0],
        $newItemCommands[0]
      ) -and
      $newItemPipeline.PipelineElements[1] -is
        [System.Management.Automation.Language.CommandAst] -and
      (Test-CommandCallText `
        $newItemPipeline.PipelineElements[1] `
        "Out-Null" `
        @())
    )
  }
  if (-not $newItemSinkIsExact) {
    Add-ContractViolation $violations "New-Item output must flow directly to Out-Null"
  }

  # 公開streamへabsolute pathを落とさないよう、4つのJoin-Pathは代入の
  # 唯一commandとして固定する。
  $pathAssignmentSpecs = @(
    @{
      Variable = "stateDir"
      Elements = @('$root', '".ui-verification"')
    },
    @{
      Variable = "stdout"
      Elements = @('$stateDir', '"dev-server.out.log"')
    },
    @{
      Variable = "stderr"
      Elements = @('$stateDir', '"dev-server.err.log"')
    },
    @{
      Variable = "pidFile"
      Elements = @('$stateDir', '"dev-server.pid.json"')
    }
  )
  foreach ($spec in $pathAssignmentSpecs) {
    $pathAssignments = @($topLevel | Where-Object {
      $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      (Test-VariableExpression $_.Left $spec.Variable)
    })
    if ($pathAssignments.Count -ne 1 -or
      -not (Test-DirectCommandAssignment `
        $pathAssignments[0] `
        "Join-Path" `
        $spec.Elements)) {
      Add-ContractViolation $violations "$($spec.Variable) must directly consume its fixed Join-Path result"
    }
  }

  $serverScriptAssignments = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name "serverScript")
  })
  $nodeCommandAssignments = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name "nodeCommandName")
  })
  $serverArgumentAssignments = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name "serverArguments")
  })
  if ($serverScriptAssignments.Count -ne 1 -or
      -not (Test-StringExpression `
      (Get-PureExpression $serverScriptAssignments[0].Right) `
      "node_modules/vite/bin/vite.js")) {
    Add-ContractViolation $violations "runbook must directly own the Vite server script"
  }
  if ($nodeCommandAssignments.Count -ne 1) {
    Add-ContractViolation $violations "one platform-aware Node command assignment is required"
  } else {
    $nodeCommandStrings = @($nodeCommandAssignments[0].Right.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($nodeCommandStrings.Count -ne 2 -or
      -not (Test-OrdinalStringInSet "node.exe" $nodeCommandStrings) -or
      -not (Test-OrdinalStringInSet "node" $nodeCommandStrings)) {
      Add-ContractViolation $violations "platform-aware command must resolve only node.exe or node"
    }
  }

  $serverEntryAssignments = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression -Ast $_.Left -Name "serverEntry")
  })
  if ($serverEntryAssignments.Count -ne 1) {
    Add-ContractViolation $violations "one top-level direct server entry assignment is required"
  } else {
    $sourceExpression = Get-PureExpression -Ast $serverEntryAssignments[0].Right
    $getCommandCalls = @($serverEntryAssignments[0].Right.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
      (Test-IdentifierEquals $node.GetCommandName() "Get-Command")
    }, $true))
    if ($sourceExpression -isnot [System.Management.Automation.Language.MemberExpressionAst] -or
      -not (Test-IdentifierEquals $sourceExpression.Member.Value "Source") -or
      $getCommandCalls.Count -ne 1 -or
      -not (Test-CommandCallText `
        $getCommandCalls[0] `
        "Get-Command" `
        @('$nodeCommandName', "-CommandType", "Application", "-ErrorAction", "Stop"))) {
      Add-ContractViolation $violations "direct executable must resolve the Node application command"
    }
  }

  $serverArgumentElements = if ($serverArgumentAssignments.Count -eq 1) {
    @(Get-ArrayExpressionElements -Ast $serverArgumentAssignments[0].Right)
  } else {
    @()
  }
  if ($serverArgumentElements.Count -ne 6 -or
    -not (Test-VariableExpression $serverArgumentElements[0] "serverScript") -or
    -not (Test-StringExpression $serverArgumentElements[1] "--host") -or
    -not (Test-StringExpression $serverArgumentElements[2] "127.0.0.1") -or
    -not (Test-StringExpression $serverArgumentElements[3] "--port") -or
    -not (Test-StringExpression $serverArgumentElements[4] "5173") -or
    -not (Test-StringExpression $serverArgumentElements[5] "--strictPort")) {
    Add-ContractViolation $violations "server arguments must directly begin with the owned Vite script"
  }

  $missingEntryBranches = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and
    (Test-DirectStringThrow `
      $_.Clauses[0].Item2 `
      "The direct Vite server entry was not found.")
  })
  $missingEntryShapeIsExact = $false
  if ($missingEntryBranches.Count -eq 1) {
    $missingEntryCondition = Get-PureExpression `
      $missingEntryBranches[0].Clauses[0].Item1
    $missingEntryCommands = @(
      $missingEntryBranches[0].Clauses[0].Item1.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
      }, $true)
    )
    $testPathCommands = @($missingEntryCommands | Where-Object {
      Test-IdentifierEquals $_.GetCommandName() "Test-Path"
    })
    $joinPathCommands = @($missingEntryCommands | Where-Object {
      Test-IdentifierEquals $_.GetCommandName() "Join-Path"
    })
    $missingEntryShapeIsExact = (
      $null -eq $missingEntryBranches[0].ElseClause -and
      $missingEntryCondition -is
        [System.Management.Automation.Language.UnaryExpressionAst] -and
      $missingEntryCondition.TokenKind -eq
        [System.Management.Automation.Language.TokenKind]::Not -and
      $testPathCommands.Count -eq 1 -and
      $joinPathCommands.Count -eq 1 -and
      (Test-CommandCallText `
        $testPathCommands[0] `
        "Test-Path" `
        @(
          "-LiteralPath",
          '(Join-Path $root $serverScript)',
          "-PathType",
          "Leaf"
        )) -and
      (Test-CommandCallText `
        $joinPathCommands[0] `
        "Join-Path" `
        @('$root', '$serverScript'))
    )
  }
  if (-not $missingEntryShapeIsExact) {
    Add-ContractViolation $violations "server script probe must consume its nested Join-Path result"
  }

  # canonical定義をnested branchで再代入してdef-useを切るfixtureを拒否する。
  foreach ($immutableName in @(
    "serverScript",
    "nodeCommandName",
    "serverEntry",
    "serverArguments"
  )) {
    $mutations = @($allAssignments | Where-Object {
      Test-AssignmentTargetsStorage -Assignment $_ -Variable $immutableName
    })
    if ($mutations.Count -ne 1) {
      Add-ContractViolation $violations "$immutableName must have one immutable definition"
    }
  }

  $outerTries = @($topLevel | Where-Object {
    $_ -is [System.Management.Automation.Language.TryStatementAst]
  })
  if ($outerTries.Count -ne 1 -or
    $outerTries[0].CatchClauses.Count -ne 1 -or
    $null -eq $outerTries[0].Finally) {
    Add-ContractViolation $violations "one top-level try/catch/finally must own verification and cleanup"
    return $violations.ToArray()
  }
  $outerTry = $outerTries[0]
  $tryStatements = @($outerTry.Body.Statements)

  $expectedTrySignatures = @(
    'AssignmentStatementAst|$startParameters',
    'IfStatementAst|',
    'AssignmentStatementAst|$server',
    'AssignmentStatementAst|$serverHandle',
    'IfStatementAst|',
    'AssignmentStatementAst|$serverStartTimeUtc',
    'PipelineAst|',
    'AssignmentStatementAst|$ready',
    'ForStatementAst|',
    'IfStatementAst|',
    'PipelineAst|'
  )
  if ($readOnlyVariantIndex -ge 0) {
    $readOnlySignature = switch ($readOnlyVariantIndex) {
      0 { 'AssignmentStatementAst|$null' }
      1 { 'PipelineAst|' }
      2 { 'PipelineAst|' }
      3 { 'IfStatementAst|' }
    }
    $expectedTrySignatures = @(
      $expectedTrySignatures[0..1] +
      $readOnlySignature +
      $expectedTrySignatures[2..($expectedTrySignatures.Count - 1)]
    )
  }
  $trySequenceIsExact = $tryStatements.Count -eq $expectedTrySignatures.Count
  if ($trySequenceIsExact) {
    for ($index = 0; $index -lt $expectedTrySignatures.Count; $index++) {
      $leftText = if ($tryStatements[$index] -is
          [System.Management.Automation.Language.AssignmentStatementAst]) {
        $tryStatements[$index].Left.Extent.Text
      } else {
        ""
      }
      $actualSignature = $tryStatements[$index].GetType().Name + "|" + $leftText
      if (-not (Test-OrdinalStringEquals `
          $actualSignature `
          $expectedTrySignatures[$index])) {
        $trySequenceIsExact = $false
        break
      }
    }
  }
  if (-not $trySequenceIsExact) {
    Add-ContractViolation $violations "outer verification block must match the closed executable sequence"
  }

  # Start-Processはouter tryのdirect assignmentであり、splatもdirect server設定だけを持つ。
  $startParameterAssignments = @(Get-DirectAssignments $outerTry.Body "startParameters")
  $serverAssignments = @(Get-DirectAssignments $outerTry.Body "server")
  $handleAssignments = @(Get-DirectAssignments $outerTry.Body "serverHandle")
  if ($startParameterAssignments.Count -ne 1 -or
    $serverAssignments.Count -ne 1 -or
    $handleAssignments.Count -ne 1) {
    Add-ContractViolation $violations "start parameters, process, and SafeHandle need one direct assignment each"
    return $violations.ToArray()
  }

  $startHashtableExpression = Get-PureExpression -Ast $startParameterAssignments[0].Right
  if ($startHashtableExpression -isnot [System.Management.Automation.Language.HashtableAst] -or
    $startHashtableExpression.KeyValuePairs.Count -ne 6 -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "FilePath") `
      -Name "serverEntry") -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "ArgumentList") `
      -Name "serverArguments") -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "WorkingDirectory") `
      -Name "root") -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "RedirectStandardOutput") `
      -Name "stdout") -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "RedirectStandardError") `
      -Name "stderr") -or
    -not (Test-VariableExpression `
      -Ast (Get-HashtableValueExpression $startHashtableExpression "PassThru") `
      -Name "true")) {
    Add-ContractViolation $violations "Start-Process splat must own executable, arguments, redirects, and Process result"
  }

  # splat生成後はWindows用WindowStyleだけを許し、FilePath等の起動契約を上書きさせない。
  $startParameterMutations = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "startParameters"
  })
  $windowStyleMutations = @($startParameterMutations | Where-Object {
    $_ -ne $startParameterAssignments[0] -and
    $_.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and
    (Test-VariableExpression $_.Left.Target "startParameters") -and
    (Test-StringExpression $_.Left.Index "WindowStyle") -and
    (Test-StringExpression (Get-PureExpression $_.Right) "Hidden") -and
    $_.Parent -is [System.Management.Automation.Language.StatementBlockAst] -and
    $_.Parent.Parent -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Parent.Parent.Clauses.Count -eq 1 -and
    (Test-VariableExpression `
      (Get-PureExpression $_.Parent.Parent.Clauses[0].Item1) `
      "runtimeIsWindows")
  })
  if ($startParameterMutations.Count -ne 2 -or $windowStyleMutations.Count -ne 1) {
    Add-ContractViolation $violations "Start-Process splat must remain immutable except for guarded WindowStyle"
  }

  $startCommands = @($serverAssignments[0].Right.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    (Test-IdentifierEquals $node.GetCommandName() "Start-Process")
  }, $true))
  if ($startCommands.Count -ne 1 -or
    $startCommands[0].InvocationOperator -ne
      [System.Management.Automation.Language.TokenKind]::Unknown -or
    $startCommands[0].CommandElements.Count -ne 2 -or
    -not (Test-VariableExpression `
      -Ast $startCommands[0].CommandElements[1] `
      -Name "startParameters" `
      -Splatted $true)) {
    Add-ContractViolation $violations "server assignment must directly call Start-Process with the audited splat"
  }

  $serverIndex = [Array]::IndexOf($tryStatements, $serverAssignments[0])
  $handleIndex = [Array]::IndexOf($tryStatements, $handleAssignments[0])
  $handleExpression = Get-PureExpression -Ast $handleAssignments[0].Right
  if ($serverIndex -lt 0 -or
    $handleIndex -ne ($serverIndex + 1) -or
    -not (Test-MemberExpression $handleExpression "server" "SafeHandle")) {
    Add-ContractViolation $violations "SafeHandle must be captured immediately after direct server start"
  }
  $initialHandleGuard = if ($handleIndex + 1 -lt $tryStatements.Count) {
    $tryStatements[$handleIndex + 1]
  } else {
    $null
  }
  if ($initialHandleGuard -isnot
      [System.Management.Automation.Language.IfStatementAst] -or
    $initialHandleGuard.Clauses.Count -ne 1 -or
    $null -ne $initialHandleGuard.ElseClause -or
    -not (Test-ServerHandleUnavailableExpression `
      (Get-PureExpression $initialHandleGuard.Clauses[0].Item1)) -or
    -not (Test-DirectStringThrow `
      $initialHandleGuard.Clauses[0].Item2 `
      "The direct server process handle could not be retained.")) {
    Add-ContractViolation $violations "initial SafeHandle guard must use the exact null/invalid/closed OR expression"
  }

  $serverStartTimeAssignments = @(Get-DirectAssignments `
    $outerTry.Body `
    "serverStartTimeUtc")
  $allServerStartTimeAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "serverStartTimeUtc"
  })
  $serverStartTimeExpression = if ($serverStartTimeAssignments.Count -eq 1) {
    Get-PureExpression -Ast $serverStartTimeAssignments[0].Right
  } else {
    $null
  }
  if ($serverStartTimeExpression -isnot
      [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
    $allServerStartTimeAssignments.Count -ne 2 -or
    $serverStartTimeExpression.Static -or
    -not (Test-IdentifierEquals `
      $serverStartTimeExpression.Member.Value `
      "ToUniversalTime") -or
    $serverStartTimeExpression.Arguments.Count -ne 0 -or
    -not (Test-MemberExpression `
      $serverStartTimeExpression.Expression `
      "server" `
      "StartTime")) {
    Add-ContractViolation $violations "report time must derive as a scalar from the retained Process"
  }

  # PID evidence JSONはsuccess streamへ出さず、同一pipelineで直ちに固定fileへ書く。
  $setContentCommands = @($allCommands | Where-Object {
    Test-IdentifierEquals $_.GetCommandName() "Set-Content"
  })
  $pidEvidenceSinkIsExact = $false
  if ($setContentCommands.Count -eq 1) {
    $pidPipeline = $setContentCommands[0].Parent
    $pidConvertCommands = if (
      $pidPipeline -is [System.Management.Automation.Language.PipelineAst]
    ) {
      @($pidPipeline.PipelineElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandAst] -and
        (Test-IdentifierEquals $_.GetCommandName() "ConvertTo-Json")
      })
    } else {
      @()
    }
    $pidEvidenceExpression = if (
      $pidPipeline -is [System.Management.Automation.Language.PipelineAst] -and
      $pidPipeline.PipelineElements.Count -ge 1 -and
      $pidPipeline.PipelineElements[0] -is
        [System.Management.Automation.Language.CommandExpressionAst]
    ) {
      $pidPipeline.PipelineElements[0].Expression
    } else {
      $null
    }
    $pidEvidenceHashtable = if (
      $pidEvidenceExpression -is
        [System.Management.Automation.Language.ConvertExpressionAst] -and
      (Test-IdentifierEquals `
        $pidEvidenceExpression.Type.TypeName.FullName `
        "ordered") -and
      $pidEvidenceExpression.Child -is
        [System.Management.Automation.Language.HashtableAst]
    ) {
      $pidEvidenceExpression.Child
    } else {
      $null
    }
    $pidStartTimeExpression = if ($null -ne $pidEvidenceHashtable) {
      Get-HashtableValueExpression $pidEvidenceHashtable "startTimeUtc"
    } else {
      $null
    }
    $pidEvidenceSinkIsExact = (
      $tryStatements -contains $pidPipeline -and
      $pidPipeline.PipelineElements.Count -eq 3 -and
      $pidPipeline.PipelineElements[0] -is
        [System.Management.Automation.Language.CommandExpressionAst] -and
      $pidConvertCommands.Count -eq 1 -and
      [object]::ReferenceEquals(
        $pidPipeline.PipelineElements[1],
        $pidConvertCommands[0]
      ) -and
      (Test-CommandCallText `
        $pidConvertCommands[0] `
        "ConvertTo-Json" `
        @("-Compress")) -and
      [object]::ReferenceEquals(
        $pidPipeline.PipelineElements[2],
        $setContentCommands[0]
      ) -and
      (Test-CommandCallText `
        $setContentCommands[0] `
        "Set-Content" `
        @("-LiteralPath", '$pidFile', "-Encoding", "UTF8")) -and
      $pidEvidenceHashtable.KeyValuePairs.Count -eq 2 -and
      (Test-MemberExpression `
        (Get-HashtableValueExpression $pidEvidenceHashtable "pid") `
        "server" `
        "Id") -and
      $pidStartTimeExpression -is
        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      -not $pidStartTimeExpression.Static -and
      (Test-VariableExpression `
        $pidStartTimeExpression.Expression `
        "serverStartTimeUtc") -and
      (Test-IdentifierEquals $pidStartTimeExpression.Member.Value "ToString") -and
      $pidStartTimeExpression.Arguments.Count -eq 1 -and
      (Test-StringExpression $pidStartTimeExpression.Arguments[0] "O")
    )
  }
  if (-not $pidEvidenceSinkIsExact) {
    Add-ContractViolation $violations "PID evidence must flow directly through JSON into Set-Content"
  }

  # health responseは必ず$responseへ代入し、response本文をsuccess streamへ流さない。
  $responseAssignments = @($allAssignments | Where-Object {
    Test-VariableExpression $_.Left "response"
  })
  if ($responseAssignments.Count -ne 1 -or
    -not (Test-DirectCommandAssignment `
      $responseAssignments[0] `
      "Invoke-WebRequest" `
      @("-Uri", '$url', "-UseBasicParsing", "-TimeoutSec", "2"))) {
    Add-ContractViolation $violations "health request output must be retained only in the response assignment"
  }

  # 初期化とcanonical capture以外の再代入/property mutationを全nested ASTから排除する。
  $serverStorageAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "server"
  })
  $handleStorageAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "serverHandle"
  })
  $postCaptureIdentityMutations = @(
    @($serverStorageAssignments + $handleStorageAssignments) | Where-Object {
      $_.Extent.StartOffset -gt $handleAssignments[0].Extent.EndOffset
    }
  )
  if ($serverStorageAssignments.Count -ne 2 -or
    $handleStorageAssignments.Count -ne 2 -or
    $postCaptureIdentityMutations.Count -ne 0) {
    Add-ContractViolation $violations "retained process identity must not be reassigned or mutated after capture"
  }

  # protected storageを別variableへ流すaliasと、深いPSObject/property writeを拒否する。
  $protectedStorageNames = @(
    "serverScript",
    "nodeCommandName",
    "serverEntry",
    "serverArguments",
    "startParameters",
    "server",
    "serverHandle"
  )
  $allowedProvenanceOffsets = @(
    $serverEntryAssignments[0].Extent.StartOffset,
    $serverArgumentAssignments[0].Extent.StartOffset,
    $startParameterAssignments[0].Extent.StartOffset,
    $serverAssignments[0].Extent.StartOffset,
    $handleAssignments[0].Extent.StartOffset,
    $serverStartTimeAssignments[0].Extent.StartOffset
  )
  $protectedAliasAssignments = @($allAssignments | Where-Object {
    $rightReferences = @($_.Right.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
      (Test-IdentifierInSet `
        (Get-NormalizedVariableName $node) `
        $protectedStorageNames)
    }, $true))
    $rightExpression = Get-PureExpression -Ast $_.Right
    $rightReferences.Count -gt 0 -and
    $allowedProvenanceOffsets -notcontains $_.Extent.StartOffset -and
    -not (Test-ReadOnlyStartParametersInvocation $rightExpression)
  })
  $indirectProtectedWrites = @($allAssignments | Where-Object {
    $leftReferences = @($_.Left.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
      (Test-IdentifierInSet `
        (Get-NormalizedVariableName $node) `
        $protectedStorageNames)
    }, $true))
    if ($leftReferences.Count -eq 0 -or
      $_.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
      return $false
    }
    $isGuardedWindowStyle = (
      $_.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and
      (Test-VariableExpression $_.Left.Target "startParameters") -and
      (Test-StringExpression $_.Left.Index "WindowStyle")
    )
    return -not $isGuardedWindowStyle
  })
  if ($protectedAliasAssignments.Count -ne 0 -or
    $indirectProtectedWrites.Count -ne 0) {
    Add-ContractViolation $violations "protected process provenance must reject aliases and indirect writes"
  }

  $postCaptureServerCalls = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $node.Static -and
    (Test-VariableExpression $node.Expression "server") -and
    $node.Extent.StartOffset -gt $handleAssignments[0].Extent.EndOffset
  }, $true))
  $killCalls = @($postCaptureServerCalls | Where-Object {
    (Test-IdentifierEquals $_.Member.Value "Kill") -and $_.Arguments.Count -eq 0
  })
  $waitCalls = @($postCaptureServerCalls | Where-Object {
    (Test-IdentifierEquals $_.Member.Value "WaitForExit") -and
    $_.Arguments.Count -eq 1 -and
    $_.Arguments[0].Value -eq 5000
  })
  $serverDisposeCalls = @($postCaptureServerCalls | Where-Object {
    (Test-IdentifierEquals $_.Member.Value "Dispose") -and
    $_.Arguments.Count -eq 0
  })
  $handleDisposeCalls = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $node.Static -and
    (Test-VariableExpression $node.Expression "serverHandle") -and
    (Test-IdentifierEquals $node.Member.Value "Dispose") -and
    $node.Arguments.Count -eq 0
  }, $true))
  $splatMemberMutations = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $node.Static -and
    (Test-VariableExpression $node.Expression "startParameters") -and
    -not (Test-ReadOnlyStartParametersInvocation $node)
  }, $true))
  if ($postCaptureServerCalls.Count -ne 3 -or
    $killCalls.Count -ne 1 -or
    $waitCalls.Count -ne 1 -or
    $serverDisposeCalls.Count -ne 1 -or
    $handleDisposeCalls.Count -ne 1 -or
    $splatMemberMutations.Count -ne 0) {
    Add-ContractViolation $violations "retained process and launch splat must reject untracked method mutation"
  }

  # instance methodは列挙済みのscalar/read-only/cleanup操作だけを許可する。
  $allInstanceInvocations = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    -not $node.Static
  }, $true))
  $unexpectedInstanceInvocations = @($allInstanceInvocations | Where-Object {
    $node = $_
    $isServerTime = (
      (Test-IdentifierEquals $node.Member.Value "ToUniversalTime") -and
      $node.Arguments.Count -eq 0 -and
      (Test-MemberExpression $node.Expression "server" "StartTime")
    )
    $isTimeFormat = (
      (Test-VariableExpression $node.Expression "serverStartTimeUtc") -and
      (Test-IdentifierEquals $node.Member.Value "ToString") -and
      $node.Arguments.Count -eq 1 -and
      (Test-StringExpression $node.Arguments[0] "O")
    )
    $isKill = (
      (Test-VariableExpression $node.Expression "server") -and
      (Test-IdentifierEquals $node.Member.Value "Kill") -and
      $node.Arguments.Count -eq 0
    )
    $isWait = (
      (Test-VariableExpression $node.Expression "server") -and
      (Test-IdentifierEquals $node.Member.Value "WaitForExit") -and
      $node.Arguments.Count -eq 1 -and
      $node.Arguments[0].Value -eq 5000
    )
    $isServerDispose = (
      (Test-VariableExpression $node.Expression "server") -and
      (Test-IdentifierEquals $node.Member.Value "Dispose") -and
      $node.Arguments.Count -eq 0
    )
    $isHandleDispose = (
      (Test-VariableExpression $node.Expression "serverHandle") -and
      (Test-IdentifierEquals $node.Member.Value "Dispose") -and
      $node.Arguments.Count -eq 0
    )
    $isVerificationAdd = (
      (Test-VariableExpression $node.Expression "failures") -and
      (Test-IdentifierEquals $node.Member.Value "Add") -and
      $node.Arguments.Count -eq 1 -and
      (Test-VariableExpression $node.Arguments[0] "verificationFailure")
    )
    $isCleanupAdd = (
      (Test-VariableExpression $node.Expression "failures") -and
      (Test-IdentifierEquals $node.Member.Value "Add") -and
      $node.Arguments.Count -eq 1 -and
      (Test-VariableExpression $node.Arguments[0] "cleanupFailure")
    )
    $isCleanupStageAdd = (
      (Test-VariableExpression $node.Expression "cleanupStageFailures") -and
      (Test-IdentifierEquals $node.Member.Value "Add") -and
      $node.Arguments.Count -eq 1 -and
      (Test-MemberExpression $node.Arguments[0] "_" "Exception")
    )
    -not (
      $isServerTime -or
      $isTimeFormat -or
      $isKill -or
      $isWait -or
      $isServerDispose -or
      $isHandleDispose -or
      $isVerificationAdd -or
      $isCleanupAdd -or
      $isCleanupStageAdd -or
      (Test-ReadOnlyStartParametersInvocation $node)
    )
  })
  if ($unexpectedInstanceInvocations.Count -ne 0) {
    Add-ContractViolation $violations "instance method provenance must use only enumerated safe operations"
  }

  # commandを介さないbare expressionもsuccess streamへ出るため、void/read-only形だけに閉じる。
  $directExpressionStatements = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
    $node.Parent -is [System.Management.Automation.Language.StatementBlockAst] -and
    $node.Parent.Statements -contains $node -and
    $node.PipelineElements.Count -eq 1 -and
    $node.PipelineElements[0] -is
      [System.Management.Automation.Language.CommandExpressionAst] -and
    -not (Test-AstHasAncestorType `
      $node `
      ([System.Management.Automation.Language.AssignmentStatementAst]))
  }, $true))
  $unexpectedExpressionStatements = @($directExpressionStatements | Where-Object {
    $expression = $_.PipelineElements[0].Expression
    $isKill = Test-InvokeMemberExpression $expression "server" "Kill"
    $isVerificationAdd = (
      $expression -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      (Test-VariableExpression $expression.Expression "failures") -and
      (Test-IdentifierEquals $expression.Member.Value "Add") -and
      $expression.Arguments.Count -eq 1 -and
      (Test-VariableExpression $expression.Arguments[0] "verificationFailure")
    )
    $isCleanupAdd = (
      $expression -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      (Test-VariableExpression $expression.Expression "failures") -and
      (Test-IdentifierEquals $expression.Member.Value "Add") -and
      $expression.Arguments.Count -eq 1 -and
      (Test-VariableExpression $expression.Arguments[0] "cleanupFailure")
    )
    $isServerDispose = Test-InvokeMemberExpression $expression "server" "Dispose"
    $isHandleDispose = Test-InvokeMemberExpression $expression "serverHandle" "Dispose"
    -not (
      $isKill -or
      $isServerDispose -or
      $isHandleDispose -or
      $isVerificationAdd -or
      $isCleanupAdd -or
      (Test-ReadOnlyStartParametersInvocation $expression)
    )
  })
  if ($unexpectedExpressionStatements.Count -ne 0) {
    Add-ContractViolation $violations "bare output expressions must use only enumerated non-sensitive operations"
  }

  # verification failureはcatch直下の代入だけを認め、dead branch/string decoyを除外する。
  $verificationAssignments = @(Get-DirectAssignments `
    $outerTry.CatchClauses[0].Body `
    "verificationFailure")
  if ($verificationAssignments.Count -ne 1 -or
    $outerTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
    -not (Test-MemberExpression `
      (Get-PureExpression $verificationAssignments[0].Right) `
      "_" `
      "Exception")) {
    Add-ContractViolation $violations "outer catch must directly retain the verification exception"
  }

  # placeholder自体もfail-closedに固定し、空script blockへの差し替えを拒否する。
  $verifyUiAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "verifyUi"
  })
  $verifyUiExpression = if ($verifyUiAssignments.Count -eq 1) {
    Get-PureExpression -Ast $verifyUiAssignments[0].Right
  } else {
    $null
  }
  $verifyUiThrow = if (
    $verifyUiExpression -is
      [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
    $verifyUiExpression.ScriptBlock.EndBlock.Statements.Count -eq 1 -and
    $verifyUiExpression.ScriptBlock.EndBlock.Statements[0] -is
      [System.Management.Automation.Language.ThrowStatementAst]
  ) {
    $verifyUiExpression.ScriptBlock.EndBlock.Statements[0]
  } else {
    $null
  }
  if ($verifyUiAssignments.Count -ne 1 -or
    $topLevel -notcontains $verifyUiAssignments[0] -or
    $verifyUiExpression -isnot
      [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
    $null -ne $verifyUiExpression.ScriptBlock.BeginBlock -or
    $null -ne $verifyUiExpression.ScriptBlock.ProcessBlock -or
    $null -eq $verifyUiThrow -or
    -not (Test-StringExpression `
      (Get-PureExpression $verifyUiThrow.Pipeline) `
      "Replace the verifyUi placeholder with bounded browser verification.")) {
    Add-ContractViolation $violations "verifyUi placeholder must remain one direct fail-closed script block"
  }

  # readiness loopは30回・1秒sleep・単一ready遷移に閉じる。
  $healthLoops = @($tryStatements | Where-Object {
    $_ -is [System.Management.Automation.Language.ForStatementAst]
  })
  $healthLoop = if ($healthLoops.Count -eq 1) {
    $healthLoops[0]
  } else {
    $null
  }
  $loopShapeIsBounded = $false
  $loopTry = $null
  $loopIterator = $null
  if ($null -ne $healthLoop) {
    $loopCondition = Get-PureExpression -Ast $healthLoop.Condition
    $loopIterator = Get-PureExpression -Ast $healthLoop.Iterator
    $loopTry = if (
      $healthLoop.Body.Statements.Count -eq 1 -and
      $healthLoop.Body.Statements[0] -is
        [System.Management.Automation.Language.TryStatementAst]
    ) {
      $healthLoop.Body.Statements[0]
    } else {
      $null
    }
    $loopShapeIsBounded = (
      $healthLoop.Initializer -is
        [System.Management.Automation.Language.AssignmentStatementAst] -and
      (Test-VariableExpression $healthLoop.Initializer.Left "attempt") -and
      (Get-PureExpression $healthLoop.Initializer.Right).Value -eq 1 -and
      $loopCondition -is
        [System.Management.Automation.Language.BinaryExpressionAst] -and
      $loopCondition.Operator -eq
        [System.Management.Automation.Language.TokenKind]::Ile -and
      (Test-VariableExpression $loopCondition.Left "attempt") -and
      $loopCondition.Right -is
        [System.Management.Automation.Language.ConstantExpressionAst] -and
      $loopCondition.Right.Value -eq 30 -and
      $loopIterator -is
        [System.Management.Automation.Language.UnaryExpressionAst] -and
      $loopIterator.TokenKind -eq
        [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus -and
      (Test-VariableExpression $loopIterator.Child "attempt") -and
      $null -ne $loopTry
    )
  }
  $readyAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "ready"
  })
  $readyInitializers = @($readyAssignments | Where-Object {
    $_.Parent -eq $outerTry.Body -and
    (Test-VariableExpression (Get-PureExpression $_.Right) "false")
  })
  $readyTransitions = @($readyAssignments | Where-Object {
    (Test-VariableExpression (Get-PureExpression $_.Right) "true") -and
    $null -ne $healthLoop -and
    (Test-AstIsDescendantOf $_ $healthLoop)
  })
  $sleepCommands = @($allCommands | Where-Object {
    Test-IdentifierEquals $_.GetCommandName() "Start-Sleep"
  })
  $loopExecutableSequenceIsExact = $false
  if ($null -ne $loopTry -and
    $loopTry.Body.Statements.Count -eq 2 -and
    $loopTry.CatchClauses.Count -eq 1 -and
    $null -eq $loopTry.Finally) {
    $statusBranch = $loopTry.Body.Statements[1]
    $statusCondition = if (
      $statusBranch -is [System.Management.Automation.Language.IfStatementAst] -and
      $statusBranch.Clauses.Count -eq 1
    ) {
      Get-PureExpression $statusBranch.Clauses[0].Item1
    } else {
      $null
    }
    $statusLeft = if (
      $statusCondition -is
        [System.Management.Automation.Language.BinaryExpressionAst]
    ) {
      $statusCondition.Left
    } else {
      $null
    }
    $statusRight = if (
      $statusCondition -is
        [System.Management.Automation.Language.BinaryExpressionAst]
    ) {
      $statusCondition.Right
    } else {
      $null
    }
    $sleepGuard = if (
      $loopTry.CatchClauses[0].Body.Statements.Count -eq 1 -and
      $loopTry.CatchClauses[0].Body.Statements[0] -is
        [System.Management.Automation.Language.IfStatementAst]
    ) {
      $loopTry.CatchClauses[0].Body.Statements[0]
    } else {
      $null
    }
    $sleepCondition = if (
      $null -ne $sleepGuard -and $sleepGuard.Clauses.Count -eq 1
    ) {
      Get-PureExpression $sleepGuard.Clauses[0].Item1
    } else {
      $null
    }
    $loopAssignments = @($healthLoop.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))
    $loopUnaryExpressions = @($healthLoop.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true))
    $loopExecutableSequenceIsExact = (
      $responseAssignments.Count -eq 1 -and
      [object]::ReferenceEquals(
        $loopTry.Body.Statements[0],
        $responseAssignments[0]
      ) -and
      $statusBranch.Clauses.Count -eq 1 -and
      $null -eq $statusBranch.ElseClause -and
      $statusCondition -is
        [System.Management.Automation.Language.BinaryExpressionAst] -and
      $statusCondition.Operator -eq
        [System.Management.Automation.Language.TokenKind]::And -and
      $statusLeft -is
        [System.Management.Automation.Language.BinaryExpressionAst] -and
      $statusLeft.Operator -eq
        [System.Management.Automation.Language.TokenKind]::Ige -and
      (Test-MemberExpression $statusLeft.Left "response" "StatusCode") -and
      $statusLeft.Right.Value -eq 200 -and
      $statusRight -is
        [System.Management.Automation.Language.BinaryExpressionAst] -and
      $statusRight.Operator -eq
        [System.Management.Automation.Language.TokenKind]::Ilt -and
      (Test-MemberExpression $statusRight.Left "response" "StatusCode") -and
      $statusRight.Right.Value -eq 500 -and
      $statusBranch.Clauses[0].Item2.Statements.Count -eq 2 -and
      $readyTransitions.Count -eq 1 -and
      [object]::ReferenceEquals(
        $statusBranch.Clauses[0].Item2.Statements[0],
        $readyTransitions[0]
      ) -and
      $statusBranch.Clauses[0].Item2.Statements[1] -is
        [System.Management.Automation.Language.BreakStatementAst] -and
      $null -ne $sleepGuard -and
      $sleepGuard.Clauses.Count -eq 1 -and
      $null -eq $sleepGuard.ElseClause -and
      $sleepCondition -is
        [System.Management.Automation.Language.BinaryExpressionAst] -and
      $sleepCondition.Operator -eq
        [System.Management.Automation.Language.TokenKind]::Ilt -and
      (Test-VariableExpression $sleepCondition.Left "attempt") -and
      $sleepCondition.Right.Value -eq 30 -and
      $sleepGuard.Clauses[0].Item2.Statements.Count -eq 1 -and
      $sleepCommands.Count -eq 1 -and
      [object]::ReferenceEquals(
        $sleepGuard.Clauses[0].Item2.Statements[0],
        $sleepCommands[0].Parent
      ) -and
      $loopAssignments.Count -eq 3 -and
      [object]::ReferenceEquals($loopAssignments[0], $healthLoop.Initializer) -and
      [object]::ReferenceEquals($loopAssignments[1], $responseAssignments[0]) -and
      [object]::ReferenceEquals($loopAssignments[2], $readyTransitions[0]) -and
      $loopUnaryExpressions.Count -eq 1 -and
      [object]::ReferenceEquals($loopUnaryExpressions[0], $loopIterator)
    )
  }
  if (-not $loopShapeIsBounded -or
    -not $loopExecutableSequenceIsExact -or
    $readyAssignments.Count -ne 2 -or
    $readyInitializers.Count -ne 1 -or
    $readyTransitions.Count -ne 1 -or
    $sleepCommands.Count -ne 1 -or
    -not (Test-CommandCallText `
      $sleepCommands[0] `
      "Start-Sleep" `
      @("-Seconds", "1")) -or
    -not (Test-AstIsDescendantOf $sleepCommands[0] $healthLoop)) {
    Add-ContractViolation $violations "readiness polling must remain a 30-attempt bounded loop with one-second sleep"
  }

  # route/state verificationはouter tryの最後のdirect statementとして実行する。
  $verifyStatement = $tryStatements[$tryStatements.Count - 1]
  $verifyCommands = @($verifyStatement.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
  }, $true))
  if ($verifyStatement -isnot [System.Management.Automation.Language.PipelineAst] -or
    $verifyCommands.Count -ne 1 -or
    $verifyCommands[0].InvocationOperator -ne
      [System.Management.Automation.Language.TokenKind]::Ampersand -or
    $verifyCommands[0].CommandElements.Count -ne 1 -or
    -not (Test-VariableExpression $verifyCommands[0].CommandElements[0] "verifyUi")) {
    Add-ContractViolation $violations "verifyUi must be the final direct statement in the cleanup-owning try"
  }

  # health timeoutはraw本文を読まず、direct ASTで固定metadataを構成してthrowする。
  $healthBranches = @($tryStatements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and
    (Test-NotVariableCondition $_.Clauses[0].Item1 "ready")
  })
  if ($healthBranches.Count -ne 1) {
    Add-ContractViolation $violations "one direct health-timeout branch is required"
  } else {
    $healthBlock = $healthBranches[0].Clauses[0].Item2
    $expectedHealthSignatures = @(
      'AssignmentStatementAst|$stderrSizeBytes',
      'IfStatementAst|',
      'AssignmentStatementAst|$healthDiagnostic',
      'PipelineAst|',
      'ThrowStatementAst|'
    )
    $healthSequenceIsExact = $healthBlock.Statements.Count -eq
      $expectedHealthSignatures.Count
    if ($healthSequenceIsExact) {
      for ($index = 0; $index -lt $expectedHealthSignatures.Count; $index++) {
        $leftText = if ($healthBlock.Statements[$index] -is
            [System.Management.Automation.Language.AssignmentStatementAst]) {
          $healthBlock.Statements[$index].Left.Extent.Text
        } else {
          ""
        }
        $actualSignature = $healthBlock.Statements[$index].GetType().Name +
          "|" + $leftText
        if (-not (Test-OrdinalStringEquals `
            $actualSignature `
            $expectedHealthSignatures[$index])) {
          $healthSequenceIsExact = $false
          break
        }
      }
    }
    if (-not $healthSequenceIsExact) {
      Add-ContractViolation $violations "health timeout block must match the closed executable sequence"
    }
    $stderrSizeAssignments = @($allAssignments | Where-Object {
      (Test-VariableExpression $_.Left "stderrSizeBytes") -and
      (Test-AstIsDescendantOf $_ $healthBlock)
    })
    $stderrSizeInitializer = @($stderrSizeAssignments | Where-Object {
      $_.Parent -eq $healthBlock -and
      (Get-PureExpression $_.Right).Value -eq 0
    })
    $stderrSizeMeasurements = @($stderrSizeAssignments | Where-Object {
      $expression = Get-PureExpression $_.Right
      $expression -is [System.Management.Automation.Language.MemberExpressionAst] -and
      (Test-IdentifierEquals $expression.Member.Value "Length")
    })
    $stderrMeasurementShapeIsExact = $false
    if ($stderrSizeMeasurements.Count -eq 1) {
      $sizeAssignment = $stderrSizeMeasurements[0]
      $sizeExpression = Get-PureExpression $sizeAssignment.Right
      $getItemCommands = @($sizeAssignment.Right.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
      }, $true))
      $sizeGuardBlock = $sizeAssignment.Parent
      $sizeGuard = if (
        $sizeGuardBlock -is
          [System.Management.Automation.Language.StatementBlockAst]
      ) {
        $sizeGuardBlock.Parent
      } else {
        $null
      }
      $sizeGuardCommands = if (
        $sizeGuard -is [System.Management.Automation.Language.IfStatementAst]
      ) {
        @($sizeGuard.Clauses[0].Item1.FindAll({
          param($node)
          $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))
      } else {
        @()
      }
      $stderrMeasurementShapeIsExact = (
        $sizeExpression.Expression -is
          [System.Management.Automation.Language.ParenExpressionAst] -and
        $getItemCommands.Count -eq 1 -and
        (Test-CommandCallText `
          $getItemCommands[0] `
          "Get-Item" `
          @("-LiteralPath", '$stderr')) -and
        (Test-AstIsDescendantOf $getItemCommands[0] $sizeAssignment) -and
        $sizeGuard.Clauses.Count -eq 1 -and
        $null -eq $sizeGuard.ElseClause -and
        $sizeGuardBlock.Statements.Count -eq 1 -and
        $sizeGuardCommands.Count -eq 1 -and
        (Test-CommandCallText `
          $sizeGuardCommands[0] `
          "Test-Path" `
          @("-LiteralPath", '$stderr', "-PathType", "Leaf"))
      )
    }
    if ($stderrSizeAssignments.Count -ne 2 -or
      $stderrSizeInitializer.Count -ne 1 -or
      -not $stderrMeasurementShapeIsExact) {
      Add-ContractViolation $violations "stderr byte count must derive only from guarded Get-Item.Length"
    }

    $diagnosticAssignments = @(Get-DirectAssignments $healthBlock "healthDiagnostic")
    $diagnosticStorageAssignments = @($allAssignments | Where-Object {
      Test-AssignmentTargetsStorage -Assignment $_ -Variable "healthDiagnostic"
    })
    $diagnosticAliases = @($allAssignments | Where-Object {
      @($_.Right.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        (Test-IdentifierEquals `
          (Get-NormalizedVariableName $node) `
          "healthDiagnostic")
      }, $true)).Count -gt 0
    })
    if ($diagnosticAssignments.Count -ne 1 -or
      $diagnosticStorageAssignments.Count -ne 1 -or
      $diagnosticAliases.Count -ne 0 -or
      -not [object]::ReferenceEquals(
        $diagnosticAssignments[0],
        $diagnosticStorageAssignments[0]
      )) {
      Add-ContractViolation $violations "health timeout must directly build one classified diagnostic"
    } else {
      $diagnosticExpression = Get-PureExpression -Ast $diagnosticAssignments[0].Right
      $orderedExpression = if (
        $diagnosticExpression -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        (Test-IdentifierEquals `
          $diagnosticExpression.Type.TypeName.FullName `
          "pscustomobject")
      ) {
        $diagnosticExpression.Child
      } else {
        $null
      }
      $diagnosticHashtable = if (
        $orderedExpression -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        (Test-IdentifierEquals `
          $orderedExpression.Type.TypeName.FullName `
          "ordered") -and
        $orderedExpression.Child -is [System.Management.Automation.Language.HashtableAst]
      ) {
        $orderedExpression.Child
      } else {
        $null
      }
      if ($null -eq $diagnosticHashtable -or
        $diagnosticHashtable.KeyValuePairs.Count -ne 4 -or
        -not (Test-StringExpression `
          (Get-HashtableValueExpression $diagnosticHashtable "classification") `
          "readiness-timeout") -or
        -not (Test-StringExpression `
          (Get-HashtableValueExpression $diagnosticHashtable "logId") `
          "dev-server.err.log") -or
        -not (Test-VariableExpression `
          (Get-HashtableValueExpression $diagnosticHashtable "logBytes") `
          "stderrSizeBytes") -or
        (Get-HashtableValueExpression $diagnosticHashtable "attempts").Value -ne 30) {
        Add-ContractViolation $violations "health diagnostic needs fixed class, relative log ID, size, and attempt count"
      }
    }

    $warningStatements = @($healthBlock.Statements | Where-Object {
      $_ -is [System.Management.Automation.Language.PipelineAst] -and
      $_.PipelineElements.Count -eq 1 -and
      $_.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
      (Test-IdentifierEquals `
        $_.PipelineElements[0].GetCommandName() `
        "Write-Warning")
    })
    $warningShapeIsSafe = $false
    if ($warningStatements.Count -eq 1) {
      $warningCommands = @($warningStatements[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
      }, $true))
      $warningVariables = @($warningStatements[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst]
      }, $true))
      $convertCommands = @($warningCommands | Where-Object {
        Test-IdentifierEquals $_.GetCommandName() "ConvertTo-Json"
      })
      $writeCommand = $warningStatements[0].PipelineElements[0]
      $warningShapeIsSafe = (
        $warningCommands.Count -eq 2 -and
        $writeCommand.CommandElements.Count -eq 2 -and
        $warningVariables.Count -eq 1 -and
        (Test-VariableExpression $warningVariables[0] "healthDiagnostic") -and
        $convertCommands.Count -eq 1 -and
        $convertCommands[0].CommandElements.Count -eq 2 -and
        $convertCommands[0].CommandElements[1] -is
          [System.Management.Automation.Language.CommandParameterAst] -and
        (Test-IdentifierEquals `
          $convertCommands[0].CommandElements[1].ParameterName `
          "Compress")
      )
    }
    if (-not $warningShapeIsSafe -or
      -not (Test-DirectTypedThrow $healthBlock "System.TimeoutException")) {
      Add-ContractViolation $violations "health timeout must emit metadata and directly throw TimeoutException"
    }
  }

  # finally直下のserver guardが、停止・失敗集約・分類結果を同じ順序で支配する。
  if ($outerTry.Finally.Statements.Count -ne 1 -or
    $outerTry.Finally.Statements[0] -isnot
      [System.Management.Automation.Language.IfStatementAst]) {
    Add-ContractViolation $violations "finally must contain one direct owned-server guard"
    return $violations.ToArray()
  }
  $serverGuard = $outerTry.Finally.Statements[0]
  $serverGuardCondition = Get-PureExpression -Ast $serverGuard.Clauses[0].Item1
  if ($serverGuard.Clauses.Count -ne 1 -or
    -not (Test-NullComparison `
      $serverGuardCondition `
      ([System.Management.Automation.Language.TokenKind]::Ine) `
      "server") -or
    $null -ne $serverGuard.ElseClause -or
    $serverGuard.Clauses[0].Item2.Statements.Count -ne 3 -or
    $serverGuard.Clauses[0].Item2.Statements[0] -isnot
      [System.Management.Automation.Language.TryStatementAst] -or
    $serverGuard.Clauses[0].Item2.Statements[1] -isnot
      [System.Management.Automation.Language.IfStatementAst] -or
    $serverGuard.Clauses[0].Item2.Statements[2] -isnot
      [System.Management.Automation.Language.IfStatementAst]) {
    Add-ContractViolation $violations "cleanup stages must be directly dominated by the owned-server guard"
    return $violations.ToArray()
  }
  $stopTry = $serverGuard.Clauses[0].Item2.Statements[0]
  $cleanupAggregationBranch = $serverGuard.Clauses[0].Item2.Statements[1]
  $cleanupResultBranch = $serverGuard.Clauses[0].Item2.Statements[2]
  if ($stopTry.CatchClauses.Count -ne 1 -or
    $null -eq $stopTry.Finally -or
    $stopTry.Body.Statements.Count -ne 2 -or
    $stopTry.Finally.Statements.Count -ne 1 -or
    $stopTry.Finally.Statements[0] -isnot
      [System.Management.Automation.Language.TryStatementAst]) {
    Add-ContractViolation $violations "cleanup stop attempt must own one catch and one disposal finally"
    return $violations.ToArray()
  }
  $cleanupStatements = @($stopTry.Body.Statements)
  $exitBranches = @($cleanupStatements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses.Count -eq 1 -and
    (Test-MemberExpression `
      (Get-PureExpression $_.Clauses[0].Item1) `
      "server" `
      "HasExited")
  })
  if ($exitBranches.Count -ne 1 -or
    $exitBranches[0].ElseClause.Statements.Count -ne 3) {
    Add-ContractViolation $violations "same Process object must control exited/kill/wait cleanup"
  } else {
    $elseStatements = @($exitBranches[0].ElseClause.Statements)
    $killTry = $elseStatements[0]
    if ($killTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
      $killTry.Body.Statements.Count -ne 1 -or
      $killTry.CatchClauses.Count -ne 1 -or
      $null -ne $killTry.Finally -or
      -not (Test-InvokeMemberExpression `
        (Get-PureExpression $killTry.Body.Statements[0]) `
        "server" `
        "Kill")) {
      Add-ContractViolation $violations "Kill must be the first direct action in a race-aware try"
    } else {
      $killCatchStatements = @($killTry.CatchClauses[0].Body.Statements)
      $killRaceBranch = if (
        $killCatchStatements.Count -eq 1 -and
        $killCatchStatements[0] -is [System.Management.Automation.Language.IfStatementAst]
      ) {
        $killCatchStatements[0]
      } else {
        $null
      }
      if ($null -eq $killRaceBranch -or
        $killRaceBranch.Clauses.Count -ne 1 -or
        $null -ne $killRaceBranch.ElseClause -or
        -not (Test-NotMemberCondition `
          $killRaceBranch.Clauses[0].Item1 `
          "server" `
          "HasExited") -or
        -not (Test-DirectBareRethrow $killRaceBranch.Clauses[0].Item2)) {
        Add-ContractViolation $violations "Kill race catch must recheck the retained Process and rethrow only while running"
      }
    }

    $waitGuard = $elseStatements[1]
    if ($waitGuard -isnot [System.Management.Automation.Language.IfStatementAst] -or
      $waitGuard.Clauses.Count -ne 1 -or
      $null -ne $waitGuard.ElseClause -or
      -not (Test-NotMemberCondition `
        $waitGuard.Clauses[0].Item1 `
        "server" `
        "HasExited") -or
      $waitGuard.Clauses[0].Item2.Statements.Count -ne 1) {
      Add-ContractViolation $violations "bounded wait must be guarded by the same retained Process"
    } else {
      $waitBranch = $waitGuard.Clauses[0].Item2.Statements[0]
      $waitCondition = if (
        $waitBranch -is [System.Management.Automation.Language.IfStatementAst] -and
        $waitBranch.Clauses.Count -eq 1
      ) {
        Get-PureExpression -Ast $waitBranch.Clauses[0].Item1
      } else {
        $null
      }
      if ($waitCondition -isnot [System.Management.Automation.Language.UnaryExpressionAst] -or
        $waitCondition.TokenKind -ne
          [System.Management.Automation.Language.TokenKind]::Not -or
        -not (Test-InvokeMemberExpression `
          $waitCondition.Child `
          "server" `
          "WaitForExit" `
          @("5000")) -or
        -not (Test-DirectTypedThrow `
          $waitBranch.Clauses[0].Item2 `
          "System.TimeoutException")) {
        Add-ContractViolation $violations "WaitForExit(5000) timeout must directly throw cleanup failure"
      }
    }

    $stopResultAssignment = $elseStatements[2]
    if ($stopResultAssignment -isnot
        [System.Management.Automation.Language.AssignmentStatementAst] -or
      -not (Test-VariableExpression $stopResultAssignment.Left "cleanupResult") -or
      -not (Test-StringExpression `
        (Get-PureExpression $stopResultAssignment.Right) `
        "Server process stop was confirmed.")) {
      Add-ContractViolation $violations "owned-process branch must report one fixed confirmed cleanup result"
    }
  }

  $handleGuardBranches = if ($exitBranches.Count -eq 1) {
    @($cleanupStatements | Where-Object {
      $_ -is [System.Management.Automation.Language.IfStatementAst] -and
      $_.Extent.StartOffset -lt $exitBranches[0].Extent.StartOffset
    })
  } else {
    @()
  }
  $partialCleanupAssignment = if (
    $handleGuardBranches.Count -eq 1 -and
    $handleGuardBranches[0].Clauses.Count -eq 1 -and
    $handleGuardBranches[0].Clauses[0].Item2.Statements.Count -eq 1
  ) {
    $handleGuardBranches[0].Clauses[0].Item2.Statements[0]
  } else {
    $null
  }
  if ($cleanupStatements.Count -ne 2 -or
    $handleGuardBranches.Count -ne 1 -or
    $null -ne $handleGuardBranches[0].ElseClause -or
    -not (Test-ServerHandleUnavailableExpression `
      (Get-PureExpression $handleGuardBranches[0].Clauses[0].Item1)) -or
    $partialCleanupAssignment -isnot
      [System.Management.Automation.Language.AssignmentStatementAst] -or
    -not (Test-VariableExpression `
      $partialCleanupAssignment.Left `
      "cleanupResult") -or
    -not (Test-StringExpression `
      (Get-PureExpression $partialCleanupAssignment.Right) `
      "Partial-start cleanup is using the direct Process object.")) {
    Add-ContractViolation $violations "partial-start cleanup must use the exact null/invalid/closed OR guard and continue"
  }

  # Stop・SafeHandle・Processの各失敗を順序付きlistへ保存し、後段の失敗で隠さない。
  $resourceTry = $stopTry.Finally.Statements[0]
  $disposeShapeIsExact = $false
  $stopCatchStatements = @($stopTry.CatchClauses[0].Body.Statements)
  if ($resourceTry.CatchClauses.Count -eq 0 -and
    $null -ne $resourceTry.Finally -and
    $resourceTry.Body.Statements.Count -eq 1 -and
    $resourceTry.Body.Statements[0] -is
      [System.Management.Automation.Language.IfStatementAst] -and
    $resourceTry.Finally.Statements.Count -eq 1 -and
    $resourceTry.Finally.Statements[0] -is
      [System.Management.Automation.Language.TryStatementAst]) {
    $handleDisposeGuard = $resourceTry.Body.Statements[0]
    $handleDisposeTry = if (
      $handleDisposeGuard.Clauses.Count -eq 1 -and
      $handleDisposeGuard.Clauses[0].Item2.Statements.Count -eq 1 -and
      $handleDisposeGuard.Clauses[0].Item2.Statements[0] -is
        [System.Management.Automation.Language.TryStatementAst]
    ) {
      $handleDisposeGuard.Clauses[0].Item2.Statements[0]
    } else {
      $null
    }
    $processDisposeTry = $resourceTry.Finally.Statements[0]
    $handleDisposeShapeIsExact = (
      $null -ne $handleDisposeTry -and
      $handleDisposeGuard.Clauses.Count -eq 1 -and
      $null -eq $handleDisposeGuard.ElseClause -and
      (Test-NullComparison `
        (Get-PureExpression $handleDisposeGuard.Clauses[0].Item1) `
        ([System.Management.Automation.Language.TokenKind]::Ine) `
        "serverHandle") -and
      $handleDisposeTry.Body.Statements.Count -eq 1 -and
      $handleDisposeTry.CatchClauses.Count -eq 1 -and
      $null -eq $handleDisposeTry.Finally -and
      (Test-InvokeMemberExpression `
        (Get-PureExpression $handleDisposeTry.Body.Statements[0]) `
        "serverHandle" `
        "Dispose") -and
      $handleDisposeTry.CatchClauses[0].Body.Statements.Count -eq 1 -and
      (Test-CleanupStageAddPipeline `
        $handleDisposeTry.CatchClauses[0].Body.Statements[0])
    )
    $processDisposeShapeIsExact = (
      $processDisposeTry.Body.Statements.Count -eq 1 -and
      $processDisposeTry.CatchClauses.Count -eq 1 -and
      $null -eq $processDisposeTry.Finally -and
      (Test-InvokeMemberExpression `
        (Get-PureExpression $processDisposeTry.Body.Statements[0]) `
        "server" `
        "Dispose") -and
      $processDisposeTry.CatchClauses[0].Body.Statements.Count -eq 1 -and
      (Test-CleanupStageAddPipeline `
        $processDisposeTry.CatchClauses[0].Body.Statements[0])
    )
    $disposeShapeIsExact = $handleDisposeShapeIsExact -and
      $processDisposeShapeIsExact
  }
  if ($stopCatchStatements.Count -ne 1 -or
    -not (Test-CleanupStageAddPipeline $stopCatchStatements[0]) -or
    -not $disposeShapeIsExact) {
    Add-ContractViolation $violations "cleanup stages must retain stop, SafeHandle, and Process failures in order"
  }

  $stageAddStatements = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
    (Test-CleanupStageAddPipeline $node)
  }, $true))
  if ($stageAddStatements.Count -ne 3 -or
    $stageAddStatements[0].Extent.StartOffset -ge
      $stageAddStatements[1].Extent.StartOffset -or
    $stageAddStatements[1].Extent.StartOffset -ge
      $stageAddStatements[2].Extent.StartOffset) {
    Add-ContractViolation $violations "cleanup stage failure list must receive exactly three ordered catch writes"
  }

  # 1件は元例外を保ち、複数件だけ固定AggregateExceptionへ束ねる。
  $stageFailureListAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "cleanupStageFailures"
  })
  $stageFailureListExpression = if ($stageFailureListAssignments.Count -eq 1) {
    Get-PureExpression $stageFailureListAssignments[0].Right
  } else {
    $null
  }
  $singleCleanupAssignments = if (
    $cleanupAggregationBranch.Clauses.Count -ge 1
  ) {
    @(Get-DirectAssignments `
      $cleanupAggregationBranch.Clauses[0].Item2 `
      "cleanupFailure")
  } else {
    @()
  }
  $multipleCleanupAssignments = if (
    $cleanupAggregationBranch.Clauses.Count -ge 2
  ) {
    @(Get-DirectAssignments `
      $cleanupAggregationBranch.Clauses[1].Item2 `
      "cleanupFailure")
  } else {
    @()
  }
  $multipleCleanupExpression = if ($multipleCleanupAssignments.Count -eq 1) {
    Get-PureExpression $multipleCleanupAssignments[0].Right
  } else {
    $null
  }
  $cleanupAggregationShapeIsExact = (
    $stageFailureListAssignments.Count -eq 1 -and
    $topLevel -contains $stageFailureListAssignments[0] -and
    (Test-StaticNewExpression `
      $stageFailureListExpression `
      "System.Collections.Generic.List[System.Exception]" `
      0) -and
    $cleanupAggregationBranch.Clauses.Count -eq 2 -and
    $null -eq $cleanupAggregationBranch.ElseClause -and
    (Test-VariableMemberComparison `
      (Get-PureExpression $cleanupAggregationBranch.Clauses[0].Item1) `
      "cleanupStageFailures" `
      "Count" `
      ([System.Management.Automation.Language.TokenKind]::Ieq) `
      1) -and
    $singleCleanupAssignments.Count -eq 1 -and
    $cleanupAggregationBranch.Clauses[0].Item2.Statements.Count -eq 1 -and
    (Test-VariableIndexExpression `
      (Get-PureExpression $singleCleanupAssignments[0].Right) `
      "cleanupStageFailures" `
      0) -and
    (Test-VariableMemberComparison `
      (Get-PureExpression $cleanupAggregationBranch.Clauses[1].Item1) `
      "cleanupStageFailures" `
      "Count" `
      ([System.Management.Automation.Language.TokenKind]::Igt) `
      1) -and
    $multipleCleanupAssignments.Count -eq 1 -and
    $cleanupAggregationBranch.Clauses[1].Item2.Statements.Count -eq 1 -and
    (Test-StaticNewExpression `
      $multipleCleanupExpression `
      "System.AggregateException" `
      2) -and
    (Test-StringExpression `
      $multipleCleanupExpression.Arguments[0] `
      "Multiple server cleanup stages failed.") -and
    (Test-VariableExpression `
      $multipleCleanupExpression.Arguments[1] `
      "cleanupStageFailures")
  )
  if (-not $cleanupAggregationShapeIsExact) {
    Add-ContractViolation $violations "cleanup stage failures must preserve one exception or aggregate multiple failures"
  }

  $cleanupResultAssignmentsInBranch = if (
    $cleanupResultBranch.Clauses.Count -eq 1
  ) {
    @(Get-DirectAssignments `
      $cleanupResultBranch.Clauses[0].Item2 `
      "cleanupResult")
  } else {
    @()
  }
  if ($cleanupResultBranch.Clauses.Count -ne 1 -or
    $null -ne $cleanupResultBranch.ElseClause -or
    -not (Test-VariableMemberComparison `
      (Get-PureExpression $cleanupResultBranch.Clauses[0].Item1) `
      "cleanupStageFailures" `
      "Count" `
      ([System.Management.Automation.Language.TokenKind]::Igt) `
      0) -or
    $cleanupResultAssignmentsInBranch.Count -ne 1 -or
    $cleanupResultBranch.Clauses[0].Item2.Statements.Count -ne 1 -or
    -not (Test-StringExpression `
      (Get-PureExpression $cleanupResultAssignmentsInBranch[0].Right) `
      "Cleanup failed; inspect the propagated exception.")) {
    Add-ContractViolation $violations "cleanup classification must fail when any stage exception was retained"
  }

  # top-levelの連続した3 branchだけがdual/single failureを伝播する。
  $outerIndex = [Array]::IndexOf($topLevel, $outerTry)
  if ($outerIndex + 3 -ge $topLevel.Count) {
    Add-ContractViolation $violations "failure propagation branches are missing"
    return $violations.ToArray()
  }
  $dualBranch = $topLevel[$outerIndex + 1]
  $verificationBranch = $topLevel[$outerIndex + 2]
  $cleanupBranch = $topLevel[$outerIndex + 3]
  if ($dualBranch -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $verificationBranch -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $cleanupBranch -isnot [System.Management.Automation.Language.IfStatementAst]) {
    Add-ContractViolation $violations "dual and single failure branches must directly follow outer try"
    return $violations.ToArray()
  }

  $dualCondition = Get-PureExpression -Ast $dualBranch.Clauses[0].Item1
  if ($dualCondition -isnot [System.Management.Automation.Language.BinaryExpressionAst] -or
    $dualCondition.Operator -ne [System.Management.Automation.Language.TokenKind]::And -or
    -not (Test-NullComparison `
      $dualCondition.Left `
      ([System.Management.Automation.Language.TokenKind]::Ine) `
      "verificationFailure") -or
    -not (Test-NullComparison `
      $dualCondition.Right `
      ([System.Management.Automation.Language.TokenKind]::Ine) `
      "cleanupFailure")) {
    Add-ContractViolation $violations "dual failure branch must require both retained exceptions"
  }

  $dualStatements = @($dualBranch.Clauses[0].Item2.Statements)
  $dualFailureShapeIsExact = $false
  if ($dualStatements.Count -eq 4 -and
    $dualStatements[0] -is
      [System.Management.Automation.Language.AssignmentStatementAst] -and
    (Test-VariableExpression $dualStatements[0].Left "failures")) {
    $listInitializer = Get-PureExpression -Ast $dualStatements[0].Right
    $verificationAdd = Get-PureExpression -Ast $dualStatements[1]
    $cleanupAdd = Get-PureExpression -Ast $dualStatements[2]
    $aggregateThrow = $dualStatements[3]
    $aggregateExpression = if (
      $aggregateThrow -is [System.Management.Automation.Language.ThrowStatementAst]
    ) {
      Get-PureExpression -Ast $aggregateThrow.Pipeline
    } else {
      $null
    }
    $dualFailureShapeIsExact = (
      (Test-StaticNewExpression `
        $listInitializer `
        "System.Collections.Generic.List[System.Exception]" `
        0) -and
      $verificationAdd -is
        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      -not $verificationAdd.Static -and
      (Test-VariableExpression $verificationAdd.Expression "failures") -and
      (Test-IdentifierEquals $verificationAdd.Member.Value "Add") -and
      $verificationAdd.Arguments.Count -eq 1 -and
      (Test-VariableExpression $verificationAdd.Arguments[0] "verificationFailure") -and
      $cleanupAdd -is
        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
      -not $cleanupAdd.Static -and
      (Test-VariableExpression $cleanupAdd.Expression "failures") -and
      (Test-IdentifierEquals $cleanupAdd.Member.Value "Add") -and
      $cleanupAdd.Arguments.Count -eq 1 -and
      (Test-VariableExpression $cleanupAdd.Arguments[0] "cleanupFailure") -and
      (Test-StaticNewExpression `
        $aggregateExpression `
        "System.AggregateException" `
        2) -and
      (Test-StringExpression `
        $aggregateExpression.Arguments[0] `
        "Browser verification and server cleanup both failed.") -and
      (Test-VariableExpression $aggregateExpression.Arguments[1] "failures")
    )
  }
  if (-not $dualFailureShapeIsExact) {
    Add-ContractViolation $violations "AggregateException must use the exact typed list, add order, and final throw"
  }

  $verificationCondition = Get-PureExpression -Ast $verificationBranch.Clauses[0].Item1
  $cleanupCondition = Get-PureExpression -Ast $cleanupBranch.Clauses[0].Item1
  if (-not (Test-NullComparison `
      $verificationCondition `
      ([System.Management.Automation.Language.TokenKind]::Ine) `
      "verificationFailure") -or
    -not (Test-DirectThrowVariable `
      $verificationBranch.Clauses[0].Item2 `
      "verificationFailure")) {
    Add-ContractViolation $violations "standalone verification failure must be directly rethrown"
  }
  if (-not (Test-NullComparison `
      $cleanupCondition `
      ([System.Management.Automation.Language.TokenKind]::Ine) `
      "cleanupFailure") -or
    -not (Test-DirectThrowVariable `
      $cleanupBranch.Clauses[0].Item2 `
      "cleanupFailure")) {
    Add-ContractViolation $violations "standalone cleanup failure must be directly rethrown"
  }

  # static invocationは固定例外生成とtyped failure listだけに限定し、reflection出力を拒否する。
  $staticInvocations = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Static
  }, $true))
  $staticKindCounts = @{}
  $unexpectedStaticInvocations = 0
  foreach ($node in $staticInvocations) {
    $kind = $null
    if ((Test-StaticNewExpression $node "System.TimeoutException" 1) -and
      (Test-StringExpression `
        $node.Arguments[0] `
        "Server readiness timed out; inspect the classified log metadata.")) {
      $kind = "readiness-timeout"
    } elseif (
      (Test-StaticNewExpression $node "System.TimeoutException" 1) -and
      (Test-StringExpression `
        $node.Arguments[0] `
        "Server process did not stop within the bounded cleanup wait.")
    ) {
      $kind = "cleanup-timeout"
    } elseif (
      Test-StaticNewExpression `
        $node `
        "System.Collections.Generic.List[System.Exception]" `
        0
    ) {
      $kind = "failure-list"
    } elseif (
      (Test-StaticNewExpression $node "System.AggregateException" 2) -and
      (Test-StringExpression `
        $node.Arguments[0] `
        "Multiple server cleanup stages failed.") -and
      (Test-VariableExpression `
        $node.Arguments[1] `
        "cleanupStageFailures")
    ) {
      $kind = "cleanup-stage-aggregate"
    } elseif (
      (Test-StaticNewExpression $node "System.AggregateException" 2) -and
      (Test-StringExpression `
        $node.Arguments[0] `
        "Browser verification and server cleanup both failed.") -and
      (Test-VariableExpression $node.Arguments[1] "failures")
    ) {
      $kind = "aggregate"
    }
    if ($null -eq $kind) {
      $unexpectedStaticInvocations++
    } else {
      if (-not $staticKindCounts.ContainsKey($kind)) {
        $staticKindCounts[$kind] = 0
      }
      $staticKindCounts[$kind]++
    }
  }
  $staticSetIsExact = $unexpectedStaticInvocations -eq 0 -and
    $staticKindCounts.Count -eq 5
  foreach ($requiredKind in @(
    "readiness-timeout",
    "cleanup-timeout",
    "failure-list",
    "cleanup-stage-aggregate",
    "aggregate"
  )) {
    $requiredCount = if ($requiredKind -ceq "failure-list") { 2 } else { 1 }
    if (-not $staticKindCounts.ContainsKey($requiredKind) -or
      $staticKindCounts[$requiredKind] -ne $requiredCount) {
      $staticSetIsExact = $false
    }
  }
  if (-not $staticSetIsExact) {
    Add-ContractViolation $violations "static invocation set must contain only fixed exception/list constructors"
  }

  # 全throwを固定shape・固定message・保持済みexceptionの再throwだけへ閉じる。
  $throwKindCounts = @{}
  $unexpectedThrows = 0
  $allThrows = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ThrowStatementAst]
  }, $true))
  foreach ($throwStatement in $allThrows) {
    $kind = $null
    if ($null -eq $throwStatement.Pipeline) {
      $kind = "kill-race-rethrow"
    } else {
      $throwExpression = Get-PureExpression -Ast $throwStatement.Pipeline
      if (Test-StringExpression `
        $throwExpression `
        "The direct Vite server entry was not found.") {
        $kind = "missing-server-script"
      } elseif (
        Test-StringExpression `
          $throwExpression `
          "Replace the verifyUi placeholder with bounded browser verification."
      ) {
        $kind = "verify-placeholder"
      } elseif (
        Test-StringExpression `
          $throwExpression `
          "The direct server process handle could not be retained."
      ) {
        $kind = "handle-retain"
      } elseif (Test-ReadOnlySplatGuardThrow $throwStatement) {
        $kind = "read-only-splat-guard"
      } elseif (
        (Test-StaticNewExpression $throwExpression "System.TimeoutException" 1) -and
        (Test-StringExpression `
          $throwExpression.Arguments[0] `
          "Server readiness timed out; inspect the classified log metadata.")
      ) {
        $kind = "readiness-timeout"
      } elseif (
        (Test-StaticNewExpression $throwExpression "System.TimeoutException" 1) -and
        (Test-StringExpression `
          $throwExpression.Arguments[0] `
          "Server process did not stop within the bounded cleanup wait.")
      ) {
        $kind = "cleanup-timeout"
      } elseif (
        (Test-StaticNewExpression $throwExpression "System.AggregateException" 2) -and
        (Test-StringExpression `
          $throwExpression.Arguments[0] `
          "Browser verification and server cleanup both failed.") -and
        (Test-VariableExpression $throwExpression.Arguments[1] "failures")
      ) {
        $kind = "aggregate"
      } elseif (Test-VariableExpression $throwExpression "verificationFailure") {
        $kind = "verification-rethrow"
      } elseif (Test-VariableExpression $throwExpression "cleanupFailure") {
        $kind = "cleanup-rethrow"
      }
    }
    if ($null -eq $kind) {
      $unexpectedThrows++
    } else {
      if (-not $throwKindCounts.ContainsKey($kind)) {
        $throwKindCounts[$kind] = 0
      }
      $throwKindCounts[$kind]++
    }
  }
  $optionalGuardCount = if ($throwKindCounts.ContainsKey("read-only-splat-guard")) {
    $throwKindCounts["read-only-splat-guard"]
  } else {
    0
  }
  $throwSetIsExact = (
    $unexpectedThrows -eq 0 -and
    $optionalGuardCount -le 1 -and
    $throwKindCounts.Count -eq (9 + $optionalGuardCount)
  )
  foreach ($requiredKind in @(
    "missing-server-script",
    "verify-placeholder",
    "handle-retain",
    "readiness-timeout",
    "kill-race-rethrow",
    "cleanup-timeout",
    "aggregate",
    "verification-rethrow",
    "cleanup-rethrow"
  )) {
    if (-not $throwKindCounts.ContainsKey($requiredKind) -or
      $throwKindCounts[$requiredKind] -ne 1) {
      $throwSetIsExact = $false
    }
  }
  if (-not $throwSetIsExact) {
    Add-ContractViolation $violations "throw set must use only fixed messages and retained exceptions"
  }

  # public console outputは列挙済み固定文だけから作り、absolute rootを反射させない。
  $cleanupResultAssignments = @($allAssignments | Where-Object {
    Test-AssignmentTargetsStorage -Assignment $_ -Variable "cleanupResult"
  })
  $allowedCleanupResults = @(
    "Server process was not started.",
    "Partial-start cleanup is using the direct Process object.",
    "Server process had already stopped.",
    "Server process stop was confirmed.",
    "Cleanup failed; inspect the propagated exception."
  )
  $unexpectedCleanupResults = @($cleanupResultAssignments | Where-Object {
    $valueExpression = Get-PureExpression -Ast $_.Right
    $valueExpression -isnot
      [System.Management.Automation.Language.StringConstantExpressionAst] -or
    -not (Test-OrdinalStringInSet `
      $valueExpression.Value `
      $allowedCleanupResults)
  })
  $writeHostCommands = @($allCommands | Where-Object {
    Test-IdentifierEquals $_.GetCommandName() "Write-Host"
  })
  if ($cleanupResultAssignments.Count -ne 5 -or
    $unexpectedCleanupResults.Count -ne 0 -or
    $writeHostCommands.Count -ne 1 -or
    $writeHostCommands[0].CommandElements.Count -ne 2 -or
    -not (Test-VariableExpression `
      $writeHostCommands[0].CommandElements[1] `
      "cleanupResult")) {
    Add-ContractViolation $violations "public cleanup report must use only fixed classified result text"
  }

  return $violations.ToArray()
}

function New-MutatedFixture {
  param(
    [string]$Markdown,
    [string]$Needle,
    [string]$Replacement,
    [string]$Name
  )

  $count = [regex]::Matches($Markdown, [regex]::Escape($Needle)).Count
  if ($count -ne 1) {
    throw "Fixture '$Name' expected one mutation target, found $count."
  }
  return $Markdown.Replace($Needle, $Replacement)
}

function Invoke-SyntheticServerIntegration {
  param([string]$RepoRoot)

  $runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
  $tempDirectory = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) ("bounded-runbook-" + [guid]::NewGuid().ToString("N"))
  $fixtureSource = Join-Path $RepoRoot "tests/fixtures/synthetic-http-server.js"
  $fixtureCopy = Join-Path $tempDirectory "synthetic-http-server.js"
  $stdout = Join-Path $tempDirectory "server.out.log"
  $stderr = Join-Path $tempDirectory "server.err.log"
  $server = $null
  $serverHandle = $null
  $testFailure = $null
  $cleanupFailure = $null
  $ready = $false

  New-Item -ItemType Directory -Path $tempDirectory | Out-Null
  Copy-Item -LiteralPath $fixtureSource -Destination $fixtureCopy

  $reservation = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    0
  )
  $reservation.Start()
  $port = $reservation.LocalEndpoint.Port
  $reservation.Stop()

  try {
    $nodeCommandName = if ($runtimeIsWindows) { "node.exe" } else { "node" }
    $hostExecutable = (
      Get-Command $nodeCommandName -CommandType Application -ErrorAction Stop
    ).Source
    $startParameters = @{
      FilePath = $hostExecutable
      ArgumentList = @(
        "synthetic-http-server.js",
        "--port", $port,
        "--max-lifetime-ms", 15000
      )
      WorkingDirectory = $tempDirectory
      RedirectStandardOutput = $stdout
      RedirectStandardError = $stderr
      PassThru = $true
    }
    if ($runtimeIsWindows) {
      $startParameters["WindowStyle"] = "Hidden"
    }

    $server = Start-Process @startParameters
    $serverHandle = $server.SafeHandle
    if ($serverHandle.IsInvalid -or $serverHandle.IsClosed) {
      throw "Synthetic direct server handle was not retained."
    }
    if (-not [object]::ReferenceEquals($server.SafeHandle, $serverHandle)) {
      throw "Synthetic Process object did not retain the same SafeHandle instance."
    }

    for ($attempt = 1; $attempt -le 50; $attempt++) {
      try {
        $response = Invoke-WebRequest `
          -Uri "http://127.0.0.1:$port/" `
          -UseBasicParsing `
          -TimeoutSec 1
        if ($response.StatusCode -eq 200 -and $response.Content -eq "ok") {
          $ready = $true
          break
        }
      } catch {
        if ($attempt -lt 50) {
          Start-Sleep -Milliseconds 100
        }
      }
    }
    if (-not $ready) {
      $stderrBytes = if (Test-Path -LiteralPath $stderr) {
        (Get-Item -LiteralPath $stderr).Length
      } else {
        0
      }
      throw "Synthetic readiness failed (classification=readiness-timeout; stderrBytes=$stderrBytes)."
    }
  } catch {
    $testFailure = $_.Exception
  } finally {
    if ($null -ne $server) {
      try {
        try {
          if ($null -eq $serverHandle -or
            $serverHandle.IsInvalid -or
            $serverHandle.IsClosed) {
            throw "Synthetic cleanup lost the retained handle."
          }
          if (-not $server.HasExited) {
            $server.Kill()
            if (-not $server.WaitForExit(5000)) {
              throw "Synthetic cleanup exceeded 5000 ms."
            }
          }
        } finally {
          # production例と同じ順序で両wrapperを決定的に解放する。
          try {
            if ($null -ne $serverHandle) {
              $serverHandle.Dispose()
            }
          } finally {
            $server.Dispose()
          }
        }
      } catch {
        $cleanupFailure = $_.Exception
      }
    }
  }

  $artifactsRemoved = $false
  $artifactRemovalFailure = $null
  for ($removeAttempt = 1; $removeAttempt -le 20; $removeAttempt++) {
    try {
      # Windows redirect handleのrelease遅延だけを有限retryで吸収する。
      foreach ($path in @($fixtureCopy, $stdout, $stderr)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          Remove-Item -LiteralPath $path -Force
        }
      }
      Remove-Item -LiteralPath $tempDirectory
      $artifactsRemoved = $true
      break
    } catch {
      $artifactRemovalFailure = $_.Exception
      if ($removeAttempt -lt 20) {
        Start-Sleep -Milliseconds 50
      }
    }
  }
  if (-not $artifactsRemoved) {
    if ($null -eq $cleanupFailure) {
      $cleanupFailure = $artifactRemovalFailure
    }
  }

  if ($null -ne $testFailure -and $null -ne $cleanupFailure) {
    $failures = [System.Collections.Generic.List[System.Exception]]::new()
    $failures.Add($testFailure)
    $failures.Add($cleanupFailure)
    throw [System.AggregateException]::new(
      "Synthetic server verification and cleanup both failed.",
      $failures
    )
  }
  if ($null -ne $testFailure) {
    throw $testFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
  if (-not $ready) {
    throw "Synthetic direct server never became ready."
  }
}

function Invoke-SyntheticNaturalExitRace {
  param([string]$RepoRoot)

  $runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
  $tempDirectory = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) ("bounded-runbook-race-" + [guid]::NewGuid().ToString("N"))
  $fixtureSource = Join-Path $RepoRoot "tests/fixtures/synthetic-http-server.js"
  $fixtureCopy = Join-Path $tempDirectory "synthetic-http-server.js"
  $stdout = Join-Path $tempDirectory "server.out.log"
  $stderr = Join-Path $tempDirectory "server.err.log"
  $server = $null
  $serverHandle = $null
  $testFailure = $null
  $cleanupFailure = $null
  $raceRecovered = $false
  $ready = $false

  New-Item -ItemType Directory -Path $tempDirectory | Out-Null
  Copy-Item -LiteralPath $fixtureSource -Destination $fixtureCopy

  $reservation = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    0
  )
  $reservation.Start()
  $port = $reservation.LocalEndpoint.Port
  $reservation.Stop()

  try {
    $nodeCommandName = if ($runtimeIsWindows) { "node.exe" } else { "node" }
    $hostExecutable = (
      Get-Command $nodeCommandName -CommandType Application -ErrorAction Stop
    ).Source
    $startParameters = @{
      FilePath = $hostExecutable
      ArgumentList = @(
        "synthetic-http-server.js",
        "--port", $port,
        "--max-lifetime-ms", 3000
      )
      WorkingDirectory = $tempDirectory
      RedirectStandardOutput = $stdout
      RedirectStandardError = $stderr
      PassThru = $true
    }
    if ($runtimeIsWindows) {
      $startParameters["WindowStyle"] = "Hidden"
    }

    $server = Start-Process @startParameters
    $serverHandle = $server.SafeHandle
    if ($serverHandle.IsInvalid -or $serverHandle.IsClosed) {
      throw "Synthetic race fixture did not retain the direct process handle."
    }

    # 実serverが正常起動したことを有限pollで確認してから、自然終了を待つ。
    for ($attempt = 1; $attempt -le 20; $attempt++) {
      try {
        $response = Invoke-WebRequest `
          -Uri "http://127.0.0.1:$port/" `
          -UseBasicParsing `
          -TimeoutSec 1
        if ($response.StatusCode -eq 200 -and $response.Content -eq "ok") {
          $ready = $true
          break
        }
      } catch {
        if ($attempt -lt 20) {
          Start-Sleep -Milliseconds 100
        }
      }
    }
    if (-not $ready -or $server.HasExited) {
      throw "Synthetic race fixture did not reach the initial running state."
    }

    # production raceを決定的に再現するため、最初のfalse確認後に自然終了を同期する。
    if (-not $server.WaitForExit(5000)) {
      throw "Synthetic race fixture did not exit naturally within 5000 ms."
    }
    $killFailureObserved = $false
    try {
      $server.Kill()
      # PowerShell 7では終了済みProcessへのKillがno-opになる実装もある。
      # その場合もPS5.1の例外を合成し、同じcatch recoveryを両hostで実行する。
      if ($server.HasExited) {
        throw [System.InvalidOperationException]::new(
          "Synthetic PS5.1 natural-exit race."
        )
      }
    } catch {
      $killFailureObserved = $true
      if (-not $server.HasExited) {
        throw
      }
      $raceRecovered = $true
    }
    if (-not $killFailureObserved) {
      throw "Synthetic race fixture did not exercise the Kill failure path."
    }
  } catch {
    $testFailure = $_.Exception
  } finally {
    if ($null -ne $server) {
      try {
        try {
          if (-not $server.HasExited) {
            $server.Kill()
            if (-not $server.WaitForExit(5000)) {
              throw "Synthetic race cleanup exceeded 5000 ms."
            }
          }
        } finally {
          try {
            if ($null -ne $serverHandle) {
              $serverHandle.Dispose()
            }
          } finally {
            $server.Dispose()
          }
        }
      } catch {
        $cleanupFailure = $_.Exception
      }
    }
    try {
      foreach ($path in @($fixtureCopy, $stdout, $stderr)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          Remove-Item -LiteralPath $path -Force
        }
      }
      Remove-Item -LiteralPath $tempDirectory
    } catch {
      if ($null -eq $cleanupFailure) {
        $cleanupFailure = $_.Exception
      }
    }
  }

  if ($null -ne $testFailure -and $null -ne $cleanupFailure) {
    $failures = [System.Collections.Generic.List[System.Exception]]::new()
    $failures.Add($testFailure)
    $failures.Add($cleanupFailure)
    throw [System.AggregateException]::new(
      "Synthetic natural-exit race and cleanup both failed.",
      $failures
    )
  }
  if ($null -ne $testFailure) {
    throw $testFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
  if (-not $raceRecovered) {
    throw "Synthetic natural-exit race was not recovered."
  }
}

function Invoke-SyntheticPartialStartCleanup {
  param([string]$RepoRoot)

  $runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
  $tempDirectory = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) ("bounded-runbook-partial-" + [guid]::NewGuid().ToString("N"))
  $fixtureSource = Join-Path $RepoRoot "tests/fixtures/synthetic-http-server.js"
  $fixtureCopy = Join-Path $tempDirectory "synthetic-http-server.js"
  $stdout = Join-Path $tempDirectory "server.out.log"
  $stderr = Join-Path $tempDirectory "server.err.log"
  $server = $null
  $serverHandle = $null
  $serverDisposed = $false
  $partialCleanupObserved = $false
  $stopConfirmed = $false
  $testFailure = $null
  $cleanupFailure = $null
  $ready = $false

  New-Item -ItemType Directory -Path $tempDirectory | Out-Null
  Copy-Item -LiteralPath $fixtureSource -Destination $fixtureCopy

  $reservation = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    0
  )
  $reservation.Start()
  $port = $reservation.LocalEndpoint.Port
  $reservation.Stop()

  try {
    $nodeCommandName = if ($runtimeIsWindows) { "node.exe" } else { "node" }
    $hostExecutable = (
      Get-Command $nodeCommandName -CommandType Application -ErrorAction Stop
    ).Source
    $startParameters = @{
      FilePath = $hostExecutable
      ArgumentList = @(
        "synthetic-http-server.js",
        "--port", $port,
        "--max-lifetime-ms", 30000
      )
      WorkingDirectory = $tempDirectory
      RedirectStandardOutput = $stdout
      RedirectStandardError = $stderr
      PassThru = $true
    }
    if ($runtimeIsWindows) {
      $startParameters["WindowStyle"] = "Hidden"
    }

    # Start後のSafeHandle取得失敗を合成するため、Processだけを直接保持する。
    $server = Start-Process @startParameters
    for ($attempt = 1; $attempt -le 50; $attempt++) {
      try {
        $response = Invoke-WebRequest `
          -Uri "http://127.0.0.1:$port/" `
          -UseBasicParsing `
          -TimeoutSec 1
        if ($response.StatusCode -eq 200 -and $response.Content -eq "ok") {
          $ready = $true
          break
        }
      } catch {
        if ($attempt -lt 50) {
          Start-Sleep -Milliseconds 100
        }
      }
    }
    if (-not $ready -or $server.HasExited) {
      throw "Synthetic partial-start fixture did not reach a running state."
    }
  } catch {
    $testFailure = $_.Exception
  } finally {
    if ($null -ne $server) {
      try {
        try {
          # production例と同じ3項OR guardでpartial-start経路を選ぶ。
          if ($null -eq $serverHandle -or
            $serverHandle.IsInvalid -or
            $serverHandle.IsClosed) {
            $partialCleanupObserved = $true
          }
          if (-not $server.HasExited) {
            try {
              $server.Kill()
            } catch {
              if (-not $server.HasExited) {
                throw
              }
            }
            if (-not $server.HasExited -and -not $server.WaitForExit(5000)) {
              throw "Synthetic partial-start cleanup exceeded 5000 ms."
            }
          }
          $stopConfirmed = $server.HasExited
        } finally {
          # handleがnullでもProcess.Disposeは必ず実行し、部分開始のwrapperを残さない。
          try {
            if ($null -ne $serverHandle) {
              $serverHandle.Dispose()
            }
          } finally {
            $server.Dispose()
            $serverDisposed = $true
          }
        }
      } catch {
        $cleanupFailure = $_.Exception
      }
    }
  }

  # assertion失敗時も合成serverを残さないbounded fallbackを持つ。
  if ($null -ne $server -and -not $serverDisposed) {
    try {
      if (-not $server.HasExited) {
        $server.Kill()
        if (-not $server.WaitForExit(5000)) {
          throw "Synthetic partial-start fallback cleanup exceeded 5000 ms."
        }
      }
      $server.Dispose()
      $serverDisposed = $true
    } catch {
      if ($null -eq $cleanupFailure) {
        $cleanupFailure = $_.Exception
      }
    }
  }
  $partialArtifactsRemoved = $false
  $partialArtifactRemovalFailure = $null
  for ($removeAttempt = 1; $removeAttempt -le 20; $removeAttempt++) {
    try {
      foreach ($path in @($fixtureCopy, $stdout, $stderr)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          Remove-Item -LiteralPath $path -Force
        }
      }
      Remove-Item -LiteralPath $tempDirectory
      $partialArtifactsRemoved = $true
      break
    } catch {
      $partialArtifactRemovalFailure = $_.Exception
      if ($removeAttempt -lt 20) {
        Start-Sleep -Milliseconds 50
      }
    }
  }
  if (-not $partialArtifactsRemoved) {
    if ($null -eq $cleanupFailure) {
      $cleanupFailure = $partialArtifactRemovalFailure
    }
  }

  if ($null -ne $testFailure -and $null -ne $cleanupFailure) {
    $failures = [System.Collections.Generic.List[System.Exception]]::new()
    $failures.Add($testFailure)
    $failures.Add($cleanupFailure)
    throw [System.AggregateException]::new(
      "Synthetic partial-start verification and cleanup both failed.",
      $failures
    )
  }
  if ($null -ne $testFailure) {
    throw $testFailure
  }
  if ($null -ne $cleanupFailure) {
    throw $cleanupFailure
  }
  if (-not $ready -or
    -not $partialCleanupObserved -or
    -not $stopConfirmed -or
    -not $serverDisposed) {
    throw "Synthetic partial-start cleanup contract was not fully observed."
  }
}

function Assert-CleanupStageFailureAggregation {
  # 3段階すべてを故障させ、後段のDispose失敗が先行例外を隠さないことを実行確認する。
  $fakeServer = New-Object psobject -Property @{ HasExited = $false }
  $fakeServer | Add-Member -MemberType ScriptMethod -Name Kill -Value {
    throw [System.InvalidOperationException]::new("stop-failure")
  }
  $fakeServer | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    return $true
  }
  $fakeServer | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    throw [System.ApplicationException]::new("process-dispose-failure")
  }
  $fakeHandle = New-Object psobject -Property @{
    IsInvalid = $false
    IsClosed = $false
  }
  $fakeHandle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
    throw [System.ApplicationException]::new("handle-dispose-failure")
  }

  $cleanupStageFailures = [System.Collections.Generic.List[System.Exception]]::new()
  $cleanupFailure = $null
  try {
    if (-not $fakeServer.HasExited) {
      $fakeServer.Kill()
    }
  } catch {
    $cleanupStageFailures.Add($_.Exception) | Out-Null
  } finally {
    try {
      if ($null -ne $fakeHandle) {
        try {
          $fakeHandle.Dispose()
        } catch {
          $cleanupStageFailures.Add($_.Exception) | Out-Null
        }
      }
    } finally {
      try {
        $fakeServer.Dispose()
      } catch {
        $cleanupStageFailures.Add($_.Exception) | Out-Null
      }
    }
  }

  if ($cleanupStageFailures.Count -eq 1) {
    $cleanupFailure = $cleanupStageFailures[0]
  } elseif ($cleanupStageFailures.Count -gt 1) {
    $cleanupFailure = [System.AggregateException]::new(
      "Multiple server cleanup stages failed.",
      $cleanupStageFailures
    )
  }

  $messages = if ($cleanupFailure -is [System.AggregateException]) {
    @($cleanupFailure.InnerExceptions | ForEach-Object {
      # ScriptMethodはMethodInvocationExceptionで包むため、内側の固定故障IDを比較する。
      if ($null -ne $_.InnerException) {
        $_.InnerException.Message
      } else {
        $_.Message
      }
    })
  } else {
    @()
  }
  $expectedMessages = @(
    "stop-failure",
    "handle-dispose-failure",
    "process-dispose-failure"
  )
  if ($cleanupStageFailures.Count -ne 3 -or
    $cleanupFailure -isnot [System.AggregateException] -or
    $cleanupFailure.Message -notlike "Multiple server cleanup stages failed.*" -or
    $messages.Count -ne $expectedMessages.Count -or
    (Compare-Object `
      -ReferenceObject $expectedMessages `
      -DifferenceObject $messages `
      -SyncWindow 0).Count -ne 0) {
    throw "Cleanup stage failures were not aggregated in stop/handle/process order."
  }
}

function Assert-ClassifiedDiagnosticPrivacy {
  $hostileRootCanary = [System.IO.Path]::GetFullPath(
    (Join-Path ([System.IO.Path]::GetTempPath()) "HOSTILE_ROOT_CANARY_DO_NOT_REFLECT")
  )
  $absoluteStderr = Join-Path $hostileRootCanary "dev-server.err.log"
  $healthDiagnostic = [pscustomobject][ordered]@{
    classification = "readiness-timeout"
    logId = "dev-server.err.log"
    logBytes = 123
    attempts = 30
  }
  $publicWarning = $healthDiagnostic | ConvertTo-Json -Compress

  # absolute pathはlocal inspectionだけに残し、公開metadataへ混ぜない。
  if ($publicWarning.Contains($hostileRootCanary) -or
    $publicWarning.Contains($absoluteStderr) -or
    $publicWarning -notmatch '"logId":"dev-server\.err\.log"') {
    throw "Classified diagnostic reflected a hostile absolute root."
  }
}

$repoRoot = (Resolve-Path -LiteralPath $Root).Path
$runbookPath = Join-Path $repoRoot "examples/server-runbook.md"
$canonicalTemplatePath = Join-Path $repoRoot "examples/server-runbook.ps1"
$failures = New-Object System.Collections.Generic.List[string]
$runbook = ""
$script:CanonicalServerRunbookCode = $null
$script:ExactReadOnlyServerRunbookVariants = @()

try {
  $runbook = Get-StrictUtf8LfFileText `
    -Path $runbookPath `
    -Description "server runbook Markdown"
  $script:CanonicalServerRunbookCode = Get-StrictUtf8LfFileText `
    -Path $canonicalTemplatePath `
    -Description "canonical server runbook template"
} catch {
  $failures.Add("canonical runbook encoding: $($_.Exception.Message)") | Out-Null
}

if ($null -ne $script:CanonicalServerRunbookCode) {
  # Markdown側もCommonMark parserで1 blockへ閉じ、culture非依存のOrdinalでbytesを照合する。
  $canonicalFenceScan = Get-CommonMarkFenceScan -Markdown $runbook
  $canonicalFenceBlocks = @($canonicalFenceScan.Blocks)
  $canonicalFenceBlock = if ($canonicalFenceBlocks.Count -eq 1) {
    $canonicalFenceBlocks[0]
  } else {
    $null
  }
  $canonicalHeader = "## Complete Bounded Workflow`n`n"
  $canonicalHeaderStart = if ($null -ne $canonicalFenceBlock) {
    $canonicalFenceBlock.OpenOffset - $canonicalHeader.Length
  } else {
    -1
  }
  $canonicalFenceIsExact = (
    $canonicalFenceScan.UnclosedFenceCount -eq 0 -and
    $canonicalFenceScan.AmbiguousFenceLikeCount -eq 0 -and
    $canonicalFenceBlocks.Count -eq 1 -and
    $canonicalFenceBlock.Character -eq '`' -and
    $canonicalFenceBlock.Length -eq 3 -and
    $canonicalFenceBlock.Indent -eq 0 -and
    (Test-OrdinalStringEquals $canonicalFenceBlock.Info "powershell") -and
    (Test-OrdinalStringEquals $canonicalFenceBlock.OpenLine '```powershell') -and
    (Test-OrdinalStringEquals $canonicalFenceBlock.CloseLine '```') -and
    $canonicalHeaderStart -ge 0 -and
    (Test-OrdinalStringEquals `
      $runbook.Substring($canonicalHeaderStart, $canonicalHeader.Length) `
      $canonicalHeader) -and
    (Test-OrdinalStringEquals `
      $canonicalFenceBlock.Content `
      $script:CanonicalServerRunbookCode)
  )
  if (-not $canonicalFenceIsExact) {
    $failures.Add(
      "canonical runbook drift: Markdown must contain one exact executable block"
    ) | Out-Null
  }

  # read-only照会は4個のclosed variantだけを生成し、任意の追加ASTを許可しない。
  $startNeedle = '$server = Start-Process @startParameters'
  $script:ExactReadOnlyServerRunbookVariants = @(
    (New-MutatedFixture `
      $script:CanonicalServerRunbookCode `
      $startNeedle `
      (
        '$null = $startParameters.ContainsKey("FilePath")' + "`n  " +
        $startNeedle
      ) `
      "canonical-read-only-assigned"),
    (New-MutatedFixture `
      $script:CanonicalServerRunbookCode `
      $startNeedle `
      (
        '$startParameters.ContainsKey("ArgumentList")' + "`n  " +
        $startNeedle
      ) `
      "canonical-read-only-bare"),
    (New-MutatedFixture `
      $script:CanonicalServerRunbookCode `
      $startNeedle `
      (
        '$startParameters.ContainsKey("WorkingDirectory") | Out-Null' + "`n  " +
        $startNeedle
      ) `
      "canonical-read-only-out-null"),
    (New-MutatedFixture `
      $script:CanonicalServerRunbookCode `
      $startNeedle `
      (
        'if (-not $startParameters.ContainsKey("FilePath")) {' + "`n    " +
        'throw "Missing direct executable."' + "`n  " +
        '}' + "`n  " +
        $startNeedle
      ) `
      "canonical-read-only-guard")
  )
  if ($script:ExactReadOnlyServerRunbookVariants.Count -ne 4) {
    $failures.Add("canonical read-only variant set must contain exactly four entries") |
      Out-Null
  }
}

$actualViolations = @(Get-ServerRunbookContractViolations -Markdown $runbook)
foreach ($violation in $actualViolations) {
  $failures.Add("actual runbook: $violation") | Out-Null
}

$expectedHostileFixtureCount = 93
$hostileFixtureCount = 0
if ($actualViolations.Count -eq 0) {
  # root ScriptBlockの非statement面もcanonical bodyを包めるため、各入口を個別に壊す。
  $canonicalFirstLine =
    '$runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT'
  $canonicalLastLine = 'Write-Host $cleanupResult'
  $rootNamedEndFixture = New-MutatedFixture `
    (New-MutatedFixture `
      $runbook `
      $canonicalFirstLine `
      ('end {' + "`n" + $canonicalFirstLine) `
      "root-named-end-wrapper-open") `
    $canonicalLastLine `
    ($canonicalLastLine + "`n" + '}') `
    "root-named-end-wrapper-close"
  $rootBeginEndFixture = New-MutatedFixture `
    (New-MutatedFixture `
      $runbook `
      $canonicalFirstLine `
      ('begin { break }' + "`n" + 'end {' + "`n" + $canonicalFirstLine) `
      "root-begin-end-wrapper-open") `
    $canonicalLastLine `
    ($canonicalLastLine + "`n" + '}') `
    "root-begin-end-wrapper-close"
  $rootProcessEndFixture = New-MutatedFixture `
    (New-MutatedFixture `
      $runbook `
      $canonicalFirstLine `
      ('process { break }' + "`n" + 'end {' + "`n" + $canonicalFirstLine) `
      "root-process-end-wrapper-open") `
    $canonicalLastLine `
    ($canonicalLastLine + "`n" + '}') `
    "root-process-end-wrapper-close"
  $rootDynamicParamEndFixture = New-MutatedFixture `
    (New-MutatedFixture `
      $runbook `
      $canonicalFirstLine `
      ('dynamicparam { break }' + "`n" + 'end {' + "`n" + $canonicalFirstLine) `
      "root-dynamicparam-end-wrapper-open") `
    $canonicalLastLine `
    ($canonicalLastLine + "`n" + '}') `
    "root-dynamicparam-end-wrapper-close"
  $rootCleanEndFixture = New-MutatedFixture `
    (New-MutatedFixture `
      $runbook `
      $canonicalFirstLine `
      ('clean { break }' + "`n" + 'end {' + "`n" + $canonicalFirstLine) `
      "root-clean-end-wrapper-open") `
    $canonicalLastLine `
    ($canonicalLastLine + "`n" + '}') `
    "root-clean-end-wrapper-close"

  # direct control-flowの各境界を一つずつ壊し、dead nodeやstring/commentで相殺できないことを固定する。
  $fixtures = @(
    @{
      Name = "root-param-block"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        $canonicalFirstLine `
        ('param()' + "`n" + $canonicalFirstLine) `
        "root-param-block"
    },
    @{
      Name = "root-using-module"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        $canonicalFirstLine `
        (
          'using module Microsoft.PowerShell.Utility' + "`n" +
          $canonicalFirstLine
        ) `
        "root-using-module"
    },
    @{
      Name = "root-trap"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        $canonicalFirstLine `
        ('trap { continue }' + "`n" + $canonicalFirstLine) `
        "root-trap"
    },
    @{
      Name = "root-script-requirements"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        $canonicalFirstLine `
        ('#requires -Version 5.1' + "`n" + $canonicalFirstLine) `
        "root-script-requirements"
    },
    @{
      Name = "root-named-end-wrapper"
      SynchronizeCanonical = $true
      Markdown = $rootNamedEndFixture
    },
    @{
      Name = "root-begin-end-wrapper"
      SynchronizeCanonical = $true
      Markdown = $rootBeginEndFixture
    },
    @{
      Name = "root-process-end-wrapper"
      SynchronizeCanonical = $true
      Markdown = $rootProcessEndFixture
    },
    @{
      Name = "root-dynamicparam-end-wrapper"
      SynchronizeCanonical = $true
      Markdown = $rootDynamicParamEndFixture
    },
    @{
      Name = "root-clean-end-wrapper"
      SynchronizeCanonical = $true
      Markdown = $rootCleanEndFixture
    },
    @{
      Name = "health-loop-attempt-decrement-after-sleep"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        'Start-Sleep -Seconds 1' `
        ('Start-Sleep -Seconds 1' + "`n        " + '$null = --$attempt') `
        "health-loop-attempt-decrement-after-sleep"
    },
    @{
      Name = "start-process-function-shadow"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          'function Start-Process {}' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "start-process-function-shadow"
    },
    @{
      Name = "url-definition-changed"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        '$url = "http://127.0.0.1:5173/"' `
        '$url = "http://127.0.0.1:9/"' `
        "url-definition-changed"
    },
    @{
      Name = "pid-file-mutated-in-nested-branch"
      SynchronizeCanonical = $true
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverStartTimeUtc = $server.StartTime.ToUniversalTime()' `
        (
          '$serverStartTimeUtc = $server.StartTime.ToUniversalTime()' + "`n  " +
          'if ($true) { $pidFile = "README.md" }'
        ) `
        "pid-file-mutated-in-nested-branch"
    },
    @{
      Name = "extra-tilde-powershell-block"
      Markdown = (
        $runbook + "`n" + '~~~powershell' + "`n" +
        'Write-Host "unreviewed tilde workflow"' + "`n" + '~~~' + "`n"
      )
    },
    @{
      Name = "extra-four-backtick-powershell-block"
      Markdown = (
        $runbook + "`n" + '````powershell' + "`n" +
        'Write-Host "unreviewed long-fence workflow"' + "`n" + '````' + "`n"
      )
    },
    @{
      Name = "extra-mixed-case-powershell-block"
      Markdown = (
        $runbook + "`n" + '```PowerShell' + "`n" +
        'Write-Host "unreviewed mixed-case workflow"' + "`n" + '```' + "`n"
      )
    },
    @{
      Name = "canonical-soft-hyphen-byte-drift"
      Markdown = New-MutatedFixture `
        $runbook `
        '# Force the Process object to acquire its OS handle immediately.' `
        (
          '# Force' + [char]0x00AD +
          ' the Process object to acquire its OS handle immediately.'
        ) `
        "canonical-soft-hyphen-byte-drift"
    },
    @{
      Name = "extra-powershell-block"
      Markdown = (
        $runbook + "`n" + '```powershell' + "`n" +
        'Write-Host "unreviewed second workflow"' + "`n" + '```' + "`n"
      )
    },
    @{
      Name = "canonical-code-prefix"
      Markdown = New-MutatedFixture `
        $runbook `
        '$runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT' `
        (
          '$null = "unreviewed prefix"' + "`n" +
          '$runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT'
        ) `
        "canonical-code-prefix"
    },
    @{
      Name = "canonical-code-suffix"
      Markdown = New-MutatedFixture `
        $runbook `
        'Write-Host $cleanupResult' `
        ('Write-Host $cleanupResult' + "`n" + '$null = "unreviewed suffix"') `
        "canonical-code-suffix"
    },
    @{
      Name = "cleanup-stage-aggregate-message-changed"
      Markdown = New-MutatedFixture `
        $runbook `
        '"Multiple server cleanup stages failed."' `
        '"Only the last cleanup failure was retained."' `
        "cleanup-stage-aggregate-message-changed"
    },
    @{
      Name = "cleanup-outside-finally"
      Markdown = New-MutatedFixture `
        $runbook `
        ("finally {`n  if (`$null -ne `$server) {") `
        ("if (`$true) {`n  if (`$null -ne `$server) {") `
        "cleanup-outside-finally"
    },
    @{
      Name = "task-runner-filepath"
      Markdown = New-MutatedFixture $runbook 'FilePath = $serverEntry' 'FilePath = "npm.cmd"' "task-runner-filepath"
    },
    @{
      Name = "server-entry-def-use-cut"
      Markdown = New-MutatedFixture `
        $runbook `
        'FilePath = $serverEntry' `
        'FilePath = $root' `
        "server-entry-def-use-cut"
    },
    @{
      Name = "server-script-def-use-cut"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverScript,' `
        '"node_modules/vite/bin/alternate.js",' `
        "server-script-def-use-cut"
    },
    @{
      Name = "server-reassigned-after-handle"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + 'if ($true) { $server = $null }') `
        "server-reassigned-after-handle"
    },
    @{
      Name = "server-reassigned-with-mixed-case"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + '$SeRvEr = $null') `
        "server-reassigned-with-mixed-case"
    },
    @{
      Name = "server-reassigned-with-local-scope"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + '$local:server = $null') `
        "server-reassigned-with-local-scope"
    },
    @{
      Name = "server-reassigned-through-variable-provider"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          '${variable:server} = $null'
        ) `
        "server-reassigned-through-variable-provider"
    },
    @{
      Name = "server-property-mutated-after-handle"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + '$server.EnableRaisingEvents = $true') `
        "server-property-mutated-after-handle"
    },
    @{
      Name = "start-filepath-overwritten"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        ('$startParameters["FilePath"] = $root' + "`n  " + '$server = Start-Process @startParameters') `
        "start-filepath-overwritten"
    },
    @{
      Name = "start-filepath-overwritten-with-local-scope"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$local:startParameters["FilePath"] = $root' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "start-filepath-overwritten-with-local-scope"
    },
    @{
      Name = "start-filepath-overwritten-through-variable-provider"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '${variable:startParameters}["FilePath"] = $root' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "start-filepath-overwritten-through-variable-provider"
    },
    @{
      Name = "server-arguments-mutated-by-method"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$serverArguments.SetValue($root, 0)' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "server-arguments-mutated-by-method"
    },
    @{
      Name = "start-filepath-overwritten-through-alias"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$launchAlias = $startParameters' + "`n  " +
          '$launchAlias["FilePath"] = $root' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "start-filepath-overwritten-through-alias"
    },
    @{
      Name = "server-entry-mutated-through-psvariable"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$ExecutionContext.SessionState.PSVariable.Set("serverEntry", $root)' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "server-entry-mutated-through-psvariable"
    },
    @{
      Name = "dual-list-initializer-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        '$failures = [System.Collections.Generic.List[System.Exception]]::new()' `
        '$failures = $null' `
        "dual-list-initializer-removed"
    },
    @{
      Name = "raw-stderr-replay"
      Markdown = New-MutatedFixture `
        $runbook `
        '$stderrSizeBytes = 0' `
        "Get-Content -LiteralPath `$stderr -Tail 80`n    `$stderrSizeBytes = 0" `
        "raw-stderr-replay"
    },
    @{
      Name = "initial-handle-guard-and-instead-of-or"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'if ($null -eq $serverHandle -or' + "`n" +
          '    $serverHandle.IsInvalid -or' + "`n" +
          '    $serverHandle.IsClosed) {'
        ) `
        (
          'if ($null -eq $serverHandle -and' + "`n" +
          '    $serverHandle.IsInvalid -and' + "`n" +
          '    $serverHandle.IsClosed) {'
        ) `
        "initial-handle-guard-and-instead-of-or"
    },
    @{
      Name = "initial-handle-null-check-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'if ($null -eq $serverHandle -or' + "`n" +
          '    $serverHandle.IsInvalid -or' + "`n" +
          '    $serverHandle.IsClosed) {'
        ) `
        'if ($serverHandle.IsInvalid -or $serverHandle.IsClosed) {' `
        "initial-handle-null-check-removed"
    },
    @{
      Name = "cleanup-handle-guard-and-instead-of-or"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'if ($null -eq $serverHandle -or' + "`n" +
          '        $serverHandle.IsInvalid -or' + "`n" +
          '        $serverHandle.IsClosed) {'
        ) `
        (
          'if ($null -eq $serverHandle -and' + "`n" +
          '        $serverHandle.IsInvalid -and' + "`n" +
          '        $serverHandle.IsClosed) {'
        ) `
        "cleanup-handle-guard-and-instead-of-or"
    },
    @{
      Name = "partial-start-cleanup-replaced-by-throw"
      Markdown = New-MutatedFixture `
        $runbook `
        '$cleanupResult = "Partial-start cleanup is using the direct Process object."' `
        'throw "Partial-start cleanup was skipped."' `
        "partial-start-cleanup-replaced-by-throw"
    },
    @{
      Name = "safe-handle-dispose-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle.Dispose()' `
        '$null = $serverHandle' `
        "safe-handle-dispose-removed"
    },
    @{
      Name = "process-dispose-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server.Dispose()' `
        '$null = $server' `
        "process-dispose-removed"
    },
    @{
      Name = "stderr-size-provenance-cut"
      Markdown = New-MutatedFixture `
        $runbook `
        '$stderrSizeBytes = (Get-Item -LiteralPath $stderr).Length' `
        (
          '$stderrSizeBytes = $root' + "`n    " +
          '(Get-Item -LiteralPath $stderr) | Out-Null'
        ) `
        "stderr-size-provenance-cut"
    },
    @{
      Name = "bare-get-item-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$stderrSizeBytes = (Get-Item -LiteralPath $stderr).Length' `
        'Get-Item -LiteralPath $stderr' `
        "bare-get-item-output"
    },
    @{
      Name = "bare-resolve-path-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$root = (Resolve-Path ".").Path' `
        ('Resolve-Path "."' + "`n" + '$root = "."') `
        "bare-resolve-path-output"
    },
    @{
      Name = "bare-new-item-output"
      Markdown = New-MutatedFixture `
        $runbook `
        'New-Item -ItemType Directory -Force -Path $stateDir | Out-Null' `
        (
          'New-Item -ItemType Directory -Force -Path $stateDir' + "`n" +
          '$null | Out-Null'
        ) `
        "bare-new-item-output"
    },
    @{
      Name = "bare-join-path-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$stateDir = Join-Path $root ".ui-verification"' `
        ('Join-Path $root ".ui-verification"' + "`n" + '$stateDir = "."') `
        "bare-join-path-output"
    },
    @{
      Name = "bare-health-response-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2' `
        (
          'Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2' + "`n      " +
          '$response = [pscustomobject]@{ StatusCode = 200; Content = "ok" }'
        ) `
        "bare-health-response-output"
    },
    @{
      Name = "bare-pid-json-output"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'ConvertTo-Json -Compress |' + "`n" +
          '    Set-Content -LiteralPath $pidFile -Encoding UTF8'
        ) `
        (
          'ConvertTo-Json -Compress' + "`n  " +
          'Set-Content -LiteralPath $pidFile -Encoding UTF8 -Value "{}"'
        ) `
        "bare-pid-json-output"
    },
    @{
      Name = "bare-health-test-path-output"
      Markdown = New-MutatedFixture `
        $runbook `
        'if (Test-Path -LiteralPath $stderr -PathType Leaf) {' `
        (
          'Test-Path -LiteralPath $stderr -PathType Leaf' + "`n    " +
          'if ($true) {'
        ) `
        "bare-health-test-path-output"
    },
    @{
      Name = "verification-placeholder-replaced-by-noop"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          '$verifyUi = {' + "`n" +
          '  throw "Replace the verifyUi placeholder with bounded browser verification."' + "`n" +
          '}'
        ) `
        '$verifyUi = {}' `
        "verification-placeholder-replaced-by-noop"
    },
    @{
      Name = "readiness-forced-true"
      Markdown = New-MutatedFixture `
        $runbook `
        '$ready = $false' `
        '$ready = $true' `
        "readiness-forced-true"
    },
    @{
      Name = "health-loop-made-effectively-unbounded"
      Markdown = New-MutatedFixture `
        $runbook `
        'for ($attempt = 1; $attempt -le 30; $attempt++) {' `
        'for ($attempt = 1; $attempt -le [int]::MaxValue; $attempt++) {' `
        "health-loop-made-effectively-unbounded"
    },
    @{
      Name = "health-sleep-made-effectively-unbounded"
      Markdown = New-MutatedFixture `
        $runbook `
        'Start-Sleep -Seconds 1' `
        'Start-Sleep -Seconds ([int]::MaxValue)' `
        "health-sleep-made-effectively-unbounded"
    },
    @{
      Name = "diagnostic-mutated-through-variable-provider"
      Markdown = New-MutatedFixture `
        $runbook `
        'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)' `
        (
          '${variable:healthDiagnostic} = $root' + "`n    " +
          'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)'
        ) `
        "diagnostic-mutated-through-variable-provider"
    },
    @{
      Name = "diagnostic-mutated-in-nested-branch"
      Markdown = New-MutatedFixture `
        $runbook `
        'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)' `
        (
          'if ($true) { $healthDiagnostic = $root }' + "`n    " +
          'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)'
        ) `
        "diagnostic-mutated-in-nested-branch"
    },
    @{
      Name = "diagnostic-mutated-through-alias"
      Markdown = New-MutatedFixture `
        $runbook `
        'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)' `
        (
          '$diagnosticAlias = $healthDiagnostic' + "`n    " +
          '$diagnosticAlias.logBytes = $root' + "`n    " +
          'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)'
        ) `
        "diagnostic-mutated-through-alias"
    },
    @{
      Name = "root-reassigned-before-launch"
      Markdown = New-MutatedFixture `
        $runbook `
        ("try {`n  `$startParameters = @{") `
        ("try {`n  `$root = `".`"`n  `$startParameters = @{") `
        "root-reassigned-before-launch"
    },
    @{
      Name = "root-overwritten-by-get-command-outvariable"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'Get-Command $nodeCommandName -CommandType Application -ErrorAction Stop'
        ) `
        (
          'Get-Command $nodeCommandName -CommandType Application ' +
          '-ErrorAction Stop -OutVariable root'
        ) `
        "root-overwritten-by-get-command-outvariable"
    },
    @{
      Name = "pid-evidence-source-replaced-by-root"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          '[ordered]@{' + "`n" +
          '    pid = $server.Id' + "`n" +
          '    startTimeUtc = $serverStartTimeUtc.ToString("O")' + "`n" +
          '  } |'
        ) `
        '$root |' `
        "pid-evidence-source-replaced-by-root"
    },
    @{
      Name = "server-start-time-mutated-in-nested-branch"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverStartTimeUtc = $server.StartTime.ToUniversalTime()' `
        (
          '$serverStartTimeUtc = $server.StartTime.ToUniversalTime()' + "`n  " +
          'if ($true) { $serverStartTimeUtc = [DateTime]::MinValue }'
        ) `
        "server-start-time-mutated-in-nested-branch"
    },
    @{
      Name = "dead-handle-capture"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        'if ($false) { $serverHandle = $server.SafeHandle }' `
        "dead-handle-capture"
    },
    @{
      Name = "here-string-handle-decoy"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        @'
$decoy = @"
$serverHandle = $server.SafeHandle
"@
'@ `
        "here-string-handle-decoy"
    },
    @{
      Name = "handle-mutated-through-get-variable"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          '(Get-Variable -Name serverHandle).Value = $null'
        ) `
        "handle-mutated-through-get-variable"
    },
    @{
      Name = "server-mutated-through-dynamic-set-variable"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          '$variableSetter = "Set-Variable"' + "`n  " +
          '& $variableSetter -Name server -Value $null'
        ) `
        "server-mutated-through-dynamic-set-variable"
    },
    @{
      Name = "server-disposed-through-alias"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          '$serverAlias = $server' + "`n  " +
          '$serverAlias.Dispose()'
        ) `
        "server-disposed-through-alias"
    },
    @{
      Name = "server-mutated-through-psobject"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          '$server.PSObject.Properties["EnableRaisingEvents"].Value = $true'
        ) `
        "server-mutated-through-psobject"
    },
    @{
      Name = "extra-warning-reflects-stderr"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        (
          '$serverHandle = $server.SafeHandle' + "`n  " +
          'Write-Warning $stderr'
        ) `
        "extra-warning-reflects-stderr"
    },
    @{
      Name = "bare-stderr-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + '$stderr') `
        "bare-stderr-output"
    },
    @{
      Name = "return-stderr-output"
      Markdown = New-MutatedFixture `
        $runbook `
        '$serverHandle = $server.SafeHandle' `
        ('$serverHandle = $server.SafeHandle' + "`n  " + 'return $stderr') `
        "return-stderr-output"
    },
    @{
      Name = "pid-reresolve-cleanup"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server.Kill()' `
        '$server = Get-Process -Id $server.Id; $server.Kill()' `
        "pid-reresolve-cleanup"
    },
    @{
      Name = "dead-kill"
      Markdown = New-MutatedFixture $runbook '$server.Kill()' 'if ($false) { $server.Kill() }' "dead-kill"
    },
    @{
      Name = "kill-race-recheck-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'if (-not $server.HasExited) {' + "`n" +
          '            throw' + "`n" +
          '          }'
        ) `
        'throw' `
        "kill-race-recheck-removed"
    },
    @{
      Name = "unbounded-stop-confirmation"
      Markdown = New-MutatedFixture $runbook ".WaitForExit(5000)" ".WaitForExit()" "unbounded-stop-confirmation"
    },
    @{
      Name = "stop-timeout-swallowed"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          'throw [System.TimeoutException]::new(' + "`n" +
          '              "Server process did not stop within the bounded cleanup wait."' + "`n" +
          '            )'
        ) `
        (
          '$null = [System.TimeoutException]::new(' + "`n" +
          '              "Server process did not stop within the bounded cleanup wait."' + "`n" +
          '            )'
        ) `
        "stop-timeout-swallowed"
    },
    @{
      Name = "timeout-message-reflects-stderr"
      Markdown = New-MutatedFixture `
        $runbook `
        '"Server readiness timed out; inspect the classified log metadata."' `
        '"Server readiness timed out: $stderr"' `
        "timeout-message-reflects-stderr"
    },
    @{
      Name = "diagnostic-classification-removed"
      Markdown = New-MutatedFixture `
        $runbook `
        'classification = "readiness-timeout"' `
        'classification = "unknown"' `
        "diagnostic-classification-removed"
    },
    @{
      Name = "absolute-log-path-reflected"
      Markdown = New-MutatedFixture `
        $runbook `
        'logId = "dev-server.err.log"' `
        'logId = $stderr' `
        "absolute-log-path-reflected"
    },
    @{
      Name = "absolute-cleanup-report-reflected"
      Markdown = New-MutatedFixture `
        $runbook `
        '$cleanupResult = "Server process was not started."' `
        '$cleanupResult = $stderr' `
        "absolute-cleanup-report-reflected"
    },
    @{
      Name = "dynamic-reader-replays-stderr"
      Markdown = New-MutatedFixture `
        $runbook `
        '$stderrSizeBytes = 0' `
        (
          '$rawReader = "Get-Content"' + "`n    " +
          '& $rawReader -LiteralPath $stderr' + "`n    " +
          '$stderrSizeBytes = 0'
        ) `
        "dynamic-reader-replays-stderr"
    },
    @{
      Name = "static-reader-replays-stderr"
      Markdown = New-MutatedFixture `
        $runbook `
        'Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)' `
        'Write-Warning ([System.IO.File]::ReadAllText($stderr))' `
        "static-reader-replays-stderr"
    },
    @{
      Name = "dead-verification-catch"
      Markdown = New-MutatedFixture `
        $runbook `
        '$verificationFailure = $_.Exception' `
        'if ($false) { $verificationFailure = $_.Exception }' `
        "dead-verification-catch"
    },
    @{
      Name = "here-string-verification-catch"
      Markdown = New-MutatedFixture `
        $runbook `
        '$verificationFailure = $_.Exception' `
        @'
$decoy = @"
$verificationFailure = $_.Exception
"@
'@ `
        "here-string-verification-catch"
    },
    @{
      Name = "dead-cleanup-catch"
      Markdown = New-MutatedFixture `
        $runbook `
        '$cleanupFailure = $cleanupStageFailures[0]' `
        'if ($false) { $cleanupFailure = $cleanupStageFailures[0] }' `
        "dead-cleanup-catch"
    },
    @{
      Name = "dead-dual-failure-add"
      Markdown = New-MutatedFixture `
        $runbook `
        '$failures.Add($verificationFailure)' `
        'if ($false) { $failures.Add($verificationFailure) }' `
        "dead-dual-failure-add"
    },
    @{
      Name = "here-string-rethrow"
      Markdown = New-MutatedFixture `
        $runbook `
        'throw $verificationFailure' `
        @'
$null = $verificationFailure
$decoy = @"
throw $verificationFailure
"@
'@ `
        "here-string-rethrow"
    },
    @{
      Name = "dual-failure-loses-cleanup"
      Markdown = New-MutatedFixture `
        $runbook `
        '$failures.Add($cleanupFailure)' `
        '$null = $cleanupFailure' `
        "dual-failure-loses-cleanup"
    },
    @{
      Name = "dual-add-order-swapped"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          '$failures.Add($verificationFailure)' + "`n" +
          '  $failures.Add($cleanupFailure)'
        ) `
        (
          '$failures.Add($cleanupFailure)' + "`n" +
          '  $failures.Add($verificationFailure)'
        ) `
        "dual-add-order-swapped"
    },
    @{
      Name = "dual-failure-collapsed"
      Markdown = New-MutatedFixture `
        $runbook `
        'throw [System.AggregateException]::new' `
        '$null = [System.AggregateException]::new' `
        "dual-failure-collapsed"
    },
    @{
      Name = "dual-aggregate-not-final"
      Markdown = New-MutatedFixture `
        $runbook `
        (
          '    $failures' + "`n" +
          '  )' + "`n" +
          '}'
        ) `
        (
          '    $failures' + "`n" +
          '  )' + "`n" +
          '  $null = "unreachable after aggregate throw"' + "`n" +
          '}'
        ) `
        "dual-aggregate-not-final"
    }
  )

  $exactOnlyFixtureNames = @(
    "canonical-soft-hyphen-byte-drift"
  )
  foreach ($fixture in $fixtures) {
    $originalCanonicalCode = $script:CanonicalServerRunbookCode
    try {
      if ($fixture.SynchronizeCanonical) {
        $mutatedWorkflow = [regex]::Match(
          $fixture.Markdown,
          '(?ms)^## Complete Bounded Workflow[ \t]*\r?\n\r?\n```powershell[ \t]*\r?\n(?<code>.*?)^```[ \t]*$'
        )
        if (-not $mutatedWorkflow.Success) {
          throw "Synchronized fixture '$($fixture.Name)' lost its workflow block."
        }
        $script:CanonicalServerRunbookCode = $mutatedWorkflow.Groups["code"].Value
      }
      $violations = @(
        Get-ServerRunbookContractViolations -Markdown $fixture.Markdown
      )
    } finally {
      $script:CanonicalServerRunbookCode = $originalCanonicalCode
    }
    if ($violations.Count -eq 0) {
      $failures.Add(
        "hostile fixture bypassed full contract: $($fixture.Name)"
      ) | Out-Null
    }
    # byte gateで先に落ちるfixtureも、境界専用3件以外はsemantic analyzer単体でrejectさせる。
    if ($exactOnlyFixtureNames -notcontains $fixture.Name -and
      @(Get-ServerRunbookContractViolations `
        -Markdown $fixture.Markdown `
        -SemanticProbe).Count -eq 0) {
      $failures.Add(
        "hostile fixture bypassed semantic analyzer: $($fixture.Name)"
      ) | Out-Null
    }
    $hostileFixtureCount++
  }

  # 全tokenをcommentへ残しても、direct executable ASTを失ったfixtureはrejectされる。
  $surfaceDecoy = New-MutatedFixture `
    $runbook `
    '$serverHandle = $server.SafeHandle' `
    '$serverHandle = $null' `
    "surface-token-decoy"
  $surfaceDecoy += @'

<!-- $serverHandle = $server.SafeHandle; $server.Kill(); $server.WaitForExit(5000);
throw $verificationFailure; throw $cleanupFailure -->
'@
  if (@(Get-ServerRunbookContractViolations -Markdown $surfaceDecoy).Count -eq 0) {
    $failures.Add("hostile fixture was accepted: surface-token-decoy") | Out-Null
  }
  if (@(Get-ServerRunbookContractViolations `
      -Markdown $surfaceDecoy `
      -SemanticProbe).Count -eq 0) {
    $failures.Add(
      "hostile fixture bypassed semantic analyzer: surface-token-decoy"
    ) | Out-Null
  }
  $hostileFixtureCount++
  if ($hostileFixtureCount -ne $expectedHostileFixtureCount) {
    $failures.Add(
      "hostile fixture count changed: expected $expectedHostileFixtureCount, " +
      "found $hostileFixtureCount"
    ) | Out-Null
  }

  # read-only splat照会はprovenanceを変えないため、mutation扱いしない。
  $expectedReadOnlyProbeCount = 4
  $readOnlySplatProbes = @(
    @{
      Name = "assigned"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$null = $startParameters.ContainsKey("FilePath")' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "read-only-splat-probe-assigned"
    },
    @{
      Name = "bare"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$startParameters.ContainsKey("ArgumentList")' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "read-only-splat-probe-bare"
    },
    @{
      Name = "out-null"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          '$startParameters.ContainsKey("WorkingDirectory") | Out-Null' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "read-only-splat-probe-out-null"
    },
    @{
      Name = "guard"
      Markdown = New-MutatedFixture `
        $runbook `
        '$server = Start-Process @startParameters' `
        (
          'if (-not $startParameters.ContainsKey("FilePath")) {' + "`n    " +
          'throw "Missing direct executable."' + "`n  " +
          '}' + "`n  " +
          '$server = Start-Process @startParameters'
        ) `
        "read-only-splat-probe-guard"
    }
  )
  foreach ($probe in $readOnlySplatProbes) {
    $readOnlyViolations = @(
      Get-ServerRunbookContractViolations `
        -Markdown $probe.Markdown `
        -AllowExactReadOnlyVariant
    )
    if ($readOnlyViolations.Count -ne 0) {
      $failures.Add(
        "read-only fixture '$($probe.Name)' was rejected: " +
        ($readOnlyViolations -join "; ")
      ) | Out-Null
    }
  }
  if ($readOnlySplatProbes.Count -ne $expectedReadOnlyProbeCount) {
    $failures.Add(
      "read-only probe count changed: expected $expectedReadOnlyProbeCount, " +
      "found $($readOnlySplatProbes.Count)"
    ) | Out-Null
  }

  try {
    Invoke-SyntheticServerIntegration -RepoRoot $repoRoot
  } catch {
    $failures.Add("synthetic direct-server integration failed: $($_.Exception.Message)") | Out-Null
  }
  try {
    Invoke-SyntheticNaturalExitRace -RepoRoot $repoRoot
  } catch {
    $failures.Add("synthetic natural-exit race failed: $($_.Exception.Message)") | Out-Null
  }
  try {
    Invoke-SyntheticPartialStartCleanup -RepoRoot $repoRoot
  } catch {
    $failures.Add("synthetic partial-start cleanup failed: $($_.Exception.Message)") | Out-Null
  }
  try {
    Assert-CleanupStageFailureAggregation
  } catch {
    $failures.Add("cleanup-stage aggregation failed: $($_.Exception.Message)") | Out-Null
  }
  try {
    Assert-ClassifiedDiagnosticPrivacy
  } catch {
    $failures.Add("classified diagnostic privacy failed: $($_.Exception.Message)") | Out-Null
  }
}

if ($failures.Count -gt 0) {
  throw ("Server runbook contract self-test failed:`n- " + ($failures -join "`n- "))
}

Write-Host (
  "Server runbook contract self-test passed " +
  "($hostileFixtureCount hostile fixtures rejected with semantic probes; " +
  "direct server, partial-start cleanup, " +
  "natural-exit race, cleanup-stage aggregation, diagnostic privacy, and " +
  "$expectedReadOnlyProbeCount read-only splat probes verified)."
)
