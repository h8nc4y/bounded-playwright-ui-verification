# HANDOFF.md

## リポジトリの目的

このリポジトリは、AI coding agent が Web UI 変更後に Playwright やブラウザ自動化で実画面を検証するときの手順をまとめた Codex-style skill を配布するためのもの。前景の dev server、無制限待機、検証していない項目の過大報告、未 cleanup の local process を避けるための運用ルールを `SKILL.md`、README、examples、local validation scripts で提供している。

## 現状サマリ

- 現在の作業 branch は `chore/backlog-handoff`。
- `chore/backlog-handoff` は `origin/chore/backlog-handoff` へ push 済み。
- `main` は `origin/main` と同じ `a2c93a2` を指している。
- `chore/backlog-handoff` には `TASKS_BACKLOG.md` 追加 commit `df9afe7` がある。
- `TASKS_BACKLOG.md` には進行中タスクなし、`skip` なし。
- `HANDOFF.md` は Claude Code へ引き継ぐための現状説明として追加した。
- repository-local `AGENTS.md` と `.codex` は見つからなかった。
- open GitHub issues は 2026-06-11 時点でなし。2026-06-13 の再確認は未実施。
- Web UI 本体はないため、ブラウザ検証は対象外。

## 完了タスクと commit

| タスク | commit | メモ |
| --- | --- | --- |
| 初期 skill と docs を追加 | `36bee96` | `SKILL.md`、README、examples、scripts の初期追加。 |
| OSS readiness を整備 | `a2c93a2` | CI、issue template、support/security/contribution docs、validation scripts を整備。 |
| 棚卸し結果を `TASKS_BACKLOG.md` に記録 | `df9afe7` | 残タスクの情報源を確認し、未処理タスクなしとして記録。 |
| 引き継ぎ文書を追加し backlog を日本語で最新化 | `56ed73b` | `HANDOFF.md` 初版と `TASKS_BACKLOG.md` 更新。 |

## 未完了 / skip タスク

- 未完了タスクなし。
- skip タスクなし。

## 既知の問題・残懸念

- `origin/feature/oss-readiness` は `main` と内容差分なしだが、履歴上は `main` の祖先ではない。削除または保持判断は未実施。
- 2026-06-13 の締め作業では GitHub issues の再確認は未実施。
- この repository は PowerShell scripts と Markdown が中心で、専用の typecheck や build コマンドは見つかっていない。

## 最終検証結果

2026-06-13 00:12 JST の締め作業で下記を実行した。

| 種別 | コマンド | 結果 |
| --- | --- | --- |
| private marker scan | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1` | pass: `Private marker scan passed: no disallowed markers found.` |
| OSS readiness | `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1` | pass: `OSS readiness check passed.` |
| whitespace lint | `git diff --check` | pass: exit 0、出力なし |
| typecheck | 該当コマンドなし | 未確認 |
| build | 該当コマンドなし | 未確認 |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
git diff --check
```

この repository は package manager manifest を持たないため、dependency install は不要。

## ブランチ状況

| branch | 状態 | 内容 |
| --- | --- | --- |
| `main` | `origin/main` と一致 | 最新 release-ready 状態。 |
| `chore/backlog-handoff` | pushed branch | backlog と handoff の文書化 branch。`origin/chore/backlog-handoff` が引き継ぎ対象。 |
| `origin/feature/oss-readiness` | remote branch | `main` と内容差分なし。履歴上は `a2c93a2` と別 commit `3fbef50` を指す。 |

## 次にやるべき候補

1. Claude Code 側で `chore/backlog-handoff` を checkout し、`TASKS_BACKLOG.md` と `HANDOFF.md` の内容を確認する。
2. `origin/feature/oss-readiness` を残すか削除するか判断する。内容差分はないため、削除候補。
3. 次に変更する場合は、`docs/release-checklist.md` の local checks を先に実行し、検証結果を PR body に記録する。
