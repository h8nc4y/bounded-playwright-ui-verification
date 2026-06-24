# TASKS_BACKLOG.md

## バックログ

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 |
| --- | --- | --- | --- | --- | --- |
| T-001 | 棚卸し結果を `TASKS_BACKLOG.md` に記録する | 2026-06-11 の棚卸し作業 | 高 | S | done |
| T-002 | Claude Code 向けの引き継ぎ情報を `HANDOFF.md` に記録する | 2026-06-13 の締め作業 | 高 | S | done |
| T-003 | Codex 自走運用契約 `AGENTS.md` を整備し、scan 除外を堅牢化する | 2026-06-20 の引き継ぎ整備 | 高 | M | done |
| T-004 | 公開 docs の `git diff --check` 表記を CI と同形に揃える | `AGENTS.md` §5 / レビュー指摘 | 中 | S | done |
| T-005 | `CHANGELOG.md` を `v0.1.0` タグとタグ後変更に整合させる | `AGENTS.md` §5 / changelog 確認 | 中 | S | done |
| T-006 | 非 Windows 寄稿者向けの `pwsh` 検証手順を明確化する | `AGENTS.md` §5 / portable validation | 中 | S | done |
| T-007 | `HANDOFF.md` を T-004〜T-006 完了後の状態へ同期する | 自走更新後の handoff 整備 | 中 | S | done |
| T-008 | 合成 evidence matrix example を `examples/` に追加する | `HANDOFF.md` 次候補 / examples 拡充 | 中 | S | done |

> 生きた候補一覧は `AGENTS.md` §5 を正本とする。新タスクは着手前にこの表へ追記する。

## 情報源の確認結果

| 情報源 | 結果 |
| --- | --- |
| 既存タスク管理ファイル | このファイルを追加する前に、既存のタスク管理ファイルは見つからなかった。 |
| README と docs | `README.md`、`docs/release-checklist.md`、contribution guidance には再利用できる検証手順があるが、現時点で新たに実装すべき未完了項目は見つからなかった。 |
| repository-local `AGENTS.md` と `.codex` | 該当なし。ファイル一覧では repository-local `AGENTS.md` と `.codex` は見つからなかった。セッション指示は別途適用済み。 |
| コードコメント | 該当なし。限定的な placeholder comment 検索で該当なし。 |
| ローカル検証 | `scan-private-markers.ps1`、`assert-oss-ready.ps1`、`git diff --check` は 2026-06-11 の棚卸し時点で pass。締め作業の最終結果は `HANDOFF.md` に記録する。 |
| Git 状態と WIP branch | 2026-06-13 時点で `chore/backlog-handoff` は origin へ push 済み。`origin/feature/oss-readiness` は `main` と内容差分なし。 |
| GitHub issues | 2026-06-11 の確認では open issue なし。2026-06-13 の締め作業では再確認未実施。 |

## メモ

- 進行中状態のタスクは残っていない。
- `skip` 状態のタスクは残っていない。
- 新しい issue、検証失敗、具体的な要求が出た場合は、実装前に上の表へ優先度・規模・状態付きで追記する。

- 📌 2026-06-21 Claude Code 再レビュー: High 指摘の advisory はローカル検証領域へ退避済み（着手前にコスト・secret・要件ゲート④の境界を確認）。横断索引: `CLAUDE_CODE_REVIEW_INDEX_2026-06-21.md`。


- 🔧 2026-06-21 Claude Code 実装: `fix/claude-scanner-hardening` ブランチに修正をコミット済み（base docs/add-evidence-matrix-example@c444e16、Codex作業ツリーは未変更）。検証/統合手順は Projectsルート `CLAUDE_FIX_BRANCHES_2026-06-21.md` 参照。
