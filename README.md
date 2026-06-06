# bounded-playwright-ui-verification

`bounded-playwright-ui-verification` is a Codex-style skill for AI coding agents that
need to verify Web UI with real browser evidence without hanging on foreground dev
servers, inventing screenshot checks, or leaving local servers running.

The skill is about bounded verification operations, not Playwright branding or assets.
It does not vendor Playwright, browser binaries, screenshots, icons, or third-party
media.

## Who It Is For

- AI coding agents working on React, Next.js, Vite, dashboard, form, or admin UI.
- Agents that can use Playwright, Chrome DevTools, an in-app browser, or another
  browser automation tool.
- Teams that want final reports to distinguish completed browser checks from
  `未確認` items.

## What It Solves

- Foreground `npm run dev`, Vite, Next.js, or similar servers blocking the agent turn.
- Unbounded waits, infinite polling, and forgotten cleanup.
- UI signoff based only on compile, lint, typecheck, or build output.
- Reports that claim screenshots, console checks, network checks, or responsive checks
  that were not actually performed.
- Missing evidence for 390 px, 768 px, and 1280 px-plus viewport checks.

## Install

Clone the repository:

```powershell
git clone https://github.com/h8nc4y/bounded-playwright-ui-verification.git
```

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
runtime's documented skill folder. Do not overwrite an existing skill folder without
reviewing local changes first.

## Manual Use

Invoke the skill before finishing Web UI work when browser verification is relevant.
Use it to plan and report:

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

All examples are synthetic. They do not include private logs, screenshots, tokens, or
customer data.

## Validation And Scan

Run the private marker scan before publishing or copying the skill:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

Run your environment's skill validator if one is available. For example:

```powershell
python path\to\quick_validate.py
```

Also run a whitespace check before committing:

```powershell
git diff --check
```

## Limitations

- This skill does not replace accessibility audits, security reviews, usability
  research, or manual product acceptance testing.
- It cannot verify authenticated or protected states without a safe authenticated
  environment.
- It does not install Playwright or browsers by itself.
- Console and network checks depend on the capabilities of the browser automation
  tool available in the agent environment.

## Non-Goals

- No Playwright icon assets, screenshots, or third-party media.
- No package publishing.
- No GitHub Marketplace listing.
- No GitHub Release workflow.
- No paid API, model, or SaaS dependency.

## Safety Notes

- Use synthetic data in examples and tests.
- Do not send secrets, OAuth credentials, auth cookies, customer data, or private logs
  to external services.
- Do not claim a verification category passed unless it was actually checked.
- Mark unavailable or blocked checks as `未確認`.
- Keep server startup, health checks, browser waits, and cleanup bounded.

## License

MIT. See [LICENSE](LICENSE).
