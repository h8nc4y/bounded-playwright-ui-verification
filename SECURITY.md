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

## Handling Sensitive Findings

If a real secret or credential may have been exposed, rotate it outside this
repository before treating the repository change as complete. Do not hide a real
exposure only with an allowlist, baseline, or ignore entry.

## Non-Security Questions

For usage questions, documentation gaps, and feature requests, use the normal
GitHub issue templates instead of the vulnerability reporting path.
