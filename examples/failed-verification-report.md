# Failed Verification Report Example

Use this synthetic example when browser verification finds a real UI problem or
when part of the verification pass is blocked. The point is to report the failed
or blocked category directly instead of turning a partial run into a pass.

## Scenario

- App type: synthetic billing settings screen
- Route checked: `/settings/billing`
- Local URL: `http://127.0.0.1:5173/settings/billing`
- Browser tool: Playwright
- Test data: synthetic plans, invoices, and accounts only
- Server handling: background process with PID/log files and bounded health check

## Evidence Collected

| Category | Evidence | Result | Correct Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | 30-attempt bounded poll reached HTTP 200 on attempt 5 | Completed | `Bounded health check passed on attempt 5 of 30.` |
| Smartphone viewport | 390 px screenshot inspected; page scroll width was 426 px | Failed | `390 px viewport failed: unexpected horizontal scroll was observed.` |
| Tablet viewport | 768 px screenshot inspected; controls stayed aligned | Completed | `768 px viewport checked; no unexpected horizontal scroll observed.` |
| Desktop viewport | 1280 px screenshot inspected; summary table remained readable | Completed | `1280 px viewport checked; summary table remained readable.` |
| Console | Browser console contained one relevant fixture-loading error | Failed | `Console checked; one relevant synthetic fixture-loading error was found.` |
| Network | `GET /fixtures/synthetic-plan-prices.json` returned 404 | Failed | `Network checked; one relevant failed synthetic fixture request was found.` |
| Hover state | Primary action hover state inspected | Completed | `Hover state checked for the primary action.` |
| Focus state | Keyboard focus path could not continue after the failed fixture left the dialog closed | 未確認 | `Focus state after the dialog opens is 未確認 because the fixture failure blocked it.` |
| Cleanup | Server process stopped after verification | Completed | `Cleanup completed; the background server process was stopped.` |

## What Not To Say

Avoid summaries that hide the failing evidence:

```markdown
Browser checks passed on phone, tablet, and desktop. Console and network looked fine.
```

That statement is wrong because phone layout, console, network, and post-dialog
focus coverage all had negative or missing evidence.

## Final Report Snippet

```markdown
Browser verification:
- Tool: Playwright
- Route: /settings/billing
- Viewports:
  - 390 px: failed; unexpected horizontal scroll observed (426 px content width)
  - 768 px: checked; no unexpected horizontal scroll observed
  - 1280 px: checked; summary table remained readable
- Console: checked; one relevant synthetic fixture-loading error found
- Network: checked; GET /fixtures/synthetic-plan-prices.json returned 404
- Cleanup: background server stopped after verification

Findings:
- Billing settings overflow horizontally at 390 px.
- The synthetic plan-price fixture path returns 404, which blocks dialog coverage.

Unverified / 未確認:
- Focus order inside the plan dialog, because the dialog did not open after the fixture failure.

Residual risks:
- Authenticated production billing data was not used or inspected.
- This run used synthetic fixtures only.
```

## Integrity Rules

- A failing browser check is still useful evidence; report it as a finding, not
  as a pass.
- Keep failed console and network categories separate from viewport results.
- Mark follow-up areas as `未確認` when the failure prevents later checks.
- Keep examples synthetic before copying this pattern into a public issue, pull
  request, or report.
