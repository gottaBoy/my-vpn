# NetBird 生产环境部署指南

## 部署决策：EC2 + docker-compose，而非 K8s Operator

### 核心原因

NetBird 的关键组件 **Coturn（TURN/STUN 中继）** 需要：
- **Host 网络模式**：UDP 端口范围 49152-49172，K8s 中需绕过 CNI 使用 `hostNetwork: true`
- **客户端真实源 IP**：TURN 协议依赖源 IP，K8s Service 默认做 SNAT
- **低延迟 UDP 转发**：每增加一跳都会增加延迟

将这些放到 K8s 中会引入不必要的复杂度，而 NetBird 本质上是一个 **6 容器的单体应用**，不需要 K8s 的编排能力。

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
│  ├── docker-compose.prod.yaml     # 生产覆盖（RDS/资源限制）       │
│  ├── .env                         # 环境变量（密钥/域名）          │
│  ├── certs/                       # TLS 证书（cert-export.sh →）  │
│  ├── cert-renew-cron.sh           # 证书自动轮换脚本              │
│  └── /etc/systemd/system/netbird.service  # systemd 托管         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  docker compose 容器组                                    │    │
│  │  ┌──────────┐ ┌────────┐ ┌──────────┐ ┌────────────┐     │    │
│  │  │Management│ │ Signal │ │Dashboard │ │   Coturn   │     │    │
│  │  │  :443    │ │ :10000 │ │   :80    │ │:3478:5349  │     │    │
│  │  │  TLS ✅  │ │ TLS ✅ │ │          │ │ UDP ✅     │     │    │
│  │  └──────────┘ └────────┘ └──────────┘ └────────────┘     │    │
│  │  ┌──────────┐                                             │    │
│  │  │ Zitadel  │  PostgreSQL → AWS RDS (外部)                 │    │
│  │  │  IdP     │                                             │    │
│  │  └──────────┘                                             │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  安全组: 443+10000/TCP, 3478+5349/UDP, 22/TCP(管理)              │
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
# 克隆 / 同步部署文件
sudo mkdir -p /opt/netbird
cd /opt/netbird
# 从 my-vpn/netbird/ 复制文件:
#   docker-compose.yaml, docker-compose.prod.yaml
#   zitadel-config.yaml, turnserver.conf
#   cert-renew-cron.sh, netbird.service

# 配置环境变量
cp .env.example .env
vim .env  # 填入实际值（见下方）

# 首次拉取 TLS 证书
bash cert-export.sh

# 安装 systemd 并启动
sudo cp netbird.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now netbird
sudo systemctl status netbird

# 安装证书自动轮换 cron
sudo crontab -e
# 添加: 0 3 * * 0  /opt/netbird/cert-renew-cron.sh >> /var/log/netbird-cert-renew.log 2>&1
```

### 4. 生产环境 .env 配置

```bash
# === 必填 ===
NETBIRD_DOMAIN=netbird.yourcompany.com       # 公网域名，已有 SSL
NETBIRD_RDS_DSN=postgres://netbird:${PG_PASSWORD}@${RDS_ENDPOINT}:5432/netbird?sslmode=require

# === 安全（生成方式: openssl rand -base64 32） ===
TURN_PASSWORD=<random-32-bytes>
POSTGRES_PASSWORD=<random-32-bytes>
ZITADEL_MASTERKEY=<random-32-bytes>
ZITADEL_ADMIN_PASSWORD=<random-16-chars>

# === 网络 ===
TURN_EXTERNAL_IP=<EC2_EIP>                  # EC2 公网 IP

# === 证书路径（cert-renew-cron.sh 自动维护） ===
# certs/tls.crt, certs/tls.key
```

### 5. 验证

```bash
# 容器健康
sudo systemctl status netbird
docker compose -f /opt/netbird/docker-compose.yaml \
  -f /opt/netbird/docker-compose.prod.yaml ps

# API 健康
curl -k https://netbird.yourcompany.com/api/status
# → {"status":"ok","version":"..."}

# Dashboard 可访问
curl -I https://netbird.yourcompany.com

# 证书信息
openssl s_client -connect netbird.yourcompany.com:443 -servername netbird.yourcompany.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# 创建 Setup Key + 车端注册测试
# 1. Dashboard → Setup Keys → Create Reusable Key
# 2. 车端: netbird up --management-url https://netbird.yourcompany.com --setup-key <KEY>
# 3. netbird status 确认 IP 分配 + 点对点连通
```

## 容量规划

| 规模 | EC2 规格 | RDS 规格 | 预计成本/月 |
|------|---------|---------|-----------|
| 测试 (< 50 车) | t3.small | db.t3.micro | ~$50 |
| 中型 (50-500 车) | t3.medium | db.t3.small | ~$120 |
| 大型 (500-2000 车) | c5.xlarge | db.t3.medium | ~$300 |
| 超大规模 (2000+) | c5.2xlarge, 多实例 | db.r5.large + 读写分离 | ~$600+ |

> NetBird Management 和 Signal 的瓶颈在内存和并发连接数，Coturn 瓶颈在 UDP 转发带宽。
> 1000 台车 × 遥测 10s 间隔 ≈ 100 msg/s，t3.medium 完全够用。

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
