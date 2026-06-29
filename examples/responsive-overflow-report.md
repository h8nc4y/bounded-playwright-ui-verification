# Responsive Overflow Verification Report Example

Use this synthetic example when responsive browser verification finds horizontal
scroll, clipping, or focus visibility problems at one viewport while other
viewport and console/network checks have different results. The point is to keep
layout evidence separate from browser-load evidence.

## Scenario

- App type: synthetic project planning board
- Route checked: `/projects/overview`
- Local URL: `http://127.0.0.1:5173/projects/overview`
- Browser tool: Playwright
- Test data: synthetic projects, members, and labels only
- Server handling: background process with PID/log files and bounded health check

## Evidence Collected

| Category | Evidence | Result | Correct Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | 30-attempt bounded poll reached HTTP 200 on attempt 3 | Completed | `Bounded health check passed on attempt 3 of 30.` |
| Smartphone viewport | 390 px screenshot inspected; document scroll width was 458 px and the secondary toolbar clipped | Failed | `390 px viewport failed: unexpected horizontal scroll and toolbar clipping were observed.` |
| Tablet viewport | 768 px screenshot inspected; filters wrapped to two lines without clipping | Completed | `768 px viewport checked; filters wrapped without unexpected horizontal scroll.` |
| Desktop viewport | 1280 px screenshot inspected; board columns and actions stayed visible | Completed | `1280 px viewport checked; board controls stayed visible.` |
| Screenshot inspection | Phone, tablet, and desktop screenshots were opened and visually inspected | Completed | `Screenshots were captured and inspected for all three viewport sizes.` |
| Focus state | Keyboard focus reached the clipped toolbar action at 390 px, but the focus ring was partly outside the visible area | Failed | `Focus state failed at 390 px because the focused toolbar action was clipped.` |
| Hover state | Desktop hover state on the primary action was inspected | Completed | `Desktop hover state checked for the primary action.` |
| Console | Browser console inspected after page load and toolbar interaction | Completed | `Console checked; no relevant errors or warnings observed.` |
| Network | Failed request list inspected after page load | Completed | `Network checked; no relevant failed requests observed.` |
| Loading state | The route loaded too quickly to inspect the loading skeleton | 未確認 | `Loading state remains 未確認 because it was not observable in this run.` |
| Cleanup | Server process stopped after verification | Completed | `Cleanup completed; the background server process was stopped.` |

## What Not To Say

Avoid wording that treats a successful page load as responsive success:

```markdown
The projects page passed browser verification because it loaded and had no console errors.
```

That statement is wrong because the 390 px viewport and keyboard focus path both
failed even though console and network checks had no relevant errors.

## Final Report Snippet

```markdown
Browser verification:
- Tool: Playwright
- Route: /projects/overview
- Viewports:
  - 390 px: failed; unexpected horizontal scroll observed (458 px document width) and secondary toolbar clipped
  - 768 px: checked; filters wrapped without clipping or unexpected horizontal scroll
  - 1280 px: checked; board controls stayed visible
- Screenshots: captured and inspected for 390 px, 768 px, and 1280 px
- Focus: failed at 390 px; focused toolbar action was partly outside the visible area
- Hover: checked on desktop primary action
- Console: checked; no relevant errors or warnings observed
- Network: checked; no relevant failed requests observed
- Cleanup: background server stopped after verification

Findings:
- The project overview toolbar overflows horizontally at 390 px.
- Keyboard users can focus a clipped toolbar action at 390 px.

Unverified / 未確認:
- Loading skeleton was not observed because the synthetic route loaded too quickly.

Residual risks:
- Production data and authenticated project permissions were not inspected.
- This run used synthetic fixtures only.
```

## Integrity Rules

- Compare viewport-fit evidence directly, such as screenshot inspection and
  measured scroll width; do not infer it from page load or console status.
- Keep focus visibility findings separate from hover findings because keyboard
  and pointer evidence do not imply each other.
- Do not claim the responsive pass is green when any required viewport has
  unexpected horizontal scroll, clipping, or overlap.
- Mark loading, empty, error, or authenticated states as `未確認` unless the
  browser run actually covered them with safe synthetic data.