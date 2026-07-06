# ClaudeCode 司令塔 引き継ぎ — bounded-playwright-ui-verification (post-Fable5)

本書は **2026-07-08 以降、または Fable5 の利用上限到達後**に有効な引き継ぎ文書。
テンプレ正本は codex-global-context repo の `templates/agent-handoff-prompt.md`。
旧 `docs/CLAUDECODE_FABLE5_HANDOFF.md` / `docs/CLAUDECODE_FABLE5_PROMPT.md` は
削除せず履歴として保持する。読み替え: 「Fable5」→「司令塔モデル」。

作成日時: 2026/07/06 JST

## 役割分担（モデル固定名を使わない）

- **司令塔**: Claude Opus 4.8 role。要件再定義・設計判断・レビュー・Codex への委譲文作成を担当。
- **実装**: `mcp__codex__codex`（通常タスク）/ `mcp__codex-deep__codex`（難所のみ、xhigh）。
- **並列調査・機械的作業**: Sonnet 5 subagent（Agent tool 経由）。
- **フロントエンド/UI**: `frontend-developer` subagent。本 repo は現時点で UI 実装なし
  （PowerShell scripts と Markdown 中心の skill 配布リポジトリ）。

固定モデル名（Fable5 等）をゴールや運用ルールの恒常記述に使わない。役割名で書くこと。

## 調査範囲と注意（引き継ぎ時点の限界）

- 根拠は local git 状態、repo 内 README/AGENTS.md/HANDOFF.md/TASKS_BACKLOG.md/docs の読み取りのみ。
- 外部の実 CI 実行結果、GitHub Actions ログ、他コントリビューターの活動は未確認。
- 既存資料は現状把握の材料であり、要件定義の最終正本ではない。市場・差別化の再調査は
  陳腐化を疑って必要に応じてやり直すこと。

## リポジトリの目的

AI coding agent が Web UI 変更後に Playwright やブラウザ自動化で実画面を検証する際の
運用手順をまとめた Codex-style skill を配布するリポジトリ。前景の dev server 待機、
無制限ポーリング、未検証項目の過大報告、cleanup 漏れを防ぐルールを `SKILL.md`、
README、examples、ローカル検証 scripts で提供する。**PUBLIC リポジトリ**であり、
ローカル絶対パスや他リポジトリの内部情報、個人環境の詳細を書き込まないこと。

## 主要ファイル（reading order）

1. `AGENTS.md` — Codex 向け恒久運用契約（4 ゲート、レビュー方針、ブリーフ雛形）
2. `HANDOFF.md` — 現況スナップショットと検証記録
3. `TASKS_BACKLOG.md` — タスク一覧（T-001〜T-015 他）と最新の棚卸しメモ
4. `docs/requirements-redefinition-2026-07.md` — 価値・差別化・証跡粒度の再要件定義ドラフト
   （未回答の質問リスト D1〜D4 / O1〜O3 を含む）
5. `README.md` / `SKILL.md` — repo 概要と skill 本体
6. `docs/release-checklist.md` — リリース前チェック

## 現在地（2026-07-06 時点）

- `main` が最新かつ唯一の通常作業対象ブランチ。直近マージは PR #14
  （`docs/requirements-redefinition-2026-07`、T-015: 再要件定義ドラフト追加）。
- T-001〜T-015 はすべて完了。open issue / open PR は本書作成時点で無し（都度
  `gh issue list` / `gh pr list` で再確認すること。スナップショットは陳腐化する）。
- `main` はブランチ保護あり。必須ステータスチェック「Validate repository」（CI）の
  通過が必須。変更は PR を開いて CI を緑にしてからマージする（`AGENTS.md` 参照）。
- **最優先の未決事項**: `docs/requirements-redefinition-2026-07.md` にある人間への
  質問リスト（決定軸 D1〜D4、運営判断 O1〜O3）が未回答。回答が出るまで、そこに
  紐づく後続タスク（R-2〜R-4、R-6 相当）は着手できない。

## 次アクション候補

1. **人間の回答待ち**: `docs/requirements-redefinition-2026-07.md` の質問リストへの
   回答を確認する。回答が得られたら、それに基づいて後続タスクを `TASKS_BACKLOG.md` へ
   優先度・規模・状態付きで追記してから着手する。
2. 回答が無い間に安全に進められる候補: 非 Windows 環境での `pwsh` スクリプト実機検証
   （実環境が無い場合は `未確認` と明記する）、既存 examples への追加的な synthetic
   scenario 拡充。
3. 新しい issue・検証失敗・具体的な要求が出た場合は、実装前に `TASKS_BACKLOG.md` へ
   記録してから着手する。

## Stop only when（費用・外部リスクの境界）

有料 API/有料クラウド/課金、OAuth/secret/token 入力、実ユーザー/実データの外部送信、
ストア提出・公開 release・production deploy、または人間の意思決定なしには進めない
product 判断が必要なときだけ止まる。本 repo は PUBLIC のため、ローカル絶対パス・
個人環境情報・他リポジトリの内部情報を書き込む操作も止めて内容を修正すること。

## 委譲時の注意

- Codex へ委譲する際は self-contained spec（対象ファイル・受け入れ条件・検証コマンド・
  書き込み許可範囲）を渡し、`multi-agent-delegation` skill の規律（再委譲禁止文言・
  成果物の実在検証）に従う。
- 本 repo は package manager manifest を持たないため依存インストールは不要。検証は
  `scripts/scan-private-markers.ps1`、`scripts/assert-oss-ready.ps1`、
  `git diff --check <empty-tree-hash> HEAD` の 3 点が基本（`AGENTS.md` / `HANDOFF.md` 参照）。
- PUBLIC repo である前提を委譲プロンプトに明記し、成果物に private context や
  ローカル絶対パスが混入していないか、マージ前に必ず scan スクリプトで確認する。

---

履歴はこちら: [`docs/CLAUDECODE_FABLE5_HANDOFF.md`](./CLAUDECODE_FABLE5_HANDOFF.md) /
[`docs/CLAUDECODE_FABLE5_PROMPT.md`](./CLAUDECODE_FABLE5_PROMPT.md)
