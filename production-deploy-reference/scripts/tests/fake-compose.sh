#!/usr/bin/env bash
# Stand-in for `docker compose`, used through COMPOSE=... by test-deploy-flow.sh.
# It records every call and pretends to run the stack. State lives in $FAKE_DIR:
#   calls.log   one line per call: "API_TAG=<tag> <arguments>"
#   db_running  exists once the database has been "started"
#   api_tag     the release the "API container" is running (read by fake-server.py)
# Failure injection: FAKE_FAIL_PULL=1, FAKE_FAIL_MIGRATE=1, FAKE_FAIL_DUMP=1,
# FAKE_FAIL_UP_TAG=<tag> (starting that release fails, but it is left running like a real
# unhealthy container), FAKE_IGNORE_TAG=<tag> (starting that release "succeeds" without taking effect).
set -u
dir="${FAKE_DIR:?FAKE_DIR must be set}"
mkdir -p "$dir"
args="$*"
echo "API_TAG=${API_TAG:-} ${args}" >>"$dir/calls.log"

case "$1" in
  pull | build)
    [ "${FAKE_FAIL_PULL:-0}" = 1 ] && exit 1
    ;;
  ps)
    [ -e "$dir/db_running" ] && echo db
    ;;
  run)
    [ "${FAKE_FAIL_MIGRATE:-0}" = 1 ] && exit 1
    ;;
  up)
    case "$args" in
      *" db")
        touch "$dir/db_running"
        ;;
      *)
        if [ "${FAKE_IGNORE_TAG:-}" != "${API_TAG:-}" ]; then echo "${API_TAG:-}" >"$dir/api_tag"; fi
        if [ -n "${FAKE_FAIL_UP_TAG:-}" ] && [ "${FAKE_FAIL_UP_TAG}" = "${API_TAG:-}" ]; then exit 1; fi
        ;;
    esac
    ;;
  exec)
    case "$args" in
      *pg_dump*)
        [ "${FAKE_FAIL_DUMP:-0}" = 1 ] && exit 1
        echo "fake dump"
        ;;
      *pg_restore*)
        cat >/dev/null
        ;;
    esac
    ;;
esac
exit 0
