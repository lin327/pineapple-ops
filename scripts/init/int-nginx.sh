#!/bin/bash
# ==============================================================================
# Pineapple Ops - Nginx 网关初始化脚本
# ==============================================================================
# 这个脚本专门给腾讯云那台 Nginx 机器用的。
# 它会装好 Nginx、调优配置、创建 SSL 和反向代理的 snippet。
# 跑完之后，把你的站点配置扔到 conf.d/ 下就能用了。
#
# 前置条件: 先跑 int.sh 完成基础初始化
# 用法: sudo bash int-nginx.sh
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
# Nginx 性能调优参数，一般不用改，除非你有特殊需求

WORKER_PROCESSES="${WORKER_PROCESSES:-auto}"       # worker 进程数，auto = 自动检测 CPU 核心
WORKER_CONNECTIONS="${WORKER_CONNECTIONS:-1024}"    # 每个 worker 最大连接数，1024 够用了

# 安全配置
ENABLE_TLS13="${ENABLE_TLS13:-true}"               # TLS 1.3，新协议更快更安全
ENABLE_OCSP_STAPLING="${ENABLE_OCSP_STAPLING:-true}"  # OCSP Stapling，加速 SSL 握手

# 日志路径，改了记得对应的 logrotate 也要改
ACCESS_LOG="${ACCESS_LOG:-/var/log/nginx/access.log}"
ERROR_LOG="${ERROR_LOG:-/var/log/nginx/error.log}"

# ---------------------- 开始安装 ----------------------
info "开始安装 Nginx 及网关环境..."
echo ""

# 1. 安装 Nginx 稳定版
info ">>> 1/8 通过 APT 安装 Nginx 稳定版"
apt update
apt install -y nginx

# 2. 启动并设置开机自启
info ">>> 2/8 启动并配置开机自启"
systemctl start nginx
systemctl enable nginx

# 3. 备份原始配置
# 万一新配置有问题，还能恢复到原来的版本。
info ">>> 3/8 备份原始配置文件"
cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d)"

# 4. 写入优化后的主配置
# 默认配置太保守了，这里做了一些调优：
# - 开启 epoll (Linux 高性能事件模型)
# - 开启 gzip 压缩，省带宽
# - 加上安全头，防 XSS/点击劫持
# - SSL 只允许 TLS 1.2 和 1.3，旧协议不安全
info ">>> 4/8 优化 Nginx 主配置"
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes ${WORKER_PROCESSES};
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections ${WORKER_CONNECTIONS};
    multi_accept on;    # 一次接受多个连接，提升性能
    use epoll;          # Linux 高性能事件模型
}

http {
    # --- 基础配置 ---
    sendfile on;            # 零拷贝发送文件，提升大文件传输性能
    tcp_nopush on;          # 配合 sendfile，减少网络包数量
    tcp_nodelay on;         # 小数据包立即发送，降低延迟
    keepalive_timeout 65;   # 长连接超时 65 秒
    types_hash_max_size 2048;
    server_tokens off;      # 隐藏 Nginx 版本号，安全起见
    client_max_body_size 64m;  # 允许上传最大 64MB 文件

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # --- 日志格式 ---
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log ${ACCESS_LOG} main;
    error_log ${ERROR_LOG} warn;

    # --- Gzip 压缩 ---
    # 开启压缩能省不少带宽，尤其是文本类资源
    gzip on;
    gzip_vary on;           # 添加 Vary: Accept-Encoding 头
    gzip_proxied any;       # 代理响应也压缩
    gzip_comp_level 6;      # 压缩级别 6，性价比最高
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml font/truetype font/opentype
               application/vnd.ms-fontobject image/svg+xml;

    # --- 安全头 ---
    # ! 这些头能防很多常见攻击，生产环境必须加上
    add_header X-Frame-Options "SAMEORIGIN" always;          # 防点击劫持
    add_header X-Content-Type-Options "nosniff" always;      # 防 MIME 类型嗅探
    add_header X-XSS-Protection "1; mode=block" always;     # 防 XSS
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: ws: wss: data: blob: 'unsafe-inline'; frame-ancestors 'self';" always;

    # --- SSL 配置 ---
    # 只允许 TLS 1.2 和 1.3，老协议 (SSLv3/TLS1.0/1.1) 不安全
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;  # 让客户端选密码，提升兼容性

    # SSL Session 缓存，减少重复握手的开销
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;  # 关闭 session tickets，更安全

EOF

# 5. 创建目录结构
# 这些目录后面放配置、证书、snippet 用的。
info ">>> 5/8 创建标准目录结构"
mkdir -p /etc/nginx/conf.d/custom  # 自定义站点配置
mkdir -p /etc/nginx/ssl             # SSL 证书
mkdir -p /etc/nginx/snippets        # 可复用的配置片段
chmod 755 /etc/nginx/ssl

# 6. 创建 SSL 配置片段
# 把 SSL 配置抽成 snippet，每个站点 include 一下就行，不用重复写。
info ">>> 6/8 创建 SSL 配置片段"
cat > /etc/nginx/snippets/ssl-params.conf <<'EOF'
# SSL 证书路径 -- 部署时替换成你自己的证书
ssl_certificate /etc/nginx/ssl/fullchain.pem;
ssl_certificate_key /etc/nginx/ssl/privkey.pem;

# 现代 SSL 配置，只允许安全的加密套件
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# HSTS -- 告诉浏览器以后都用 HTTPS 访问
# ! warning: 一旦启用，想回退到 HTTP 会很麻烦，先在测试环境试
# add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF

# 7. 创建反向代理配置片段
# 标准的反向代理参数，包括真实 IP 传递、超时配置、WebSocket 支持。
info ">>> 7/8 创建反向代理配置片段"
cat > /etc/nginx/snippets/proxy-params.conf <<'EOF'
# 传递真实客户端信息给后端
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# 超时配置 -- 根据后端响应速度调整
proxy_connect_timeout 60s;   # 连接后端超时
proxy_send_timeout 60s;      # 发送请求超时
proxy_read_timeout 60s;      # 读取响应超时

# 缓冲配置
proxy_buffering on;
proxy_buffer_size 4k;
proxy_buffers 8 4k;

# WebSocket 支持 -- Kuboard、Grafana 等都需要
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
EOF

# 8. 清理默认配置并重启
# Debian/Ubuntu 默认有个 default 站点配置，会拦截所有请求，得删掉。
info ">>> 8/8 清理默认配置并重启 Nginx"
if [ -L /etc/nginx/sites-enabled/default ] || [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# 先测试配置，语法错误会导致 Nginx 起不来
nginx -t || error "Nginx 配置测试失败！请检查上面的错误信息"

systemctl restart nginx

# ---------------------- 大功告成 ----------------------
echo ""
echo "=============================================================================="
success "Nginx 安装配置完成！"
echo ""
echo "  配置文件:   /etc/nginx/nginx.conf"
echo "  配置片段:   /etc/nginx/snippets/"
echo "  自定义配置: /etc/nginx/conf.d/custom/"
echo "  SSL 证书:   /etc/nginx/ssl/"
echo "=============================================================================="
echo ""
echo "💡 下一步:"
echo "  1. 把 SSL 证书放到 /etc/nginx/ssl/ 目录"
echo "  2. 在 /etc/nginx/conf.d/ 下创建站点配置 (可以参考现有的 pineapple-user.site.conf)"
echo "  3. 跑 'nginx -t' 确认配置没问题"
echo "  4. 跑 'systemctl reload nginx' 热加载配置"
echo ""
