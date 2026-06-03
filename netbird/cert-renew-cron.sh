#!/usr/bin/env bash
# cert-renew-cron.sh — Cron-based TLS cert renewal for production NetBird.
# Runs weekly via cron. Pulls latest TLS cert from K8s Secret and restarts
# NetBird services if the cert has changed.
#
# Install:
#   sudo cp cert-renew-cron.sh /opt/netbird/
#   sudo crontab -e
#   0 3 * * 0  /opt/netbird/cert-renew-cron.sh >> /var/log/netbird-cert-renew.log 2>&1
#
# Prerequisites:
#   - kubectl configured with read access to fleet-platform/netbird-tls-secret
#   - docker compose installed
#   - /opt/netbird/certs/ directory exists

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/netbird}"
CERT_DIR="${COMPOSE_DIR}/certs"
SECRET_NAME="netbird-tls-secret"
SECRET_NS="fleet-platform"
COMPOSE_FILES="-f docker-compose.yaml -f docker-compose.prod.yaml"
CHECKSUM_FILE="${CERT_DIR}/.tls-checksum"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mkdir -p "$CERT_DIR"
cd "$COMPOSE_DIR"

# --- Pull current cert from K8s ---
log "Pulling TLS cert from K8s Secret ${SECRET_NS}/${SECRET_NAME}..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

kubectl get secret "$SECRET_NAME" -n "$SECRET_NS" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMP_DIR/tls.crt" 2>/dev/null || {
  log "ERROR: Failed to read Secret ${SECRET_NS}/${SECRET_NAME}. Check kubectl context."
  exit 1
}

kubectl get secret "$SECRET_NAME" -n "$SECRET_NS" \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$TMP_DIR/tls.key"

NEW_CHECKSUM=$(sha256sum "$TMP_DIR/tls.crt" | cut -d' ' -f1)
OLD_CHECKSUM=$(cat "$CHECKSUM_FILE" 2>/dev/null || echo "")

# --- Check if cert has changed ---
if [ "$NEW_CHECKSUM" = "$OLD_CHECKSUM" ] && [ -f "$CERT_DIR/tls.crt" ]; then
  log "Certificate unchanged, nothing to do."
  # Still verify expiry
  DAYS_LEFT=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -checkend 864000 2>/dev/null && echo "ok" || echo "expiring")
  if [ "$DAYS_LEFT" = "expiring" ]; then
    log "WARNING: Certificate expires within 10 days!"
  fi
  exit 0
fi

# --- Deploy new cert ---
log "Certificate changed, deploying..."
cp "$TMP_DIR/tls.crt" "$CERT_DIR/tls.crt"
cp "$TMP_DIR/tls.key" "$CERT_DIR/tls.key"
chmod 600 "$CERT_DIR/tls.key"
echo "$NEW_CHECKSUM" > "$CHECKSUM_FILE"

# Show cert details
openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject -dates 2>/dev/null | while read line; do
  log "  $line"
done

# --- Restart NetBird services that use TLS ---
log "Restarting NetBird services..."
docker compose $COMPOSE_FILES restart management signal coturn

# Wait for health
sleep 10
if docker compose $COMPOSE_FILES ps | grep -qE '(unhealthy|restarting)'; then
  log "ERROR: Some services are unhealthy after restart!"
  docker compose $COMPOSE_FILES ps
  exit 1
fi

log "Certificate renewal complete."
