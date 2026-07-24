# Security Policy

## Supported Scope

This repository contains a Codex-style skill, documentation, examples, and local
PowerShell validation scripts. It does not run a hosted service, collect
telemetry, or process production user data.

Security-relevant reports include:

- Secret, token, auth cookie, or private path leakage in repository content.
- Guidance that encourages sending private data to external services.
- Validation bypasses that allow obvious private markers to pass.
- Instructions that encourage fabricated browser verification evidence.
- Unbounded server or browser workflows that could leave local processes running.

## Reporting

Use GitHub's private vulnerability reporting flow if it is enabled for the
repository. If that is unavailable, open a GitHub issue with a minimal
description and omit secrets, tokens, auth cookies, private logs, customer data,
and exploit payloads that would expose real systems.

When reporting a possible leak, include:

- File path and line number.
- Finding type.
- Why the content appears sensitive.
- Suggested remediation, if known.

Do not paste the sensitive value itself into a public issue.

## Scan Coverage

`scripts/scan-private-markers.ps1` is a best-effort guard. It blocks common
secret prefixes (including AWS, Google, Slack, Stripe, and PEM private-key
forms), private path markers, unexpected GitHub repository links, and
email-like values, but it does not guarantee detection of every secret format
or every high-entropy value. Do not treat a passing scan as proof that no
secret is present; keep secrets, tokens, and private data out of the repository
in the first place.

In Git repositories, the scanner reads bounded index blobs and stable
working-tree bytes, including eligible untracked text. It isolates Git
configuration and protocols, rejects index mutation and ambiguous metadata,
does not follow symlinks or reparse points, applies one scan-wide deadline, and
emits only redacted bounded diagnostics. A `.git` entry is detected by
non-recursive parent enumeration so a dangling junction or symlink cannot
silently downgrade the run to a non-Git fallback. Bootstrap, process-boundary,
and Git-isolation exceptions are converted to fixed exit-code-2 diagnostics
without exposing repository, temporary, or helper paths. Nested cleanup failure
during stack unwinding cannot append or replace the first one-line diagnostic.

The Windows process boundary assigns a suspended child to a kill-on-close Job
before execution and preserves raw standard-stream bytes. Job handle ownership
is released only after a successful close; a close anomaly triggers direct child
termination, bounded waiting, and a retry with the retained handle. Sub-second
timeouts retain their millisecond precision. POSIX uses a
dedicated process group/session. Regression tests cover Windows PowerShell 5.1
BOM-less stdin, native Git batch bytes, a normal linked-worktree Gitfile, and
first-call AST module-qualified bootstrap/provenance, assignment/Variable
provider/PSVariable mutation, indirect provider and custom mutation alias,
copy/move/rename, dynamic `New-Item`, class inheritance, alias-order, and
transitive wrapper bypasses.

`assert-oss-ready.ps1` fixes the current active CI job shape, but the checked-in
workflow still uses the mutable `actions/checkout@v4` major tag. That is not an
immutable dependency guarantee; changing `.github/workflows/**` requires the
owner gate documented in `AGENTS.md`.

## Handling Sensitive Findings

If a real secret or credential may have been exposed, rotate it outside this
repository before treating the repository change as complete. Do not hide a real
exposure only with an allowlist, baseline, or ignore entry.

## Non-Security Questions

For usage questions, documentation gaps, and feature requests, use the normal
GitHub issue templates instead of the vulnerability reporting path.
