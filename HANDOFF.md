# HANDOFF.md

## リポジトリの目的

このリポジトリは、AI coding agent が Web UI 変更後に Playwright やブラウザ自動化で実画面を検証するときの手順をまとめた Codex-style skill を配布するためのもの。前景の dev server、無制限待機、検証していない項目の過大報告、未 cleanup の local process を避けるための運用ルールを `SKILL.md`、README、examples、local validation scripts で提供している。

## 引き継ぎの主役

- **`AGENTS.md` が Codex 向けの恒久運用契約（主開発者として自走するためのルール）。** Codex CLI がリポジトリ直下の `AGENTS.md` を自動で読み込む。日々の作業ルール・4ゲート・レビュー方針・ブリーフ雛形はすべてそこにある。
- 本 `HANDOFF.md` は現状スナップショットと検証記録。残タスク台帳は `TASKS_BACKLOG.md`。

## 現状サマリ（2026-06-30 03:12 JST 自走更新時点）

- `main` がリリース可能・最新で、唯一の通常作業対象ブランチ。タグ `v0.1.0` は `main` 上にある。
- Codex 自走のための運用契約 `AGENTS.md` があり、`TASKS_BACKLOG.md` と本 `HANDOFF.md` を併用する。
- T-004 / T-005 / T-006 / T-008 / T-009 / T-010 / T-011 は完了済み。公開 docs の whitespace check は CI と同じ空ツリー比較へ統一され、`CHANGELOG.md` は `Unreleased` と `0.1.0 - 2026-06-06` に分離され、非 Windows shell 向けの `pwsh` 実行形式も明記された。`examples/evidence-matrix.md` / `examples/failed-verification-report.md` / `examples/protected-route-report.md` / `examples/responsive-overflow-report.md` には、合成データだけで完了・失敗・blocked・protected route 未確認・responsive overflow を分ける browser evidence 記録例を追加済み。
- open GitHub issue / open PR は無し（2026-06-30 03:05 JST に `gh issue list` / `gh pr list` で確認）。
- 古い `feature/oss-readiness`、`docs/align-whitespace-check`、`docs/update-changelog-v0-1-0`、`docs/portable-pwsh-validation` はマージ済みで、リモート追跡 ref も prune 済み。
- `main` はブランチ保護が有効で、必須ステータスチェック「Validate repository」（CI）の通過を要求する。変更は PR を開いて CI を緑にしてからマージするのが基本（`AGENTS.md` §9 参照）。
- スナップショットは陳腐化する。実際の状態は `git status` / `gh pr list` / `gh issue list` で都度確認すること。

## 完了タスクと commit

| タスク | 区分 | メモ |
| --- | --- | --- |
| 初期 skill と docs を追加 | `36bee96` | `SKILL.md`、README、examples、scripts の初期追加。 |
| OSS readiness を整備 | `a2c93a2` | CI、issue template、support/security/contribution docs、validation scripts を整備。 |
| 棚卸し結果を `TASKS_BACKLOG.md` に記録 | `df9afe7` | 残タスクの情報源を確認し、未処理タスクなしとして記録。 |
| 引き継ぎ文書を追加し backlog を日本語で最新化 | `56ed73b` / `6582fda` | `HANDOFF.md` 初版と `TASKS_BACKLOG.md` 更新。 |
| Codex 自走運用契約 `AGENTS.md` を追加し、scan 除外を堅牢化 | `f6a5aba` / `3393305` | `AGENTS.md` 追加、`.claude`/`.codex` 除外、main ブランチ保護の扱いを明記。 |
| T-004: whitespace check 表記を CI と同形に統一 | `3b63b5b` | PR #2。README / CONTRIBUTING / release checklist を空ツリー比較へ統一。 |
| T-005: changelog を v0.1.0 と未リリース変更に分離 | `e5cd014` | PR #3。既存タグ `v0.1.0` とタグ後変更を区別。 |
| T-006: 非 Windows shell 向け `pwsh` 手順を明確化 | `275d77d` | PR #4。README / CONTRIBUTING / release checklist に `pwsh` 実行形式を追記。 |
| T-007: handoff を最新化 | `c444e16` | 古い T-004 残懸念を削除し、現在のブランチ・検証状態へ同期。 |
| T-008: evidence matrix example を追加 | `ad4decd` | 合成データだけで、完了・未確認・blocked を分ける browser evidence 記録例を追加。 |
| T-009: 失敗時 report example を追加 | `fb16227` | PR #7。合成データだけで、browser verification の失敗・部分未確認を過大報告せず書く例を追加。 |
| T-010: protected route report example を追加 | `5ff7adc` | PR #8。ログイン/OAuth 境界で protected UI を未確認として残す合成例を追加。 |
| T-011: responsive overflow report example を追加 | `docs/responsive-overflow-report-example` | 390 px の横スクロールと focus clipping を console/network 結果と混ぜずに報告する合成例を追加。 |

## 既知の問題・残懸念

- このリポジトリは PowerShell scripts と Markdown が中心で、専用の typecheck や build コマンドは無い。
- macOS / Linux 上での `pwsh` 実行は文書上の明確化のみで、実機検証は未確認。
- `examples/evidence-matrix.md` と `examples/protected-route-report.md` は合成データのみ。実プロジェクトへ転用するときは route、URL、fixture、browser evidence を各案件の実測に置き換える。

## 最終検証結果

2026-06-30 の responsive overflow example 追加後に下記を実行した（`AGENTS.md` §6 と同形）。

| 種別 | コマンド | 結果 |
| --- | --- | --- |
| private marker scan | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-private-markers.ps1` | pass |
| OSS readiness | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/assert-oss-ready.ps1` | pass |
| whitespace lint | `git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD` | pass: exit 0、出力なし |
| typecheck / build | 該当コマンドなし | 未確認 |
| UI / browser verification | フロント UI なし | 未確認 |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

この repository は package manager manifest を持たないため、dependency install は不要。非 Windows shell では PowerShell 7+ の `pwsh -NoProfile -File ./scripts/<script-name>.ps1` 形式を使う。

## ブランチ状況

| branch | 状態 | 内容 |
| --- | --- | --- |
| `main` | 最新・唯一 | release-ready 状態。タグ `v0.1.0` を含む。ブランチ保護あり（必須チェック「Validate repository」）。Codex はここから自走する。 |

## 次にやるべき候補

- 生きた候補一覧は `AGENTS.md` §5 と `TASKS_BACKLOG.md` を参照。2026-06-30 時点で T-001〜T-011 はすべて `done`。
- 次に安全に具体化しやすい候補は、`pwsh` 手順の非 Windows 実機検証記録、または既存 examples の追加的な synthetic scenario 拡充。ただし実機環境が無い場合は `未確認` と明記する。
- 着手前に `TASKS_BACKLOG.md` へ優先度・規模・状態付きで追記し、`AGENTS.md` の自走ループ（§4）と4ゲート（§14）に従う。
