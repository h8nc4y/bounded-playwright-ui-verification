# Contributing

Thanks for helping improve `bounded-playwright-ui-verification`.

## Scope

Good changes keep the skill focused on bounded, truthful Web UI verification for
AI coding agents. The project should stay small, portable, and free of paid
service requirements.

Strong contributions usually improve one of these areas:

- Clearer browser verification rules.
- Safer bounded server workflows.
- Better report integrity guidance.
- More portable local validation.
- Synthetic examples that do not include private data.

Out-of-scope changes include package publishing pipelines, bundled browser
binaries, Playwright branding assets, third-party screenshots, and paid service
dependencies.

## Local Development

Run these checks before opening a pull request:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

If your shell cannot execute PowerShell scripts directly, use PowerShell 7+ as
`pwsh -NoProfile -File ./scripts/<script-name>.ps1`. Windows contributors can
also use Windows PowerShell 5.1 with the command form above.

## Documentation Style

- Keep examples synthetic.
- Avoid secrets, auth cookies, private logs, customer data, and local absolute
  paths.
- Use `未確認` for planned or relevant checks that were not actually completed.
- Do not imply that a build, lint, typecheck, or compile pass is browser
  verification.
- Keep commands bounded and non-interactive.

## Pull Request Expectations

Every pull request should explain:

- What changed.
- Why the change improves bounded UI verification.
- Which local checks passed.
- Any remaining `未確認` areas.
- Whether the change has any cost impact.

Small, focused pull requests are easier to review and maintain.
