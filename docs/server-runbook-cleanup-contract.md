# Server Runbook Cleanup Contract

## Objective

`examples/server-runbook.ps1`を実行可能な正本とし、`examples/server-runbook.md`の
PowerShell blockをbyte単位で一致させる。Windows PowerShell 5.1とPowerShell 7の
両方で実行可能な合成/local用runbookへ揃え、browser verificationの成功・失敗・timeoutに
かかわらずcleanupを実行する。別processの誤停止、raw logの自動再生、cleanup failureの
隠蔽、文書と実行例のdriftを防ぐ。

## Impact And Scope

- 対象は合成runbookのMarkdown / executable template、readiness contract test、
  synthetic local HTTP server fixture、
  README / CHANGELOG / HANDOFF / TASKS_BACKLOG。
- 実server、production、deploy、OAuth、secret、実ユーザーデータ、課金操作は扱わない。
- `.github/workflows/**`は変更しない。
- 製品要件の意味は変えず、既存のbounded execution / truthful reporting契約へ例を
  一致させる。

## Requirements

### R1. Direct Server Ownership

- `npm` / `npm.cmd` / shell wrapper / task runnerは起動しない。
- 合成例は実行可能なserver entry（解決済みNode runtime）を`FilePath`へ、Vite CLI
  scriptを`ArgumentList`の先頭へ渡す。
- `serverEntry -> startParameters.FilePath -> Start-Process`と
  `serverScript -> serverArguments -> startParameters.ArgumentList -> Start-Process`の
  def-use chainをASTで固定し、起動直前のsplat上書き、alias経由の上書き、
  collection mutatorによるargument差替えを拒否する。
- `ContainsKey`等の列挙済みread-only照会は、provenanceや値を変えないため許可する。
- `Start-Process`のstdout/stderr redirectがPS5.1 / PowerShell 7の両方で成功することを、
  tracked synthetic local server fixtureで実行確認する。

### R2. Stable Process Identity

- `Start-Process -PassThru`直後に同じ`Process` objectの`SafeHandle`を取得して保持する。
- capture直後のguardは`null` / `IsInvalid` / `IsClosed`を左から`-or`で短絡評価する。
- handle保持後は`server` / `serverHandle`の再代入と、`server` propertyへの代入を
  許可しない。
- PowerShellのvariable名は大小文字を区別せず、`variable:` provider qualifierと
  `local:` / `script:` / `global:` / `private:` scope qualifierを除いた同一storageとして
  検査する。
- alias、`PSVariable.Set`、`Get-Variable ... .Value`、call operator経由の
  `Set-Variable`、`PSObject.Properties`等を使った間接mutationも同じ違反として拒否する。
- cleanup時にPIDから`Get-Process`で再解決しない。
- 停止・有限waitは起動時の`Process` objectに対して行う。PIDと開始時刻はreport用の
  identityであり、停止対象の再特定には使わない。

### R3. Bounded Cleanup

- server startとbrowser verificationを同じouter `try`で囲み、cleanupはその
  `finally`からのみ実行する。
- `Start-Process`成功後にhandle取得・guardが失敗しても、cleanupをskipしない。
  cleanup側でも同じ3項`-or` guardを使い、直接返された`Process` objectへbounded
  stopを試みる。PIDの再解決は行わない。
- `HasExited = false`の確認直後にprocessが自然終了して`Kill()`が例外を返すraceでは、
  catch内で同じ保持済み`Process` objectの`HasExited`を再確認する。既に終了していれば
  cleanup成功とし、未終了なら元の例外を再throwする。
- `WaitForExit(5000)`がfalseならcleanup failureとしてthrowする。
- stop試行を囲むnested `finally`で、保持済み`SafeHandle`（存在する場合）、
  `Process`の順に各1回`Dispose()`する。stop、SafeHandle Dispose、Process Disposeは
  それぞれ独立したcatchで例外を順序付き`List[Exception]`へ保持する。1件なら元例外を
  維持し、複数件なら固定messageの`AggregateException`へ束ね、後段の失敗で先行失敗を
  隠さない。
- verification failureとcleanup failureが同時に起きた場合は、両方を
  型付き`List[Exception]`へverification、cleanupの順で1回ずつ追加し、最後のdirect
  statementで`AggregateException`としてthrowする。

### R4. Fixed Classified Diagnostics

- health timeoutでstderr本文を`Get-Content`等により自動再生しない。
- 出力してよいのは固定classification、固定相対log ID、log byte size、attempt count。
- absolute path、root path、host固有文字列はwarning / public reportへ反射しない。
- `Write-Warning` / `Write-Host` / bare pipeline / `throw` / dynamic invocationを
  列挙済みshapeへ限定する。throw messageにもabsolute pathやraw logを含めない。
- `Resolve-Path` / `Join-Path` / `New-Item` / `Get-Item` /
  `Invoke-WebRequest` / `ConvertTo-Json`等の許可commandも、canonical代入または
  明示的な`Out-Null` / `Set-Content` sinkへ結び付ける。command名と個数だけでは
  合格させない。
- `stderrSizeBytes`は、leaf存在guard内の
  `(Get-Item -LiteralPath $stderr).Length`だけから定義する。
- command alias、call operator、reflection、static/instance method経由でraw logを
  読み出すsinkを許可しない。
- raw logの読取・report貼付は自動化しない。

### R5. Descendant Boundary

- 既定例はtask runnerではなく実server processを直接所有する。
- 実serverまたはpluginが子孫processを生成する案件では、この例だけでprocess-tree
  cleanupをpassedとしない。OS固有のJob Object / process group等へ置換して実測するまで
  descendant cleanupは`未確認`とする。

