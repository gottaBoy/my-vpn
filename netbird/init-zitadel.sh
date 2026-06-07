#!/bin/bash
# Zitadel OIDC 初始化脚本
# 在 Zitadel 中创建 NetBird 所需的 OIDC 应用和服务账号
# 并生成 management.json 中的 IdpManagerConfig
#
# 前置条件：
#   1. Zitadel 容器已启动并完成初始化
#   2. PAT 文件已生成: ./machinekey/zitadel-admin-sa.token
#
# 用法：
#   cd my-vpn/netbird
#   bash init-zitadel.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- 配置 ---
ZITADEL_URL="${ZITADEL_URL:-https://${NETBIRD_DOMAIN:-netbird.local}:8443}"
PAT_FILE="${PAT_FILE:-./machinekey/zitadel-admin-sa.token}"
PROJECT_NAME="NETBIRD"
DASHBOARD_APP_NAME="Dashboard"
CLI_APP_NAME="Cli"
SERVICE_USER_NAME="netbird-service-account"

# redirect URIs
DASHBOARD_REDIRECT="${ZITADEL_URL}/nb-auth"
DASHBOARD_SILENT_REDIRECT="${ZITADEL_URL}/nb-silent-auth"
DASHBOARD_LOGOUT="${ZITADEL_URL}/"
CLI_REDIRECT1="http://localhost:53000/"
CLI_REDIRECT2="http://localhost:54000/"

# --- 工具函数 ---
check_deps() {
  for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
      echo "ERROR: $cmd is required. Please install it first." >&2
      exit 1
    fi
  done
}

handle_error() {
  local func_name=$1
  local response=$2
  local parsed=$3
  if [[ "$parsed" == "null" || -z "$parsed" ]]; then
    echo "ERROR calling $func_name: $(echo "$response" | jq -r '.message // "unknown error"')" >&2
    exit 1
  fi
}

# --- 1. 读取 PAT ---
get_admin_token() {
  echo ">>> Reading admin PAT from ${PAT_FILE}..."
  
  if [ ! -f "$PAT_FILE" ]; then
    echo "ERROR: PAT file not found: ${PAT_FILE}" >&2
    echo "Make sure Zitadel is running and has generated the admin token." >&2
    exit 1
  fi

  ADMIN_TOKEN=$(cat "$PAT_FILE" | tr -d '\n\r')
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "ERROR: PAT file is empty" >&2
    exit 1
  fi
  echo "  PAT loaded successfully."
}

# --- 2. 创建项目 ---
create_project() {
  echo ">>> Creating project '${PROJECT_NAME}'..."
  
  # Check if project already exists
  local existing
  existing=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/projects/_search" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"query":{"offset":"0","limit":100,"asc":true},"queries":[{"nameQuery":{"name":"'"${PROJECT_NAME}"'","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
  
  PROJECT_ID=$(echo "$existing" | jq -r '.result[0].id // empty')
  
  if [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "null" ]]; then
    echo "  Project already exists: ${PROJECT_ID}"
    return
  fi

  local resp
  resp=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/projects" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"'"${PROJECT_NAME}"'"}')
  
  PROJECT_ID=$(echo "$resp" | jq -r '.id')
  handle_error "create_project" "$resp" "$PROJECT_ID"
  echo "  Project created: ${PROJECT_ID}"
}

