# HANDOFF.md — 引き継ぎの単一入口

このファイルは、どのエージェント（Codex / Claude Code / その他）がこのリポジトリを
引き継ぐ場合でも最初に読む現況スナップショット。恒久ルールは `AGENTS.md`、残タスク台帳は
`TASKS_BACKLOG.md` が正本。スナップショットは陳腐化するため、実際の状態は毎回
`git status` / `gh pr list` / `gh issue list` で確認すること。

## リポジトリの目的

AI coding agent が Web UI 変更後に Playwright やブラウザ自動化で実画面を検証するときの
運用規律（bounded execution / truthful reporting / evidence separation）を配布する
Codex-style skill。主成果物は `SKILL.md` で、UI 検証を実行するコードは同梱しない。
`scripts/` はこのリポジトリ自身の OSS 健全性チェック。**PUBLIC リポジトリ**であり、
ローカル絶対パス・秘匿値・他リポジトリの内部情報・個人環境の詳細を書き込まない。

## 読み順（reading order）

1. `AGENTS.md` — 恒久運用契約（自走ループ §4、check:all §6、4ゲート §14）
2. 本 `HANDOFF.md` — 現況スナップショット
3. `TASKS_BACKLOG.md` — 残タスク台帳（T-018〜T-020 / T-022 / T-024 が現役）
4. `docs/requirements-redefinition-2026-07.md` — 要件再定義ドラフトと未回答の質問リスト
   （D1〜D4 / O1〜O3）
5. `README.md` / `SKILL.md` — repo 概要とスキル本体

## 現状サマリ（2026-07-27 時点）

- `main` がリリース可能・最新で、唯一の通常作業対象ブランチ。タグ `v0.1.0` は `main` 上。
- ブランチ保護あり。必須ステータスチェック「Validate repository」（CI）の通過が必須。
  変更は PR → CI 緑 → セルフマージが基本（`AGENTS.md` §9）。
- T-001〜T-017 / T-021 / T-023 / T-025〜T-028 は完了。T-026ではscannerを
  bounded process、hermetic Git、index＋全working tree（untracked textを含む）、
  scan-wide deadline、atomic redacted outputのfail-closed境界へ更新した。first-call ASTは
  target shadow、Alias/Function provider代入、module-qualified bootstrap/provenance、
  Variable providerの間接参照/custom mutation alias/PSVariable更新、
  Copy/Move/Rename/dynamic New-Item、class継承、推移的wrapperを拒否する。
  Windows Jobはsub-second timeoutを
  millisecond値のまま適用し、close失敗はdirect terminate・有限wait・handle再試行、
  process/isolationの複合例外も二重出力しない固定診断へ閉じる。正常なlinked-worktree
  Gitfileも実物fixtureで確認する。T-024のtracked-only modeは採用していない。詳細は
  `docs/private-marker-scanner-hardening.md`と`TASKS_BACKLOG.md`、変更履歴は
  `git log` / `CHANGELOG.md`を参照する。
- bounded launcherはcaller指定値を適用した後にchild環境を固定allowlistへ再構築し、
  ambientの非Git変数を継承しない。POSIXはexternal/nativeの両経路でwrapper PIDを受け取り、
  `getpgid(pid) == pid`をkernelへ確認した後だけtargetをreleaseする。operation clockは
  prep/start/containment前に開始し、全phaseが残budgetを共有する一方、tree stopとstream
  drainは単一の独立absolute cleanup slackを共有する。各境界はdeadline前target非起動、
  POSIX target/grandchild開始、cleanup後release sentinelで回帰固定した。
- **最大のゲート**: `docs/requirements-redefinition-2026-07.md` §5 の質問リスト
  （決定軸 D1〜D4・運営判断 O1〜O3）が人間の回答待ち。回答が出るまで
  T-018〜T-020 / T-022 は blocked。scanner の tracked-only 走査モード（T-024）も
  §14④ ゲートで人間承認待ち。
- 外部レビューの非 gate 指摘（Playwright 推奨例の `networkidle`）は T-025 / PR #22 で対応。
  private marker literalの扱いとT-024はオーナー裁定または§14④ gateの対象。
- OSS readinessは現行CIのtrigger、permissions、job、stepを完全一致で検証する。
  `actions/checkout@v4`はmutable tagでimmutable保証ではないが、workflow編集は§14①
  gateのためT-026では変更していない。
