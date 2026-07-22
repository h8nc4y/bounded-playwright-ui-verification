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

## 現状サマリ（2026-07-22 時点）

- `main` がリリース可能・最新で、唯一の通常作業対象ブランチ。タグ `v0.1.0` は `main` 上。
- ブランチ保護あり。必須ステータスチェック「Validate repository」（CI）の通過が必須。
  変更は PR → CI 緑 → セルフマージが基本（`AGENTS.md` §9）。
- T-001〜T-017 / T-021 / T-023 / T-025 と scanner hardening（`914aee1`）は完了。詳細な完了履歴は
  `TASKS_BACKLOG.md` の表と `git log` / `CHANGELOG.md` を参照（本ファイルには重複させない）。
- **最大のゲート**: `docs/requirements-redefinition-2026-07.md` §5 の質問リスト
  （決定軸 D1〜D4・運営判断 O1〜O3）が人間の回答待ち。回答が出るまで
  T-018〜T-020 / T-022 は blocked。scanner の tracked-only 走査モード（T-024）も
  §14④ ゲートで人間承認待ち。
- 外部レビューの非 gate 指摘（Playwright 推奨例の `networkidle`）は T-025 / PR #22 で対応。
  残る scanner 2件はオーナー裁定または §14④ gate の対象。

## 次の一手

1. **人間（最優先）**: `docs/requirements-redefinition-2026-07.md` §5 の D1〜D4 / O1〜O3 と、
   private marker literal の扱いを裁定する。T-024 の tracked-only 走査も §14④ の承認待ち。
2. **Codex（回答待ちに自走可）**: 既存スコープ内の合成 example を拡充する。着手時に
   具体的なシナリオを `TASKS_BACKLOG.md` へ追加し、製品要件の意味は変えない。

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

### 最新の検証結果（2026-07-22、本ファイル更新時）

- Windows PowerShell 5.1: check:all 4ステップ pass（scanner 回帰テスト 11/11）。
- Debian GNU/Linux 12 コンテナ / PowerShell 7.5.8 / Git 2.39.5: check:all 4ステップ pass
  （Microsoft 公式 `mcr.microsoft.com/dotnet/sdk:9.0`、network 無効、repository read-only mount、
  PowerShell telemetry 無効）。

## 残懸念・未確認

- macOS と native Linux host での `pwsh` 実機動作は `未確認`。Linux コンテナ上の動作は
  T-021 で確認済み。
- 導入先の route/state 固有 readiness locator は本リポジトリでは決定できないため、
  `SKILL.md` の合成例を各 UI に合わせて置き換える必要がある。
- 外部利用者の存在・利用実態（star / fork / 転用事例）は `未確認`。
- examples はすべて合成データ。実プロジェクトへ転用するときは route / URL / fixture /
  browser evidence を各案件の実測に置き換える。

## 引き継ぎ時の注意

- 他エージェントへ委譲する場合は self-contained spec（対象ファイル・受け入れ条件・
  検証コマンド・書き込み許可範囲）を渡し、成果物の実在（`git status --porcelain`、
  ファイル hash、PR state）で完了を検証する。
- PUBLIC repo である前提を委譲プロンプトに明記し、マージ前に必ず
  `scan-private-markers.ps1` で private context の混入を確認する。
- 停止条件は `AGENTS.md` §14 の4ゲート（デプロイ/Actions/release・tag、課金・有料 API、
  secret・実データの外部送信、製品要件の意味変更）。それ以外は自走する。
