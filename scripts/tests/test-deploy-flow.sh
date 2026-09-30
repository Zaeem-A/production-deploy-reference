#!/usr/bin/env bash
# Tests scripts/deploy.sh and scripts/rollback.sh without Docker. A fake `docker compose` records the
# calls and injects failures, and a small HTTPS server plays Nginx and the API. It runs in a scratch
# copy of the repo, so nothing in your checkout is touched. Needs bash, curl, openssl and python3.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null; fi
  rm -rf "$work"
}
trap cleanup EXIT

cp -r "$repo/scripts" "$repo/nginx" "$repo/.env.example" "$work/"
cd "$work" || exit 1
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cp .env.example .env
sed -i "s/^HTTPS_PORT=.*/HTTPS_PORT=${port}/" .env

export FAKE_DIR="$work/fake" COMPOSE="$work/scripts/tests/fake-compose.sh"
export DEPLOY_VERIFY_TIMEOUT=4 METRICS_TEXTFILE_DIR="$work/textfile"
scripts/gen-secrets.sh 2>/dev/null
scripts/init-tls.sh selfsigned 2>/dev/null
live=data/letsencrypt/live/localhost
mkdir -p "$FAKE_DIR"
python3 scripts/tests/fake-server.py "$port" "$live/fullchain.pem" "$live/privkey.pem" "$FAKE_DIR/api_tag" &
server_pid=$!
for _ in $(seq 1 25); do
  curl -ksf --max-time 1 "https://localhost:${port}/" >/dev/null 2>&1 && break
  sleep 0.2
done

calls="$FAKE_DIR/calls.log"
passed=0
failed=0
ok() {
  passed=$((passed + 1))
  echo "  PASS $*"
}
bad() {
  failed=$((failed + 1))
  echo "  FAIL $*"
}
check() {
  local what="$1"
  shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}

reset_state() {
  rm -rf "$FAKE_DIR/calls.log" "$FAKE_DIR/db_running" "$FAKE_DIR/api_tag" .deploy backups
  sed -i 's/^API_TAG=.*/API_TAG=local/; s/^APP_VERSION=.*/APP_VERSION=dev/' .env
}
run_deploy() { # run_deploy TAG [VAR=value ...]  ->  $rc, output in out.log, calls in calls.log
  local tag="$1"
  shift
  : >"$calls"
  env "$@" scripts/deploy.sh "$tag" >"$work/out.log" 2>&1
  rc=$?
}
run_rollback() { # run_rollback [TAG]
  : >"$calls"
  scripts/rollback.sh "$@" >"$work/out.log" 2>&1
  rc=$?
}
served() { cat "$FAKE_DIR/api_tag" 2>/dev/null; }
current() { cat .deploy/current_tag 2>/dev/null; }
previous() { cat .deploy/previous_tag 2>/dev/null; }
called() { grep -Eq -- "$1" "$calls"; }
not_called() { ! called "$1"; }
logged() { grep -q -- "$1" "$work/out.log"; }
is() { [ "$1" = "$2" ]; }
succeeded() { [ "$rc" -eq 0 ]; }
failed_run() { [ "$rc" -ne 0 ]; }
in_order() { # every pattern must match a call after the previous pattern's match
  local last=0 pattern line
  for pattern in "$@"; do
    line="$(awk -v p="$pattern" -v after="$last" 'NR > after && $0 ~ p { print NR; exit }' "$calls")"
    [ -n "$line" ] || return 1
    last="$line"
  done
}
env_line() { grep -c "^$1=$2\$" .env; }

echo "== first deploy fails: nothing to roll back to"
reset_state
run_deploy 0.0.1 FAKE_FAIL_UP_TAG=0.0.1
check "deploy exits non-zero" failed_run
check "says there is no previous release" logged "no previous release is recorded"
check "no release is recorded" test ! -e .deploy/current_tag
check ".env still points at the old tag" is "$(env_line API_TAG local)" 1

echo "== first deploy"
reset_state
run_deploy 1.0.0
check "deploy exits 0" succeeded
check "steps run in order: pull, database, migrations, start, reload prometheus" \
  in_order 'pull api' 'wait-timeout 120 --no-build db$' 'run --rm -T --no-deps api python -m notes_api.migrate' \
  'wait-timeout 180 --no-build$' 'kill -s HUP prometheus'
check "no backup when no database is running yet" not_called pg_dump
check "no nginx restart on the first deploy" not_called 'restart nginx'
check "the new version is serving" is "$(served)" 1.0.0
check "current release recorded" is "$(current)" 1.0.0
check "no previous release yet" test ! -e .deploy/previous_tag
check ".env has API_TAG once, set to the release" is "$(env_line API_TAG 1.0.0)" 1
check ".env has APP_VERSION once, set to the release" is "$(env_line APP_VERSION 1.0.0)" 1
check "other .env settings survive" grep -q '^APP_DOMAIN=localhost$' .env