- T-027は初回レビューP1=2 / P2=3 / P3=0、v1再レビューP1=0 / P2=3 / P3=1、
  v2再レビューP1=2 / P2=0 / P3=1、v3再レビューP1=3 / P2=1 / P3=1を受け、
  v4再レビューP1=4 / P2=2 / P3=0、v5再レビューP1=4 / P2=1 / P3=0を受け、
  v6再レビューP1=1 / P2=0 / P3=0、v7最終レビューP0 / P1 / P2 / P3=0で完了した。
  server-entry def-useと起動時`SafeHandle`保持に加え、alias/dynamic storage provenance、
  provider/scope/case正規化、exact SafeHandle OR guard、全command/invocation/output/throw sink、
  partial-start cleanup、両wrapper Dispose、PS5.1自然終了race、固定相対log ID、
  型付きdual-failure listをcontractへ追加した。v5ではexecutable正本とMarkdown blockの
  byte一致、bounded readiness、root / PID evidence / diagnosticの不変性、
  3段階cleanup failureの順序付き集約を追加した。read-only `ContainsKey`は
  正本から生成する4種だけ許可する。v6ではCommonMark全fence、Ordinal byte比較、
  identifierのOrdinalIgnoreCase、top-level /各block /全writeのclosed sequence、
  function/type shadow拒否、critical def-use固定を追加した。v7ではroot ScriptBlockを
  unnamed endだけへ閉じ、`param` / `using` / requirements / named block / `trap`を拒否する。
  PR #24を`10e7cd0`へsquash merge済み。設計正本は
  `docs/server-runbook-cleanup-contract.md`。
- T-028はloading / empty / error stateを別々の合成fixtureで確認するreport例を追加し、
  全11公開exampleのfile名・表示名・README / SKILLリンクと、7 reportの証跡カテゴリ集合を
  readinessの単一manifestへ閉じた。リンク欠落、state行欠落、file名drift、正常表の後ろへ
  相反する`未確認`を足すappendを4 mutationで拒否したv1は、独立reviewでP2=4 / P3=2、
  clearanceなし。v2は再帰的な未宣言file、comment / fence / 別section decoy、
  state prefix違いを含む14 mutationとrole付きmanifestへ修正したが、独立reviewで
  P2=3 / P3=0、clearanceなし。v3は表セルのnegative verdictも共通語彙で拒否し、
  ordered-list / 英語`unverified`を含む17 mutationへ拡張したが、inline-codeを保つ
  表セルの偽合格とcurrent docsの14件表記を独立reviewでP2=2として確認した。v4は
  inline-codeの可視本文を正規化し、3文書を17件へ同期。最終独立reviewは
  P0 / P1 / P2 / P3=0。PR #26を`a749422`へsquash mergeし、PR CIとmerge後main CIもpass。

## 次の一手

1. **人間（最優先）**: `docs/requirements-redefinition-2026-07.md` §5 の D1〜D4 / O1〜O3 と、
   private marker literal の扱いを裁定する。T-024 の tracked-only 走査も §14④ の承認待ち。
2. **Codex（回答待ちに自走可）**: 新たな具体的coverage gap、失敗、または安全な
   maintenance候補が確認できた場合だけ次のtaskとして台帳化する。現時点で未完了の
   既知taskはすべて上記の人間gate対象。

## 検証コマンド（check:all、CI と同形）

