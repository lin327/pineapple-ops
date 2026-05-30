#!/bin/bash
# ==============================================================================
# Pineapple Ops - 堡垒机初始化脚本
# ==============================================================================
# 给火山云那台堡垒机用的，装 Docker + Next-Terminal。
# 堡垒机比较敏感，只允许通过 Tailscale 内网访问，公网不开放任何端口。
#
# 前置条件: 先跑 int.sh 完成基础初始化
# 用法: sudo bash int-bastion.sh
# 环境变量:
#   NT_DATA_DIR      - Next-Terminal 数据目录，默认 /opt/next-terminal/data
#   NT_PORT          - 对外端口，默认 8088
#   NT_IMAGE         - Docker 镜像，默认 dushixiang/next-terminal:latest
#   ALLOW_PUBLIC_SSH - 是否允许公网 SSH，默认 false (不推荐开启)
# ==============================================================================

set -e

# ---------------------- 日志工具 ----------------------
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()  { log "ℹ️  $*"; }
success(){ log "✅ $*"; }
warning(){ log "⚠️  $*"; }
error() { log "❌ $*"; exit 1; }

# ---------------------- 权限检查 ----------------------
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 权限或 sudo 运行此脚本！"
fi

# ---------------------- 配置区 ----------------------

# Next-Terminal 配置
NT_DATA_DIR="${NT_DATA_DIR:-/opt/next-terminal/data}"  # 数据持久化目录
NT_PORT="${NT_PORT:-8088}"                              # 对外端口
NT_IMAGE="${NT_IMAGE:-dushixiang/next-terminal:latest}" # Docker 镜像

# 安全配置：堡垒机默认只允许 Tailscale 内网访问
# 如果你实在需要公网 SSH，可以把这个设成 true，但真的不推荐
ALLOW_PUBLIC_SSH="${ALLOW_PUBLIC_SSH:-false}"

# ---------------------- 开始安装 ----------------------
info "🚀 开始初始化堡垒机环境..."
echo ""

# 1. 安装 Docker
# Next-Terminal 跑在容器里，Docker 是必须的。
info ">>> 1/5 检查并安装 Docker"
if command -v docker &>/dev/null; then
    success "Docker 已安装"
else
    info "正在安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# 2. 安装 Docker Compose
info ">>> 2/5 检查 Docker Compose"
if docker compose version &>/dev/null; then
    success "Docker Compose 已安装"
else
    info "正在安装 Docker Compose 插件..."
    apt update
    apt install -y docker-compose-plugin
fi

# 3. 部署 Next-Terminal
# Next-Terminal 是个堡垒机 Web UI，支持 SSH/RDP 远程连接。
info ">>> 3/5 部署 Next-Terminal"
mkdir -p "${NT_DATA_DIR}"

cat > /tmp/next-terminal-compose.yml <<EOF
services:
  next-terminal:
    image: ${NT_IMAGE}
    container_name: next-terminal
    restart: unless-stopped
    ports:
      - "${NT_PORT}:8080"
    volumes:
      - ${NT_DATA_DIR}:/app/data
    environment:
      - TZ=Asia/Shanghai
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
EOF

cd /tmp
docker compose -f next-terminal-compose.yml up -d
cd -

# 4. 配置防火墙
# 堡垒机的安全策略要严一点：只允许 Tailscale 内网访问。
info ">>> 4/5 配置防火墙安全策略"
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing

# SSH 必须放行
ufw allow ssh comment 'Allow SSH (22/tcp)'

# Tailscale 内网通信
ufw allow in on tailscale0 comment 'Allow Tailscale Internal Traffic'
ufw allow 41641/udp comment 'Allow Tailscale Peer-to-Peer'

# Next-Terminal 只允许通过 Tailscale 访问，公网不开放
ufw allow in on tailscale0 to any port "${NT_PORT}" proto tcp comment 'Allow Next-Terminal via Tailscale'

# 如果真的需要公网 SSH (不推荐)
if [ "${ALLOW_PUBLIC_SSH}" == "true" ]; then
    warning "允许公网 SSH 访问 (不推荐用于生产环境)"
    ufw allow ssh comment 'Allow Public SSH'
fi

systemctl enable ufw --now
ufw --force enable

# 5. 安装 Fail2Ban
# 防暴力破解，SSH 连续输错 3 次密码就封 IP 1 小时。
info ">>> 5/5 安装 Fail2Ban 防暴力破解"
apt install -y fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600      # 封禁 1 小时
findtime = 600      # 10 分钟内
maxretry = 5        # 最多重试 5 次
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3        # SSH 更严格，3 次就封
EOF

systemctl enable fail2ban
systemctl restart fail2ban
success "Fail2Ban 已安装并配置"

# ---------------------- 大功告成 ----------------------
TS_IP=$(tailscale ip -4 2>/dev/null || echo "未启动")

echo ""
echo "=============================================================================="
success "堡垒机初始化完成！"
echo ""
echo "  Next-Terminal 地址: http://${TS_IP}:${NT_PORT}"
echo "  数据目录: ${NT_DATA_DIR}"
echo "  Tailscale IP: ${TS_IP}"
echo ""
echo "  🔒 安全策略:"
echo "    - 仅允许 Tailscale 内网访问"
echo "    - SSH 端口: 22"
echo "    - Next-Terminal 端口: ${NT_PORT}"
echo "    - Fail2Ban: 已启用 (暴力破解防护)"
echo "=============================================================================="
echo ""
echo "💡 下一步:"
echo "  1. 通过 Tailscale 访问 Next-Terminal Web UI"
echo "  2. 登录后修改默认密码"
echo "  3. 添加 SSH/RDP 连接凭证"
echo ""
