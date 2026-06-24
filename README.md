# bounded-playwright-ui-verification

[![CI](https://github.com/h8nc4y/bounded-playwright-ui-verification/actions/workflows/ci.yml/badge.svg)](https://github.com/h8nc4y/bounded-playwright-ui-verification/actions/workflows/ci.yml)

`bounded-playwright-ui-verification` is a Codex-style skill for AI coding agents
that need real browser evidence for Web UI changes while keeping local server
workflows bounded and cleanup explicit.

The skill is about operational discipline. It does not vendor Playwright,
browser binaries, screenshots, icons, or third-party media.

## Who It Is For

- AI coding agents working on React, Next.js, Vite, dashboard, form, or admin UI.
- Agents that can use Playwright, Chrome DevTools, an in-app browser, or another
  browser automation tool.
- Teams that want final reports to distinguish completed browser checks from
  `未確認` items.

## What It Solves

- Foreground `npm run dev`, Vite, Next.js, or similar servers blocking an agent
  turn.
- Unbounded waits, infinite polling, and forgotten cleanup.
- UI signoff based only on compile, lint, typecheck, or build output.
- Reports that claim screenshots, console checks, network checks, or responsive
  checks that were not actually performed.
- Missing evidence for 390 px, 768 px, and 1280 px-plus viewport checks.

## Install

Clone the repository:

```powershell
git clone https://github.com/h8nc4y/bounded-playwright-ui-verification.git
cd bounded-playwright-ui-verification
```

Run the repository checks before copying the skill:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

On macOS, Linux, or a bash/zsh shell, install PowerShell 7+ and call the scripts
with `pwsh -NoProfile -File ./scripts/<script-name>.ps1`; keep the Git command
unchanged.

Manual install into a Codex-style skill directory:

```powershell
$skillRoot = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path $HOME ".codex\skills"
}

$target = Join-Path $skillRoot "bounded-playwright-ui-verification"
if (Test-Path -LiteralPath $target) {
  throw "Skill already exists: $target"
}

New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -LiteralPath ".\SKILL.md" -Destination (Join-Path $target "SKILL.md")
```

If your agent runtime uses a different skill location, copy `SKILL.md` into the
runtime's documented skill folder. Review local changes before overwriting an
existing skill folder.

## Manual Use

Invoke the skill before finishing Web UI work when browser verification is
relevant. Use it to plan and report:

- Background dev server startup with PID and log capture.
- Bounded health checks.
- Browser verification at around 390 px, 768 px, and 1280 px or wider.
- Screenshot inspection.
- Console and network checks.
- Cleanup and `未確認` items.

## Examples

- [UI verification checklist](examples/ui-verification-checklist.md)
- [Final report template](examples/final-report-template.md)
- [Bounded server runbook](examples/server-runbook.md)
- [Evidence matrix example](examples/evidence-matrix.md)

All examples are synthetic. They do not include private logs, screenshots,
tokens, auth cookies, or customer data.

## Validation And Scan

Run all local checks before publishing, copying, or opening a pull request:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
```

Use the same `pwsh -NoProfile -File ./scripts/<script-name>.ps1` form from
non-Windows shells.

`scan-private-markers.ps1` blocks common secret prefixes (OpenAI, GitHub, Slack,
AWS, Google, Stripe, and PEM private-key forms), private path markers,
unexpected GitHub repository links, email-like values, and absolute Windows path
leaks. It is a best-effort guard and does not guarantee detection of every
secret format, so keep secrets out of the repository regardless of a passing
scan. `assert-oss-ready.ps1` checks the skill front matter, required public
project files, required README sections, broken local Markdown links, mojibake,
and placeholder markers.

Use your agent runtime's skill validator as an additional check when one is
available.

## Contributing

Contributions are welcome when they keep the skill focused on bounded,
truthful UI verification. See [CONTRIBUTING.md](CONTRIBUTING.md) for the local
development loop, pull request expectations, and review criteria.

## Security

This project is designed to prevent accidental over-claiming and private-data
leakage in verification reports, but it is not a general-purpose security tool.
See [SECURITY.md](SECURITY.md) for reporting guidance and supported scope.

## Limitations

- This skill does not replace accessibility audits, security reviews, usability
  research, or manual product acceptance testing.
- It cannot verify authenticated or protected states without a safe authenticated
  environment.
- It does not install Playwright, browser binaries, or browsers by itself.
- Console and network checks depend on the capabilities of the browser
  automation tool available in the agent environment.

## Non-Goals

- No Playwright icon assets, screenshots, or third-party media.
- No package publishing workflow.
- No GitHub Marketplace listing.
- No GitHub Release workflow.
- No paid API, model, or SaaS dependency.

## Safety Notes

- Use synthetic data in examples and tests.
- Do not send secrets, OAuth credentials, auth cookies, customer data, or
  private logs to external services.
- Do not claim a verification category passed unless it was actually checked.
- Mark unavailable or blocked checks as `未確認`.
- Keep server startup, health checks, browser waits, and cleanup bounded.

## License

MIT. See [LICENSE](LICENSE).
