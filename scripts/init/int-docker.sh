#!/bin/bash
# ==============================================================================
# Pineapple Ops - Docker 容器运行环境初始化脚本
# ==============================================================================
# 给需要跑容器的机器准备环境，比如京东云那台跑 Vaultwarden 和 Uptime Kuma 的。
# 它会从官方源装 Docker，配好日志轮转、存储驱动这些。
#
# 前置条件: 先跑 int.sh 完成基础初始化
# 用法: sudo bash int-docker.sh
# 环境变量:
#   NODE_LOCATION   - 节点位置: global(海外) / cn(国内)，默认 global
#   DOCKER_DATA_DIR - Docker 数据目录，不设就用默认的 /var/lib/docker
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

# 节点位置：国内机器用腾讯云镜像源，海外用官方源
# 国内用官方源太慢了，腾讯云镜像快很多
NODE_LOCATION="${NODE_LOCATION:-global}"

# Docker APT 源地址
MIRROR_CN="https://mirrors.cloud.tencent.com/docker-ce/linux/debian"
MIRROR_GLOBAL="https://download.docker.com/linux/debian"

# Docker 数据目录：如果系统盘空间不够，可以把数据放到数据盘
DOCKER_DATA_DIR="${DOCKER_DATA_DIR:-}"

# 国内镜像加速：国内机器拉官方镜像太慢，用腾讯云的镜像加速
MIRROR_REGISTRY="https://mirror.ccs.tencentyun.com"

# ---------------------- 开始安装 ----------------------
info "开始初始化 Docker 容器运行环境..."
echo ""

# 1. 清理旧版本
# 有些系统预装了 docker.io 或 podman-docker，跟官方 Docker 冲突，得先卸掉。
info ">>> 1/7 卸载残留的旧版包"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt remove -y "$pkg" >/dev/null 2>&1 || true
done

# 2. 安装依赖
info ">>> 2/7 安装必要的基础依赖"
apt update
apt install -y ca-certificates curl gnupg lsb-release

# 3. 导入 GPG 密钥
# Docker 官方的 APT 源需要用这个密钥来验证包的完整性。
info ">>> 3/7 导入 Docker 官方 GPG 密钥"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 4. 配置 APT 源
info ">>> 4/7 配置 Docker APT 源"
DEBIAN_CODENAME=$(lsb_release -cs)

if [[ "${NODE_LOCATION}" == "cn" ]]; then
    MIRROR_URL="${MIRROR_CN}"
    info "使用国内镜像源: ${MIRROR_URL}"
else
    MIRROR_URL="${MIRROR_GLOBAL}"
    info "使用官方源: ${MIRROR_URL}"
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${MIRROR_URL} ${DEBIAN_CODENAME} stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. 安装 Docker
# 装 docker-ce (社区版) + compose 插件 + buildx 构建工具
info ">>> 5/7 安装 Docker 本体及插件"
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 6. 配置 Docker Daemon
# note: 生产环境关键优化项：
# - 日志轮转：防止日志文件撑爆磁盘
# - overlay2 存储驱动：性能最好
# - live-restore：Docker 重启时容器不中断
# - 文件描述符限制：防止高并发时报错
info ">>> 6/7 配置 Docker 守护进程"
mkdir -p /etc/docker

# 构建 daemon.json，根据配置动态生成
DAEMON_JSON="{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"storage-driver\": \"overlay2\",
  \"live-restore\": true,
  \"default-ulimits\": {
    \"nofile\": {
      \"Name\": \"nofile\",
      \"Hard\": 65536,
      \"Soft\": 65536
    }
  }"

# 国内机器添加镜像加速，拉镜像快很多
if [[ "${NODE_LOCATION}" == "cn" ]]; then
    DAEMON_JSON="${DAEMON_JSON},
  \"registry-mirrors\": [\"${MIRROR_REGISTRY}\"]"
    info "已配置国内镜像加速: ${MIRROR_REGISTRY}"
fi

# 自定义数据目录
if [ -n "${DOCKER_DATA_DIR}" ]; then
    mkdir -p "${DOCKER_DATA_DIR}"
    DAEMON_JSON="${DAEMON_JSON},
  \"data-root\": \"${DOCKER_DATA_DIR}\""
    info "Docker 数据目录: ${DOCKER_DATA_DIR}"
fi

echo "${DAEMON_JSON}
}" > /etc/docker/daemon.json

# 7. 启动 Docker
info ">>> 7/7 启动 Docker 并配置开机自启"
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

# 清理 APT 缓存，省点磁盘空间
apt clean
rm -rf /var/lib/apt/lists/*

# ---------------------- 验证安装 ----------------------
echo ""
echo "=============================================================================="
success "Docker 安装配置完成！"
echo ""
echo "  Docker 版本:"
docker --version
echo ""
echo "  Docker Compose 版本:"
docker compose version || true
echo ""
echo "  Docker 信息:"
docker info --format '{{.ServerVersion}}' | xargs -I {} echo "    服务端版本: {}"
docker info --format '{{.Driver}}' | xargs -I {} echo "    存储驱动: {}"
echo "=============================================================================="
echo ""
echo "💡 下一步:"
echo "  - 跑 'docker compose up -d' 部署服务"
echo "  - 如果是新装的机器，记得先创建 Docker 网络和卷"
echo ""
