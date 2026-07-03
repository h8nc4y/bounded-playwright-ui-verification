# ClaudeCode Fable5 handoff - 019_bounded-playwright-ui-verification

作成日時: 2026/07/02 08:30:54 JST。
配置: repo-local draft。公開・commit・PR化する前に、private context とローカル絶対パスが残っていないか確認すること。

## 調査範囲と注意

- 根拠は local git 状態、repo 内 README/HANDOFF/TASKS/docs、読み取り専用 subagent 調査。
- 外部API、GitHub live、CI、ブラウザ、テスト、Cloudflare、Chrome Web Store、Discord、Google、Anthropic、YouTube、X API は今回未確認。
- `*.p12`、`*.pem`、`*.pfx`、`.env*`、`auth.json` は読んでいない。
- raw log、cache、DB、state、queue、drafts、実データの中身は読んでいない。
- 既存のWeb調査/判断資材は repo 内資料の path map であり、Fable5 側で最新市場調査・最新仕様確認をやり直すこと。

## Repo handoff

## 019_bounded-playwright-ui-verification

- 状態: `<repo-root>`; branch `docs/hover-focus-state-report`; clean; latest `092b62c docs: add hover focus state verification example`
- 目的: Web UI 変更後の Playwright/browser 実画面検証を bounded server・cleanup・未確認報告つきで行う Codex-style skill。
- 要件定義/要件相当: `AGENTS.md` §10, `README.md`, `SKILL.md`; 専用 `REQUIREMENTS.md` は未整備/未確認。
- Web調査/判断資材: 未整備/未確認。
- 設計書: `README.md`, `AGENTS.md`, `docs/release-checklist.md`; フロントUI自体は無し。
- 完成までのタスク一覧: `TASKS_BACKLOG.md`
- 進捗: T-001-T-014 done。hover/focus state 合成例が現 branch にあり、handoff は scan/OSS readiness/whitespace pass を記録。
- 残タスク/gate: 非Windows `pwsh` 実機検証は未確認。main は保護あり、PR+CI前提。外部公開・要件変更は gate。
- Fable5 reading order: `AGENTS.md` → `HANDOFF.md` → `TASKS_BACKLOG.md` → `README.md` → `docs/release-checklist.md`
- Prompt addendum: UI検証skillとしての価値、ほか自動検証手段との差別化、証跡粒度を再定義する。現 checkout と `HANDOFF.md` の main 記述がずれるため ancestry/merge 状態を確認する。

## Fable5 next action

1. `docs/CLAUDECODE_FABLE5_PROMPT.md` を読み、Fable5 の作業方針を確認する。
2. 上記の reading order に従って repo の正本資料を読む。
3. 既存要件をそのまま前提にせず、ユーザーへの質問から目的・市場・成功指標・非目標を再定義する。
4. UI が存在する repo では ClaudeDesign で wireframe または UI spec を作ってから実装へ進む。
5. 実装は Codex GPT5.5 XHIGH skill に依頼してよいが、Fable5 が受け入れ条件・対象ファイル・検証コマンド・gate を具体化してから渡す。