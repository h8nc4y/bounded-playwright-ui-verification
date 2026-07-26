# Changelog

All notable changes to this project are recorded here.

## Unreleased

### Added

- Codex 自走運用契約 `AGENTS.md`、引き継ぎ文書 `HANDOFF.md`、残タスク台帳
  `TASKS_BACKLOG.md` を追加しました。
- 合成データのみの verification report example 群を `examples/` に追加しました:
  evidence matrix / failed verification / protected route (login/OAuth blocked) /
  responsive overflow / blank render target / hover-focus state /
  loading-empty-error state。
- Scanner hardening: 秘匿値プレフィックスの拡充（AWS / GCP / Slack / Stripe / PEM）、
  self-exempt hole の修正、除外ディレクトリ集合の単一情報源化
  （`scripts/private-scan-config.ps1`）、whitespace check の単一エントリ点
  （`scripts/check-whitespace.ps1`）、依存ゼロの回帰テスト
  （`tests/scan-private-markers.Tests.ps1`）を追加し、CI shell を `pwsh` に統一しました。
- Scanner process境界をWindowsのsuspended child + kill-on-close Job、およびPOSIXの専用
  process group/sessionへ統合しました。binary standard stream、PS5.1のBOMなしstdin、
  native Git batch bytes、ancestor/dangling `.git`、index mutation、scan-wide deadline、
  正常なlinked-worktree Gitfile、atomic UTF-8 finding出力の敵対的fixtureを追加しました。
  最初のraw fixtureを守るAST gateはtarget shadow、Alias/Function provider代入、
  module-qualified bootstrapとPSScriptRoot provenance、Set/New-Variable・Variable provider・
  間接provider/custom mutation alias・PSVariable object更新、Copy/Move/Rename/dynamic
  New-Item、class継承、推移的wrapperを追跡し、
  dynamic invocationを拒否します。Windows Job closeは成功時だけhandle ownershipを放棄し、
  失敗時はdirect terminate・bounded wait・同じhandleの再試行を行い、sub-second timeoutも
  millisecond値のまま適用します。bootstrap / process / isolation例外は内部pathを含まない
  固定診断1行とexit code 2へ変換し、cleanupの複合failureでも診断を二重出力しません。

### Changed

- README「What It Solves」を pre-claim evidence contract の定式化（bounded execution /
  truthful reporting / evidence separation）で明確化しました。対象範囲・Non-Goals・
  判定基準は不変です。
- ローカル検証手順の記載を CI と同形の4ステップ（scan → 回帰テスト → OSS readiness →
  whitespace check）に統一しました（README / CONTRIBUTING / release checklist /
  AGENTS / HANDOFF）。
- 非 Windows 寄稿者向けに `pwsh` での validation 実行手順を明確化しました。
- `main` のブランチ保護と必須チェックの扱いを引き継ぎ文書に明記しました。
- agent ローカルの `.claude` / `.codex` ディレクトリを validation scan と ignore 対象にしました。
- Git repositoryのscanner対象を、index snapshot、stable working-tree bytes、
  除外外のuntracked textのunionとして明文化しました。T-024のtracked-only modeは
  引き続き人間承認待ちで、採用していません。
- OSS readinessで現行CIのtrigger、permissions、job、step所有境界を完全一致検証します。
  `actions/checkout@v4`のmutable tagは未解決のowner-gated残差で、immutable保証ではありません。
- OSS readinessで全公開exampleのfile名・表示名・README / SKILLリンク・report証跡カテゴリを
  role付きの1つのexact manifestへ閉じました。再帰的な未宣言file、リンク / state行の
  comment・fence decoy、example名drift、完了済みstateへの相反する`未確認` / blocked /
  failed / error追記を17の合成mutationで拒否します。
- `SKILL.md` の Playwright 推奨例を、`networkidle` 依存から `load` と route/state 固有 locator の
  bounded readiness 待機へ変更しました。
- 合成server runbookを単一の`try`/`finally` workflowへ更新し、実server executableの
  直接起動、起動時`SafeHandle`の保持、5秒上限の停止確認、
  verification/cleanup両failureの伝播を追加しました。health timeoutはraw stderrを再生せず、
  固定classification・相対log ID・byte sizeだけを出します。readinessでは実行可能ASTの
  親子・順序・支配関係に加えてserver-entry def-use、後続mutation不在、型付きfailure
  listの追加順、大小文字・scope qualifierを正規化したstorage provenance、
  command/output/throw/invocation sinkを固定します。handle取得に失敗したpartial-startでも
  同じdirect `Process`を停止し、nested `finally`で`SafeHandle`と`Process`を解放します。
  実行可能正本`examples/server-runbook.ps1`をUTF-8 BOMなし・LF-onlyで追加し、
  CommonMarkとして認識される全fenceを1 blockへ閉じ、Markdown内PowerShell bodyとの
  Ordinal完全一致を固定しました。`variable:` providerを含むstorage正規化後のidentifierは
  `OrdinalIgnoreCase`で比較します。top-level / verification / health / polling / cleanupと
  全assignment・unary writeをclosed sequence化し、command shadow、root / URL / PID evidence /
  readiness bound / diagnostic provenanceを検査します。root ScriptBlockはunnamed endだけへ
  閉じ、`param` / `using` / script requirements / named block / `trap`を拒否します。
  stop・SafeHandle Dispose・Process Disposeの各例外はstage順で保持します。
  93種の敵対的fixture、4種のexact read-only probe、synthetic local HTTP server、
  partial-start cleanup、PS5.1自然終了race、3段階cleanup failure集約、
  hostile root非反射をWindows PowerShell 5.1 / PowerShell 7で検査します。

### Removed

- 陳腐化したエージェント引き継ぎメモ（`NOTES_CLAUDE.md`、`docs/CLAUDECODE_*.md`）を
  削除し、引き継ぎ情報を `HANDOFF.md` に一本化しました（内容は git 履歴に保持）。

## 0.1.0 - 2026-06-06

### Added

- OSS readiness validation with `scripts/assert-oss-ready.ps1`.
- GitHub Actions CI for private marker scanning, OSS readiness checks, and
  whitespace checks.
- Public contribution, security, support, issue, and pull request guidance.

### Changed

- Clarified `未確認` reporting expectations in the README, skill, and examples.
- Made private marker scanning compatible with Windows PowerShell 5.1 and
  PowerShell 7+.
