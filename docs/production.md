# NetBird 生产环境部署指南

## 部署策略

单机 EC2（4C8G）+ RDS PostgreSQL，docker-compose 部署，支持 20 台车。

Coturn 用 host network 保证 UDP 性能，后续扩展时拆到独立机器。

### 全局架构

```
┌──────────────────────────────────────────────────────────────────┐
│                      K8s 集群 (my-infra)                          │
│                                                                  │
│  ┌──────────┐     ┌─────────────┐     ┌────────────────────┐     │
│  │  Vault   │────▶│ cert-manager│────▶│ netbird-tls-secret │     │
│  │ PKI 引擎 │     │ (ClusterIssuer)   │ (自动续期 30d 前)    │     │
│  └──────────┘     └─────────────┘     └────────┬───────────┘     │
│                                                │                 │
│                                          cert-renew-cron.sh      │
│                                          (每周拉取 → EC2)         │
└────────────────────────────────────────────────┼─────────────────┘
                                                 │
                                                 ▼
┌──────────────────────────────────────────────────────────────────┐
│                  EC2 (t3.medium, EIP 绑定)                        │
│                                                                  │
│  /opt/netbird/                                                   │
│  ├── docker-compose.yaml          # 基础服务定义                  │
│  ├── docker-compose.prod.yaml     # 生产覆盖（Caddy+RDS+资源限制） │
│  ├── Caddyfile                    # Caddy 路由规则                │
│  ├── zitadel-config.yaml          # Zitadel IdP 配置              │
│  ├── management.json.example      # Management 配置模板            │
│  ├── auto-init.sh                 # OIDC 自动初始化                │
│  ├── turnserver.conf              # Coturn TURN/STUN              │
│  ├── .env                         # 环境变量（密钥/域名）          │
│  ├── certs/                       # TLS 证书                      │
│  ├── cert-renew-cron.sh           # 证书自动轮换                  │
│  └── /etc/systemd/system/netbird.service  # systemd 托管         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  docker compose 容器组                                    │    │
│  │  ┌──────────┐ ┌────────┐ ┌──────────┐ ┌────────────┐     │    │
│  │  │  Caddy   │ │ Signal │ │Dashboard │ │   Coturn   │     │    │
│  │  │ :443,80  │ │ :10000 │ │   :80    │ │:3478:5349  │     │    │
│  │  └────┬─────┘ └────────┘ └──────────┘ └────────────┘     │    │
│  │       │                                                   │    │
│  │  ┌────┴─────┐ ┌────────┐                                 │    │
│  │  │Management│ │Zitadel │  PostgreSQL → AWS RDS (外部)     │    │
│  │  │  :443    │ │  IdP   │                                 │    │
│  │  └──────────┘ └────────┘                                 │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  安全组: 80+443+10000/TCP, 3478+5349/UDP, 22/TCP(管理)          │
└──────────────────────────────────────────────────────────────────┘
```

## 部署步骤

### 1. 基础设施准备

```bash
# AWS CLI / 阿里云 CLI 创建资源
# EC2: t3.medium, 50GB GP3, Amazon Linux 2023 / Ubuntu 22.04
# EIP: 绑定到 EC2，用于 NetBird 域名解析
# RDS: PostgreSQL 15, db.t3.micro, 20GB, 多 AZ（可选）
# 安全组: TCP 22/80/443/10000, UDP 3478/5349/49152-49172
```

### 2. EC2 环境初始化

```bash
# 安装 Docker
sudo yum install -y docker       # Amazon Linux
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# 安装 docker compose (v2)
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 安装 kubectl（用于证书拉取）
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/
```

### 3. 部署 NetBird

```bash
sudo mkdir -p /opt/netbird && cd /opt/netbird
# 从 my-vpn/netbird/ 复制文件:
#   docker-compose.yaml, docker-compose.prod.yaml, Caddyfile
#   zitadel-config.yaml, management.json.example, auto-init.sh
#   turnserver.conf, cert-renew-cron.sh, netbird.service

# 配置环境变量
cp .env.example .env && chmod 600 .env
vim .env  # 填入实际值（见下方）

# 放置 TLS 证书到 ./certs/
# （kubectl 可用时: bash cert-export.sh）

# 启动
docker compose -f docker-compose.yaml -f docker-compose.prod.yaml up -d

# 等 Zitadel 初始化完成后自动配置
NETBIRD_PORT=443 ./auto-init.sh

# 安装 systemd
sudo cp netbird.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable netbird
```

### 4. 生产环境 .env 配置

```bash
NETBIRD_DOMAIN=netbird.yourcompany.com
NETBIRD_VERSION=0.72.1
ZITADEL_MASTERKEY=<openssl rand -base64 32 | head -c 32>
ZITADEL_ADMIN_PASSWORD=<含大小写+数字+符号，如 MyP@ssw0rd>
ZITADEL_EXTERNALPORT=443
NB_DATASTORE_ENCRYPTION_KEY=<openssl rand -base64 32>
POSTGRES_PASSWORD=<openssl rand -base64 24>
TURN_PASSWORD=<openssl rand -base64 32>
TURN_EXTERNAL_IP=<ECS公网IP>
NETBIRD_RDS_DSN=postgres://netbird:<PG_PASSWORD>@<RDS_ENDPOINT>:5432/netbird?sslmode=require
```

### 5. 验证

```bash
# 容器健康
docker compose -f docker-compose.yaml -f docker-compose.prod.yaml ps
# → 所有服务 Up (healthy)

# Dashboard
curl -I https://netbird.yourcompany.com

# API（需先登录 Dashboard 获取 token）
# 创建 Setup Key → 车端注册:
# netbird up --management-url https://netbird.yourcompany.com --setup-key <KEY>
# netbird status  # 确认 Connected + IP 分配
```

## 资源规格

| 组件 | 规格 | 说明 |
|------|------|------|
| EC2 | 4C8G, 50GB GP3 | EIP 绑定，Amazon Linux 2023 / Ubuntu 22.04 |
| RDS | PostgreSQL 15, db.t3.small, 20GB | 多 AZ 可选 |
| 安全组 | TCP 80/443/10000, UDP 3478/5349, TCP 22 | |

4C8G 跑 20 台车绰绰有余。Management + Signal 是轻量 Go 服务，1C 就够。

## 监控

```bash
# 容器资源
docker stats --no-stream

# EC2 层面: CloudWatch Agent
#   - CPU/Memory/Disk/Network
#   - 告警: CPU > 80% / 内存 > 85% / 磁盘 > 80%

# NetBird API 健康检查
#   - CloudWatch Synthetics Canary: GET https://netbird.xxx/api/status
#   - 告警: 连续 3 次失败 → PagerDuty

# 证书到期监控
#   - cert-renew-cron.sh 会检查 10 天内到期的证书
#   - 额外: CloudWatch Alarm 监控 cert-manager Certificate Ready 状态
```

## 灾难恢复

| 组件 | 备份策略 | RTO |
|------|---------|-----|
| PostgreSQL (RDS) | 自动每日快照 + Point-in-time Recovery | < 30 min |
| TLS 证书 | cert-manager 自动续期，Secret 在 etcd 中 | < 5 min |
| EC2 配置 | /opt/netbird/ 纳入 Git (不含 .env/certs/) | < 15 min |
| NetBird 数据 | `/var/lib/netbird` (management volume)，定期同步到 S3 | < 1 hour |
