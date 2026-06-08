#!/bin/bash
# 在有网络的机器上执行：pull → tag → push 到 Harbor
# 用法: HARBOR_REGISTRY=harbor.yourcompany.com ./sync-images.sh

set -e
HARBOR_REGISTRY=${HARBOR_REGISTRY:?请设置 HARBOR_REGISTRY}

# === 1. Pull ===
docker pull postgres:16-alpine
docker pull ghcr.io/zitadel/zitadel:latest
docker pull ghcr.io/zitadel/zitadel-login:latest
docker pull netbirdio/management:0.72.1
docker pull netbirdio/signal:0.72.1
docker pull coturn/coturn:4.6-alpine
docker pull netbirdio/dashboard:latest

# === 2. Tag ===
docker tag postgres:16-alpine                    ${HARBOR_REGISTRY}/library/postgres:16-alpine
docker tag ghcr.io/zitadel/zitadel:latest         ${HARBOR_REGISTRY}/library/zitadel:latest
docker tag ghcr.io/zitadel/zitadel-login:latest    ${HARBOR_REGISTRY}/library/zitadel-login:latest
docker tag netbirdio/management:0.72.1             ${HARBOR_REGISTRY}/library/management:0.72.1
docker tag netbirdio/signal:0.72.1                 ${HARBOR_REGISTRY}/library/signal:0.72.1
docker tag coturn/coturn:4.6-alpine                ${HARBOR_REGISTRY}/library/coturn:4.6-alpine
docker tag netbirdio/dashboard:latest              ${HARBOR_REGISTRY}/library/dashboard:latest

# === 3. Push ===
docker push ${HARBOR_REGISTRY}/library/postgres:16-alpine
docker push ${HARBOR_REGISTRY}/library/zitadel:latest
docker push ${HARBOR_REGISTRY}/library/zitadel-login:latest
docker push ${HARBOR_REGISTRY}/library/management:0.72.1
docker push ${HARBOR_REGISTRY}/library/signal:0.72.1
docker push ${HARBOR_REGISTRY}/library/coturn:4.6-alpine
docker push ${HARBOR_REGISTRY}/library/dashboard:latest

echo "=== 完成！记得更新 .env 中的 MY_*_IMAGE ==="