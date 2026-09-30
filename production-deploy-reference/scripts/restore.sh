#!/usr/bin/env bash
# Restore a dump made by backup.sh.
#
#   restore.sh FILE                 into a new scratch database, left in place for inspection
#   restore.sh FILE --into NAME     into database NAME, which must not exist yet
#   restore.sh FILE --live          REPLACE the live database (stops the API, asks to confirm)
#
# --live takes a safety backup first. Set RESTORE_CONFIRM=<database name> to skip the prompt in
# automation, or SKIP_SAFETY_BACKUP=1 if the database is too broken to dump.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage
file="$(abspath "$1")"
shift
mode=scratch
target="${DB_NAME}_restore_$(date -u +%Y%m%d%H%M%S)"
case "${1:-}" in
  "") ;;
  --into)
    [ $# -eq 2 ] || usage
    mode=into
    target="$2"
    ;;
  --live)
    mode=live
    target="$DB_NAME"
    ;;
  *) usage ;;
esac
[[ "$target" =~ ^[A-Za-z0-9_]+$ ]] || die "database names may only contain letters, digits and _"
[ -r "$file" ] || die "cannot read $file"

if [ -r "$file.sha256" ]; then
  (cd "$(dirname "$file")" && sha256sum --check --status "$(basename "$file").sha256") ||
    die "checksum mismatch for $file"
  log "checksum ok"
else
  log "WARN: no .sha256 next to the dump, skipping the checksum"
fi

admin() { db_exec psql -U "$DB_USER" -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
created=""
restore_into() {
  admin -c "CREATE DATABASE \"$1\""
  created="$1" # only a database this run created may be cleaned up after a failure
  db_exec pg_restore -U "$DB_USER" -d "$1" --no-owner --exit-on-error <"$file"
}

drop_created() {
  if [ -n "$created" ]; then
    admin -c "DROP DATABASE IF EXISTS \"$created\" WITH (FORCE)" >/dev/null 2>&1 || true
  fi
}

if [ "$mode" != live ]; then
  trap drop_created ERR
  restore_into "$target"
  log "restored $(basename "$file") into database '$target'"
  exit 0
fi

if [ "${RESTORE_CONFIRM:-}" != "$DB_NAME" ]; then
  log "This REPLACES the live database '$DB_NAME' with $(basename "$file")."
  read -r -p "Type the database name to continue: " answer || die "aborted: no confirmation given"
  [ "$answer" = "$DB_NAME" ] || die "aborted"
fi

safety=none
if [ "${SKIP_SAFETY_BACKUP:-0}" != 1 ]; then
  safety="$("$SCRIPT_DIR/backup.sh" pre-restore)" ||
    die "could not take a safety backup (SKIP_SAFETY_BACKUP=1 to go on without one)"
fi

trap 'log "RESTORE FAILED: the live database may be incomplete. Safety backup: ${safety}. Fix the cause and re-run this command."' ERR
compose stop api
admin -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)"
restore_into "$DB_NAME"
compose up -d --wait --no-build api
log "live database restored from $(basename "$file"); safety backup: ${safety}"
