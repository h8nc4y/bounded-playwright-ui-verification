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
| T-009 | browser verification の失敗時報告例を `examples/` に追加する | `HANDOFF.md` 次候補 / examples 拡充 | 中 | S | done |
| T-010 | login/OAuth で保護routeが blocked になった時の合成報告例を `examples/` に追加する | `HANDOFF.md` 次候補 / examples 拡充 | 中 | S | done |
| T-011 | responsive overflow の合成報告例を `examples/` に追加する | `HANDOFF.md` 次候補 / examples 拡充 | 中 | S | done |
| T-012 | blank render target の合成報告例を `examples/` に追加する | `HANDOFF.md` 次候補 / examples 拡充 | 中 | S | done |
| T-013 | PR #11 後の current-state を `HANDOFF.md` / `TASKS_BACKLOG.md` に同期する | PR #11 merge 後の文書drift | 中 | S | done |

> 生きた候補一覧は `AGENTS.md` §5 を正本とする。新タスクは着手前にこの表へ追記する。

## 情報源の確認結果

| 情報源 | 結果 |
| --- | --- |
| 既存タスク管理ファイル | このファイルを追加する前に、既存のタスク管理ファイルは見つからなかった。 |
| README と docs | `README.md`、`docs/release-checklist.md`、contribution guidance には再利用できる検証手順があるが、現時点で新たに実装すべき未完了項目は見つからなかった。 |
| repository-local `AGENTS.md` と `.codex` | `AGENTS.md` は存在し、このリポジトリの自走運用契約として適用中。repo-local `.codex` は該当なし。 |
| コードコメント | 該当なし。限定的な placeholder comment 検索で該当なし。 |
| ローカル検証 | 2026-07-01 current-state sync branchで `scan-private-markers.ps1`、`assert-oss-ready.ps1`、CI同形の空ツリー比較 `git diff --check` がpass。最終結果は `HANDOFF.md` に記録。 |
| Git 状態と WIP branch | 2026-07-01 12:33 JST時点で `main...origin/main` clean。古い通常作業branchは整理済みで、PR #11 merge `822d000` まで反映済み。 |
| GitHub issues / PRs | 2026-07-01 12:33 JST時点で open issue / open PR は0件。 |

## メモ

- 進行中状態のタスクは残っていない。
- 📌 2026-06-28 Codex 実装: `examples/protected-route-report.md` を追加し、ログイン/OAuth 境界で protected UI を過大報告せず `未確認` として残す合成例を README / CHANGELOG と同期した。
- 📌 2026-06-30 Codex 実装: `examples/responsive-overflow-report.md` を追加し、390px の横スクロールと focus clipping を console/network 結果と混ぜずに報告する合成例を README / CHANGELOG と同期した。
- 📌 2026-06-30 Codex 実装: `examples/blank-render-target-report.md` を追加し、DOM load / console / network が緑でも主要canvas/chartがblankなら描画成功と報告しない合成例を README / CHANGELOG と同期した。
- 📌 2026-07-01 Codex 同期: PR #11 merge `822d000` 後の current-state を HANDOFF / TASKS_BACKLOG に反映し、repo-local `AGENTS.md` の存在と open issue / open PR 0件を再確認した。
- `skip` 状態のタスクは残っていない。
- 新しい issue、検証失敗、具体的な要求が出た場合は、実装前に上の表へ優先度・規模・状態付きで追記する。

- 📌 2026-06-21 Claude Code 再レビュー: High 指摘の advisory はローカル検証領域へ退避済み（着手前にコスト・secret・要件ゲート④の境界を確認）。横断索引: `CLAUDE_CODE_REVIEW_INDEX_2026-06-21.md`。


- 🔧 2026-06-21 Claude Code 実装: `fix/claude-scanner-hardening` ブランチに修正をコミット済み（base docs/add-evidence-matrix-example@c444e16、Codex作業ツリーは未変更）。検証/統合手順は Projectsルート `CLAUDE_FIX_BRANCHES_2026-06-21.md` 参照。
