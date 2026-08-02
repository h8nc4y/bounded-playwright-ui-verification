# HANDOFF.md

PUBLIC repositoryの現況スナップショット。
恒久ルールは`AGENTS.md`、タスク正本は`TASKS_BACKLOG.md`とする。

## 現在の目標

T-032の12-file runtime closure導入は完了した。
回答待ちの要件とオーナー承認待ちのscanner提案を越えず、次の安全な改善候補を選ぶ。

## スナップショット

- T-032実装はPR #30でmainへmerge済み（merge commit
  `6eb085360a4ac8c12033e854fc1c24351bdc771e`）。
- runtime pathは`SKILL.md`＋public-example manifestの11 pathから導出する。
- `SKILL.md`は公式Playwright 1行＋公開example 11行のraw linkをexactな順序・件数で許可する。
- READMEはcanonical Install bytes、Install前raw less-than / fence、outside runtime
  token / character reference、exact `#`含有行、container-prefixed Setext-like /
  thematic-break surface、code span内も含むraw h1〜h6 tag-like tokenを固定する。
- 38 hostile mutationと、atomic claim、fail-closed SHA-256取得、source / staging再照合、
  失敗時のstaging保持、copy後source変更のfixtureで契約を固定する。

## 成功条件と実測

- 2026-07-29 11:33 JST、PR #30をmainへmergeした。PRの必須check
  `Validate repository`はsuccessだった。
- main push CI run `30417135131`は11:36 JSTにsuccessとなり、private marker scan、
  scanner回帰、OSS readiness、whitespaceの4 stepがすべてpassした。
- 13:02〜13:07 JST、merge commit上でWindows PowerShell 5.1のcheck:all 4ステップを
  再実行し、すべてpassした。runtime 12 files、38 hostile mutation classes、
  atomic claim / failure retention、hash failure / source mutationもreadiness内で確認した。
- 同じpost-main確認時点でlocal mainとorigin/mainは一致し、working treeはcleanだった。
- 実ブラウザ、active skill更新、deploy、OAuth、secret、実データ、課金操作は実施していない。

## 次の一手

1. D1〜D4 / O1〜O3へのオーナー回答後、T-018〜T-020 / T-022のblockedを再評価する。
2. §14④の承認が得られた場合だけ、T-024のtracked-only走査モードを再評価する。
3. 回答・承認が無い間は、製品要件を変えない公開docsのdriftや合成exampleの改善候補を監査する。

## 読み直さない範囲

- v1〜v11のparser実装履歴、長いprobe秒数、解消済み反例は再読しない。
- T-032の実装詳細は`TASKS_BACKLOG.md`の実装契約、PR #30、git履歴を参照する。

## オーナー境界と保留

- active skill更新、deploy、OAuth、secret、実データ、課金操作は行わない。
- T-032作業中、`.review-019-runtime-closure-20260729`と
  `.skillspector-019-terminal.log`のcleanupはpolicy層で拒否された。拒否回数は正本上`未確認`で、
  迂回や追加retryは行わない。
- 2026-08-03 01:27 JSTのread-only確認時点では上記2 pathはいずれも不在だった。
  削除の実行主体と時刻は`未確認`であり、cleanup成功の証拠として扱わない。
- ignoredの`.claude/`と`.ui-verification/`は同確認時点で存在した。
  内容は読まず、既存WIPとして削除・変更せず保持する。
