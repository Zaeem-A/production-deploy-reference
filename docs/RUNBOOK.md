# Runbook

Everything runs on one Linux server with Docker Compose. Commands are run from the install
directory (`/opt/notes-stack` in the examples) as the deploy user.

## 1. First server setup

1. **Server.** Any Linux VPS with Docker Engine and the Compose plugin (2.24 or newer). Open ports
   22, 80 and 443 only. Docker publishes ports around `ufw`, so the port list in `compose.yaml` is
   what counts: Nginx publishes 80 and 443, Prometheus and Grafana bind to `127.0.0.1`.
2. **Deploy user.** `sudo adduser --disabled-password deploy && sudo usermod -aG docker deploy`
   (membership of the `docker` group is root-equivalent, so use a key pair only CI holds). Add the
   CI public key to `~deploy/.ssh/authorized_keys`.
3. **Directories.**
   ```bash
   sudo install -d -o deploy -g deploy /opt/notes-stack /var/log/notes-stack
   sudo install -d -o deploy -g deploy -m 755 /var/lib/node-exporter-textfile
   ```
4. **Files.** Let the deploy workflow copy them (section 2) or run
   `rsync -a compose.yaml nginx monitoring scripts deploy@HOST:/opt/notes-stack/`.
5. **Configuration.** `cp .env.example .env`, then set `APP_DOMAIN`, `LETSENCRYPT_EMAIL` and
   `API_IMAGE=ghcr.io/<owner>/<repo>/notes-api` (lowercase).
6. **Secrets and placeholder certificate.**
   `./scripts/gen-secrets.sh && ./scripts/init-tls.sh selfsigned`. Nginx cannot start without a
   certificate file, and Let's Encrypt cannot validate a domain without Nginx, hence the placeholder.
7. **Registry login**, only if the GHCR package is private:
   `echo TOKEN | docker login ghcr.io -u USER --password-stdin` (token with `read:packages`).
   The deploy workflow logs in with its own short-lived token on every run.
8. **First deploy**, using the `sha-...` tag from the first successful workflow run (see the
   package list on GitHub): `./scripts/deploy.sh sha-1a2b3c4`. The placeholder certificate is
   detected, so the version check skips certificate validation until a real one is installed.
9. **DNS.** Point the A/AAAA record of `APP_DOMAIN` at the server.
10. **Real certificate.** `./scripts/init-tls.sh letsencrypt`. To rehearse first, set
    `LETSENCRYPT_STAGING=1`; to switch from staging to real, `sudo rm -rf data/letsencrypt` and run
    `init-tls.sh selfsigned` and `init-tls.sh letsencrypt` again.
11. **Cron** (`crontab -e` as the deploy user):
    ```cron
    17 2 * * *  cd /opt/notes-stack && ./scripts/backup.sh        >>/var/log/notes-stack/backup.log 2>&1
    43 3 1 * *  cd /opt/notes-stack && ./scripts/restore-drill.sh >>/var/log/notes-stack/drill.log  2>&1
    23 4 * * *  cd /opt/notes-stack && ./scripts/renew-certs.sh   >>/var/log/notes-stack/certs.log  2>&1
    ```
12. **Check it.**
    - `curl -I https://APP_DOMAIN/healthz` and `docker compose ps` (everything healthy).
    - `ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 deploy@HOST`, then open
      `http://127.0.0.1:3000` (user `admin`, password in `secrets/grafana_admin_password`).
    - Run `./scripts/backup.sh`, `./scripts/restore-drill.sh` and `./scripts/renew-certs.sh` once.
      The "Since backup" and "Since drill" panels should show a few seconds within a minute.

## 2. CI/CD setup

In the repository settings, under *Secrets and variables → Actions*:

| Kind | Name | Value |
|---|---|---|
| Variable | `DEPLOY_HOST` | Server hostname. The deploy job is skipped while this is empty. |
| Variable | `DEPLOY_USER`, `DEPLOY_PATH` | Optional. Defaults: `deploy`, `/opt/notes-stack`. |
| Secret | `DEPLOY_SSH_KEY` | Private key of the CI-only key pair. |
| Secret | `DEPLOY_KNOWN_HOSTS` | `ssh-keyscan -t ed25519 HOST`, checked against the fingerprint your provider shows. |

