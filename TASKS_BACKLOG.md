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
| T-027 | bounded server runbook の cleanup を直接process所有・例外安全・fail-closed にする | `AGENTS.md` §10 と独立レビュー | 高 | L | done (PR #24) |
| T-028 | loading / empty / error state の合成report例と全公開exampleのreadiness契約を追加する | `SKILL.md` の状態確認要件と公開example検証のcoverage gap | 中 | M | done (PR #26) |
| T-029 | 要件再定義ドラフトの確認済み事実を現行状態へ同期する | 2026-07-28 current-state drift | 中 | S | done |
| T-030 | Playwright 推奨例の bounded readiness 契約を hostile mutation で回帰固定する | T-025 後の検査欠落と配布先copyのdrift | 高 | M | done (PR #29 / active copy同期済み) |
| T-031 | Windows scanner process回帰のhost timing依存を意味論oracleとfinite hang guardへ分離する | PR #29 CI run `30373424494` | 高 | M | done (PR #29) |
| T-032 | README installを12-file runtime closureとdeterministic manifestへ閉じる | active copy同期で判明したrelative link欠落 | 高 | M | in_progress |

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
- **T-028 の実装契約（2026-07-27）**:
  - **目的**: `SKILL.md` が確認を求める loading / empty / error state を、実データや認証情報を
    使わない1つの合成report例で具体化する。同時に、README / SKILL が公開する全exampleを
    readinessで同じmanifestへ閉じ、例の追加後に片方のリンクや必要な証跡カテゴリだけが
    driftする状態をfail closedにする。
  - **影響**: 公開example、README / SKILL のexample索引、OSS readiness検証だけを変更する。
    verdict、applicability、対象範囲など回答待ちの製品要件は変更しない。
  - **検証**: 全公開exampleのfile名・表示名・README / SKILLリンクを完全一致で照合し、
    report例ごとの証跡カテゴリ集合を閉じて検証する。状態行欠落、リンク欠落、再帰的な
    未宣言file、file名drift、comment / fence decoy、完了済みstateへ`未確認` / blocked /
    failed / errorを追記する矛盾の17 mutationを拒否する。PowerShell 7 /
    Windows PowerShell 5.1のcheck:all、private marker scan、UTF-8、whitespaceを実測する。
  - **安全境界**: exampleとmutationは合成値のみを使う。実ブラウザ、実UI、deploy、OAuth、
    secret、実データ、有料サービスは利用せず、実施していないものは`未確認`とする。
- **T-029 の実装契約（2026-07-28）**:
  - **目的**: 要件再定義ドラフトの「確認済み事実」とタスク対応表を、現行の公開example数、
    T-021完了状態、非Windows検証範囲、GitHub実状態へ同期する。
  - **影響**: current-stateの事実記録だけを修正する。D1〜D4 / O1〜O3、verdict、
    applicability、scanner走査対象、bounded契約、Non-Goalsの意味は変更しない。
  - **検証**: public exampleのmanifest実測、GitHub issue / PR / CI実測、PowerShell 5.1の
    check:all 4ステップ、private marker / whitespaceを確認する。文書のみのため挙動REDは
    非該当とする。
- **T-030 の実装契約（2026-07-28）**:
  - **目的**: T-025で修正した`SKILL.md`のPlaywright推奨例を、`load`までの有限navigationと
    route/state固有locatorの有限`visible`待機という順序付き契約へ閉じる。説明文中の
    `networkidle`言及は許可しつつ、実行例が旧待機へ戻るdriftをfail closedにする。
  - **影響**: `SKILL.md`の既存推奨例とrepository readiness検証だけを対象にする。
    導入先UIのlocator、製品要件、scanner走査対象、workflow、配布先copyは変更しない。
  - **検証**: 対象H2内の単一JavaScript fenceだけを抽出し、bounded `goto`、
    `readyLocator.waitFor`、実行順序を検証する。active tokenをline / block comment、
    single / double quoted string、template literalの外側だけから確定し、unescaped template
    interpolationは内容にかかわらずfail closedにする。`networkidle`復帰、
    timeout欠落、locator待機欠落、順序逆転、comment / string / template / 別fence decoy、
    未終端fence / string / template、template interpolation、code / H2の大小文字drift、
    HTML commentによるH2 / fence delimiter分断、0〜3空白indentを含む重複H2を含む
    28 hostile mutationを拒否し、indent付きの別H2がsectionを閉じるpositive fixtureも
    合格させる。このself-testをWindows PowerShell 5.1 / PowerShell 7で実行し、
    check:all 4ステップを両runtimeで通す。
  - **安全境界**: 合成文字列の静的検査だけを行う。実ブラウザ、実UI、deploy、OAuth、secret、
    実データ、有料サービスは利用しない。配布先copyの更新はrepo merge後の別境界とする。
- **T-031 の実装契約（2026-07-29）**:
  - **目的**: Windows hosted runnerの一時的なprep / cleanup遅延と、timeout・containment・
    tree cleanupの挙動破壊を同じwall-clock aggregateで判定しない。
  - **影響**: scanner production sourceの挙動、scan対象、timeout既定値は変更しない。
    scanner self-testと、その回帰契約を固定するOSS readinessだけを変更する。
  - **検証**: sub-second精度はC#の`WaitForExit(int milliseconds)`がWin32 waitへ同じ
    millisecond値を渡し、PowerShell callerが未丸めのremaining budgetを渡す構造で固定する。
    caller / helperの秒丸めと、実行側の再代入を隠すfull-region comment / string decoyを
    hostile mutationで拒否する。Add-Type対象外のC# method comment / string decoyと、
    raw callを残したまま丸め済みnative waitを追加するmutationも拒否する。
    runtime/tree cleanupは両OSでtarget・grandchild開始を確認してからrelease sentinelを作り、
    cleanup後にsentinelが書かれないことを確認する。prelaunchはtarget非起動で判定する。
    elapsedは意味論oracleに使わず、有限hang guardだけに限定する。
  - **診断**: timeout / containment / tree / streams / started / sentinel / elapsedを
    path・環境値・例外文を含まない固定labelへ分離する。
- **T-032 の実装契約（2026-07-29）**:
  - **目的**: `SKILL.md`だけをcopyしてrelative link先を欠落させるREADME install例を廃止し、
    `SKILL.md`とpublic-example manifestの11 pathを12-file runtime closureとして一括導入する。
  - **影響**: 公開README、tracked runtime manifest、repository readiness検証だけを変更する。
    active skill copy、production scanner、workflow、公開example本文の意味は変更しない。
  - **検証**: runtime manifestは`SKILL.md`＋public-example manifestのpath集合・順序・件数へ
    exactに閉じる。`SKILL.md`は公式Playwright 1行と公開example 11行からなるraw link
    12行だけを、exactな順序・件数で許可する。未宣言のraw link、reference-style定義、
    raw HTML linkは固定errorでfail closedにする。READMEはcanonical `## Install` sectionの
    raw bytesを固定し、Install前のraw less-than / top-level fence、section外の
    runtime token / character reference、exact allowlist外の`#`含有行、
    container-prefixedを含むSetext-like underline / thematic breakと、code span /
    escaped prose内も含むraw h1〜h6 tag-like token surfaceを拒否する。
    埋め込みPowerShellをASTで構文検証し、
    38 hostile mutationで限定surfaceを回帰固定する。install fixtureはportable path、
    atomic target claim、fail-closedなSHA-256取得、source / staging再照合、失敗時の
    staging保持、copy後source変更の拒否を検証する。
  - **安全境界**: 合成repository textとOS temp配下の決定論fixtureだけを検査する。
    install例はtrusted / quiescent cloneを前提とし、同一accountの悪意あるprocessが個々の
    path openを精密にraceする脅威と任意Markdown / CommonMark parserは非目標。
    active skill更新、deploy、OAuth、secret、実データ、有料サービスは利用しない。

## 外部レビュー指摘の台帳（2026-07-15 maxエフォート横断レビュー）

読取専用レビュー（実行検証なし）の指摘。採否と実装は次担当が判断する。完了時は行頭を [x] にし、対応PRを追記する。

- [ ] scan-private-markers.ps1:30-32 — 検出パターン定義に実private値(private repo slug/ローカル絶対パス)が分割literalで残存(公開repo上で人間には読める)。018方式(.private-markers.local外部ロード)か017方式(汎用regex)へ — オーナー裁定待ち。
- [ ] 同:106 — 019のみ全working-tree走査(他repoはgit-tracked優先へ移行済み)。git-trackedモード追加。confidence高
- [x] SKILL.md:104 — waitUntil networkidleはPlaywright公式がdiscourage(timeout有界で実害小)。loadへの変更+明示待ち推奨。confidence中 — T-025 / PR #22
