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

Browser automation capability is widely available; reporting discipline is not.
This skill is a pre-claim evidence contract: it defines when an agent may claim
that browser verification happened, independent of which tool performed the
verification (Playwright scripts, MCP browser tools, or an in-app browser).
Capability layers such as Playwright MCP or Chrome DevTools MCP are
complementary: they provide observation, while this skill constrains what may
be claimed from those observations.

The contract has three parts:

- Bounded execution: every server start, health check, browser wait, and
  cleanup step has a finite timeout, a retry limit, and a cleanup path that
  runs on success, failure, and timeout.
- Truthful reporting: verification categories that were not performed are
  reported as `未確認`, never as passed.
- Evidence separation: verification categories do not imply each other. A green
  build is not UI verification, a DOM node is not a rendered chart, and a hover
  check is not a focus check.

Typical failure modes this contract targets:

- Foreground `npm run dev`, Vite, Next.js, or similar servers blocking an agent
  turn.
- Unbounded waits, infinite polling, and forgotten cleanup.
- UI signoff based only on compile, lint, typecheck, or build output.
- Reports that claim screenshots, console checks, network checks, or responsive
  checks that were not actually performed.
- Missing evidence for 390 px, 768 px, and 1280 px-plus viewport checks.

The skill is a reporting contract, not an enforcement engine. It does not
prevent a determined over-claim by itself; it makes over-claiming explicit and
easier to detect by requiring `未確認` as a first-class reporting term.

## Install

Clone the repository:

```powershell
git clone https://github.com/h8nc4y/bounded-playwright-ui-verification.git
cd bounded-playwright-ui-verification
```

Run the repository checks (see [Validation And Scan](#validation-and-scan))
before copying the skill.

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
- [Bounded server executable template](examples/server-runbook.ps1)
- [Evidence matrix example](examples/evidence-matrix.md)
- [Failed verification report example](examples/failed-verification-report.md)
- [Protected route blocked verification report](examples/protected-route-report.md)
- [Responsive overflow verification report](examples/responsive-overflow-report.md)
- [Blank render target verification report](examples/blank-render-target-report.md)
- [Hover and focus state verification report](examples/hover-focus-state-report.md)

All examples are synthetic. They do not include private logs, screenshots,
tokens, auth cookies, or customer data.

## Validation And Scan

Run all local checks before publishing, copying, or opening a pull request.
These are the same four steps CI runs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\scan-private-markers.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-whitespace.ps1
```

On macOS, Linux, or any shell with PowerShell 7+, use
`pwsh -NoProfile -File ./scripts/<script-name>.ps1` instead. Run
`check-whitespace.ps1` after committing: it compares against the git empty
tree, so it checks all committed content rather than only the working-tree
diff.

`scan-private-markers.ps1` blocks common secret prefixes (OpenAI, GitHub, Slack,
AWS, Google, Stripe, and PEM private-key forms), private path markers,
unexpected GitHub repository links, email-like values, and absolute Windows path
leaks. It is a best-effort guard and does not guarantee detection of every
secret format, so keep secrets out of the repository regardless of a passing
scan. In a Git repository it compares the index snapshot with stable working-tree
bytes and also scans eligible untracked text files; it does not use the
owner-gated tracked-only proposal. Git subprocesses run inside bounded,
network-disabled process boundaries. Normal linked-worktree Gitfiles are
accepted; symlink/reparse, index-drift, malformed or dangling Git metadata,
scan-wide deadline, and diagnostic byte-budget failures stop closed. Process
bootstrap and Git-isolation failures emit only fixed redacted diagnostics.
The Windows Job boundary retains handle ownership until close succeeds and
falls back to direct child termination plus a bounded close retry; sub-second
timeouts keep their millisecond precision. The same operation deadline starts
before environment preparation and covers launch, containment, target runtime,
and standard streams; cleanup uses one independent absolute slack. Sanitized
Git children are rebuilt from a fixed environment allowlist. On POSIX, both
external and native session launchers publish a ready PID, verify that it is
the process-group leader, and release the target only after that proof.
`assert-oss-ready.ps1` checks the skill front matter, required public
project files, required README sections, broken local Markdown links, mojibake,
placeholder markers, scanner boundary needles, and the exact active CI
trigger/permission/job/step shape. The existing `actions/checkout@v4` reference
is a mutable major tag, not an immutable supply-chain guarantee; changing
workflow files remains an owner-gated operation under `AGENTS.md`. The readiness
check also runs the server-runbook contract self-test against the complete
PowerShell workflow and a synthetic local HTTP server. The executable template is
strict UTF-8 without BOM and LF-only. A CommonMark-aware scanner permits one exact
PowerShell fence, and its body must match the template with ordinal comparison;
only four generated read-only `ContainsKey` variants are accepted. It rejects 93 hostile
fixtures that cut the server-entry def-use chain, overwrite the launch splat,
mutate the retained process identity through aliases/dynamic storage, move cleanup
outside `finally`, substitute a task runner, replay raw stderr through direct or
dynamic readers, reflect an absolute path through output/throw sinks, discard the
bounded stop/race handling, remove deterministic disposal, shadow a command,
mutate the poll counter or a critical output target, add a differently formed
CommonMark executable block, drift ordinal canonical bytes, or weaken ordered
failure propagation. Root `param`, `using`, script requirements, named blocks,
and every `trap` are rejected before statement analysis. Variable, command, and member identifiers use
`OrdinalIgnoreCase` after provider/scope normalization. Top-level, verification,
health, polling, cleanup, and all assignment/unary writes use closed executable
sequences. Except for the U+00AD byte-boundary-only fixture, every hostile mutation
must also be rejected when the semantic analyzer is exercised independently of
the byte gate.
The integration also verifies partial-start cleanup without a retained handle, the
PS5.1 natural-exit race, ordered aggregation when stop and both wrapper disposals
all fail, and fixed relative diagnostic metadata without exposing the local root.
`tests/scan-private-markers.Tests.ps1` is a
dependency-free regression suite covering the scanner's detection, redaction,
false-positive guards, binary standard streams, native Git batch bytes, process
tree cleanup, first-call AST bootstrap/mutation/shadow/transitive bypasses,
dangling Git metadata, fixed diagnostics, and Windows PowerShell 5.1 encoding;
run it whenever the scanner changes.

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
