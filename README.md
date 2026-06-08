# my-vpn — 车云 VPN 管理

基于 **NetBird**（自托管）实现车云 WireGuard 全互联网络。单机 EC2（4C8G）部署，支持 20 台车。

## 为什么用 NetBird（替换 OpenVPN）

```
OpenVPN:  车端 ──加密──→ VPN 服务器 ──转发──→ ZLM 拉流     ← 所有流转发，服务器瓶颈
NetBird:  车端 ══WireGuard P2P══→ ZLM 拉流                 ← 直连，不经过服务器

用户侧播放: 一样的 ZLM → WebRTC → 浏览器
```

| | OpenVPN | NetBird P2P |
|------|:---:|:---:|
| 数据路径 | 车→服务器→ZLM | 车→ZLM 直连 |
| 服务器流量 | 全部视频流 | 仅信令（几 Kbps） |
| 加密 | 用户态 TLS，较重 | 内核态 WireGuard，极轻 |
| 弱网断线重连 | 秒级 | 毫秒级，无感 |
| 4G/5G 切换 | TCP 断开需重建 | UDP 无连接，IP 变即恢复 |
| 加解密开销 | ~15% CPU | ~4% CPU |

> **弱网稳定性**：WireGuard 基于 UDP + Noise 协议，无连接无握手开销。车端 4G/5G 切换时 IP 变化，NetBird 毫秒级恢复，OpenVPN 需要断开 TCP→重连→TLS 握手（3-10 秒），视频会卡。

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
│  │ Caddy    │  │ Signal │  │Dashboard │         │
│  │ :443,80  │  │:10000  │  │   :80    │         │
│  └────┬─────┘  └────────┘  └──────────┘         │
│       │                                          │
│  ┌────┴─────┐  ┌────────┐  ┌──────────┐         │
│  │Management│  │Zitadel │  │PostgreSQL│         │
│  │  :443    │  │ IdP    │  │  :5432   │         │
│  └──────────┘  └────────┘  └──────────┘         │
│                                                  │
│  Coturn (TURN/STUN) :3478, :5349 UDP             │
└──────────────────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
   ┌─────────────┐        ┌─────────────┐
   │ 车端 (VIN-1) │  ...   │ 车端 (VIN-N) │
   │ netbird agent│        │ netbird agent│
   │ 100.x.y.z   │        │ 100.x.y.z   │
   └─────────────┘        └─────────────┘
```

## 目录结构

```
my-vpn/
├── Makefile                         # VPN 全生命周期管理
├── README.md
├── docs/
│   └── production.md                # 生产部署指南（EC2 + RDS）
└── netbird/
    ├── docker-compose.yaml          # 基础服务定义
    ├── docker-compose.test.yaml     # macOS 测试覆盖（Caddy 反向代理）
    ├── docker-compose.prod.yaml     # 生产覆盖（Caddy + RDS + 资源限制）
    ├── Caddyfile                    # Caddy 路由规则
    ├── zitadel-config.yaml          # Zitadel IdP 配置
    ├── management.json.example      # Management 配置模板
    ├── auto-init.sh                 # Zitadel OIDC 自动初始化
    ├── init-zitadel.sh              # Zitadel 手动初始化（备用）
    ├── turnserver.conf              # Coturn TURN/STUN 配置
    ├── cert-export.sh               # 从 K8s Secret 导出 TLS 证书
    ├── cert-renew-cron.sh           # 证书自动轮换（cron）
    ├── netbird.service              # systemd 单元（生产用）
    ├── .env.example                 # 环境变量模板
    └── certs/                       # TLS 证书（gitignored）
```

## 快速开始（macOS 本地测试）

```bash
# 0. 一次性准备
sudo sh -c 'echo "127.0.0.1 netbird.local" >> /etc/hosts'

# 1. 启动 my-infra PKI（确保证书签发）
cd ../my-infra
make kind-up && make bootstrap && make test

# 2. 启动 NetBird 全栈 + 自动配置
cd ../my-vpn
cp netbird/.env.example netbird/.env
make test && cd netbird && ./auto-init.sh

# 3. 访问 Dashboard
open https://netbird.local:8443
# 登录: zitadel-admin@zitadel.netbird.local
# 密码: NetBirdAdmin123!（测试默认，生产务必更换）

# 4. 停止
make netbird-down-test
```

> **注意**：macOS 单机只能验证服务端全链路（OIDC 登录 → Dashboard → Setup Key → Peer 注册）。
> WireGuard P2P 隧道需要两台独立机器（macOS + ECS），见下方生产部署。

## 生产部署（ECS + RDS）

```bash
# === 1. 生成密钥 ===
ZITADEL_MASTERKEY=$(openssl rand -base64 32 | head -c 32)
ZITADEL_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9!@#$' | head -c 16)
NB_DATASTORE_ENCRYPTION_KEY=$(openssl rand -base64 32)
POSTGRES_PASSWORD=$(openssl rand -base64 24)
TURN_PASSWORD=$(openssl rand -base64 32)

# === 2. 写入 .env（chmod 600） ===
cat > netbird/.env << EOF
NETBIRD_DOMAIN=netbird.yourcompany.com
NETBIRD_VERSION=0.72.1
ZITADEL_MASTERKEY=${ZITADEL_MASTERKEY}
ZITADEL_ADMIN_PASSWORD=${ZITADEL_ADMIN_PASSWORD}
ZITADEL_EXTERNALPORT=443
NB_DATASTORE_ENCRYPTION_KEY=${NB_DATASTORE_ENCRYPTION_KEY}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
TURN_PASSWORD=${TURN_PASSWORD}
TURN_EXTERNAL_IP=<ECS公网IP>
NETBIRD_RDS_DSN=postgres://netbird:${POSTGRES_PASSWORD}@<RDS_ENDPOINT>:5432/netbird?sslmode=require
EOF
chmod 600 netbird/.env

# === 3. 放置 TLS 证书到 netbird/certs/ ===

# === 4. 一键启动 ===
cd netbird
docker compose -f docker-compose.yaml -f docker-compose.prod.yaml up -d

# === 5. 等 Zitadel 初始化后自动配置 ===
NETBIRD_PORT=443 ./auto-init.sh

# === 6. 访问 Dashboard ===
open https://netbird.yourcompany.com
```

详细步骤见 [docs/production.md](docs/production.md)。

## 产线集成

```bash
VIN=$(cat /etc/vehicle_vin)
SETUP_KEY="${NETBIRD_SETUP_KEY}"       # 从产线系统注入
MGMT_URL="https://netbird.internal"    # VPN 隧道内域名

sudo netbird up \
  --management-url "${MGMT_URL}" \
  --setup-key "${SETUP_KEY}" \
  --hostname "${VIN}"
```

## 证书管理

TLS 证书由 `my-infra` PKI 平台统一管理（cert-manager + Vault）。30d 自动续期，`cert-renew-cron.sh` 每周同步。

```
my-infra → Certificate: netbird-tls → Secret → cert-export.sh → netbird/certs/
```

设备入网使用 **Setup Key**，不需要 PKI 签发的 x.509 证书。PKI 只负责服务端 TLS。
