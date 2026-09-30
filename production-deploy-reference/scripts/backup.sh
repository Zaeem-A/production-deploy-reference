#!/usr/bin/env bash
# Dump the database, check that the dump is readable, prune old dumps, optionally copy the dump
# off-site with rclone, and publish a metric so Prometheus can alert when backups stop.
#
#   backup.sh [label]     label goes into the file name, e.g. "predeploy"
#
# Prints the path of the new dump on stdout. Run from cron; see docs/RUNBOOK.md.
# Only unlabelled (scheduled) backups update the backup metric, so a broken cron job is not
# hidden by the pre-deploy backups that deploy.sh takes.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

label="${1:-}"
[[ "$label" =~ ^[A-Za-z0-9_-]*$ ]] || die "label may only contain letters, digits, - and _"
retention="$(setting BACKUP_RETENTION_DAYS 14)"
remote="$(setting BACKUP_REMOTE "")"
name="${DB_NAME}-$(date -u +%Y%m%dT%H%M%SZ)${label:+-$label}.dump"

umask 077
mkdir -p "$BACKUP_DIR"
partial="$BACKUP_DIR/.${name}.partial"
trap 'rm -f "$partial"' EXIT

log "dumping database '$DB_NAME'"
db_exec pg_dump -U "$DB_USER" -Fc "$DB_NAME" >"$partial" || die "pg_dump failed"
[ -s "$partial" ] || die "pg_dump produced an empty file"
db_exec pg_restore --list <"$partial" >/dev/null || die "the dump cannot be read back by pg_restore"

mv "$partial" "$BACKUP_DIR/$name"
(cd "$BACKUP_DIR" && sha256sum "$name" >"$name.sha256")
size="$(wc -c <"$BACKUP_DIR/$name")"

find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name "${DB_NAME}-*.dump" -o -name "${DB_NAME}-*.dump.sha256" \) \
  -mtime "+${retention}" -delete

if [ -n "$remote" ]; then
  command -v rclone >/dev/null || die "BACKUP_REMOTE is set but rclone is not installed"
  rclone copyto "$BACKUP_DIR/$name" "${remote%/}/$name"
  rclone copyto "$BACKUP_DIR/$name.sha256" "${remote%/}/$name.sha256"
  log "copied to ${remote%/}/$name"
fi

if [ -z "$label" ]; then
  write_metric backup <<EOF
# HELP backup_last_success_timestamp_seconds Unix time of the last successful scheduled backup.
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds $(date +%s)
# HELP backup_last_size_bytes Size of the last successful scheduled backup.
# TYPE backup_last_size_bytes gauge
backup_last_size_bytes ${size}
EOF
fi

log "backup written: $BACKUP_DIR/$name (${size} bytes)"
printf '%s\n' "$BACKUP_DIR/$name"
