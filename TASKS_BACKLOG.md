# TASKS_BACKLOG.md

残タスクの生きた台帳。新タスクは着手前にこの表へ優先度・規模・状態付きで追記し、
完了したら `done` に更新する（`AGENTS.md` §5）。完了タスクの詳細な経緯は
`git log` / `CHANGELOG.md` / マージ済み PR を参照する。

## バックログ

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 |
| --- | --- | --- | --- | --- | --- |
| T-001 | 棚卸し結果を `TASKS_BACKLOG.md` に記録する | 2026-06-11 棚卸し | 高 | S | done |
| T-002 | 引き継ぎ情報を `HANDOFF.md` に記録する | 2026-06-13 締め作業 | 高 | S | done |
| T-003 | Codex 自走運用契約 `AGENTS.md` を整備し、scan 除外を堅牢化する | 2026-06-20 引き継ぎ整備 | 高 | M | done |
| T-004 | 公開 docs の whitespace check 表記を CI と同形に揃える | `AGENTS.md` §5 | 中 | S | done |
| T-005 | `CHANGELOG.md` を `v0.1.0` タグとタグ後変更に整合させる | `AGENTS.md` §5 | 中 | S | done |
| T-006 | 非 Windows 寄稿者向けの `pwsh` 検証手順を明確化する | `AGENTS.md` §5 | 中 | S | done |
| T-007 | `HANDOFF.md` を T-004〜T-006 完了後の状態へ同期する | handoff 整備 | 中 | S | done |
| T-008 | 合成 evidence matrix example を追加する | examples 拡充 | 中 | S | done |
| T-009 | browser verification の失敗時報告例を追加する | examples 拡充 | 中 | S | done |
| T-010 | login/OAuth で保護 route が blocked になる合成報告例を追加する | examples 拡充 | 中 | S | done |
| T-011 | responsive overflow の合成報告例を追加する | examples 拡充 | 中 | S | done |
| T-012 | blank render target の合成報告例を追加する | examples 拡充 | 中 | S | done |
| T-013 | PR #11 後の current-state を handoff / 台帳に同期する | 文書 drift | 中 | S | done |
| T-014 | hover/focus state の合成報告例を追加する | examples 拡充 | 中 | S | done |
| T-015 | 価値・差別化・証跡粒度の再要件定義ドラフトを `docs/` に追加する | 2026-07-03 引き継ぎ | 高 | M | done |
| T-016 | R-6: README「What It Solves」へ pre-claim evidence contract の文言明確化を反映する | 再定義ドラフト §6 | 中 | S | done |
| T-017 | 2026-07-11 時点の current-state を handoff / 台帳へ同期する | Codex 引き継ぎ整備 | 中 | S | done |
| T-018 | R-2: verdict 4値 + applicability 別軸 + passed の evidence pointer 必須化を `SKILL.md` へ明文化する | 再定義ドラフト §6 | 高 | S | blocked (D2 回答待ち) |
| T-019 | R-3: MCP ツール経由の検証経路を examples または `SKILL.md` に追記する | 再定義ドラフト §6 | 中 | M | blocked (D4 回答待ち) |
| T-020 | R-4: sparse claim ledger の合成 example を追加する | 再定義ドラフト §6 | 中 | S | blocked (D3 回答待ち) |
| T-021 | R-5: 非 Windows `pwsh` 実機検証を記録する（実機が無い間は `未確認` を維持） | 再定義ドラフト §6 | 低 | S | done |
| T-022 | R-1: 質問リスト回答後に要件正本（REQUIREMENTS 相当）を整備する | 再定義ドラフト §6 | 高 | M | blocked (D1〜D4 / O1〜O3 回答待ち) |
| T-023 | 引き継ぎ文書の一本化と check:all 文書の CI 同形化（4ステップ） | 2026-07-12 資料整理 | 中 | M | done |
| T-024 | scanner に tracked-only 走査モード（`-TrackedOnly`）を追加する | scanner hardening 提案（`914aee1` 時の残提案） | 中 | M | blocked (§14④ 人間承認待ち) |
| T-025 | Playwright 推奨例の `networkidle` を route/state 固有の bounded readiness 待機へ置き換える | 2026-07-15 外部レビュー | 中 | M | done (PR #22) |
| T-026 | private marker scannerのprocess・Git・出力境界をfail-closed化する | 2026-07-24 cross-repo maintenance | 高 | L | done |
| T-027 | bounded server runbook の cleanup を直接process所有・例外安全・fail-closed にする | `AGENTS.md` §10 と独立レビュー | 高 | L | in progress (review-fix v7) |

## 補足メモ

- **T-018〜T-020 / T-022 のゲート**: `docs/requirements-redefinition-2026-07.md` §5 の
  質問リスト（D1〜D4 / O1〜O3）への人間の回答。回答が出たら blocked を解除して着手する。
- **T-021 の検証証跡**: 2026-07-22、Debian GNU/Linux 12 コンテナの PowerShell 7.5.8
  （Git 2.39.5）で check:all 4ステップが pass。Microsoft 公式
  `mcr.microsoft.com/dotnet/sdk:9.0` を network 無効・repository read-only mount・telemetry
  無効で実行した。macOS と native Linux host は `未確認` を維持する。
- **T-024 の提案概要**: `scan-private-markers.ps1` に `param([switch]$TrackedOnly)` を追加し、
  有効時は `git ls-files -z` の結果のみを走査対象にする。CI は checkout 済み tracked のみ
  なので CI で既定有効にすると手元/CI の対象が一致する。走査対象という**振る舞いの変更**
  （「scan passed」の意味が変わる）を伴うため §14④ ゲート。承認時は README / CHANGELOG /
  HANDOFF に対象の変更を明記する。詳細な検討記録は git 履歴の `NOTES_CLAUDE.md`
  （2026-07-12 に整理・削除済み）を参照。
- scanner hardening（秘匿値 regex 拡充・self-exempt hole 修正・CI shell の pwsh 統一・
  回帰テスト `tests/scan-private-markers.Tests.ps1` 追加）は `914aee1`（2026-06-21）で
  マージ済み。
- **T-026 の非変更境界**: T-024のtracked-only化は行わない。Git indexのstaged内容に加え、
  除外対象外のworking tree textをuntracked fileも含めて走査し、既存のown-repository URL、
  reserved example email、Bearer prose、directory除外、temp cleanup契約を維持する。
- **T-026 の追加回帰境界**: first-call ASTはtarget shadow、引数順序を変えたalias、
  function provider、class constructor/method、function/class間の推移的wrapperを拒否する。
  Windows Job close失敗ではhandleを保持してdirect terminate・有限wait・再closeし、
  bootstrap/process/isolationの複合例外も内部pathを出さない固定診断1行とexit code 2へ閉じる。
- **T-026 の残差**: `.github/workflows/ci.yml`は§14①の人間gateにつき変更していない。
  readinessは現行trigger / permissions / job / stepを完全一致で固定するが、
  `actions/checkout@v4`はmutable tagのままでありimmutable保証ではない。
- **T-027 の実装契約（2026-07-26）**:
  - **目的**: browser verification が成功・失敗・timeoutのどの経路を通っても
    `finally` でcleanupを実行する。task runnerや`.cmd`を介さず実server executableを
    直接起動し、起動直後に取得した同一process handleを保持して停止を有限時間で確認する。
  - **影響**: 合成/local用途のPowerShell runbookと、その契約を守るreadiness回帰だけを
    厳格化する。実server、production、OAuth、secret、実データ、課金操作は扱わない。
  - **安全境界**: health timeoutではraw stderrを自動再生せず、固定相対log ID・byte size・
    固定classificationだけを出し、absolute rootをpublic warningへ反射しない。
    `HasExited=false`直後の自然終了raceは同じ保持processだけを再確認する。直接serverが
    子孫processを生成する案件は、この例だけでtree cleanupを主張せず、OS固有containmentへ
    置換するまで`未確認`とする。
    handle取得がStart後に失敗した場合も同じdirect `Process`へbounded cleanupを行い、
    `SafeHandle`と`Process`はnested `finally`で決定的に解放する。stop / SafeHandle
    Dispose / Process Disposeの失敗はstage順で保持し、複数時だけ集約する。
  - **検証**: コメント・文字列・here-string・dead branchを証拠に数えない実行可能ASTと
    def-use / 後続mutation / 支配関係で、`finally`、同一handle、bounded stop、
    race recovery、diagnostic、両failure伝播、alias/dynamic storage、
    provider/scope/case正規化、command/output/throw/invocation sinkを検査する。
    CommonMark fence全体を1 executable blockへ閉じ、executable正本とMarkdown bodyの
    strict UTF-8 / LF / Ordinal一致を固定する。top-level / outer try / health / polling /
    cleanupと全assignment・unary writeをclosed sequence化し、function/typeによる
    command shadowとcritical variableの後続provider writeを拒否する。root ScriptBlockは
    unnamed endだけを許可し、`param` / `using` / requirements / named block / `trap`を
    拒否する。93種の
    敵対的fixture、4種のexact read-only probe、synthetic local HTTP server、
    partial-start cleanup、自然終了race、3段階cleanup failure集約、hostile root canaryを
    Windows PowerShell 5.1 / PowerShell 7で実行し、check:all 4ステップも両runtimeで通す。
  - **設計正本**: `docs/server-runbook-cleanup-contract.md`。

## 外部レビュー指摘の台帳（2026-07-15 maxエフォート横断レビュー）

読取専用レビュー（実行検証なし）の指摘。採否と実装は次担当が判断する。完了時は行頭を [x] にし、対応PRを追記する。

- [ ] scan-private-markers.ps1:30-32 — 検出パターン定義に実private値(private repo slug/ローカル絶対パス)が分割literalで残存(公開repo上で人間には読める)。018方式(.private-markers.local外部ロード)か017方式(汎用regex)へ — オーナー裁定待ち。
- [ ] 同:106 — 019のみ全working-tree走査(他repoはgit-tracked優先へ移行済み)。git-trackedモード追加。confidence高
- [x] SKILL.md:104 — waitUntil networkidleはPlaywright公式がdiscourage(timeout有界で実害小)。loadへの変更+明示待ち推奨。confidence中 — T-025 / PR #22