Under *Environments* create `staging` (used by pushes to `main`) and `production` (used by `v*`
tags) and add required reviewers to `production`. To deploy production to a different server, set
`DEPLOY_HOST` and the two secrets on the `production` environment: environment values win.

Flow: pull request → CI. Push to `main` → CI, build and push `ghcr.io/<owner>/<repo>/notes-api:sha-<commit>`,
deploy to staging. `git tag v1.2.0 && git push origin v1.2.0` → the same image also gets the `v1.2.0`
tag and is deployed to production once a reviewer approves.

## 3. Deploying by hand

```bash
./scripts/deploy.sh sha-1a2b3c4
```

The script pulls the image, takes a database backup when a database is already running, applies
migrations with the new image, starts the new version, waits until every container is healthy, and
checks that `GET /` through Nginx reports the tag it just deployed. Only then does it record the
release (`.deploy/current_tag`, `.deploy/previous_tag`) and update `API_TAG` and `APP_VERSION` in `.env`.

`DEPLOY_BUILD=1` builds from `./service` instead of pulling; `SKIP_BACKUP=1` skips the backup;
`DEPLOY_VERIFY_TIMEOUT=120` changes how long it waits for the new version (default 90 seconds).

What a deploy applies: the new image, and any change to `compose.yaml` (containers are recreated).
Prometheus reloads its config on `SIGHUP`, Nginx is restarted when its template changed, and Grafana
re-reads dashboards within a minute. Changed Grafana datasource provisioning needs
`docker compose restart grafana`.

## 4. Rolling back

- **Automatic.** If the new version does not start healthy, or does not answer with its own tag
  within the timeout, the API goes back to the previous release. Look for `rolled back to` in the
  output. If it says `ROLLBACK FAILED`, run `docker compose ps` and `docker compose logs --tail 100 api`.
  A first deploy has no previous release to go back to.
- **Manual.** `./scripts/rollback.sh` returns to the previous release, `./scripts/rollback.sh TAG`
  to a specific one. The image must still be on the server (do not run `docker image prune -a`).
- **The schema stays where it is.** Migrations are forward-only and run before the new version
  starts, so a migration has to work with the old and the new code: add a column in one release,
  remove the old one in a later release. If a migration breaks the previous release too, roll the
  image back, then restore the pre-deploy backup (section 5).
- **Not covered.** Changes to `nginx/`, `monitoring/` and `compose.yaml` are not rolled back by
  the script. They live in git: revert the commit and deploy again.

## 5. Backups and restores

`backup.sh` writes `backups/<db>-<UTC time>[-label].dump` and a `.sha256` next to it. It checks that
`pg_restore --list` can read the dump, keeps 14 days (`BACKUP_RETENTION_DAYS`) and, when
`BACKUP_REMOTE` is set (`remote:bucket/path`, `rclone` configured for the deploy user), copies the
dump off the server. `deploy.sh` takes `predeploy` backups and `restore.sh --live` takes
`pre-restore` backups; only the unlabelled scheduled backup updates the backup metric.

- **Look inside a backup without touching production.**
  `./scripts/restore.sh backups/FILE` restores into a new database `notes_restore_<time>`. Inspect it
  with `docker compose exec db psql -U notes -d notes_restore_<time>`, then drop it with
  `docker compose exec db psql -U notes -d postgres -c 'DROP DATABASE notes_restore_<time>'`.
- **Replace the live database.** `./scripts/restore.sh backups/FILE --live`. It asks you to type the
  database name, takes a safety backup, stops the API, drops and recreates the database, restores,
  and starts the API. In automation set `RESTORE_CONFIRM=notes`.
- **Lost server.** Set up a new one (sections 1 and 2), run `./scripts/deploy.sh TAG` to get an
  empty database, copy a dump from off-site into `backups/`, then restore it with `--live`.
- **Restore drill.** Monthly, `restore-drill.sh` restores the newest dump into a scratch database,
  checks that the migrations table is populated and that neither it nor the notes table holds more
  rows than live, drops the scratch database and records the time. `RestoreDrillStale` fires when no drill has passed for 35 days.

