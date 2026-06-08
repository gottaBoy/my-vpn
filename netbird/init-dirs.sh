#!/bin/bash
# ================================================================
# init-dirs.sh — 初始化目录/文件权限，解决 git clone 后常见问题
# 在 docker compose up 之前运行一次即可。
# ================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> 初始化 NetBird 运行目录 ..."

# ── 1. machinekey/：Zitadel 写 token 文件，须可写 ──
if [ ! -d machinekey ]; then
    echo "  mkdir  machinekey/"
    mkdir -p machinekey
fi
chmod 777 machinekey
echo "  [OK] machinekey/ (777)"

# ── 2. login-client.pat：Zitadel 读/写 PAT 文件 ──
if [ -d login-client.pat ]; then
    echo "  rm -rf login-client.pat (was directory)"
    rm -rf login-client.pat
fi
if [ ! -f login-client.pat ]; then
    touch login-client.pat
fi
chmod 666 login-client.pat
echo "  [OK] login-client.pat (666)"

# ── 3. certs/：TLS 证书目录 ──
mkdir -p certs
for f in tls.crt tls.key; do
    path="certs/$f"
    if [ -d "$path" ]; then
        echo "  rm -rf $path (was directory)"
        rm -rf "$path"
    fi
done
if [ -f certs/tls.crt ] && [ -s certs/tls.crt ]; then
    echo "  [OK] certs/tls.crt (exists)"
else
    echo "  [WARN] certs/tls.crt 不存在或为空 — 请放入 TLS 证书"
fi
if [ -f certs/tls.key ] && [ -s certs/tls.key ]; then
    chmod 600 certs/tls.key
    echo "  [OK] certs/tls.key (exists, 600)"
else
    echo "  [WARN] certs/tls.key 不存在或为空 — 请放入 TLS 私钥"
fi

# ── 4. management.json：Management 配置文件，由 auto-init.sh 生成 ──
if [ -d management.json ]; then
    echo "  rm -rf management.json (was directory)"
    rm -rf management.json
fi
if [ -f management.json ] && [ -s management.json ]; then
    echo "  [OK] management.json (exists)"
else
    echo "  [OK]  management.json 稍后由 auto-init.sh 生成"
fi

echo ""
echo "=== 初始化完成 ==="
echo "下一步："
echo "  1. 确保证书已放入 certs/"
echo "  2. docker compose -f docker-compose.yaml -f docker-compose.prod.yaml up -d"
echo "  3. NETBIRD_PORT=443 ./auto-init.sh"