# --- 3. 创建 OIDC 应用 ---
create_oidc_app() {
  local app_name=$1
  local redirect_uri1=$2
  local redirect_uri2=$3
  local logout_uri=$4
  local dev_mode=$5
  local device_code=$6

  echo ">>> Creating OIDC app '${app_name}'..."

  local grant_types
  if [[ "$device_code" == "true" ]]; then
    grant_types='["OIDC_GRANT_TYPE_AUTHORIZATION_CODE","OIDC_GRANT_TYPE_DEVICE_CODE","OIDC_GRANT_TYPE_REFRESH_TOKEN"]'
  else
    grant_types='["OIDC_GRANT_TYPE_AUTHORIZATION_CODE","OIDC_GRANT_TYPE_REFRESH_TOKEN"]'
  fi

  # Check if app already exists
  local existing
  existing=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/projects/${PROJECT_ID}/apps/_search" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"query":{"offset":"0","limit":100},"queries":[{"nameQuery":{"name":"'"${app_name}"'","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
  
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.result[0].id // empty')
  
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    echo "  App already exists: ${existing_id}"
    echo "$existing_id"
    return
  fi

  local resp
  resp=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/projects/${PROJECT_ID}/apps/oidc" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "'"${app_name}"'",
      "redirectUris": ["'"${redirect_uri1}"'","'"${redirect_uri2}"'"],
      "postLogoutRedirectUris": ["'"${logout_uri}"'"],
      "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
      "grantTypes": '"${grant_types}"',
      "appType": "OIDC_APP_TYPE_USER_AGENT",
      "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
      "version": "OIDC_VERSION_1_0",
      "devMode": '"${dev_mode}"',
      "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
      "accessTokenRoleAssertion": true,
      "skipNativeAppSuccessPage": true
    }')

  local app_id
  app_id=$(echo "$resp" | jq -r '.clientId')
  handle_error "create_oidc_app (${app_name})" "$resp" "$app_id"
  echo "  App created: ${app_id}"
  echo "$app_id"
}

# --- 4. 创建服务账号 (machine user) ---
create_service_user() {
  echo ">>> Creating service user '${SERVICE_USER_NAME}'..."

  # Check if already exists
  local existing
  existing=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/users/_search" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"queries":[{"userNameQuery":{"userName":"'"${SERVICE_USER_NAME}"'","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
  
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.result[0].id // empty')
  
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    echo "  Service user already exists: ${existing_id}"
    echo "$existing_id"
    return
  fi

  local resp
  resp=$(curl -sk -X POST "${ZITADEL_URL}/management/v1/users/machine" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "userName": "'"${SERVICE_USER_NAME}"'",
      "name": "Netbird Service Account",
      "description": "Netbird Service Account for IDP management",
      "accessTokenType": "ACCESS_TOKEN_TYPE_JWT"
    }')
  
  SERVICE_USER_ID=$(echo "$resp" | jq -r '.userId')
  handle_error "create_service_user" "$resp" "$SERVICE_USER_ID"
  echo "  Service user created: ${SERVICE_USER_ID}"
  echo "$SERVICE_USER_ID"
}