## 6. Certificates

`renew-certs.sh` runs daily. It renews certificates within 30 days of expiry, reloads Nginx and
writes the expiry date as a metric; `CertExpiringSoon` fires under 14 days. If renewal fails, the
usual causes are DNS pointing elsewhere, port 80 blocked, or Nginx not running: run the script by
hand and read certbot's output.

## 7. Monitoring and alerts

Prometheus (`http://127.0.0.1:9090`) and Grafana (`http://127.0.0.1:3000`) are reachable through an
SSH tunnel only. The dashboard is *Notes API overview*. Alerts are evaluated by Prometheus and shown
under *Alerts*; there is no Alertmanager in this stack, so add one with a receiver (email, Slack)
and an `alerting:` block in `prometheus.yml` when you want notifications.

| Alert | Means | First look |
|---|---|---|
| `TargetDown` | A scrape target is unreachable for 2 minutes | `docker compose ps`, then that service's logs |
| `ApiNotReady` | The API is up but `/readyz` returns 503 | `docker compose logs db`; is the disk full? |
| `HighErrorRate` | Over 5% of requests are 5xx for 5 minutes | `docker compose logs api` (JSON), recent deploy? Roll back |
| `HighLatencyP95` | p95 above 1 second for 10 minutes | Dashboard "p95 latency by route", `docker stats` |
| `DiskSpaceLow` | Under 15% free on `/` | `docker system df`, `backups/`, `docker image prune -f` |
| `MemoryPressure`, `HighCpu` | Host above 90% for 10 or 15 minutes | `docker stats`, container limits in `compose.yaml` |
| `BackupStale` | No successful backup for 26 hours | `/var/log/notes-stack/backup.log`, run `backup.sh` |
| `BackupMetricMissing` | No backup ever recorded | Is the cron entry installed? Is `/var/lib/node-exporter-textfile` writable? |
| `RestoreDrillStale` | The last passing drill is over 35 days old | Run `restore-drill.sh` and read the failure reason |
| `RestoreDrillMissing` | No drill has ever passed | Is the monthly cron entry installed? Run `restore-drill.sh` |
| `CertExpiringSoon` | Certificate expires in under 14 days | Section 6 |

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Deploy fails while fetching the image | Registry login expired, or the tag does not exist | `docker login ghcr.io`; check the tag in the package list |
| `up --wait` times out, API restarting | Database password does not match the one Postgres was initialised with (the secret was regenerated) | `docker compose exec db psql -U notes -c "ALTER USER notes PASSWORD '$(cat secrets/db_password)'"`, then redeploy. Never regenerate `secrets/db_password` on a server with data. |
| Nginx restarting | Certificate files missing, a template error, or a host kernel with IPv6 disabled (delete the `listen [::]` lines) | `./scripts/init-tls.sh selfsigned`; `docker compose logs nginx` |
| 502 from Nginx | API down or restarting | `docker compose logs api` |
| 429 from Nginx | Rate limit: 10 requests/s per IP, burst 20 | Expected for abusive clients; tune `limit_req` in the template |
| `backup.sh` reports `pg_dump failed` | Database container down, or disk full | `docker compose ps`, `df -h` |
| node-exporter target down | The `rslave` host mount is not supported (Docker Desktop) | Run on Linux |

## 9. Routine maintenance

- **Updates.** Dependabot opens pull requests for Python packages, base images, Compose images and
  Actions; the smoke test runs on each.
- **Disk.** `docker image prune -f` removes dangling images and keeps tagged ones, so rollback keeps
  working.
- **Rotate the Grafana admin password.** Edit `secrets/grafana_admin_password`, then
  `docker compose exec grafana grafana cli admin reset-admin-password "$(cat secrets/grafana_admin_password)"`
  (Grafana reads the environment only when it first creates the admin user).
- **Rotate the database password.** `ALTER USER` as in section 8 with the new value, write the same
  value to `secrets/db_password`, then `docker compose up -d --force-recreate api`.
- **Reboots.** Docker starts on boot and every container has `restart: unless-stopped`. Check
  `docker compose ps` afterwards.
