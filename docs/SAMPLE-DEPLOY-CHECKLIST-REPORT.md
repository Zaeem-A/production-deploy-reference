# Deploy Checklist Report (SAMPLE)

**Run against:** my own public reference setup, github.com/Zaeem-A/production-deploy-reference. No client data. This is what you receive with every tier, filled in for your app.

**Scope:** one app, one server, one domain. Review of what I could see in the repo and on the server. Not a penetration test and not a security guarantee.

Status key: **Pass** = checked, nothing to fix. **Fixed** = found a gap and changed it. **Not covered** = outside scope or not present in this app, with a note.

| # | Area | What I checked | Status | Note |
|---|---|---|---|---|
| 1 | Secrets | Passwords kept out of the repo and out of environment variables | Pass | DB and Grafana passwords mounted as read-only files; `.env`, `secrets/`, `data/` are git-ignored. Still plaintext on disk, so not a secrets manager. |
| 2 | HTTPS | HTTP redirects to HTTPS; TLS 1.2/1.3 only; HSTS set | Pass | Let's Encrypt issuance is not exercised in CI (needs a real domain); steps are in the runbook. |
| 3 | Security headers | nosniff, frame deny, no referrer, server version hidden | Pass | |
| 4 | Rate limiting | Per-IP limit at the proxy | Pass | 10 req/s with a burst of 20, returns 429. A starting value; tune to real traffic. |
| 5 | Upload / request size | Body size cap | Pass | 1 MB cap at Nginx; note text capped at 2,000 characters. This app has no file upload endpoint. |
| 6 | Ops endpoints | `/metrics`, Prometheus, Grafana not public | Pass | `/metrics` returns 404 publicly; Prometheus and Grafana listen on localhost only (SSH tunnel). |
| 7 | Database exposure | DB reachable only from the app | Pass | Internal-only Docker network. |
| 8 | Container hardening | Non-root user, read-only filesystem, dropped capabilities, resource limits | Pass | |
| 9 | Deploy and rollback | One scripted deploy; image rolled back if the new version does not answer | Pass | Tested in CI. Schema changes still need a person; the script says so. |
| 10 | Backups | Dump, integrity check, restore into a scratch DB | Pass | Daily dump with retention; monthly restore drill; stale-backup alert. Off-site copy is optional and off by default. |
| 11 | Monitoring and alerts | Target down, 5xx rate, latency, disk, memory, CPU, backup age, cert expiry | Pass | Alerts show in Prometheus only. No Alertmanager receiver (email/Slack) configured. |
| 12 | Logging | Structured logs with request IDs, rotation | Pass | JSON logs, 10 MB x 3 files per container. |
| 13 | CI/CD | Lint, tests against real Postgres, full-stack smoke test, ShellCheck | Pass | Dependabot opens dependency update PRs. |
| 14 | CORS | Allowed origins | Not covered | No browser front end in this demo. I would set an explicit allow-list for a separate front end. |
| 15 | Authentication | Who can call the API | Not covered | The demo API has no login. For your app I would review your auth flow (JWT secrets, expiry, admin routes). |
| 16 | Dependency vulnerabilities | Known CVEs in dependencies | Not covered | Only Dependabot updates; no vulnerability scan step. I can add one. |

## Fix list (priority order)
1. Add an alert receiver (email or Slack) so alerts leave Prometheus. ~1 h.
2. Add a dependency vulnerability scan to CI. ~1 h.
3. Enable the off-site backup copy. ~1 h plus a bucket.

*Estimates are for this demo; yours will be quoted in the audit.*
