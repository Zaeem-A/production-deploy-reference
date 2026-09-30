#!/usr/bin/env bash
# End-to-end check on a throwaway copy of the stack. CI runs it; you can run it too.
#
#   build and deploy -> API and Nginx -> second deploy -> rollback -> backup -> restore drill
#   -> restore over the live database -> Prometheus targets, rules and metrics -> Grafana
#
# It creates .env, secrets/, data/, .deploy/ and backups/, and removes them together with the
# containers and volumes when it exits. It refuses to start if any of them exists, so it cannot
# touch a real installation. Needs Docker with Compose, curl, openssl and python3.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

for path in .env secrets data .deploy backups; do
  [ ! -e "$path" ] || die "$path already exists: run the smoke test in a clean checkout"
done

http_port=8080
https_port=8443
base="https://localhost:${https_port}"

cleanup() {
  local code=$?
  trap - EXIT
  if [ "$code" -ne 0 ]; then
    log "SMOKE TEST FAILED (exit ${code}). Container state and recent logs follow."
    compose ps -a || true
    compose logs --no-color --tail 80 || true
  fi
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf .env secrets data .deploy backups
  exit "$code"
}
trap cleanup EXIT

step() { log "== $*"; }
expect() { [ "$2" = "$3" ] || die "$1: expected '$3', got '$2'"; }
api() { curl -fsS -k --max-time 10 "$@"; }
status_of() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
json_get() { # json_get a.b.c: print a nested value from the JSON on stdin
  python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value)' "$1"
}

wait_until() {
  local timeout="$1" what="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    [ "$waited" -lt "$timeout" ] || die "timed out after ${timeout}s waiting for: ${what}"
    sleep 3
    waited=$((waited + 3))
  done
  log "ok: ${what}"
}

prom() { curl -fsS --max-time 10 "http://127.0.0.1:9090$1"; }
grafana() { curl -fsS --max-time 10 -u "admin:$(cat secrets/grafana_admin_password)" "http://127.0.0.1:3000$1"; }
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