echo "== second deploy"
run_deploy 1.1.0
check "deploy exits 0" succeeded
check "backup happens before migrations" \
  in_order 'pull api' 'exec -T db pg_dump' 'wait-timeout 120 --no-build db$' 'run --rm' 'wait-timeout 180'
check "a pre-deploy dump exists" bash -c 'ls backups/*-predeploy.dump >/dev/null 2>&1'
check "no partial dump left behind" bash -c '! ls -a backups | grep -q partial'
check "current = 1.1.0, previous = 1.0.0" is "$(current)/$(previous)" 1.1.0/1.0.0
check "the new version is serving" is "$(served)" 1.1.0

echo "== deploying the current tag again"
run_deploy 1.1.0
check "deploy exits 0" succeeded
check "says it is already current" logged "already the current release"
check "previous release is not overwritten with the same tag" is "$(previous)" 1.0.0

echo "== starting the new release fails: automatic rollback"
run_deploy 1.2.0 FAKE_FAIL_UP_TAG=1.2.0
check "deploy exits non-zero" failed_run
check "API is put back on 1.1.0 after the failed start" \
  in_order 'API_TAG=1.2.0 up .*wait-timeout 180' 'API_TAG=1.1.0 up .*--no-deps api'
check "1.1.0 is serving again" is "$(served)" 1.1.0
check "release records are unchanged" is "$(current)/$(previous)" 1.1.0/1.0.0
check ".env still points at 1.1.0" is "$(env_line API_TAG 1.1.0)" 1
check "says it rolled back" logged "rolled back to 1.1.0"

echo "== new release starts but never answers: automatic rollback"
run_deploy 1.3.0 FAKE_IGNORE_TAG=1.3.0
check "deploy exits non-zero" failed_run
check "reports the timeout" logged "timed out"
check "API is put back on 1.1.0" in_order 'API_TAG=1.3.0 up .*wait-timeout 180' 'API_TAG=1.1.0 up .*--no-deps api'
check "1.1.0 is serving" is "$(served)" 1.1.0
check "current release unchanged" is "$(current)" 1.1.0

echo "== migration fails: the running API is left alone"
run_deploy 1.4.0 FAKE_FAIL_MIGRATE=1
check "deploy exits non-zero" failed_run
check "the API is never replaced" not_called 'wait-timeout 180'
check "no rollback needed" not_called 'up .*--no-deps api'
check "says the API was not replaced" logged "the running API was not replaced"
check "1.1.0 is still serving" is "$(served)" 1.1.0

echo "== image cannot be pulled"
run_deploy 1.5.0 FAKE_FAIL_PULL=1
check "deploy exits non-zero" failed_run
check "stops before the backup and migrations" not_called 'pg_dump|run --rm'
check "says the API was not replaced" logged "the running API was not replaced"

echo "== pre-deploy backup fails: no backup, no deploy"
run_deploy 1.6.0 FAKE_FAIL_DUMP=1
check "deploy exits non-zero" failed_run
check "migrations never run" not_called 'run --rm'
check "the failure is reported" logged "pg_dump failed"
check "no partial dump left behind" bash -c '! ls -a backups | grep -q partial'

echo "== changed Nginx template is picked up"
echo "# edited" >>nginx/templates/default.conf.template
run_deploy 1.7.0
check "deploy exits 0" succeeded
check "nginx is restarted" called 'restart nginx'
run_deploy 1.7.1
check "unchanged template: nginx is left alone" not_called 'restart nginx'
check "current = 1.7.1, previous = 1.7.0" is "$(current)/$(previous)" 1.7.1/1.7.0

echo "== manual rollback"
run_rollback
check "rollback exits 0" succeeded
check "returns to the previous release" is "$(served)/$(current)/$(previous)" 1.7.0/1.7.0/1.7.1
check ".env follows" is "$(env_line API_TAG 1.7.0)" 1
run_rollback 1.1.0
check "rollback to an explicit tag" is "$(served)/$(current)/$(previous)" 1.1.0/1.1.0/1.7.0
run_rollback 1.1.0
check "rolling back to the current release is refused" failed_run
run_rollback 'bad tag'
check "invalid tag is refused" failed_run
reset_state
run_rollback
check "rollback with no recorded release is refused" failed_run
check "and explains why" logged "no previous release is recorded"

echo "== input and preflight checks"
for tag in 'bad tag' '' '../x' '-rf'; do
  run_deploy "$tag"
  check "deploy refuses tag '$tag'" failed_run
done
mv secrets/db_password secrets/db_password.bak
run_deploy 2.0.0
check "missing secret is refused" failed_run
check "and named" logged "secrets/db_password is missing"
check "nothing was started" not_called 'up '
mv secrets/db_password.bak secrets/db_password
mv "$live" "$live.bak"
run_deploy 2.0.0
check "missing certificate is refused" failed_run
check "and explained" logged "no certificate for localhost"
check "nothing was started" not_called 'up '
mv "$live.bak" "$live"

echo
echo "passed=${passed} failed=${failed}"
[ "$failed" -eq 0 ]
