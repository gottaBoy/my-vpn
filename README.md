# my-vpn — 车云 VPN 管理

基于 **NetBird**（自托管）实现 1000+ L4 车辆的车云 WireGuard 全互联网络。

## 架构

```
┌──────────────────────────────────────────────────┐
│                  my-infra (PKI)                   │
│  cert-manager + Vault → netbird-tls-secret       │
│                     │                            │
│               cert-export.sh                     │
│                     ▼                            │
└──────────────────────────────────────────────────┘
                      │
┌──────────────────────────────────────────────────┐
│                  my-vpn (NetBird)                 │
│                                                  │
│  ┌──────────┐  ┌────────┐  ┌──────────┐         │
│  │Management│  │ Signal │  │ Dashboard│         │
│  │  :443    │  │:10000  │  │  :80     │         │
│  └──────────┘  └────────┘  └──────────┘         │
│  ┌──────────┐  ┌────────┐  ┌──────────┐         │
│  │ Coturn   │  │Zitadel │  │PostgreSQL│         │
│  │  :3478   │  │  IdP   │  │          │         │
│  └──────────┘  └────────┘  └──────────┘         │
│                                                  │
│  TLS certs ← cert-manager (auto-renew 30d)       │
└──────────────────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
   ┌─────────────┐        ┌─────────────┐
   │ 车端 (VIN-1) │  ...   │ 车端 (VIN-N) │
   │ netbird agent│        │ netbird agent│
   │ 10.99.0.x   │        │ 10.99.0.y   │
   └─────────────┘        └─────────────┘
```

## 目录结构

```
my-vpn/
├── Makefile                         # VPN 全生命周期管理
└── netbird/
    ├── docker-compose.yaml          # NetBird 自托管（Management+Signal+Coturn+Dashboard+Zitadel+PG）
    ├── zitadel-config.yaml          # Zitadel IdP 最小配置
    ├── turnserver.conf              # Coturn TURN/STUN 配置
    ├── cert-export.sh               # 从 K8s Secret 导出 TLS 证书到 ./certs/
    ├── .env.example                 # 环境变量模板
    └── certs/                       # (gitignored) 证书导出目录
```

## 快速开始（本地 kind 测试）

```bash
# 1. 确保 PKI 平台已就绪
cd ../my-infra
make kind-up && make bootstrap && make test
# → netbird-tls-secret 已由 cert-manager 签发

# 2. 导出证书 + 启动 NetBird
cd ../my-vpn
cp netbird/.env.example netbird/.env
# 编辑 netbird/.env 按需修改（本地测试保持默认即可）

make netbird-up
# → 证书自动从 K8s 导出 → docker compose 启动所有服务

# 3. 验证
make netbird-status          # API 健康检查
make cert-verify             # 查看证书信息
docker compose -f netbird/docker-compose.yaml ps   # 所有容器状态

# 4. 访问 Dashboard
open http://localhost
# 首次登录用 Zitadel 账号: netbird-admin / NetBirdAdmin123!
```

## 证书集成说明

NetBird 的 TLS 证书由 `my-infra` PKI 平台统一管理：

```
my-infra/pki/issuers/certificates.yaml
  └── Certificate: netbird-tls
      ├── issuerRef: vault-fleet-issuer (ClusterIssuer → Vault PKI)
      ├── secretName: netbird-tls-secret
      └── dnsNames: netbird.internal, netbird.fleet-platform.svc.cluster.local

cert-manager 自动续期（renewBefore: 30d）
  → Secret 热更新
  → cert-export.sh 重新执行即可拉取新证书
  → docker compose restart 生效
```

**为什么不用设备 x.509 证书？**
- NetBird 的 WireGuard 隧道使用 Curve25519 密钥对（客户端自动生成）
- 设备入网使用 **Setup Key**（一次性注册令牌），不需要 PKI 签发
- PKI 只负责 NetBird 服务端的 TLS 加密（API/Dashboard/Signal）

## 产线集成

设备注册时，VPN 入网作为并行步骤之一：

```bash
# 车端 init-agent 中的 VPN 步骤
VIN=$(cat /etc/vehicle_vin)
SETUP_KEY="${NETBIRD_SETUP_KEY}"       # 从产线系统注入
MGMT_URL="https://netbird.internal"    # VPN 隧道内域名

sudo netbird up \
  --management-url "${MGMT_URL}" \
  --setup-key "${SETUP_KEY}" \
  --hostname "${VIN}"                  # 用 VIN 作为节点名
```

Setup Key 通过 Dashboard 或 API 创建（`make setup-key-create`）。
