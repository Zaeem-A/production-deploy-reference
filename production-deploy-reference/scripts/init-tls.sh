#!/usr/bin/env bash
# Certificates for Nginx.
#   init-tls.sh selfsigned     placeholder certificate so Nginx can start (browsers will warn)
#   init-tls.sh letsencrypt    replace it with a real Let's Encrypt certificate
#
# Order on a new server: selfsigned -> deploy.sh -> letsencrypt. Nginx needs a certificate file to
# start, and Let's Encrypt needs Nginx running to answer its HTTP-01 challenge on port 80.
# LETSENCRYPT_STAGING=1 uses Let's Encrypt's staging CA, for rehearsing without rate limits.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

domain="$(setting APP_DOMAIN localhost)"
live="$LE_DIR/live/$domain"

selfsigned() {
  local san="DNS:${domain},DNS:localhost,IP:127.0.0.1"
  if [ "$domain" = localhost ]; then san="DNS:localhost,IP:127.0.0.1"; fi
  if [ -s "$live/fullchain.pem" ]; then
    log "a certificate for $domain already exists in $live; leaving it alone"
    return 0
  fi
  mkdir -p "$live"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=${domain}" \
    -addext "subjectAltName=${san}" \
    -keyout "$live/privkey.pem" -out "$live/fullchain.pem" 2>/dev/null
  chmod 600 "$live/privkey.pem"
  chmod 644 "$live/fullchain.pem"
  touch "$live/SELF_SIGNED"
  log "placeholder certificate for $domain written to $live (valid 30 days)"
}

letsencrypt() {
  local email stash="$LE_DIR/placeholder-$domain" args=()
  email="$(setting LETSENCRYPT_EMAIL "")"
  [ -n "$email" ] || die "set LETSENCRYPT_EMAIL in .env"
  [ "$domain" != localhost ] || die "APP_DOMAIN is localhost; Let's Encrypt needs a public hostname"
  [ ! -e "$LE_DIR/renewal/$domain.conf" ] ||
    die "a Let's Encrypt certificate for $domain already exists (renew-certs.sh renews it)"
  compose ps --status running --services | grep -qx nginx ||
    die "nginx is not running. Run scripts/deploy.sh first: it serves the challenge path on port 80."
  if [ -n "$(setting LETSENCRYPT_STAGING "")" ]; then args+=(--staging); fi

  # certbot refuses to create a certificate where a directory already exists, so park the
  # placeholder outside live/ and put it back if issuing fails (a restart must not break Nginx).
  rm -rf "$stash"
  if [ -d "$live" ]; then mv "$live" "$stash"; fi
  mkdir -p "$ROOT_DIR/data/certbot-www"
  if ! compose run --rm -T --no-deps --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot -d "$domain" --email "$email" \
    --agree-tos --no-eff-email --non-interactive "${args[@]}"; then
    log "certbot failed: check that $domain resolves to this server and port 80 is reachable"
    rm -rf "$live" "$LE_DIR/archive/$domain" "$LE_DIR/renewal/$domain.conf"
    if [ -d "$stash" ]; then mv "$stash" "$live"; fi
    exit 1
  fi
  rm -rf "$stash"
  compose exec -T nginx nginx -s reload
  log "certificate for $domain installed and Nginx reloaded"
}

case "${1:-}" in
  selfsigned) selfsigned ;;
  letsencrypt) letsencrypt ;;
  *)
    echo "usage: init-tls.sh selfsigned|letsencrypt" >&2
    exit 2
    ;;
esac
