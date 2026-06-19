# HANDOFF.md

## リポジトリの目的

このリポジトリは、AI coding agent が Web UI 変更後に Playwright やブラウザ自動化で実画面を検証するときの手順をまとめた Codex-style skill を配布するためのもの。前景の dev server、無制限待機、検証していない項目の過大報告、未 cleanup の local process を避けるための運用ルールを `SKILL.md`、README、examples、local validation scripts で提供している。

## 引き継ぎの主役

- **`AGENTS.md` が Codex 向けの恒久運用契約（主開発者として自走するためのルール）。** Codex CLI がリポジトリ直下の `AGENTS.md` を自動で読み込む。日々の作業ルール・4ゲート・レビュー方針・ブリーフ雛形はすべてそこにある。
- 本 `HANDOFF.md` は現状スナップショットと検証記録。残タスク台帳は `TASKS_BACKLOG.md`。

## 現状サマリ（2026-06-20 整備時点）

- `main` がリリース可能・最新で、唯一の作業対象ブランチ。タグ `v0.1.0` は `main` 上にある。
- Codex 自走のための運用契約 `AGENTS.md` を追加した。
- 検証スクリプトの走査除外に `.claude` / `.codex`（agent ローカルのツール用ディレクトリ）を追加し、ローカル生成物起因で check:all が誤って赤になる罠を塞いだ。`.gitignore` にも両者を追加。
- open GitHub issue / open PR は無し（PR #1 はマージ済み）。
- 古い `feature/oss-readiness`（`main` と内容差分なし）は削除した。
- スナップショットは陳腐化する。実際の状態は `git status` / `gh pr list` / `gh issue list` で都度確認すること。

## 完了タスクと commit

| タスク | 区分 | メモ |
| --- | --- | --- |
| 初期 skill と docs を追加 | `36bee96` | `SKILL.md`、README、examples、scripts の初期追加。 |
| OSS readiness を整備 | `a2c93a2` | CI、issue template、support/security/contribution docs、validation scripts を整備。 |
| 棚卸し結果を `TASKS_BACKLOG.md` に記録 | `df9afe7` | 残タスクの情報源を確認し、未処理タスクなしとして記録。 |
| 引き継ぎ文書を追加し backlog を日本語で最新化 | `56ed73b` / `6582fda` | `HANDOFF.md` 初版と `TASKS_BACKLOG.md` 更新。 |
| Codex 自走運用契約 `AGENTS.md` を追加し、scan 除外を堅牢化 | この引き継ぎ整備 | `AGENTS.md` 追加、`.claude`/`.codex` を両 scan スクリプトの除外と `.gitignore` に追加。 |

## 既知の問題・残懸念

- 公開ドキュメント（`README.md` / `CONTRIBUTING.md` / `docs/release-checklist.md`）の whitespace チェックは素の `git diff --check` 表記のまま。CI は空ツリー比較（`git diff --check 4b825dc…04 HEAD`）でコミット済み内容を見るため、表記を揃えるのが望ましい（`AGENTS.md` §5 の候補、`TASKS_BACKLOG.md` 参照）。
- このリポジトリは PowerShell scripts と Markdown が中心で、専用の typecheck や build コマンドは無い。

## 最終検証結果

2026-06-20 の引き継ぎ整備で下記を実行した（`AGENTS.md` §6 と同形）。

| 種別 | コマンド | 結果 |
| --- | --- | --- |
| private marker scan | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-private-markers.ps1` | pass |
| OSS readiness | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/assert-oss-ready.ps1` | pass |
| whitespace lint | `git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD` | pass: exit 0、出力なし |
| 除外の動作確認 | `.codex/` に絶対パスを置いて scan | pass: 除外され検出されないことを確認 |
| typecheck / build | 該当コマンドなし | 未確認 |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

この repository は package manager manifest を持たないため、dependency install は不要。

## ブランチ状況

| branch | 状態 | 内容 |
| --- | --- | --- |
| `main` | 最新・唯一 | release-ready 状態。タグ `v0.1.0` を含む。Codex はここから自走する。 |

## 次にやるべき候補

- 生きた候補一覧は `AGENTS.md` §5 と `TASKS_BACKLOG.md` を参照。
- 着手前に `TASKS_BACKLOG.md` へ優先度・規模・状態付きで追記し、`AGENTS.md` の自走ループ（§4）と4ゲート（§14）に従う。
