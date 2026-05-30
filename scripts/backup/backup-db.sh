#!/bin/bash
# ==============================================================================
# Pineapple Ops - 数据库自动备份脚本
# ==============================================================================
# 支持 MySQL/MariaDB 和 PostgreSQL，自动备份 + 压缩 + 清理旧备份。
#
# 用法:
#   sudo bash backup-db.sh
#
# 环境变量 (优先级高于脚本内默认值):
#   BACKUP_DIR      - 备份存放目录，默认 /opt/backups/databases
#   RETENTION_DAYS  - 保留天数，默认 14
#
#   # MySQL
#   ENABLE_MYSQL    - 是否备份 MySQL，默认 true
#   MYSQL_HOST      - MySQL 地址，默认 127.0.0.1
#   MYSQL_PORT      - MySQL 端口，默认 3306
#   MYSQL_USER      - MySQL 用户，默认 root
#   MYSQL_PASS      - MySQL 密码 (必填)
#   MYSQL_DB        - 要备份的数据库 (必填)
#
#   # PostgreSQL
#   ENABLE_PG       - 是否备份 PostgreSQL，默认 true
#   PG_HOST         - PostgreSQL 地址，默认 127.0.0.1
#   PG_PORT         - PostgreSQL 端口，默认 5432
#   PG_USER         - PostgreSQL 用户，默认 postgres
#   PG_PASS         - PostgreSQL 密码 (必填)
#   PG_DB           - 要备份的数据库 (必填)
#
# 定时任务示例 (每天凌晨 3 点):
#   0 3 * * * /usr/bin/bash /path/to/backup-db.sh >> /var/log/backup-db.log 2>&1
# ==============================================================================

set -e

# ---------------------- 日志工具 ----------------------
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()  { log "ℹ️  $*"; }
success(){ log "✅ $*"; }
warning(){ log "⚠️  $*"; }
error() { log "❌ $*"; exit 1; }

# ---------------------- 配置区 ----------------------
# 备份目录和保留策略
BACKUP_DIR="${BACKUP_DIR:-/opt/backups/databases}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DATE=$(date +"%Y%m%d_%H%M%S")

# MySQL / MariaDB
ENABLE_MYSQL="${ENABLE_MYSQL:-true}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"
MYSQL_DB="${MYSQL_DB:-}"

# PostgreSQL
ENABLE_PG="${ENABLE_PG:-true}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-}"
PG_DB="${PG_DB:-}"

# ---------------------- 参数校验 ----------------------
# MySQL 配置检查
if [ "${ENABLE_MYSQL}" == "true" ]; then
    if [ -z "${MYSQL_PASS}" ] || [ -z "${MYSQL_DB}" ]; then
        error "MySQL 备份已启用，但 MYSQL_PASS 或 MYSQL_DB 未配置！"
    fi
fi

# PostgreSQL 配置检查
if [ "${ENABLE_PG}" == "true" ]; then
    if [ -z "${PG_PASS}" ] || [ -z "${PG_DB}" ]; then
        error "PostgreSQL 备份已启用，但 PG_PASS 或 PG_DB 未配置！"
    fi
fi

# 如果都没启用，就没必要跑了
if [ "${ENABLE_MYSQL}" != "true" ] && [ "${ENABLE_PG}" != "true" ]; then
    warning "MySQL 和 PostgreSQL 备份都未启用，退出。"
    exit 0
fi

# ---------------------- 开始备份 ----------------------
mkdir -p "${BACKUP_DIR}"
info "开始数据库备份任务 [${DATE}]..."
echo ""

# 1. 备份 MySQL / MariaDB
if [ "${ENABLE_MYSQL}" == "true" ]; then
    info ">>> 备份 MySQL/MariaDB: ${MYSQL_DB}"
    MYSQL_BACKUP_FILE="${BACKUP_DIR}/mysql_${MYSQL_DB}_${DATE}.sql.gz"

    if command -v mysqldump &>/dev/null; then
        # 用环境变量传密码，避免在 ps 进程列表里暴露
        if MYSQL_PWD="${MYSQL_PASS}" mysqldump -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" "${MYSQL_DB}" 2>/dev/null | gzip > "${MYSQL_BACKUP_FILE}"; then
            success "MySQL 备份完成: ${MYSQL_BACKUP_FILE}"
        else
            error "MySQL 备份失败！请检查连接配置。"
        fi
    else
        warning "未找到 mysqldump 命令，跳过 MySQL 备份"
        warning "如果是 Docker 部署，可以用: docker exec <container> mysqldump ..."
    fi
fi

# 2. 备份 PostgreSQL
if [ "${ENABLE_PG}" == "true" ]; then
    info ">>> 备份 PostgreSQL: ${PG_DB}"
    PG_BACKUP_FILE="${BACKUP_DIR}/pg_${PG_DB}_${DATE}.sql.gz"

    if command -v pg_dump &>/dev/null; then
        # 用环境变量传密码
        if PGPASSWORD="${PG_PASS}" pg_dump -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" | gzip > "${PG_BACKUP_FILE}"; then
            success "PostgreSQL 备份完成: ${PG_BACKUP_FILE}"
        else
            error "PostgreSQL 备份失败！请检查连接配置。"
        fi
    else
        warning "未找到 pg_dump 命令，跳过 PostgreSQL 备份"
    fi
fi

# 3. 清理过期备份
info ">>> 清理 ${RETENTION_DAYS} 天前的旧备份..."
DELETED=$(find "${BACKUP_DIR}" -type f -name "*.sql.gz" -mtime +"${RETENTION_DAYS}" -print -delete | wc -l)
success "已清理 ${DELETED} 个过期备份文件"

# ---------------------- 备份汇总 ----------------------
echo ""
echo "=============================================================================="
success "数据库备份完成！"
echo ""
echo "  备份目录: ${BACKUP_DIR}"
echo "  保留天数: ${RETENTION_DAYS}"
echo ""
echo "  当前备份文件:"
find "${BACKUP_DIR}" -type f -name "*.sql.gz" -printf "    %p  %s bytes\n" 2>/dev/null | tail -5 || echo "    (暂无备份)"
echo "=============================================================================="
