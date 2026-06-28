# Protected Route Verification Report Example

Use this synthetic example when a browser verification pass reaches a login,
OAuth, or permission boundary. The goal is to report the public and mockable
checks that were actually performed without pretending that the protected state
was inspected.

## Scenario

- App type: synthetic admin portal
- Public route checked: `/login`
- Protected route attempted: `/admin/users`
- Local URL: `http://127.0.0.1:5173`
- Browser tool: Playwright
- Test data: synthetic users and roles only
- Auth state: no test account, OAuth session, cookie, or token was available
- Server handling: background process with PID/log files and bounded health check

## Evidence Collected

| Category | Evidence | Result | Correct Report Wording |
| --- | --- | --- | --- |
| Server startup | Background process started, PID saved, stdout/stderr paths recorded | Completed | `Server started in the background; PID and log paths recorded.` |
| Health check | Bounded poll reached HTTP 200 before browser checks started | Completed | `Bounded health check passed before browser verification.` |
| Public login route | `/login` rendered at 390 px, 768 px, and 1280 px | Completed | `Public login route checked at 390/768/1280 px.` |
| Login form labels | Email and password fields had visible labels in the synthetic login view | Completed | `Login form labels were visible and tied to controls.` |
| Protected route navigation | `/admin/users` redirected to `/login` because no authenticated state was available | Blocked | `Protected admin route redirected to login; authenticated admin content remains 未確認.` |
| Console | Console inspected after `/login` load and protected-route redirect | Completed | `Console checked for the public login and redirect flow.` |
| Network | Failed request list inspected; no synthetic fixture failures observed | Completed | `Network checked for the public login and redirect flow.` |
| Authenticated admin table | No credential, cookie, token, or test account was available | 未確認 | `Authenticated admin table was not inspected because login/OAuth is required.` |
| Role-specific actions | Admin-only action buttons require an authenticated role fixture | 未確認 | `Role-specific actions remain 未確認; no synthetic authenticated fixture was available.` |
| Cleanup | Server process stopped after verification | Completed | `Cleanup completed; the background server process was stopped.` |

## What Not To Say

Avoid wording that turns the blocked state into a pass:

```markdown
Admin users page passed browser verification on all viewports.
```

That statement is wrong because only the public login and redirect behavior were
checked. The authenticated admin content was not available.

## Final Report Snippet

```markdown
Browser verification:
- Tool: Playwright
- Public route: /login
- Attempted protected route: /admin/users
- Viewports:
  - 390 px: login view checked; no unexpected horizontal scroll observed
  - 768 px: login view checked; labels stayed visible
  - 1280 px: login view checked; layout remained readable
- Console: checked for login and redirect flow; no relevant errors observed
- Network: checked for login and redirect flow; no relevant failed requests observed
- Cleanup: background server stopped after verification

Blocked / 未確認:
- Authenticated /admin/users content was not inspected because no safe test login, cookie, token, or OAuth session was available.
- Admin-only action buttons and role-specific states remain 未確認.
```

## Integrity Rules

- Do not ask the user to paste a real token, cookie, or OAuth result into the
  report.
- Do not mark the protected UI as verified when only the redirect or login page
  was checked.
- Use a synthetic authenticated fixture or a safe local test account when the
  project provides one; otherwise keep protected states as `未確認`.
- Keep public-route evidence separate from protected-route evidence.