## Contract Test Design

- `examples/server-runbook.ps1`はstrict UTF-8（BOMなし）、LF-only、末尾LF必須とする。
  CommonMarkのbacktick / tilde、3文字以上の長いfence、info文字列の大小文字をline parserで
  認識し、Markdown全体を`## Complete Bounded Workflow`直下のexact PowerShell fence
  1個だけへ閉じる。fence内部は正本と`StringComparison.Ordinal`で一致させる。
  U+00AD等のculture上ignorableな差、追加block、block前後へのcode挿入、
  改行・encoding driftをfail-closedにする。
- read-only `ContainsKey`は正本から生成する4個のexact variantだけを許可する。
- Markdownの対象code fenceをPowerShell ASTへparseする。
- root ScriptBlockは`ParamBlock=null`、`UsingStatements=0`、`ScriptRequirements=null`、
  `DynamicParamBlock` / `BeginBlock` / `ProcessBlock` / `CleanBlock=null`、
  `EndBlock.Unnamed=true`へ閉じる。入れ子を含む全`TrapStatementAst`も拒否する。
- コメント、文字列、here-stringのtokenを証拠に使わない。
- `Extent.Text`の広域regex一致を合否根拠に使わず、実行可能AST nodeの型、operand、
  direct parent、statement順、def-use/provenance、alias不在、後続mutation不在、
  command/invocation/output/throw allowlist、catch代入、rethrow、
  同一branch内の支配関係を検査する。
- variableはprovider/scope qualifier除去後、command / memberとともに
  `StringComparison.OrdinalIgnoreCase`で比較する。SafeHandle guardの3項`-or` boolean
  ASTはcapture直後とcleanupの両方で固定する。
- top-level、outer verification、health timeout、polling、cleanupのstatement順を
  closed sequenceにする。全assignment / provider writeをsource順のclosed target列へ、
  unary writeをloop iterator 1個へ限定する。function / filter / class / enum definitionを
  拒否し、`Start-Process`等のcommand shadowを許可しない。
- runtime、root、path、URL、server entry/arguments、PID evidence、diagnosticを固定
  def-useで結び、nested branchやprovider経由の後続writeを許可しない。
- dead `if ($false)`等のbranch内に置いた安全そうなnodeは、要求されたdirect control
  flowの代替として受理しない。
- outer `try` / `catch` / `finally`、direct process start、handle capture、
  handle-based cleanup、bounded wait、classified diagnostic、単独/両failure伝播の各境界を
  一つずつ壊す93種のhostile fixtureを用意する。
- byte一致専用のU+00AD fixtureを除き、hostile fixtureはexact gateだけでなくsemantic analyzer
  単体にも通し、AST検査の退行をbyte mismatchで隠さない。
- 少なくともserver entry切断、handle保持後のprocess再代入、起動直前のFilePath上書き、
  dual-failure List initializer消失、自然終了race catch消失、absolute log path反射を
  false-greenにしない。
- alias/PSVariable/Get-Variable/call-operator/PSObject/collection mutator経由のmutation、
  追加warning、throw messageへのpath反射、dynamic raw readerをfalse-greenにしない。
- loop内sleep後のcounter減算、functionによる`Start-Process` shadow、URL差替え、
  nested PID output先変更、tilde / long / mixed-case追加fence、片側U+00AD driftを
  full contractとsemantic analyzerの該当境界でfalse-greenにしない。
- 許可commandをbare outputへ移すmutation、diagnostic byte countのprovenance切断、
  partial-start cleanupのthrow置換、SafeHandle / Process Dispose消失をfalse-greenにしない。
- direct `startParameters.ContainsKey("FilePath")`は4個のexact read-only variant内だけで
  false-positiveにしない。
- 本設計文書自体を`assert-oss-ready.ps1`のrequired fileへ含める。

## Integration Test Plan

1. current PowerShell host executableを直接起動し、tracked synthetic HTTP server fixtureを
   loopback上の一時portで開始する。
2. stdout/stderrを一時fileへredirectし、有限health pollでHTTP 200を確認する。
3. 起動直後の`SafeHandle`を保持し、同じ`Process` objectへstopを要求する。
4. 再取得した`SafeHandle`が同じobject referenceであることを確認する。
5. SafeHandle未取得のままrunning serverを合成し、同じdirect `Process` objectで
   stop確認とProcess Disposeまで完了することを確認する。
6. 別processを自然終了させ、直前の`HasExited = false`から`Kill()`例外へ遷移するraceを
   合成し、同じobjectの再確認でcleanup成功になることを確認する。
7. direct integrationと自然終了raceではSafeHandle / Processの両wrapperをnested
   `finally`で解放する。
8. stop / SafeHandle Dispose / Process Disposeを同時に失敗させ、3例外がstage順で
   `AggregateException`へ保持されることを確認する。
9. hostile root canaryをabsolute stderr pathへ含めても、公開diagnostic JSONへ反射しない
   ことを確認する。
10. `WaitForExit(5000)`で停止を確認し、process残留とraw stderr自動再生がないことを確認する。
11. Windows PowerShell 5.1 / PowerShell 7の両方でfocused testとcheck:all 4ステップを通す。

## Completion Gates

- focused contract / integration: PS5.1 pass、PowerShell 7 pass。
- check:all 4ステップ: PS5.1 4/4、PowerShell 7 4/4。
- Semgrep（変更script）0、Gitleaks 0、private marker scan pass。
- UTF-8 / BOM / LF / NUL / `git diff --check` pass。
- exact freezeを同じ独立reviewerへ再提示し、P1 / P2 / P3が0。
