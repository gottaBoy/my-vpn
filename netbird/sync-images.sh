#!/bin/bash
# 在有网络的机器上执行：pull → tag → push 到 Harbor
# 用法: HARBOR_REGISTRY=harbor.yourcompany.com ./sync-images.sh
# 注意：pull 后会 rmi 清理，不残留 amd64 镜像影响本地 arm64 环境。

set -e
HARBOR_REGISTRY=${HARBOR_REGISTRY:?请设置 HARBOR_REGISTRY}

IMAGES=(
    "postgres:16-alpine                   ${HARBOR_REGISTRY}/library/postgres:16-alpine"
    "ghcr.io/zitadel/zitadel:latest        ${HARBOR_REGISTRY}/library/zitadel:latest"
    "ghcr.io/zitadel/zitadel-login:latest   ${HARBOR_REGISTRY}/library/zitadel-login:latest"
    "netbirdio/management:0.72.1            ${HARBOR_REGISTRY}/library/management:0.72.1"
    "netbirdio/signal:0.72.1                ${HARBOR_REGISTRY}/library/signal:0.72.1"
    "coturn/coturn:4.6-alpine               ${HARBOR_REGISTRY}/library/coturn:4.6-alpine"
    "netbirdio/dashboard:latest             ${HARBOR_REGISTRY}/library/dashboard:latest"
    "caddy:2-alpine                         ${HARBOR_REGISTRY}/library/caddy:2-alpine"
)

total=${#IMAGES[@]}
current=0
for entry in "${IMAGES[@]}"; do
    current=$((current + 1))
    read -r src dst <<< "$entry"
    echo -e "\n\033[1;36m[$current/$total]\033[0m \033[1;33m$src\033[0m → \033[1;32m$dst\033[0m"
    echo "  pull ..."
    # docker pull --platform linux/amd64 "$src"
    docker pull "$src"
    echo "  tag  ..."
    docker tag "$src" "$dst"
    echo "  push ..."
    docker push "$dst"
    echo "  clean ..."
    docker rmi "$src" "$dst" > /dev/null 2>&1
    echo -e "  \033[0;32m✓ done\033[0m"
done

echo -e "\n\033[1;32m=== 全部完成 ($total/$total) ===\033[0m"
echo "记得更新服务器 .env 中的 HARBOR_REGISTRY"