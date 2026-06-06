#!/bin/bash
# ==============================================================================
# Pineapple Ops - 通用机器初始化脚本
# ==============================================================================
# 每台新机器到手，先跑这个脚本打个底。
# 它会帮你搞定：主机名、时区、基础工具、防火墙、Tailscale 组网、SSH 加固。
# 跑完之后，再根据机器角色跑对应的 int-xxx.sh。
#
# 用法: sudo bash int.sh
# 环境变量:
#   REGION     - 区域 (bj/sg)，默认 bj
#   PROVIDER   - 云厂商 (tencent/jd/volcano/do)，默认 tencent
#   ROLE       - 角色 (nginx/docker/bastion/k3s-master/k3s-worker)，默认 nginx
#   SEQ        - 序号，区分同类型节点，默认 01
#   TS_AUTH_KEY - Tailscale 认证密钥 (可选)
# ==============================================================================

set -e

# ---------------------- 日志工具 ----------------------
# 带时间戳的日志输出，不同级别带不同图标，一目了然。
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()  { log "ℹ️  $*"; }
success(){ log "✅ $*"; }
warning(){ log "⚠️  $*"; }
error() { log "❌ $*"; exit 1; }

# ---------------------- 权限检查 ----------------------
# 这种系统级操作，没 root 权限可搞不定。
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 权限或 sudo 运行此脚本！"
fi

# ---------------------- 配置区 ----------------------
# 下面这些变量可以根据实际情况调整，也可以通过环境变量传入。
# 详见 docs/architecture.mmd 了解整体架构。

# 节点标识：区域-厂商-角色-序号，比如 bj-tencent-nginx-01
REGION="${REGION:-bj}"
PROVIDER="${PROVIDER:-tencent}"
ROLE="${ROLE:-nginx}"
SEQ="${SEQ:-01}"

# Tailscale 认证密钥，没有的话脚本会提示你手动认证
TS_AUTH_KEY="${TS_AUTH_KEY:-}"

# 基础工具包，新机器总得有几个趁手的工具
BASE_PACKAGES="curl wget vim net-tools unzip git tree htop tmux ca-certificates gnupg lsb-release software-properties-common apt-transport-https"

# 主机名：把上面的配置拼起来
HOSTNAME="${REGION}-${PROVIDER}-${ROLE}-${SEQ}"

# ---------------------- 开始干活 ----------------------
info "开始执行通用机器初始化..."
info "节点标识: ${HOSTNAME}"
echo ""

# 1. 更新系统软件包
# 新机器第一件事，先把系统更新到最新，打好安全补丁。
info ">>> 1/7 更新系统软件包"
apt update && apt upgrade -y

# 2. 设置主机名
# 给机器起个好认的名字，方便在 Tailscale 和各种管理面板里区分。
info ">>> 2/7 设置主机名: ${HOSTNAME}"
hostnamectl set-hostname "${HOSTNAME}"
# 同时写入 /etc/hosts，有些服务可能会用到
if ! grep -q "${HOSTNAME}" /etc/hosts; then
    echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
fi

# 3. 设置时区
# 统一用上海时区，日志时间对得上，排查问题方便。
info ">>> 3/7 设置时区为 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai
hwclock --systohc || true  # 同步硬件时钟，防止重启后时间漂移

# 4. 安装基础工具包
# curl/wget 下载用，vim 编辑配置用，git 拉代码用，htop 看资源用...
info ">>> 4/7 安装必要的系统基础包"
apt install -y ${BASE_PACKAGES}

# 5. 配置防火墙
# 安全第一，先deny所有入站，再按需放行。
info ">>> 5/7 配置 UFW 防火墙基础规则"
apt install -y ufw

ufw default deny incoming   # 默认拒绝所有入站
ufw default allow outgoing  # 出站随便走

# SSH 必须放行，不然就连不上了
ufw allow ssh comment 'Allow SSH (22/tcp)'

# Tailscale 内网通信必须放行，这是咱们的内网通道
ufw allow in on tailscale0 comment 'Allow Tailscale Internal Traffic'
ufw allow 41641/udp comment 'Allow Tailscale Peer-to-Peer'

# 根据角色，额外放行需要的端口
case "${ROLE}" in
    nginx)
        # Nginx 要对外服务，80/443 得开着
        ufw allow http comment 'Allow HTTP (80/tcp)'
        ufw allow https comment 'Allow HTTPS (443/tcp)'
        ;;
    bastion)
        # 堡垒机比较敏感，只允许 Tailscale 内网访问，公网不开放
        info "堡垒机模式: 仅允许 Tailscale 内网访问"
        ;;
esac

# 启用防火墙
systemctl enable ufw --now
ufw --force enable

# 6. 安装 Tailscale
# Tailscale 是咱们的内网组网神器，所有节点通过它互通。
info ">>> 6/7 加入 Tailscale 网络"
if command -v tailscale &>/dev/null; then
    success "Tailscale 已安装"
else
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if [ -n "${TS_AUTH_KEY}" ]; then
    # 有认证密钥就直接上，省得手动操作
    tailscale up --auth-key="${TS_AUTH_KEY}" --hostname="${HOSTNAME}"
    success "Tailscale 已认证并加入网络"
else
    # 没密钥也没关系，给个提示，手动跑一下就行
    warning "未提供 Tailscale Auth Key，请手动运行 'tailscale up' 进行认证"
fi

# 7. SSH 安全加固
# ! 默认的 SSH 配置有点松，收紧一下更安全。
info ">>> 7/7 SSH 安全加固"
SSH_CONFIG="/etc/ssh/sshd_config"
if [ -f "${SSH_CONFIG}" ]; then
    # 先备份，万一改坏了还能恢复
    cp "${SSH_CONFIG}" "${SSH_CONFIG}.bak.$(date +%Y%m%d)"

    # note: 已配密钥时禁用密码登录，仅保留密钥认证
    if [ -d /root/.ssh ] && [ -f /root/.ssh/authorized_keys ]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "${SSH_CONFIG}"
        sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "${SSH_CONFIG}"
        success "已禁用 SSH 密码登录 (检测到密钥)"
    else
        warning "未检测到 SSH 密钥，保留密码登录"
    fi

    # root 用户禁止密码登录，但密钥登录还是允许的
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "${SSH_CONFIG}"

    systemctl restart sshd
    success "SSH 加固完成"
fi

# ---------------------- 大功告成 ----------------------
echo ""
echo "=============================================================================="
success "通用机器初始化完成！"
echo ""
echo "  节点标识: ${HOSTNAME}"
echo "  当前主机名: $(hostname)"
echo "  当前时区: $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo "  Tailscale 状态:"
tailscale status 2>/dev/null || echo "    未启动或未认证"
echo "=============================================================================="
echo ""
echo "💡 下一步:"
echo "  根据这台机器的角色，运行对应的附加脚本："
echo "    - Nginx 节点:  sudo bash int-nginx.sh"
echo "    - Docker 节点: sudo bash int-docker.sh"
echo "    - K3s 集群:    sudo bash int-k3s.sh master|worker"
echo "    - 堡垒机:      sudo bash int-bastion.sh"
echo ""
