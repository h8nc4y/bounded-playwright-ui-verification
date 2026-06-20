# Changelog

All notable changes to this project are recorded here.

## Unreleased

### Added

- Codex 自走運用契約を `AGENTS.md` に追加しました。
- 引き継ぎ情報と残タスク台帳を `HANDOFF.md` と `TASKS_BACKLOG.md` に整理しました。

### Changed

- 公開 docs の whitespace check 表記を CI と同じ空ツリー比較に揃えました。
- 非 Windows 寄稿者向けに `pwsh` での validation 実行手順を明確化しました。
- `main` のブランチ保護と必須チェックの扱いを引き継ぎ文書に明記しました。
- agent ローカルの `.claude` / `.codex` ディレクトリを validation scan と ignore 対象にしました。

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
