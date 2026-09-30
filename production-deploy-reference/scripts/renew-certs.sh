#!/usr/bin/env bash
# Renew certificates that are close to expiry, reload Nginx, and publish the expiry date as a
# metric (the CertExpiringSoon alert watches it). Run daily from cron; see docs/RUNBOOK.md.
set -Eeuo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

domain="$(setting APP_DOMAIN localhost)"
cert="$LE_DIR/live/$domain/fullchain.pem"

if [ -e "$LE_DIR/live/$domain/SELF_SIGNED" ]; then
  log "placeholder certificate in use; run scripts/init-tls.sh letsencrypt for a real one"
else
  compose run --rm -T --no-deps --entrypoint certbot certbot renew \
    --webroot -w /var/www/certbot --quiet
  compose exec -T nginx nginx -s reload
fi

[ -s "$cert" ] || die "no certificate at $cert"
not_after="$(openssl x509 -noout -enddate -in "$cert" | cut -d= -f2)"
write_metric tls <<EOF
# HELP tls_cert_not_after_timestamp_seconds Unix time at which the served certificate expires.
# TYPE tls_cert_not_after_timestamp_seconds gauge
tls_cert_not_after_timestamp_seconds{domain="${domain}"} $(date -d "$not_after" +%s)
EOF
log "certificate for $domain expires $not_after"
