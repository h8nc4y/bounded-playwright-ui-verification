# Loading, Empty, And Error State Verification Report Example

Use this synthetic example when one browser verification run exercises loading,
empty, and error states through local fixtures. The point is to record distinct
evidence for each state instead of treating a successful default response as
coverage of every response path.

All names, records, responses, and evidence paths below are illustrative. No
real account, production response, credential, auth cookie, or private log is
used.

## Scenario

- App type: synthetic order history
- Route checked: `/orders`
- Local URL: `http://127.0.0.1:4173/orders`
- Browser tool: Playwright with local synthetic response fixtures
- Test data: fictional order labels and generic response bodies only
- Server handling: background process with PID/log files and bounded health check
- State control: finite local fixture cases selected before each navigation

The local fixture cases are deliberately separate:

1. A delayed successful response exposes the loading skeleton before two
   fictional order rows render.
2. An immediate successful response with an empty array exposes the empty
   message and its primary action.
3. A generic synthetic 503 response exposes the error message and Retry
   control; Retry then receives the empty response.

## Evidence Collected

| Category | Evidence | Result | Correct Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | 30-attempt bounded poll reached HTTP 200 on attempt 3 | Completed | `Bounded health check passed on attempt 3 of 30.` |
| Smartphone viewport | 390 px screenshots for all three synthetic states were opened and inspected; messages and actions stayed within the viewport | Completed | `390 px viewport checked for loading, empty, and error fixtures; no unexpected horizontal scroll observed.` |
| Tablet viewport | 768 px screenshots for all three synthetic states were opened and inspected; state panels remained readable | Completed | `768 px viewport checked for loading, empty, and error fixtures; state panels remained readable.` |
| Desktop viewport | 1280 px screenshots for all three synthetic states were opened and inspected; content width and hierarchy remained coherent | Completed | `1280 px viewport checked for loading, empty, and error fixtures; layout hierarchy remained coherent.` |
| Loading state | Delayed synthetic response kept the labelled loading skeleton visible until the fictional rows replaced it | Completed | `Loading state checked with a delayed synthetic response; the labelled skeleton was visible before rows rendered.` |
| Empty state | Empty synthetic response rendered the no-orders message and visible create-order action | Completed | `Empty state checked with an empty synthetic response; message and primary action were visible.` |
| Error state | Generic synthetic 503 response rendered a plain-language error message and visible Retry control | Completed | `Error state checked with a synthetic 503 response; message and Retry control were visible.` |
| Screenshot inspection | Nine synthetic screenshots were opened and inspected: three states at each of the three viewport widths | Completed | `Nine screenshots were captured and inspected across loading, empty, and error states.` |
| Console | Browser console inspected after each fixture case and after Retry | Completed | `Console checked across all three synthetic states; no relevant errors or warnings observed.` |
| Network | Request events inspected; the one synthetic 503 matched the error fixture and no unexpected failed requests appeared | Completed | `Network checked; the expected synthetic 503 was isolated from unexpected failures.` |
| Retry interaction | Retry was activated from the synthetic error panel and the empty fixture replaced the error message | Completed | `Retry interaction checked; the error panel transitioned to the synthetic empty state.` |
| Cleanup | Server process stopped after verification | Completed | `Cleanup completed; the background server process was stopped.` |

## What Not To Say

Avoid wording that turns a successful default route into state coverage:

```markdown
All application states passed because the order history loaded successfully.
```

That statement is unsupported unless the loading, empty, and error paths were
each selected, observed, and reported separately.

## Final Report Snippet

```markdown
Browser verification:
- Tool: Playwright with local synthetic response fixtures
- Route: /orders
- Viewports:
  - 390 px: checked across loading, empty, and error fixtures; no unexpected horizontal scroll
  - 768 px: checked across loading, empty, and error fixtures; state panels remained readable
  - 1280 px: checked across loading, empty, and error fixtures; layout hierarchy remained coherent
- States:
  - Loading: checked; labelled skeleton appeared before fictional rows
  - Empty: checked; no-orders message and create-order action were visible
  - Error: checked; generic message and Retry control were visible
- Retry: checked; synthetic error state transitioned to the synthetic empty state
- Screenshots: nine captured and inspected
- Console: checked after each state and Retry; no relevant errors or warnings observed
- Network: checked; one expected synthetic 503 and no unexpected failed requests observed
- Cleanup: background server stopped after verification

Unverified / 未確認:
- Authenticated order history and production responses were not inspected.
- Screen-reader announcements and cross-browser behavior were not checked.

Residual risks:
- This report uses local synthetic fixtures only.
- A real integration can differ in timing, copy, and retry behavior.
```

## Integrity Rules

- Exercise each relevant state through a finite local or synthetic fixture.
- Keep the intentionally injected failure separate from unexpected network
  failures.
- Inspect screenshots before claiming visual state coverage.
- Do not generalize one viewport or one response path into coverage of another.
- Keep authenticated, production-backed, destructive, and real-data paths
  `未確認` unless a separate safe run actually covers them.
