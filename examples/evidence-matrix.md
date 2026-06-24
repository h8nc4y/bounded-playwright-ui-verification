# Evidence Matrix Example

Use this synthetic matrix when a UI pass has mixed evidence: some checks were
completed, some were blocked, and some were not relevant. Replace the route names,
commands, and findings with project-specific values.

## Scenario

- App type: synthetic admin dashboard
- Route checked: `/dashboard`
- Local URL: `http://127.0.0.1:5173/dashboard`
- Browser tool: Playwright
- Test data: synthetic accounts and orders only

## Evidence Matrix

| Category | Evidence Collected | Result | Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | 30-attempt bounded poll reached HTTP 200 on attempt 4 | Completed | `Bounded health check passed on attempt 4 of 30.` |
| Smartphone viewport | 390 px screenshot inspected for layout and horizontal scroll | Completed | `390 px viewport checked; no unexpected horizontal scroll observed.` |
| Tablet viewport | 768 px screenshot inspected for form spacing | Completed | `768 px viewport checked; form labels stayed aligned.` |
| Desktop viewport | 1280 px screenshot inspected for table density | Completed | `1280 px viewport checked; table controls remained visible.` |
| Console | Browser console inspected after page load and primary action | Completed | `Console checked; no relevant errors observed.` |
| Network | Failed request list inspected after page load | Completed | `Network checked; no relevant failed requests observed.` |
| Hover state | Pointer hover checked on the primary action | Completed | `Hover state checked for the primary action.` |
| Focus state | Keyboard tab order checked through visible controls | Completed | `Focus state checked for visible controls.` |
| Loading state | The route loaded too quickly to observe loading UI | 未確認 | `Loading state was relevant but not observed; marked 未確認.` |
| Empty state | Synthetic fixture did not include an empty dataset | 未確認 | `Empty state not covered by the selected synthetic fixture; marked 未確認.` |
| Error state | No local error fixture was available | 未確認 | `Error state not covered because no synthetic error fixture was available; marked 未確認.` |

## Final Report Snippet

```markdown
Browser verification:
- Tool: Playwright
- Route: /dashboard
- Viewports:
  - 390 px: checked; no unexpected horizontal scroll observed
  - 768 px: checked; form labels stayed aligned
  - 1280 px: checked; table controls remained visible
- Console: checked; no relevant errors observed
- Network: checked; no relevant failed requests observed

Unverified / 未確認:
- Loading state: relevant but not observed during this run
- Empty state: no synthetic empty dataset fixture was used
- Error state: no synthetic error fixture was available
```

## Integrity Rules

- Do not convert a blocked or unavailable check into a pass.
- Do not cite screenshots, console output, or network inspection unless the
  browser tool actually captured that evidence.
- Keep local URLs, logs, and data synthetic before copying this pattern into a
  public issue, pull request, or report.
