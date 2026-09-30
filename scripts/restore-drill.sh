#!/usr/bin/env bash
# Prove that backups restore. Restores the newest dump into a scratch database, checks it against
# the live database, drops the scratch database, and publishes a metric (the RestoreDrillStale
# alert fires if no drill has passed for 35 days). Run monthly from cron.
#
#   restore-drill.sh [FILE]     default: the newest dump in BACKUP_DIR
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [ $# -ge 1 ]; then
  file="$(abspath "$1")"
else
  file="$(newest_backup)" || die "no backups found in $BACKUP_DIR"
fi
scratch="${DB_NAME}_drill"

query() { db_exec psql -U "$DB_USER" -d "$1" -X -A -t -v ON_ERROR_STOP=1 -c "$2"; }
drop_scratch() {
  db_exec psql -U "$DB_USER" -d postgres -X -q \
    -c "DROP DATABASE IF EXISTS \"$scratch\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap drop_scratch EXIT

started="$(date +%s)"
drop_scratch
log "restoring $(basename "$file") into scratch database '$scratch'"
"$SCRIPT_DIR/restore.sh" "$file" --into "$scratch"

restored_migrations="$(query "$scratch" 'SELECT count(*) FROM schema_migrations')"
live_migrations="$(query "$DB_NAME" 'SELECT count(*) FROM schema_migrations')"
restored_notes="$(query "$scratch" 'SELECT count(*) FROM notes')"
live_notes="$(query "$DB_NAME" 'SELECT count(*) FROM notes')"

log "schema_migrations: restored=${restored_migrations} live=${live_migrations}"
log "notes:             restored=${restored_notes} live=${live_notes}"

# The backup is older than the live data, so it can hold less but never more.
[ "$restored_migrations" -ge 1 ] || die "drill failed: the restored database has no migrations"
[ "$restored_migrations" -le "$live_migrations" ] || die "drill failed: more migrations than live"
[ "$restored_notes" -le "$live_notes" ] || die "drill failed: more notes than live"

duration=$(($(date +%s) - started))
write_metric restore_drill <<EOF
# HELP restore_drill_last_success_timestamp_seconds Unix time of the last successful restore drill.
# TYPE restore_drill_last_success_timestamp_seconds gauge
restore_drill_last_success_timestamp_seconds $(date +%s)
# HELP restore_drill_duration_seconds How long the last successful restore drill took.
# TYPE restore_drill_duration_seconds gauge
restore_drill_duration_seconds ${duration}
EOF
log "restore drill passed in ${duration}s"
