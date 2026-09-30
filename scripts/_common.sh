# shellcheck shell=bash
# shellcheck disable=SC2034
# Shared helpers, sourced by the other scripts (not run directly). Needs bash 4.4+.
#
# Test hooks: COMPOSE=true makes every `docker compose` call a no-op, and DB_EXEC="" runs
# psql/pg_dump/pg_restore on the host (set PGHOST and PGPORT) instead of inside the db container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CALLER_DIR="$PWD"
cd "$ROOT_DIR" || exit 1

LE_DIR="${LE_DIR:-$ROOT_DIR/data/letsencrypt}"
DEPLOY_DIR="$ROOT_DIR/.deploy"

read -r -a COMPOSE_CMD <<<"${COMPOSE-docker compose}"
read -r -a DB_EXEC_CMD <<<"${DB_EXEC-${COMPOSE-docker compose} exec -T db}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

compose() { "${COMPOSE_CMD[@]}" "$@"; }
db_exec() { "${DB_EXEC_CMD[@]}" "$@"; }

# A path given on the command line is relative to where the user ran the script, not the repo root.
abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$CALLER_DIR" "$1" ;;
  esac
}

# env_get KEY [DEFAULT]: read a value from .env without sourcing it (the file is data, not code).
# An empty value counts as unset, so the default still applies.
env_get() {
  local key="$1" default="${2-}" line
  line="$(grep -E "^${key}=" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  line="${line%\'}"
  line="${line#\'}"
  printf '%s' "${line:-$default}"
}

# env_set KEY VALUE: replace the line in .env (or append it), keeping the file's permissions.
env_set() {
  local key="$1" value="$2" file="$ROOT_DIR/.env" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  if grep -qE "^${key}=" "$file"; then
    awk -v k="$key" -v v="$value" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' \
      "$file" >"$tmp"
  else
    cat "$file" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
}

# setting KEY [DEFAULT]: the environment wins over .env, which wins over the default.
setting() {
  local key="$1" default="${2-}"
  if [ -n "${!key-}" ]; then
    printf '%s' "${!key}"
  else
    env_get "$key" "$default"
  fi
}

DB_NAME="$(setting DB_NAME notes)"
DB_USER="$(setting DB_USER notes)"
BACKUP_DIR="$(setting BACKUP_DIR "$ROOT_DIR/backups")"
METRICS_DIR="$(setting METRICS_TEXTFILE_DIR /var/lib/node-exporter-textfile)"

# newest_backup: path of the most recent dump. Names embed a UTC timestamp, so glob order is time order.
newest_backup() {
  local f newest=""
  for f in "$BACKUP_DIR/${DB_NAME}-"*.dump; do
    if [ -e "$f" ]; then newest="$f"; fi
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# write_metric NAME: read Prometheus text-format metrics on stdin and publish them atomically for
# node-exporter's textfile collector. A directory we cannot write to is a warning, not a failure:
# the job itself succeeded, and the BackupMetricMissing alert will point at the gap.
write_metric() {
  local name="$1" tmp
  if [ ! -d "$METRICS_DIR" ] && ! mkdir -p "$METRICS_DIR" 2>/dev/null; then
    log "WARN: $METRICS_DIR does not exist and cannot be created; metric '$name' not published"
    cat >/dev/null
    return 0
  fi
  if ! tmp="$(mktemp "$METRICS_DIR/.${name}.XXXXXX" 2>/dev/null)"; then
    log "WARN: $METRICS_DIR is not writable; metric '$name' not published"
    cat >/dev/null
    return 0
  fi
  cat >"$tmp"
  chmod 644 "$tmp" # node-exporter runs as an unprivileged user
  mv "$tmp" "$METRICS_DIR/${name}.prom"
}

# wait_for_version VERSION [SECONDS]: poll GET / through Nginx until it reports VERSION.
# Certificate checks are skipped only while the placeholder certificate is installed.
wait_for_version() {
  local want="$1" timeout="${2:-60}" domain port body="" waited=0
  local curl_args=(-fsS --max-time 5)
  domain="$(setting APP_DOMAIN localhost)"
  port="$(setting HTTPS_PORT 443)"
  if [ -e "$LE_DIR/live/$domain/SELF_SIGNED" ]; then curl_args+=(-k); fi
  while [ "$waited" -lt "$timeout" ]; do
    body="$(curl "${curl_args[@]}" --resolve "${domain}:${port}:127.0.0.1" \
      "https://${domain}:${port}/" 2>/dev/null || true)"
    if [[ "$body" == *"\"version\":\"${want}\""* ]]; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  log "timed out after ${timeout}s waiting for version ${want}; last response: ${body:-<none>}"
  return 1
}
