#!/bin/bash
# ==============================================================================
# Pineapple Ops - K3s 集群初始化脚本
# ==============================================================================
# 给 DigitalOcean 新加坡那三台机器用的，装 K3s 组成集群。
# Master 节点先跑，拿到 token 后 Worker 节点再跑加入集群。
#
# 前置条件: 先跑 int.sh 完成基础初始化 (Tailscale 必须组好网)
# 用法:
#   Master: sudo bash int-k3s.sh master
#   Worker: sudo bash int-k3s.sh worker <master_ip> <node_token>
#
# note: Master 先跑拿 token，Worker 再用 token 加入集群
# 环境变量:
#   K3S_VERSION        - K3s 版本，留空用最新版
#   FLANNEL_IFACE      - 网络接口，默认 tailscale0
#   DISABLE_COMPONENTS - 禁用的组件，默认 traefik,servicelb
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

# ---------------------- 参数解析 ----------------------
ROLE="${1:-}"
MASTER_IP="${2:-}"
NODE_TOKEN="${3:-}"

if [[ -z "${ROLE}" || ! "${ROLE}" =~ ^(master|worker)$ ]]; then
    echo ""
    echo "用法: sudo bash int-k3s.sh <master|worker> [master_ip] [node_token]"
    echo ""
    echo "示例:"
    echo "  Master 节点: sudo bash int-k3s.sh master"
    echo "  Worker 节点: sudo bash int-k3s.sh worker 100.115.0.33 K10...token..."
    echo ""
    exit 1
fi

# ---------------------- 配置区 ----------------------

# K3s 版本，留空就用最新稳定版
K3S_VERSION="${K3S_VERSION:-}"

# 网络接口，K3s 要绑到 Tailscale 的网卡上
FLANNEL_IFACE="${FLANNEL_IFACE:-tailscale0}"

# 禁用的组件：
# - Traefik: 我们用腾讯云的 Nginx 做入口，不需要 K3s 自带的
# - ServiceLB: 同理，入口在 K3s 外面
DISABLE_COMPONENTS="${DISABLE_COMPONENTS:-traefik,servicelb}"

# ---------------------- 检查 Tailscale ----------------------
# K3s 的网络要绑到 Tailscale IP，所以 Tailscale 必须先组好网。
TS_IP=$(tailscale ip -4 2>/dev/null || true)
if [ -z "${TS_IP}" ]; then
    error "无法获取 Tailscale IP，请确保基础脚本 int.sh 已运行且 Tailscale 已组网！"
fi

info "检测到本地 Tailscale IP: ${TS_IP}"
info "🚀 开始安装 K3s (${ROLE} 节点)..."
echo ""

# 构建版本参数
VERSION_PARAM=""
if [ -n "${K3S_VERSION}" ]; then
    VERSION_PARAM="K3S_VERSION=${K3S_VERSION}"
fi

# 构建禁用组件参数
DISABLE_PARAM=""
if [ -n "${DISABLE_COMPONENTS}" ]; then
    DISABLE_FLAGS="${DISABLE_COMPONENTS//,/ --disable }"
    DISABLE_PARAM="--disable ${DISABLE_FLAGS}"
fi

if [ "${ROLE}" == "master" ]; then
    # ==================== Master 节点 ====================
    # Master 是集群的大脑，负责 etcd 存储和 API 调度。
    info ">>> 初始化 K3s Master 控制面节点"

    # 安装 K3s Server，绑定到 Tailscale IP
    # 禁用 Traefik 和 ServiceLB，入口由外部 Nginx 负责
    curl -sfL https://get.k3s.io | ${VERSION_PARAM} INSTALL_K3S_EXEC="server \
        --node-ip=${TS_IP} \
        --bind-address=${TS_IP} \
        --advertise-address=${TS_IP} \
        --flannel-iface=${FLANNEL_IFACE} \
        ${DISABLE_PARAM}" sh -

    # 等服务启动，检查一下状态
    info "等待 K3s 服务启动..."
    sleep 10

    if systemctl is-active --quiet k3s; then
        success "K3s Master 安装完成"
    else
        warning "K3s 服务可能仍在启动中，请稍后检查"
    fi

    # 拿到 Node Token，Worker 节点加入集群要用
    TOKEN=$(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "")

    echo ""
    echo "=============================================================================="
    success "K3s Master 初始化完成！"
    echo ""
    echo "  节点 IP: ${TS_IP}"
    echo "  API Server: https://${TS_IP}:6443"
    echo ""
    if [ -n "${TOKEN}" ]; then
        echo "  🔐 Node Token (用于 Worker 加入):"
        echo "  ${TOKEN}"
        echo ""
        echo "  📋 Worker 加入命令:"
        echo "  sudo bash int-k3s.sh worker ${TS_IP} ${TOKEN}"
    fi
    echo "=============================================================================="
    echo ""
    echo "💡 下一步:"
    echo "  - 把上面的命令拿到 Worker 节点执行，让它们加入集群"
    echo "  - 用 'kubectl get nodes' 看节点状态"
    echo ""

elif [ "${ROLE}" == "worker" ]; then
    # ==================== Worker 节点 ====================
    # Worker 是干活的，跑具体的服务 Pod。
    if [ -z "${MASTER_IP}" ] || [ -z "${NODE_TOKEN}" ]; then
        error "作为 Worker 节点，必须提供 Master 节点的 Tailscale IP 和 Node Token"
    fi

    info ">>> 加入 K3s Worker 工作节点"
    info "Master IP: ${MASTER_IP}"

    # 用 Master 给的 token 加入集群
    curl -sfL https://get.k3s.io | ${VERSION_PARAM} K3S_URL="https://${MASTER_IP}:6443" K3S_TOKEN="${NODE_TOKEN}" INSTALL_K3S_EXEC="agent \
        --node-ip=${TS_IP} \
        --flannel-iface=${FLANNEL_IFACE}" sh -

    info "等待 K3s Agent 启动..."
    sleep 10

    if systemctl is-active --quiet k3s-agent; then
        success "K3s Worker 加入成功"
    else
        warning "K3s Agent 服务可能仍在启动中，请稍后检查"
    fi

    echo ""
    echo "=============================================================================="
    success "K3s Worker 初始化完成！"
    echo ""
    echo "  节点 IP: ${TS_IP}"
    echo "  已尝试加入 Master: ${MASTER_IP}"
    echo ""
    echo "  请在 Master 节点运行以下命令确认节点状态:"
    echo "  kubectl get nodes"
    echo "=============================================================================="
fi
