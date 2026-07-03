# Hover And Focus State Verification Report Example

Use this synthetic example when a browser verification run checks hover and
keyboard focus states separately. The point is to avoid treating pointer hover
success as keyboard accessibility evidence, or treating one focused control as
proof that every interactive state was verified.

## Scenario

- App type: synthetic billing settings panel
- Route checked: `/settings/billing`
- Local URL: `http://127.0.0.1:5173/settings/billing`
- Browser tool: Chrome DevTools MCP
- Test data: synthetic plan names, invoice rows, and account labels only
- Server handling: background process with PID/log files and bounded health check

## Evidence Collected

| Category | Evidence | Result | Correct Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | 30-attempt bounded poll reached HTTP 200 on attempt 2 | Completed | `Bounded health check passed on attempt 2 of 30.` |
| Smartphone viewport | 390 px screenshot inspected; billing action row wrapped without horizontal scroll | Completed | `390 px viewport checked; billing actions wrapped without unexpected horizontal scroll.` |
| Tablet viewport | 768 px screenshot inspected; account summary and invoice table stayed readable | Completed | `768 px viewport checked; account summary and invoice table stayed readable.` |
| Desktop viewport | 1280 px screenshot inspected; sidebar, table, and action controls stayed aligned | Completed | `1280 px viewport checked; layout stayed aligned.` |
| Hover state | Pointer hover inspected on the primary billing action and invoice download action | Completed | `Hover states checked for primary billing and invoice download actions.` |
| Keyboard focus | Tab order reached the primary billing action, but skipped the invoice download action | Failed | `Keyboard focus failed because the invoice download action was not reachable by Tab.` |
| Focus visibility | Primary billing action showed a visible focus ring | Completed | `Visible focus state checked for the primary billing action.` |
| Active/pressed state | Mouse down state on the primary billing action changed color and returned on release | Completed | `Active state checked for the primary billing action.` |
| Disabled state | Disabled downgrade action retained readable label and did not expose a click handler | Completed | `Disabled action checked; label remained readable and click handler was absent.` |
| Console | Browser console inspected after page load and interaction | Completed | `Console checked; no relevant errors or warnings observed.` |
| Network | Failed request list inspected after page load and interaction | Completed | `Network checked; no relevant failed requests observed.` |
| Error state | Synthetic payment-provider error state was not opened in this run | 未確認 | `Payment-provider error state remains 未確認 because it was not exercised.` |
| Cleanup | Server process stopped after verification | Completed | `Cleanup completed; the background server process was stopped.` |

## What Not To Say

Avoid wording that collapses hover and keyboard evidence into one claim:

```markdown
Interactive states passed because the billing buttons have hover styles.
```

That statement is wrong because keyboard focus did not reach the invoice
download action, even though pointer hover styles were visible.

## Final Report Snippet

```markdown
Browser verification:
- Tool: Chrome DevTools MCP
- Route: /settings/billing
- Viewports:
  - 390 px: checked; billing actions wrapped without unexpected horizontal scroll
  - 768 px: checked; account summary and invoice table stayed readable
  - 1280 px: checked; sidebar, table, and action controls stayed aligned
- Hover: checked for primary billing and invoice download actions
- Focus:
  - Primary billing action: checked; visible focus ring observed
  - Invoice download action: failed; not reachable by Tab
- Active state: checked for primary billing action
- Disabled state: checked for downgrade action
- Console: checked; no relevant errors or warnings observed
- Network: checked; no relevant failed requests observed
- Cleanup: background server stopped after verification

Findings:
- The invoice download action is pointer-reachable but not keyboard-reachable.

Unverified / 未確認:
- Synthetic payment-provider error state was not exercised in this run.
- Real billing provider data and authenticated production accounts were not inspected.

Residual risks:
- This run used synthetic fixtures only.
- Additional role and name checks are still needed before claiming full accessibility coverage.
```

## Integrity Rules

- Report hover, focus, active, disabled, and keyboard order evidence separately.
- Do not infer keyboard accessibility from pointer hover behavior.
- Do not claim all interactive states passed when one control was not reached or
  one state was not exercised.
- Mark provider-backed, authenticated, destructive, or real-data states as
  `未確認` unless a safe synthetic path actually covered them.
