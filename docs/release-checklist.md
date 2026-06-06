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
git diff --check
```

## Review

- [ ] Diff is focused on bounded UI verification.
- [ ] No verification category is claimed without evidence.
- [ ] New commands are bounded and non-interactive.
- [ ] Cost impact is documented.
