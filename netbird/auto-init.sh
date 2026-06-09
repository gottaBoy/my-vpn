#!/bin/bash
# auto-init.sh — Complete Zitadel + NetBird bootstrap
# Run AFTER Zitadel FirstInstance completes.
# Supports both test (macOS with Caddy) and prod (ECS with Caddy) modes.
#
# Usage:
#   test:  ./auto-init.sh
#   prod:  NETBIRD_PORT=443 ./auto-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
PORT="${NETBIRD_PORT:-8443}"
MGMT_URL="https://${DOMAIN}:${PORT}"
# Strip :443 (standard HTTPS port is implicit, Zitadel issuer omits it)
MGMT_URL_NO_PORT="${MGMT_URL%:443}"
MACHINE_KEY_FILE="${SCRIPT_DIR}/machinekey/zitadel-admin-sa.token"
DASHBOARD_YAML="${SCRIPT_DIR}/docker-compose.test.yaml"

# Detect overlay file
COMPOSE_OVERLAY="docker-compose.test.yaml"
if [ -f "${SCRIPT_DIR}/docker-compose.prod.yaml" ] && [ "$PORT" = "443" ]; then
    COMPOSE_OVERLAY="docker-compose.prod.yaml"
fi

# --- Wait for Zitadel ---
echo "==> Waiting for Zitadel (checking every 5s, up to 200s)..."
for i in $(seq 1 40); do
    echo -n "  [$i/40] "
    if [ -f "$MACHINE_KEY_FILE" ] && [ -s "$MACHINE_KEY_FILE" ]; then
        MACHINE_KEY=$(cat "$MACHINE_KEY_FILE")
        CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
            -H "Authorization: Bearer ${MACHINE_KEY}" \
            "${MGMT_URL}/management/v1/projects/_search" -d '{}' 2>/dev/null || echo "000")
        [ "$CODE" = "200" ] && { echo " [OK] ready"; break; }
        echo "API returned $CODE, retrying..."
    else
        echo "waiting for machine key token..."
    fi
    [ "$i" = "40" ] && { echo "  [FAIL] Timeout"; exit 1; }
    sleep 5
done

API="curl -sk --max-time 10 -H 'Authorization: Bearer ${MACHINE_KEY}' -H 'Content-Type: application/json'"

