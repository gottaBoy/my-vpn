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
├── docs/
│   └── production.md                # 生产部署指南（EC2 + RDS）
└── netbird/
    ├── docker-compose.yaml          # NetBird 基础服务定义
    ├── docker-compose.test.yaml     # macOS 测试覆盖（Caddy 反向代理，禁用 Coturn）
    ├── docker-compose.prod.yaml     # 生产覆盖（RDS、资源限制、健康检查）
    ├── Caddyfile                    # Caddy 反向代理路由规则（测试用）
    ├── zitadel-config.yaml          # Zitadel IdP 最小配置
    ├── turnserver.conf              # Coturn TURN/STUN 配置
    ├── cert-export.sh               # 首次证书导出（从 K8s Secret）
    ├── cert-renew-cron.sh           # 证书自动轮换（cron 脚本，生产用）
    ├── netbird.service              # systemd 单元（生产用）
    ├── .env.example                 # 环境变量模板
    └── certs/                       # (gitignored) 证书导出目录
```
    └── certs/                       # (gitignored) 证书导出目录
```

## 快速开始（macOS 最小化测试）

```bash
# 0. 一次性准备：域名解析
sudo sh -c 'echo "127.0.0.1 netbird.local" >> /etc/hosts'

# 1. 确保 my-infra PKI 平台已就绪
cd ../my-infra
make kind-up && make bootstrap && make test
# → netbird-tls-secret 已由 cert-manager 签发（含 netbird.local SAN）

# 2. 运行 NetBird 全栈测试
cd ../my-vpn
cp netbird/.env.example netbird/.env   # 默认即 netbird.local
make test
# → 自动完成: 证书导出 → 容器启动 → API 健康检查 → Dashboard 验证

# 3. 访问 Dashboard
open https://netbird.local
# 首次登录: netbird-admin / NetBirdAdmin123!

# 4. 查看状态
make cert-verify           # 证书详情（SANs、有效期）
make netbird-logs-test     # 实时日志
make netbird-down-test     # 停止
```

### 测试架构（macOS）

```
                    https://netbird.local:443
                           │
                    ┌──────┴──────┐
                    │    Caddy    │  ← TLS 终止（cert-manager 证书）
                    │  反向代理   │
                    └──────┬──────┘
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌──────────────┐
    │ Management │  │  Zitadel   │  │  Dashboard   │
    │   :443     │  │   :8080    │  │    :80       │
    └────────────┘  └────────────┘  └──────────────┘
           │
    ┌──────┴──────┐
    ▼             ▼
  Signal     PostgreSQL
  :10000       :5432

  Coturn: 禁用（macOS 无 host networking，不影响 API 测试）
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