# --- 5. 生成服务账号 secret ---
create_service_user_secret() {
  local user_id=$1
  echo ">>> Generating secret for service user..."

  local resp
  resp=$(curl -sk -X PUT "${ZITADEL_URL}/management/v1/users/${user_id}/secret" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json")
  
  CLIENT_ID=$(echo "$resp" | jq -r '.clientId')
  CLIENT_SECRET=$(echo "$resp" | jq -r '.clientSecret')
  handle_error "create_service_user_secret" "$resp" "$CLIENT_ID"
  echo "  Client ID: ${CLIENT_ID}"
}

# --- 6. 授予 Org User Manager 权限 ---
grant_org_permissions() {
  local user_id=$1
  echo ">>> Granting ORG_USER_MANAGER permission..."

  # Get organization ID
  local org_resp
  org_resp=$(curl -sk "${ZITADEL_URL}/management/v1/orgs/me" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")
  ORG_ID=$(echo "$org_resp" | jq -r '.org.id')
  
  if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
    echo "WARNING: Could not determine org ID, skipping permission grant"
    return
  fi

  curl -sk -X POST "${ZITADEL_URL}/management/v1/orgs/${ORG_ID}/memberships" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "userId": "'"${user_id}"'",
      "roles": ["ORG_USER_MANAGER"]
    }' > /dev/null
  
  echo "  Permission granted."
}

# --- 7. 生成 management.json IdpManagerConfig ---
generate_management_json() {
  local dashboard_client_id=$1
  local cli_client_id=$2
  local mgmt_client_id=$3
  local mgmt_client_secret=$4

  echo ">>> Generating management.json IdpManagerConfig..."

  # Use the base URL from ZITADEL_URL (strip port for issuer)
  local base_url="${ZITADEL_URL%:*}"
  if [[ "$base_url" == *":8443" ]]; then
    base_url="${base_url%:*}"
  fi
  # Reconstruct with https://HOST:8443 for test, or just https://HOST for prod
  local issuer_url="${ZITADEL_URL}"

  cat > management.json <<EOF
{
    "DataStoreEncryptionKey": "LXqg45oj5CD/zGjbbuAfDhfNUzWLAU1KxyunAayFmY4=",
    "HttpConfig": {
        "Address": "0.0.0.0:443",
        "LetsEncryptDomain": "",
        "CertFile": "/etc/netbird/tls.crt",
        "CertKey": "/etc/netbird/tls.key",
        "AuthIssuer": "${issuer_url}",
        "AuthAudience": "${dashboard_client_id}",
        "OIDCConfigEndpoint": "${issuer_url}/.well-known/openid-configuration"
    },
    "IdpManagerConfig": {
        "ManagerType": "zitadel",
        "ClientConfig": {
            "Issuer": "${issuer_url}",
            "TokenEndpoint": "${issuer_url}/oauth/v2/token",
            "ClientID": "${mgmt_client_id}",
            "ClientSecret": "${mgmt_client_secret}",
            "GrantType": "client_credentials"
        },
        "ExtraConfig": {
            "ManagementEndpoint": "${issuer_url}/management/v1"
        }
    },
    "DeviceAuthorizationFlow": {
        "Provider": "hosted",
        "ProviderConfig": {
            "Audience": "${cli_client_id}",
            "ClientID": "${cli_client_id}",
            "Scope": "openid"
        }
    },
    "PKCEAuthorizationFlow": {
        "ProviderConfig": {
            "Audience": "${cli_client_id}",
            "ClientID": "${cli_client_id}",
            "Scope": "openid profile email offline_access",
            "RedirectURLs": ["http://localhost:53000/", "http://localhost:54000/"]
        }
    },
    "StoreConfig": {
        "Engine": "postgres"
    }
}
EOF
  echo "  management.json updated."
}

# --- 主流程 ---
main() {
  check_deps
  echo "=== Zitadel OIDC 初始化 ==="
  echo "Zitadel URL: ${ZITADEL_URL}"
  echo ""

  get_admin_token
  create_project
  DASHBOARD_CLIENT_ID=$(create_oidc_app "${DASHBOARD_APP_NAME}" "${DASHBOARD_REDIRECT}" "${DASHBOARD_SILENT_REDIRECT}" "${DASHBOARD_LOGOUT}" "false" "false")
  CLI_CLIENT_ID=$(create_oidc_app "${CLI_APP_NAME}" "${CLI_REDIRECT1}" "${CLI_REDIRECT2}" "http://localhost:53000/" "true" "true")
  SVC_USER_ID=$(create_service_user)
  create_service_user_secret "${SVC_USER_ID}"
  grant_org_permissions "${SVC_USER_ID}"

  generate_management_json "${DASHBOARD_CLIENT_ID}" "${CLI_CLIENT_ID}" "${CLIENT_ID}" "${CLIENT_SECRET}"

  echo ""
  echo "=== 初始化完成 ==="
  echo "Dashboard Client ID: ${DASHBOARD_CLIENT_ID}"
  echo "CLI Client ID:      ${CLI_CLIENT_ID}"
  echo "Management Client:  ${CLIENT_ID}"
  echo ""
  echo "Next: restart management and dashboard containers:"
  echo "  docker compose -f docker-compose.yaml -f docker-compose.test.yaml restart management dashboard"
}

main "$@"
