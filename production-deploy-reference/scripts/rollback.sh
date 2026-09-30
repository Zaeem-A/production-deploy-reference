#!/usr/bin/env bash
# Put a previous release back:  scripts/rollback.sh [tag]
# Without a tag it returns to the release before the current one. Only the API image changes; the
# database schema stays as it is (migrations are forward-only, see the note in deploy.sh).
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

current="$(cat "$DEPLOY_DIR/current_tag" 2>/dev/null || true)"
target="${1:-$(cat "$DEPLOY_DIR/previous_tag" 2>/dev/null || true)}"
[ -n "$target" ] || die "no previous release is recorded: pass a tag, rollback.sh <tag>"
[[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid tag '$target'"
[ "$target" != "$current" ] || die "$target is already the current release"

export API_TAG="$target" APP_VERSION="$target"
# The image is normally still on this host. Try the registry only when it is not.
compose pull --quiet api 2>/dev/null || true
compose up -d --wait --wait-timeout 120 --no-build --no-deps api
wait_for_version "$target" "${DEPLOY_VERIFY_TIMEOUT:-90}"

mkdir -p "$DEPLOY_DIR"
echo "$target" >"$DEPLOY_DIR/current_tag"
if [ -n "$current" ]; then echo "$current" >"$DEPLOY_DIR/previous_tag"; fi
env_set API_TAG "$target"
env_set APP_VERSION "$target"
log "rolled back${current:+ from $current} to $target"
