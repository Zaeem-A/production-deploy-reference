# Design decisions

Each entry says what was chosen, why, and what it costs. The service is small on purpose, so the
choices are about the deployment around it.

## One server with Compose, not Kubernetes

One service and one database do not need a scheduler. Compose gives declarative config, health checks,
restart policies and resource limits with very little to operate. The cost is no failover: if the
server is lost, recovery means a new server and a restored backup (`RUNBOOK.md`, section 5), which is
why the restore drill exists. I would move to something larger for several services, several teams, or
a need to survive a node failure without downtime.

## Nginx and certbot, not Caddy or Traefik

Nginx is what most existing setups already run, so this reads like something you would inherit, and the
configuration is explicit. The cost is that certificates are a script and a cron entry instead of
built in. The placeholder-certificate step exists because Nginx cannot start without a certificate file
and Let's Encrypt cannot validate a domain without a running Nginx. Nginx also resolves `api` through
Docker's DNS at request time instead of once at start-up: a deploy recreates the API container, which can
get a new address, and a start-up lookup would keep sending traffic to the old one.

## Secrets as files

The database and Grafana passwords are mounted read-only from `secrets/` (Compose file secrets), and
the app reads `DB_PASSWORD_FILE` before `DB_PASSWORD`. Environment variables leak through
`docker inspect`, crash reports and child processes; a mounted file does not. It is still plaintext on
disk (files 444 in a 700 directory), so it is not a replacement for a secrets manager.

## Forward-only migrations, run before the new version starts

The runner is a few dozen lines: it takes an advisory lock, applies each SQL file once inside a
transaction, and records it in `schema_migrations`. Two runners at once take turns. There are no
down-migrations, so rollback safety depends on writing migrations that work with the old and the new
code (add first, remove in a later release). The pre-deploy backup covers everything else.

## Automatic rollback covers the image only

The image is the one part that can be swapped back mechanically and safely. Schema and configuration
changes need a person, so the script says so instead of guessing. The script also does not treat
"containers are up" as success: it checks that `GET /` through Nginx reports the tag it just deployed.

## A backup is not real until it has been restored

Every dump is read back with `pg_restore --list`, checksummed and pruned by age. Once a month a drill
restores the newest dump into a scratch database and compares it with the live one; the result is a
metric with an alert. The comparison (a backup never holds more migrations or notes than live) fits
this append-only app; a real application needs its own invariants there.

## Metrics use route templates

The request counter and latency histogram are labelled with `/api/notes/{note_id}`, not
`/api/notes/42`, and unmatched requests share one label. That keeps the number of series bounded no
matter what clients send.

## Operations endpoints are private

Prometheus and Grafana bind to `127.0.0.1` and are reached through an SSH tunnel. Nginx answers 404 for
`/metrics`, and Prometheus scrapes the API directly over the private Docker network. The cost is
convenience; put an authenticating proxy in front if a team needs browser access.

## Pinned versions and immutable image tags

Python packages and container images are pinned, and Dependabot proposes updates. Deploys name an
exact build (`sha-<commit>`), never `latest`. Pins go stale without attention; each update pull
request runs the smoke test, so an update that breaks the stack fails before it is merged.

## Tests run the real stack, plus a fake for the failure paths

CI builds the image and brings up the actual Compose stack, then deploys, rolls back, backs up and
restores through Nginx. Failure paths of `deploy.sh` (an image that never becomes healthy, a migration
that fails, a backup that fails) are slow and awkward to stage with real containers, so those are tested
against a fake `docker compose` that records calls and injects failures
(`scripts/tests/test-deploy-flow.sh`).

## Left out on purpose

Alertmanager routing, log aggregation, a secrets manager, server provisioning (Terraform or Ansible),
intrusion prevention, and blue-green or canary releases. For a real engagement I would add them where
the risk justifies the extra moving parts, starting with alert routing and off-site backups.
