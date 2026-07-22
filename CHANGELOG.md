# Changelog

All notable changes to this project are recorded here.

## Unreleased

### Added

- Codex 自走運用契約 `AGENTS.md`、引き継ぎ文書 `HANDOFF.md`、残タスク台帳
  `TASKS_BACKLOG.md` を追加しました。
- 合成データのみの verification report example 群を `examples/` に追加しました:
  evidence matrix / failed verification / protected route (login/OAuth blocked) /
  responsive overflow / blank render target / hover-focus state。
- Scanner hardening: 秘匿値プレフィックスの拡充（AWS / GCP / Slack / Stripe / PEM）、
  self-exempt hole の修正、除外ディレクトリ集合の単一情報源化
  （`scripts/private-scan-config.ps1`）、whitespace check の単一エントリ点
  （`scripts/check-whitespace.ps1`）、依存ゼロの回帰テスト
  （`tests/scan-private-markers.Tests.ps1`）を追加し、CI shell を `pwsh` に統一しました。

### Changed

- README「What It Solves」を pre-claim evidence contract の定式化（bounded execution /
  truthful reporting / evidence separation）で明確化しました。対象範囲・Non-Goals・
  判定基準は不変です。
- ローカル検証手順の記載を CI と同形の4ステップ（scan → 回帰テスト → OSS readiness →
  whitespace check）に統一しました（README / CONTRIBUTING / release checklist /
  AGENTS / HANDOFF）。
- 非 Windows 寄稿者向けに `pwsh` での validation 実行手順を明確化しました。
- `main` のブランチ保護と必須チェックの扱いを引き継ぎ文書に明記しました。
- agent ローカルの `.claude` / `.codex` ディレクトリを validation scan と ignore 対象にしました。
- `SKILL.md` の Playwright 推奨例を、`networkidle` 依存から `load` と route/state 固有 locator の
  bounded readiness 待機へ変更しました。

### Removed

- 陳腐化したエージェント引き継ぎメモ（`NOTES_CLAUDE.md`、`docs/CLAUDECODE_*.md`）を
  削除し、引き継ぎ情報を `HANDOFF.md` に一本化しました（内容は git 履歴に保持）。

## 0.1.0 - 2026-06-06

### Added

- OSS readiness validation with `scripts/assert-oss-ready.ps1`.
- GitHub Actions CI for private marker scanning, OSS readiness checks, and
  whitespace checks.
- Public contribution, security, support, issue, and pull request guidance.

### Changed

- Clarified `未確認` reporting expectations in the README, skill, and examples.
- Made private marker scanning compatible with Windows PowerShell 5.1 and
  PowerShell 7+.
