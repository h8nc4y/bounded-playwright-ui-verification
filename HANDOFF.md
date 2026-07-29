# HANDOFF.md

PUBLIC repositoryの現況スナップショット。
恒久ルールは`AGENTS.md`、タスク正本は`TASKS_BACKLOG.md`とする。

## 現在の目標

T-032でREADME installを、任意Markdown解析ではなく監査可能なstrict subsetへ閉じる。
`SKILL.md`単体copyによるrelative link欠落を防ぎ、12-file runtime closureを原子的に導入する。

## スナップショット

- branch：`fix/runtime-closure-install-contract`
- base / HEAD：`bfb5c9f29b39e3dccbf8d19fd1d3dbfb47eb3793`
- 変更6ファイル：`CHANGELOG.md`、`HANDOFF.md`、`README.md`、
  `TASKS_BACKLOG.md`、`scripts/assert-oss-ready.ps1`、`runtime-files.txt`
- runtime pathは`SKILL.md`＋public-example manifestの11 pathから導出する。
- `SKILL.md`は公式Playwright 1行＋公開example 11行のraw linkをexactな順序・件数で許可する。
- READMEはcanonical Install bytes、Install前raw less-than / fence、outside runtime
  token / character reference、exact `#`含有行、container-prefixed Setext-like /
  thematic-break surface、code span内も含むraw h1〜h6 tag-like tokenを固定する。
- 38 hostile mutationと、atomic claim、fail-closed SHA-256取得、source / staging再照合、
  失敗時のstaging保持、copy後source変更のfixtureで契約を固定する。

## 成功条件と実測

- 27-mutation版の両PowerShell readinessとscannerはpassしたが、10:49 JSTの統合reviewで
  hash fail-open、outer wrapper、semantic heading反例が見つかりNO-GOとなった。
- 2026-07-29 11:18〜11:20 JST、38-mutation版のPowerShell 7 / 5.1 readinessはpassした。
  runtime 12 files、hash failure / source mutation、atomic claim / failure retentionを確認した。
- 11:18 JST、Windows PowerShell 5.1 scanner回帰suiteは175.7秒、再試行なしでpassし、
  前後のscanner関連processは0件だった。
- 11:21 JST、private-marker本体、Gitleaks、Semgrepはpassした。
- 11:24 JST、最終read-only独立reviewはP0〜P3すべて0、`CLEARANCE=YES`だった。
- Git stage / commit / push、PR / CI / mergeは`未確認`。
- v1〜v11の任意CommonMark parser案は独立reviewで境界欠陥が続きNO-GOとなった。
  この案は廃止し、上記strict subsetへ設計変更した。

## 次の一手

1. 変更6ファイルの差分をfreezeし、read-only独立reviewを通す。
2. CLEAR後にPowerShell 5.1 focused gate、両host full gate、scannerとsecurity checksを直列実行する。
3. 全証跡を同一treeへ同期し、commit、push、PR、必須CI、merge、post-main確認へ進む。

## 読み直さない範囲

- v1〜v11のparser実装履歴、長いprobe秒数、解消済み反例は再読しない。
- README canonical Installとscript templateは、同じ変更で同期する。

## オーナー境界と保留

- active skill更新、deploy、OAuth、secret、実データ、課金操作は行わない。
- `.review-019-runtime-closure-20260729`と`.skillspector-019-terminal.log`は、
  cleanupがpolicy層で拒否されたため保持する。迂回削除しない。
