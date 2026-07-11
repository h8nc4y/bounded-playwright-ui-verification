# Release Checklist

Use this checklist before tagging or publishing a repository update.

## Repository

- [ ] `README.md` describes install, manual use, validation, contribution, and
  security guidance.
- [ ] `SKILL.md` front matter has the expected name and a specific description.
- [ ] Examples use synthetic data only.
- [ ] Unverified browser checks are marked `未確認`.
- [ ] No generated screenshots, browser reports, local logs, or private fixtures
  are staged.

## Local Checks

Run the same four steps CI runs (`check-whitespace.ps1` after committing):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\scan-private-markers.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-whitespace.ps1
```

On non-Windows shells, use PowerShell 7+ as `pwsh`; run each script with
`pwsh -NoProfile -File ./scripts/<script-name>.ps1`.

## Review

- [ ] Diff is focused on bounded UI verification.
- [ ] No verification category is claimed without evidence.
- [ ] New commands are bounded and non-interactive.
- [ ] Cost impact is documented.