CI（`.github/workflows/ci.yml`）は次の4ステップ。ローカル自己検証も同じ4点を回す
（`AGENTS.md` §6 が正本）:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/scan-private-markers.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/assert-oss-ready.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-whitespace.ps1
```

- 非 Windows シェルでは PowerShell 7+ の `pwsh -NoProfile -File ./scripts/<name>.ps1` 形式。
- `check-whitespace.ps1` は空ツリー比較で**コミット済み内容全体**を検査するため、
  コミット後に実行する。
- package manager manifest は無く、依存インストールは不要。

### 最新の検証結果（2026-07-27、本ファイル更新時）

- Windows PowerShell 5.1.26100.8894 / PowerShell 7.6.2: check:all
  4ステップ pass。scanner self-testはbinary standard stream、native Git batch byte、
  Job/process-group cleanup、first-call AST bypass、正常なlinked-worktree Gitfile、
  固定redacted診断、ancestor/dangling `.git`、index drift、sub-second deadline、
  output budget、fixed allowlist、launch-inclusive deadlineを含む。不正deadline 3種も
  exit 2・固定stdout 1行・empty stderrを両runtimeで直接再確認した。
- Debian GNU/Linux 12 / PowerShell 7.5.8 / Git 2.39.5でも同じ4ステップがpass
  （Microsoft 公式`mcr.microsoft.com/dotnet/sdk:9.0`、network無効、
  repository read-only mount、telemetry無効）。POSIX verified-group gate、
  option-free `setsid <pwsh> ...`、cleanup後release sentinelも含む。
- T-027 v4 freezeは両runtimeでcheck:all 4/4 pass後、独立v4レビューで
  P1=4 / P2=2 / P3=0。v5は両runtimeでcheck:all 4/4 pass後、独立v5レビューで
  P1=4 / P2=1 / P3=0。v6は両runtimeでcheck:all 4/4 pass後、独立v6レビューで
  P1=1 / P2=0 / P3=0。v7 focused testは両runtimeで93種の敵対的fixture reject、
  4種のexact read-only probe、synthetic Node HTTP server、partial-start cleanup、
  自然終了race、3段階cleanup failure集約、hostile root非反射がpass。
  v7は両runtimeでcheck:all 4/4 pass。Semgrep / Gitleaksと対象10ファイルの
  UTF-8・改行・BOM契約もpass。独立v7レビューはP0 / P1 / P2 / P3=0。
  PR #24のCIと`10e7cd0` merge後main CIもpass。
- T-028 v1のexact staged treeはPowerShell 7.6.2でcheck:all 4/4を246.1秒、
  Windows PowerShell 5.1.26100.8894で4/4を203.3秒でpass。OSS readinessは
  11 example / 7 report schema / 4 hostile mutationと既存server-runbook 93 hostile
  fixtureを両runtimeでpassした。Gitleaks working tree、local Semgrep rules、
  HANDOFF同期前の変更6ファイルのstrict UTF-8 / BOMをpass。最終staged scopeは
  7ファイルで、staged global hookと`git diff --cached --check`をpassした。
  独立reviewでP2=4 / P3=2となったため、このv1結果だけではmergeしない。
- T-028 v2のexact staged treeはPowerShell 7.6.2でcheck:all 4/4を256.5秒、
  Windows PowerShell 5.1.26100.8894で4/4を206.7秒でpass。OSS readinessは
  11 example / 7 report schema / 14 hostile mutationと既存server-runbook 93 hostile
  fixtureを両runtimeでpassした。Gitleaks working tree、local Semgrep rules、
  対象7ファイルのstrict UTF-8 / BOM、staged global hook、
  `git diff --cached --check`もpassした。独立reviewで表セルの`error`偽合格、
  ordered-list / 英語`unverified`のmutation不足、この証跡欄の旧値をP2=3として確認した
  ため、このv2結果だけではmergeしない。
- T-028 v3のindex＋working-tree unionはPowerShell 7.6.2と
  Windows PowerShell 5.1.26100.8894でcheck:all 4/4をpass。OSS readinessは
  11 example / 7 report schema / 17 hostile mutationと既存server-runbook 93 hostile
  fixtureを両runtimeでpassした。v3では表セルの`error`、ordered-listの`incomplete`、
  英語`unverified`を独立mutationで拒否した。この証跡同期を含むexact staged treeを
  integration freezeとして、両runtime full gate / security / UTF-8 / diff /
  独立reviewのclearanceを必須とする。wall-clock秒数はmachine loadで変動する外部実測で
  あり、このhandoffのsame-freeze contractには含めない。独立reviewでinline-codeを保つ
  表セルのnegative verdictとcurrent docsのmutation件数driftをP2=2として確認した。
- T-028 v4のexact staged treeは両runtimeでcheck:all 4/4をpass。外部実測の参考値は
  PowerShell 7.6.2が246.6秒、Windows PowerShell 5.1.26100.8894が203.9秒。
  OSS readinessは11 example / 7 report schema / 17 hostile mutation、
  server-runbook contractは93 hostile fixtureを両runtimeでpassした。Gitleaks whole tree、
  local Semgrep rules、対象7ファイルのstrict UTF-8 / BOM、staged global hook、
  `git diff --cached --check`をpass。独立reviewはP0 / P1 / P2 / P3=0。
  PR #26 CIと`a749422` merge後main CI（run `30224634711`）も全step pass。

## 残懸念・未確認

- macOSとnative Linux hostでの`pwsh`実機動作は`未確認`。Debianコンテナ上の動作は
  T-026で再確認済み。
- CI checkout actionのimmutable commit SHA固定は`未確認`ではなく**未実施**。
  現行mutable major tagの変更には§14①の人間承認が必要。
- 導入先の route/state 固有 readiness locator は本リポジトリでは決定できないため、
  `SKILL.md` の合成例を各 UI に合わせて置き換える必要がある。
- 外部利用者の存在・利用実態（star / fork / 転用事例）は `未確認`。
- examples はすべて合成データ。実プロジェクトへ転用するときは route / URL / fixture /
  browser evidence を各案件の実測に置き換える。
- T-028はreport契約の合成exampleとrepository readinessだけを検証した。実ブラウザ / 実UI、
  deploy、OAuth、secret、実データ、費用操作は実施していない。

## 引き継ぎ時の注意

- 他エージェントへ委譲する場合は self-contained spec（対象ファイル・受け入れ条件・
  検証コマンド・書き込み許可範囲）を渡し、成果物の実在（`git status --porcelain`、
  ファイル hash、PR state）で完了を検証する。
- PUBLIC repo である前提を委譲プロンプトに明記し、マージ前に必ず
  `scan-private-markers.ps1` で private context の混入を確認する。
- 停止条件は `AGENTS.md` §14 の4ゲート（デプロイ/Actions/release・tag、課金・有料 API、
  secret・実データの外部送信、製品要件の意味変更）。それ以外は自走する。
