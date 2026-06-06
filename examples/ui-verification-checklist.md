# UI Verification Checklist

Use this checklist for a synthetic or local Web UI target. Replace route names
and commands with project-specific values.

## Server

- [ ] Start the dev server in the background.
- [ ] Save the server PID.
- [ ] Save stdout and stderr logs.
- [ ] Run a bounded health check with a maximum attempt count.
- [ ] Stop the server after verification, unless intentionally kept alive.

## Browser Coverage

- [ ] Browser/tool used:
- [ ] Route or URL checked:
- [ ] Smartphone viewport checked around 390 px wide.
- [ ] Tablet viewport checked around 768 px wide.
- [ ] Desktop viewport checked at 1280 px wide or wider.
- [ ] Screenshots captured and inspected.
- [ ] No unexpected horizontal scroll.
- [ ] Text is readable and not overlapping.
- [ ] Primary action is visible and understandable.
- [ ] Buttons and controls have practical tap targets.
- [ ] Labels are tied to form controls.
- [ ] Validation messages are understandable.
- [ ] Loading state checked or marked `未確認`.
- [ ] Empty state checked or marked `未確認`.
- [ ] Error state checked or marked `未確認`.
- [ ] Focus state checked or marked `未確認`.
- [ ] Hover and active states checked or marked `未確認`.
- [ ] Console checked for relevant errors or warnings.
- [ ] Network checked for relevant failed requests.

## Report Integrity

- [ ] Commands run are listed.
- [ ] Server PID and log path are listed.
- [ ] Viewport sizes are listed.
- [ ] Findings and fixes are listed.
- [ ] Unverified items are explicitly marked `未確認`.
- [ ] Cleanup result is listed.
- [ ] No check is reported as completed unless it was actually performed.