prom_has() { # true when the PromQL expression returns at least one series
  prom "/api/v1/query?query=$(urlencode "$1")" |
    python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["data"]["result"] else 1)'
}
targets_up() {
  prom /api/v1/targets | python3 -c '
import json, sys
targets = json.load(sys.stdin)["data"]["activeTargets"]
sys.exit(0 if len(targets) == 3 and all(t["health"] == "up" for t in targets) else 1)'
}
rules_loaded() { # Prometheus must report as many groups and rules as monitoring/prometheus/alerts.yml declares
  local want_groups want_rules
  want_groups="$(grep -c '^  - name:' monitoring/prometheus/alerts.yml)"
  want_rules="$(grep -c '^      - alert:' monitoring/prometheus/alerts.yml)"
  prom /api/v1/rules | python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
want_groups, want_rules = int(sys.argv[1]), int(sys.argv[2])
sys.exit(0 if len(groups) == want_groups and sum(len(g["rules"]) for g in groups) == want_rules else 1)' \
    "$want_groups" "$want_rules"
}
grafana_ready() { curl -fsS --max-time 5 http://127.0.0.1:3000/api/health | json_get database | grep -qx ok; }
dashboard_queries_valid() { # a 400 from Prometheus means a panel expression does not parse
  python3 - "$ROOT_DIR/monitoring/grafana/dashboards/app-overview.json" <<'PY'
import json, sys, urllib.parse, urllib.request

dashboard = json.load(open(sys.argv[1]))
bad = 0
for panel in dashboard["panels"]:
    for target in panel["targets"]:
        url = "http://127.0.0.1:9090/api/v1/query?query=" + urllib.parse.quote(target["expr"])
        try:
            urllib.request.urlopen(url, timeout=10).read()
        except Exception as exc:
            print(f"bad query in panel '{panel['title']}': {target['expr']}: {exc}")
            bad += 1
sys.exit(1 if bad else 0)
PY
}

step "setting up a throwaway stack on ports ${http_port}/${https_port}"
cp .env.example .env
env_set HTTP_PORT "$http_port"
env_set HTTPS_PORT "$https_port"
mkdir -p data/textfile
env_set METRICS_TEXTFILE_DIR "$ROOT_DIR/data/textfile"
"$SCRIPT_DIR/gen-secrets.sh"
"$SCRIPT_DIR/init-tls.sh" selfsigned
export DEPLOY_BUILD=1

step "first deploy"
"$SCRIPT_DIR/deploy.sh" smoke-1

step "API through Nginx"
api "$base/healthz" >/dev/null
api "$base/readyz" >/dev/null
created="$(api -X POST -H 'content-type: application/json' -d '{"text":"smoke test note"}' "$base/api/notes")"
note_id="$(json_get id <<<"$created")"
[[ "$(api "$base/api/notes/${note_id}")" == *"smoke test note"* ]] || die "note ${note_id} did not round-trip"
expect "empty note is rejected" "$(status_of -X POST -H 'content-type: application/json' -d '{"text":""}' "$base/api/notes")" 422
expect "/metrics is not public" "$(status_of "$base/metrics")" 404
expect "http redirects to https" "$(status_of "http://localhost:${http_port}/")" 301
curl -skI --max-time 10 "$base/healthz" | grep -qi '^strict-transport-security:' || die "HSTS header missing"

step "second deploy backs up first and remembers the previous release"
"$SCRIPT_DIR/deploy.sh" smoke-2
expect "current tag" "$(cat .deploy/current_tag)" smoke-2
expect "previous tag" "$(cat .deploy/previous_tag)" smoke-1
compgen -G "backups/*-predeploy.dump" >/dev/null || die "the deploy did not write a pre-deploy backup"
[[ "$(api "$base/")" == *'"version":"smoke-2"'* ]] || die "smoke-2 is not serving"
[[ "$(api "$base/api/notes/${note_id}")" == *"smoke test note"* ]] || die "data lost during deploy"

step "rollback"
"$SCRIPT_DIR/rollback.sh"
expect "current tag after rollback" "$(cat .deploy/current_tag)" smoke-1
[[ "$(api "$base/")" == *'"version":"smoke-1"'* ]] || die "smoke-1 is not serving after rollback"
[[ "$(api "$base/api/notes/${note_id}")" == *"smoke test note"* ]] || die "data lost during rollback"

step "backup, restore drill and certificate metric"
dump="$("$SCRIPT_DIR/backup.sh")"
[ -s "$dump" ] || die "the backup file is missing"
[ -s "$dump.sha256" ] || die "the checksum file is missing"
"$SCRIPT_DIR/restore-drill.sh"
"$SCRIPT_DIR/renew-certs.sh"

step "restore the backup over the live database"
RESTORE_CONFIRM="$DB_NAME" "$SCRIPT_DIR/restore.sh" "$dump" --live
wait_until 60 "API serves again after the restore" api "$base/readyz"
[[ "$(api "$base/api/notes/${note_id}")" == *"smoke test note"* ]] || die "note missing after restore"

step "Prometheus"
wait_until 120 "all three targets are up" targets_up
wait_until 30 "every alert rule in alerts.yml is loaded" rules_loaded
wait_until 90 "API request metrics are scraped" prom_has 'sum(http_requests_total)'
wait_until 90 "backup metric reaches Prometheus" prom_has 'backup_last_success_timestamp_seconds'
wait_until 90 "restore drill metric reaches Prometheus" prom_has 'restore_drill_last_success_timestamp_seconds'
wait_until 90 "certificate expiry metric reaches Prometheus" prom_has 'tls_cert_not_after_timestamp_seconds'

step "Grafana"
wait_until 90 "Grafana is healthy" grafana_ready
expect "provisioned dashboard" \
  "$(grafana /api/dashboards/uid/notes-api-overview | json_get dashboard.title)" "Notes API overview"
expect "Prometheus datasource health" \
  "$(grafana /api/datasources/uid/prometheus/health | json_get status)" OK
dashboard_queries_valid || die "the dashboard contains an invalid PromQL query"

step "smoke test passed"
