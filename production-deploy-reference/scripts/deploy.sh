#!/usr/bin/env bash
# Deploy a release:  scripts/deploy.sh <image-tag>
#
#   1. pull the image (DEPLOY_BUILD=1 builds it from ./service instead: local runs and CI)
#   2. back up the database if one is already running (SKIP_BACKUP=1 to skip)
#   3. start the database and apply migrations with the NEW image
#   4. start the new version and wait until every container is healthy
#   5. check that the public URL answers with the new version
#
# If step 4 or 5 fails, the previous release is put back automatically.
#
# Migrations are forward-only and run before the new version starts, so a schema change must keep
# working with the previous release too (add a column first, drop the old one in a later release).
# When it cannot, rolling back the image does not help: restore the pre-deploy backup instead
# (docs/RUNBOOK.md). Rollback covers the application image, not the Nginx or monitoring files:
# those live in git, so revert the commit and deploy again.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

tag="${1:-}"
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
  die "usage: deploy.sh <image-tag>   (letters, digits, '.', '_' and '-')"

verify_timeout="${DEPLOY_VERIFY_TIMEOUT:-90}" # seconds to wait for the new version to answer
stage=preflight
armed=0 # becomes 1 once the running API is about to be replaced
previous="$(cat "$DEPLOY_DIR/current_tag" 2>/dev/null || true)"

on_error() {
  local code=$?
  trap - ERR
  log "FAILED during: ${stage} (exit ${code})"
  if [ "$armed" = 1 ] && [ -n "$previous" ] && [ "$previous" != "$tag" ]; then
    log "rolling the API back to ${previous}"
    export API_TAG="$previous" APP_VERSION="$previous"
    if compose up -d --wait --wait-timeout 120 --no-build --no-deps api &&
      wait_for_version "$previous" "$verify_timeout"; then
      log "rolled back to ${previous}; the failed release was ${tag}"
    else
      log "ROLLBACK FAILED, the site may be down: docker compose ps; docker compose logs api"
    fi
  elif [ "$armed" = 1 ]; then
    log "no previous release is recorded, so there is nothing to roll back to"
  else
    log "the running API was not replaced"
  fi
  exit "$code"
}
trap on_error ERR

[ -f .env ] || die ".env is missing: cp .env.example .env and edit it"
for secret in db_password grafana_admin_password; do
  [ -s "secrets/$secret" ] || die "secrets/$secret is missing: run scripts/gen-secrets.sh"
done
domain="$(setting APP_DOMAIN localhost)"
[ -s "$LE_DIR/live/$domain/fullchain.pem" ] ||
  die "no certificate for $domain: run scripts/init-tls.sh selfsigned"
mkdir -p "$DEPLOY_DIR"
mkdir -p "$METRICS_DIR" 2>/dev/null || log "WARN: cannot create $METRICS_DIR, backup metrics will not reach Prometheus"
compose config -q

export API_TAG="$tag" APP_VERSION="$tag"
if [ "$previous" = "$tag" ]; then log "$tag is already the current release, deploying it again"; fi

stage="fetching the image"
if [ "${DEPLOY_BUILD:-0}" = 1 ]; then
  log "building $tag from ./service"
  compose build api
else
  log "pulling $tag"
  compose pull api
fi

stage="backing up the database"
if [ "${SKIP_BACKUP:-0}" != 1 ] && compose ps --status running --services | grep -qx db; then
  "$SCRIPT_DIR/backup.sh" predeploy >/dev/null
fi

stage="starting the database"
compose up -d --wait --wait-timeout 120 --no-build db

stage="applying migrations"
log "applying migrations with $tag"
compose run --rm -T --no-deps api python -m notes_api.migrate

stage="starting $tag"
armed=1
nginx_hash="$(cat nginx/templates/* | sha256sum | cut -d' ' -f1)"
compose up -d --wait --wait-timeout 180 --no-build
# Bind-mounted config is not watched: Prometheus reloads on SIGHUP, Nginx renders its template at
# start, so restart it when the template changed. Grafana re-reads dashboards on its own.
compose kill -s HUP prometheus >/dev/null 2>&1 || true
if [ -f "$DEPLOY_DIR/nginx_template.sha256" ] &&
  [ "$nginx_hash" != "$(cat "$DEPLOY_DIR/nginx_template.sha256")" ]; then
  log "the Nginx template changed, restarting nginx"
  compose restart nginx
fi

stage="checking that $tag is serving"
wait_for_version "$tag" "$verify_timeout"

echo "$tag" >"$DEPLOY_DIR/current_tag"
if [ -n "$previous" ] && [ "$previous" != "$tag" ]; then echo "$previous" >"$DEPLOY_DIR/previous_tag"; fi
echo "$nginx_hash" >"$DEPLOY_DIR/nginx_template.sha256"
env_set API_TAG "$tag"
env_set APP_VERSION "$tag"
log "deployed $tag${previous:+ (previous: $previous)}"
