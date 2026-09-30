#!/usr/bin/env bash
# Create the secret files Compose mounts into the containers. Existing files are kept.
# The directory is private to the current user; the files are world-readable so the unprivileged
# users inside the containers can read them through the bind mount.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

umask 077
mkdir -p secrets
chmod 700 secrets

generate() {
  local file="secrets/$1"
  if [ -s "$file" ]; then
    log "keep   $file"
    return 0
  fi
  # 32 alphanumeric characters: safe in connection strings and shell without quoting.
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-32 >"$file"
  chmod 444 "$file"
  log "create $file"
}

generate db_password
generate grafana_admin_password
