#!/usr/bin/env bash
# cert-export.sh — Pull the netbird TLS certificate from the K8s Secret
# (issued by cert-manager + Vault) into local ./certs/ for docker-compose.
#
# Prerequisites:
#   - kubectl configured for the cluster (kind-my-infra or cloud)
#   - netbird-tls-secret already provisioned (make test or kubectl apply -k pki/issuers)
#
# Usage:
#   cd my-vpn/netbird
#   bash cert-export.sh                     # pull from default context
#   bash cert-export.sh --context kind-my-infra
#   bash cert-export.sh --namespace fleet-platform --secret netbird-tls-secret

set -euo pipefail

CONTEXT="${CONTEXT:-}"
NAMESPACE="${NAMESPACE:-fleet-platform}"
SECRET="${SECRET:-netbird-tls-secret}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)   CONTEXT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --secret)    SECRET="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

KCTL="kubectl"
[[ -n "$CONTEXT" ]] && KCTL="kubectl --context $CONTEXT"

echo "==> Exporting TLS cert from Secret ${NAMESPACE}/${SECRET}"
mkdir -p "$OUT_DIR"

# Verify the Secret exists and has the expected keys
if ! $KCTL get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Secret ${NAMESPACE}/${SECRET} not found."
  echo "Run 'kubectl apply -k my-infra/pki/issuers' or 'make test' first."
  exit 1
fi

# cert-manager stores: tls.crt (full chain), tls.key (private key), ca.crt (optional)
$KCTL get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$OUT_DIR/tls.crt"
$KCTL get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$OUT_DIR/tls.key"

# ca.crt is included in tls.crt by cert-manager when the issuer provides the chain,
# but extract separately if present (useful for client mTLS trust).
if $KCTL get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.ca\.crt}' >/dev/null 2>&1; then
  $KCTL get secret "$SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUT_DIR/ca.crt"
  echo "  ca.crt extracted"
fi

chmod 600 "$OUT_DIR/tls.key"

echo "  tls.crt  ($(wc -c < "$OUT_DIR/tls.crt") bytes)"
echo "  tls.key  ($(wc -c < "$OUT_DIR/tls.key") bytes)"
echo
echo "==> Certificate details:"
openssl x509 -in "$OUT_DIR/tls.crt" -noout -subject -issuer -dates 2>/dev/null || true
echo
echo "==> Done. Run: docker compose up -d"
