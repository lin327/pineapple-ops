#!/bin/bash
# ================================================================
# setup_python.sh
# 用途：检测并安装 Python3 及依赖，在 /home 下创建 venv 虚拟环境
# 适用系统：Debian / Ubuntu
# 用法：sudo bash setup_python.sh
# ================================================================

set -e

VENV_PATH="/home/venv"

# ================================================================
# 0. 检查 root 权限
# ================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请使用 root 权限运行: sudo bash $0"
    exit 1
fi

# ================================================================
# 1. 安装 Python3 及完整依赖
#    python3-venv: 提供 venv 模块，创建虚拟环境必须
#    python3-full: 确保 activate、pip 等完整可用
#    python3-dev:  部分包编译时需要的头文件
# ================================================================
echo "[INFO] 安装 Python3 及依赖..."
apt update -y
apt install -y python3 python3-pip python3-venv python3-dev python3-full
echo "[OK] Python3: $(python3 --version 2>&1)"

# ================================================================
# 2. 清理已存在的不完整 venv（如果有）
#    之前创建失败的残留目录会导致再次创建出问题
# ================================================================
if [ -d "$VENV_PATH" ]; then
    # 检查 activate 是否存在来判断是否完整
    if [ ! -f "$VENV_PATH/bin/activate" ]; then
        echo "[WARN] 发现不完整的虚拟环境，正在清理..."
        rm -rf "$VENV_PATH"
    else
        echo "[INFO] 有效的虚拟环境已存在: $VENV_PATH"
        echo "[INFO] 如需重建，请先执行: rm -rf $VENV_PATH"
        source "$VENV_PATH/bin/activate"
        echo "[OK] 已激活虚拟环境"
        pip install psutil
        echo "[OK] psutil 已安装，可以运行 server_info.py 了"
        exit 0
    fi
fi

# ================================================================
# 3. 创建虚拟环境
# ================================================================
echo "[INFO] 创建虚拟环境: $VENV_PATH"
python3 -m venv "$VENV_PATH"

# 创建后立刻验证完整性
if [ ! -f "$VENV_PATH/bin/activate" ]; then
    echo "[ERROR] 虚拟环境创建失败，缺少 activate 文件"
    echo "[ERROR] 请检查 python3-venv 和 python3-full 是否安装成功"
    exit 1
fi
echo "[OK] 虚拟环境创建成功"

# ================================================================
# 4. 升级 pip 并安装常用包
# ================================================================
echo "[INFO] 升级 pip 并安装依赖..."
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install psutil
echo "[OK] pip: $("$VENV_PATH/bin/pip" --version 2>&1 | cut -d' ' -f1-2)"

# ================================================================
# 5. 输出结果
# ================================================================
echo ""
echo "========================================="
echo "  安装完成"
echo "========================================="
echo "  Python:    $(python3 --version 2>&1)"
echo "  venv 路径: $VENV_PATH"
echo ""
echo "  激活虚拟环境:"
echo "    source $VENV_PATH/bin/activate"
echo ""
echo "  运行检测脚本:"
echo "    python3 server_info.py"
echo ""
echo "  退出虚拟环境:"
echo "    deactivate"
echo "========================================="
