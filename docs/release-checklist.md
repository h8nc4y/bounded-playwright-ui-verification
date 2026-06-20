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

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

On non-Windows shells, use PowerShell 7+ as `pwsh`; run each script with
`pwsh -NoProfile -File ./scripts/<script-name>.ps1`.

## Review

- [ ] Diff is focused on bounded UI verification.
- [ ] No verification category is claimed without evidence.
- [ ] New commands are bounded and non-interactive.
- [ ] Cost impact is documented.