# --- 1. Find or Create Project ---
echo "==> Looking up NetBird project..."
# List all projects and find NETBIRD
PROJECT_ID=$(eval "$API ${MGMT_URL}/management/v1/projects/_search" -d '{"query":{"offset":0,"limit":100,"asc":true}}' \
    | python3 -c "
import sys,json
r=json.load(sys.stdin)
for p in r.get('result',[]):
    if p.get('name','')=='NETBIRD':
        print(p['id'])
        break
" 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ]; then
    echo "==> Creating NetBird project..."
    PROJECT_ID=$(eval "$API ${MGMT_URL}/management/v1/projects" -d '{"name":"NETBIRD"}' \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'id' in d:
    print(d['id'])
else:
    # already exists — list and find
    import subprocess,os
    print('')
" 2>/dev/null || echo "")
    if [ -z "$PROJECT_ID" ]; then
        echo "  Project already exists, finding by list..."
        PROJECT_ID=$(eval "$API ${MGMT_URL}/management/v1/projects/_search" -d '{"query":{"offset":0,"limit":100}}' \
            | python3 -c "import sys,json;r=json.load(sys.stdin);print(next((p['id'] for p in r['result'] if p['name']=='NETBIRD'),''))")
    fi
fi
echo "  Project: $PROJECT_ID"

# --- 2. Create Dashboard OIDC App (WEB type) ---
echo "==> Creating Dashboard OIDC App (WEB)..."
DASHBOARD_CLIENT_ID=$(eval "$API ${MGMT_URL}/management/v1/projects/${PROJECT_ID}/apps/oidc -d '{
    \"name\":\"Dashboard\",
    \"redirectUris\":[\"${MGMT_URL}/nb-auth\",\"${MGMT_URL}/nb-silent-auth\"],
    \"postLogoutRedirectUris\":[\"${MGMT_URL}/\"],
    \"responseTypes\":[\"OIDC_RESPONSE_TYPE_CODE\"],
    \"grantTypes\":[\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",\"OIDC_GRANT_TYPE_REFRESH_TOKEN\"],
    \"appType\":\"OIDC_APP_TYPE_WEB\",
    \"authMethodType\":\"OIDC_AUTH_METHOD_TYPE_NONE\",
    \"version\":\"OIDC_VERSION_1_0\",
    \"devMode\":false,
    \"accessTokenType\":\"OIDC_TOKEN_TYPE_JWT\",
    \"accessTokenRoleAssertion\":true
}'" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
echo "  Dashboard ClientID: $DASHBOARD_CLIENT_ID"

# --- 3. Create CLI OIDC App (USER_AGENT type, for PKCE/device flow) ---
echo "==> Creating CLI OIDC App (USER_AGENT)..."
CLI_CLIENT_ID=$(eval "$API ${MGMT_URL}/management/v1/projects/${PROJECT_ID}/apps/oidc -d '{
    \"name\":\"Cli\",
    \"redirectUris\":[\"http://localhost:53000/\",\"http://localhost:54000/\"],
    \"postLogoutRedirectUris\":[\"http://localhost:53000/\"],
    \"responseTypes\":[\"OIDC_RESPONSE_TYPE_CODE\"],
    \"grantTypes\":[\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",\"OIDC_GRANT_TYPE_DEVICE_CODE\",\"OIDC_GRANT_TYPE_REFRESH_TOKEN\"],
    \"appType\":\"OIDC_APP_TYPE_USER_AGENT\",
    \"authMethodType\":\"OIDC_AUTH_METHOD_TYPE_NONE\",
    \"version\":\"OIDC_VERSION_1_0\",
    \"devMode\":true,
    \"accessTokenType\":\"OIDC_TOKEN_TYPE_JWT\",
    \"accessTokenRoleAssertion\":true,
    \"skipNativeAppSuccessPage\":true
}'" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
echo "  CLI ClientID: $CLI_CLIENT_ID"

# --- 4. Create Service Account (machine user) ---
echo "==> Creating service account..."
SA_USER_ID=$(eval "$API ${MGMT_URL}/management/v1/users/machine -d '{
    \"userName\":\"netbird-service-account\",
    \"name\":\"Netbird Service Account\",
    \"description\":\"Netbird Service Account for IDP management\",
    \"accessTokenType\":\"ACCESS_TOKEN_TYPE_JWT\"
}'" | python3 -c "import sys,json; print(json.load(sys.stdin)['userId'])")
echo "  SA UserID: $SA_USER_ID"

# --- 5. Generate SA client secret ---
echo "==> Generating SA secret..."
SECRET_RESP=$(eval "$API -X PUT ${MGMT_URL}/management/v1/users/${SA_USER_ID}/secret -d '{}'")
SA_CLIENT_ID=$(echo "$SECRET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
SA_CLIENT_SECRET=$(echo "$SECRET_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientSecret'])")
echo "  SA ClientID: $SA_CLIENT_ID"

# --- 6. Grant ORG_USER_MANAGER (org-level) ---
echo "==> Granting ORG_USER_MANAGER..."
ORG_ID=$(eval "$API ${MGMT_URL}/management/v1/orgs/me" | python3 -c "import sys,json; print(json.load(sys.stdin)['org']['id'])")
eval "$API ${MGMT_URL}/management/v1/orgs/${ORG_ID}/memberships -d '{\"userId\":\"${SA_USER_ID}\",\"roles\":[\"ORG_USER_MANAGER\"]}'" > /dev/null && echo "  OK"

# --- 7. Find admin + login-client IDs ---
ADMIN_ID=$(eval "$API ${MGMT_URL}/management/v1/users/_search -d '{}'" \
    | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin)['result'] if 'zitadel-admin@' in r.get('userName','')]")
LOGIN_ID=$(eval "$API ${MGMT_URL}/management/v1/users/_search -d '{}'" \
    | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin)['result'] if r.get('userName')=='login-client']")

# --- 8. Grant PROJECT_OWNER to admin + SA ---
echo "==> Granting PROJECT_OWNER..."
eval "$API ${MGMT_URL}/management/v1/projects/${PROJECT_ID}/members -d '{\"userId\":\"${ADMIN_ID}\",\"roles\":[\"PROJECT_OWNER\"]}'" > /dev/null && echo "  Admin: OK"
eval "$API ${MGMT_URL}/management/v1/projects/${PROJECT_ID}/members -d '{\"userId\":\"${SA_USER_ID}\",\"roles\":[\"PROJECT_OWNER\"]}'" > /dev/null && echo "  SA: OK"

# --- 9. Grant IAM_LOGIN_CLIENT to login-client ---
echo "==> Granting IAM_LOGIN_CLIENT..."
eval "$API ${MGMT_URL}/admin/v1/members -d '{\"userId\":\"${LOGIN_ID}\",\"roles\":[\"IAM_LOGIN_CLIENT\"]}'" > /dev/null && echo "  OK"

# --- 10. Regenerate login-client PAT ---
echo "==> Regenerating login-client PAT..."
eval "$API ${MGMT_URL}/management/v1/users/${LOGIN_ID}/pats -d '{\"name\":\"login\",\"expirationDate\":\"2030-12-31T23:59:59Z\"}'" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" > "${SCRIPT_DIR}/login-client.pat"
chmod 666 "${SCRIPT_DIR}/login-client.pat"
echo "  OK"

# --- 11. Update management.json ---
echo "==> Updating management.json..."
python3 -c "
import json
with open('${SCRIPT_DIR}/management.json') as f:
    c = json.load(f)

c['HttpConfig']['AuthAudience'] = '$DASHBOARD_CLIENT_ID'
c['HttpConfig']['AuthIssuer'] = '$MGMT_URL_NO_PORT'
c['HttpConfig']['OIDCConfigEndpoint'] = '$MGMT_URL_NO_PORT/.well-known/openid-configuration'
c['HttpConfig']['IdpSignKeyRefreshEnabled'] = True

# Preserve DataStoreEncryptionKey from env or existing config
import os
env_key = os.environ.get('NB_DATASTORE_ENCRYPTION_KEY', '')
if env_key:
    c['DataStoreEncryptionKey'] = env_key

# Signal URI from NETBIRD_DOMAIN
domain = os.environ.get('NETBIRD_DOMAIN', '${DOMAIN}')
if 'Signal' in c and domain:
    c['Signal']['Proto'] = 'http'
    c['Signal']['URI'] = domain + ':10000'

c['IdpManagerConfig']['ManagerType'] = 'zitadel'
c['IdpManagerConfig']['ClientConfig']['Issuer'] = '$MGMT_URL_NO_PORT'
c['IdpManagerConfig']['ClientConfig']['TokenEndpoint'] = '$MGMT_URL_NO_PORT/oauth/v2/token'
c['IdpManagerConfig']['ClientConfig']['ClientID'] = '$SA_CLIENT_ID'
c['IdpManagerConfig']['ClientConfig']['ClientSecret'] = '$SA_CLIENT_SECRET'
c['IdpManagerConfig']['ClientConfig']['GrantType'] = 'client_credentials'
c['IdpManagerConfig']['ExtraConfig'] = {'ManagementEndpoint': '$MGMT_URL_NO_PORT/management/v1'}

c['DeviceAuthorizationFlow']['Provider'] = 'hosted'
c['DeviceAuthorizationFlow']['ProviderConfig']['Audience'] = '$CLI_CLIENT_ID'
c['DeviceAuthorizationFlow']['ProviderConfig']['ClientID'] = '$CLI_CLIENT_ID'
c['DeviceAuthorizationFlow']['ProviderConfig']['Scope'] = 'openid'

c['PKCEAuthorizationFlow']['ProviderConfig']['Audience'] = '$CLI_CLIENT_ID'
c['PKCEAuthorizationFlow']['ProviderConfig']['ClientID'] = '$CLI_CLIENT_ID'
c['PKCEAuthorizationFlow']['ProviderConfig']['Scope'] = 'openid profile email offline_access'

with open('${SCRIPT_DIR}/management.json','w') as f:
    json.dump(c, f, indent=4); f.write('\n')
"

# --- 12. Update dashboard compose file env vars ---
echo "==> Updating ${COMPOSE_OVERLAY}..."
for var in AUTH_CLIENT_ID AUTH_AUDIENCE NEXT_PUBLIC_AUTH_CLIENT_ID NEXT_PUBLIC_AUTH_AUDIENCE; do
    if grep -q "${var}:" "${SCRIPT_DIR}/${COMPOSE_OVERLAY}" 2>/dev/null; then
        sed -i '' "s/${var}: '.*'/${var}: '${DASHBOARD_CLIENT_ID}'/" "${SCRIPT_DIR}/${COMPOSE_OVERLAY}" 2>/dev/null || \
        sed -i "s/${var}: '.*'/${var}: '${DASHBOARD_CLIENT_ID}'/" "${SCRIPT_DIR}/${COMPOSE_OVERLAY}"
    fi
done
echo "  OK"

# --- 13. Restart services ---
echo "==> Restarting..."
cd "$SCRIPT_DIR"
docker compose -f docker-compose.yaml -f "${COMPOSE_OVERLAY}" up -d --force-recreate management dashboard 2>&1 | tail -2
docker compose -f docker-compose.yaml -f "${COMPOSE_OVERLAY}" restart caddy zitadel-login 2>&1 | tail -1

echo ""
echo "============================================"
echo "  Dashboard ClientID: $DASHBOARD_CLIENT_ID"
echo "  CLI ClientID:       $CLI_CLIENT_ID"
echo "  SA ClientID:        $SA_CLIENT_ID"
echo "  Dashboard:          $MGMT_URL"
echo "  User:               zitadel-admin@${DOMAIN}"
echo "============================================"
