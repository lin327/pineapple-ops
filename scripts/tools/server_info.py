import psutil
import platform
import os
import subprocess
import shutil

try:
    import pwd  # note: Unix/Linux/macOS 专用模块，Windows 上不存在
except ImportError:
    pwd = None


def get_size(bytes, suffix="B"):
    """
    将字节按合适的单位（KB, MB, GB, TB）进行格式化转换
    """
    factor = 1024
    for unit in ["", "K", "M", "G", "T", "P"]:
        if bytes < factor:
            return f"{bytes:.2f} {unit}{suffix}"
        bytes /= factor


def run_cmd(cmd):
    """
    安全地执行 shell 命令，返回输出字符串；失败时返回空字符串。
    所有外部调用统一走这个函数，避免到处写 try/except。
    """
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=10
        )
        return result.stdout.strip()
    except Exception:
        return ""


def get_server_info():
    # ================================================================
    # 1. 操作系统基础信息
    # ================================================================
    print("=" * 40, "服务器基础信息", "=" * 40)
    print(f"主机名称: {platform.node()}")
    print(f"操作系统: {platform.system()} {platform.release()}")
    print(f"系统架构: {platform.machine()}")
    # 完整的发行版信息（Debian 版本号、代号等）
    # 读 /etc/os-release 是最可靠的获取发行版详情的方式
    os_info = run_cmd("cat /etc/os-release | grep PRETTY_NAME | cut -d'\"' -f2")
    if os_info:
        print(f"发行版: {os_info}")

    # ================================================================
    # 2. 系统运行时间 & 负载
    # ================================================================
    # 刚装完的服务器需要确认是否刚重启过，负载是否正常
    print("\n" + "=" * 40, "运行时间 & 系统负载", "=" * 40)
    boot_time = psutil.boot_time()
    from datetime import datetime
    boot_dt = datetime.fromtimestamp(boot_time)
    print(f"上次启动时间: {boot_dt.strftime('%Y-%m-%d %H:%M:%S')}")
    uptime_sec = psutil.time.time() - boot_time if hasattr(psutil, 'time') else 0
    # psutil 没有直接的 uptime，用 /proc/uptime 读取更准确
    uptime_raw = run_cmd("cat /proc/uptime").split()[0] if os.path.exists("/proc/uptime") else "0"
    try:
        uptime_seconds = float(uptime_raw)
        days, remainder = divmod(int(uptime_seconds), 86400)
        hours, remainder = divmod(remainder, 3600)
        minutes, _ = divmod(remainder, 60)
        print(f"已运行: {days}天 {hours}小时 {minutes}分钟")
    except ValueError:
        pass

    # load average 反映最近 1/5/15 分钟的系统压力
    # 对于刚装完的服务器，如果负载已经很高，说明有问题
    load1, load5, load15 = os.getloadavg()
    cpu_count = psutil.cpu_count(logical=True) or 1
    print(f"负载均值 (1/5/15分钟): {load1:.2f} / {load5:.2f} / {load15:.2f}")
    if load1 > cpu_count:
        print(f"  ⚠ 负载已超过逻辑核心数 ({cpu_count})，系统可能过载")

    # ================================================================
    # 3. CPU 信息
    # ================================================================
    print("\n" + "=" * 40, "CPU 信息", "=" * 40)
    print(f"物理核心数: {psutil.cpu_count(logical=False)}")
    print(f"逻辑核心数 (线程): {psutil.cpu_count(logical=True)}")
    try:
        cpu_freq = psutil.cpu_freq()
        if cpu_freq:
            print(f"最大频率: {cpu_freq.max:.2f} MHz")
    except Exception:
        pass
    # 当前 CPU 使用率快照，采样 1 秒
    cpu_percent = psutil.cpu_percent(interval=1)
    print(f"当前 CPU 使用率: {cpu_percent}%")

    # ================================================================
    # 4. 内存信息（含 Swap）
    # ================================================================
    # Debian 最小化安装可能没配 swap，这里主动检测
    print("\n" + "=" * 40, "内存信息", "=" * 40)
    svmem = psutil.virtual_memory()
    print(f"总内存: {get_size(svmem.total)}")
    print(f"已用内存: {get_size(svmem.used)}")
    print(f"可用内存: {get_size(svmem.available)}")
    print(f"内存使用率: {svmem.percent}%")

    swap = psutil.swap_memory()
    if swap.total > 0:
        print(f"Swap 总量: {get_size(swap.total)}")
        print(f"Swap 已用: {get_size(swap.used)} ({swap.percent}%)")
    else:
        # warning: 无 Swap 分区可能导致低内存服务器 OOM
        print("⚠ 未检测到 Swap 分区 —— 建议为低内存服务器配置 swap")

    # ================================================================
    # 5. 磁盘信息（所有挂载分区）
    # ================================================================
    # 只看 / 会漏掉数据盘，这里遍历所有实际挂载的物理分区
    print("\n" + "=" * 40, "磁盘信息", "=" * 40)
    for part in psutil.disk_partitions():
        # 跳过虚拟文件系统（tmpfs、devtmpfs 等）和 macOS 系统卷，只看真实磁盘
        if any(fs in part.fstype for fs in ["tmpfs", "devtmpfs", "squashfs", "overlay"]):
            continue
        if "/System/Volumes" in part.mountpoint:
            continue
        try:
            usage = psutil.disk_usage(part.mountpoint)
            print(f"\n  挂载点: {part.mountpoint}")
            print(f"  文件系统: {part.fstype}")
            print(f"  设备: {part.device}")
            print(f"  总空间: {get_size(usage.total)}")
            print(f"  已用: {get_size(usage.used)} ({usage.percent}%)")
            print(f"  剩余: {get_size(usage.free)}")
            # 磁盘使用率超过 85% 要提醒
            if usage.percent >= 85:
                print(f"  ⚠ 磁盘使用率过高 ({usage.percent}%)，请及时清理")
        except PermissionError:
            pass

    # ================================================================
    # 6. 网络信息
    # ================================================================
    # 刚装完的服务器必须确认网络是否通、IP 是否正确、DNS 是否配好
    print("\n" + "=" * 40, "网络信息", "=" * 40)

    # 6a. 网卡与 IP 地址
    # 只显示有 IP 地址的真实网卡，跳过 macOS 的 utun/anpi 等内部虚拟接口
    print("\n  --- 网卡 & IP 地址 ---")
    addrs = psutil.net_if_addrs()
    stats = psutil.net_if_stats()
    for iface, addr_list in addrs.items():
        if iface == "lo" or iface == "lo0":
            continue
        ips = [a.address for a in addr_list if a.family.name == "AF_INET"]
        # 没有 IP 的接口通常是内部虚拟接口，跳过不显示
        if not ips:
            continue
        is_up = stats[iface].isup if iface in stats else False
        status = "UP" if is_up else "DOWN"
        macs = [a.address for a in addr_list if a.family.name in ("AF_LINK", "AF_PACKET")]
        print(f"  {iface} [{status}]: IP={ips}, MAC={macs[0] if macs else 'N/A'}")

    # 6b. 已建立的网络连接数（粗略了解服务器活跃程度）
    # macOS 上 psutil.net_connections() 需要 root 权限，普通用户会报 AccessDenied
    try:
        connections = psutil.net_connections(kind="inet")
        established = [c for c in connections if c.status == "ESTABLISHED"]
        listening = [c for c in connections if c.status == "LISTEN"]
        print(f"\n  活跃连接数: {len(established)}")
        print(f"  监听端口数: {len(listening)}")

        # 6c. 监听端口明细（可以看到哪些服务在对外提供端口）
        if listening:
            print("\n  --- 监听端口明细 ---")
            for conn in sorted(listening, key=lambda c: c.laddr.port):
                proc_name = "-"
                if conn.pid:
                    try:
                        proc_name = psutil.Process(conn.pid).name()
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
                print(f"    端口 {conn.laddr.port:<6} ({conn.laddr.ip:<15})  进程: {proc_name}")
    except (psutil.AccessDenied, PermissionError):
        print("\n  网络连接详情: 需要 root/sudo 权限才能查看")
        # 降级方案：用系统命令获取监听端口
        ss_output = run_cmd("ss -tlnp 2>/dev/null || netstat -an | grep LISTEN")
        if ss_output:
            print("  监听端口 (降级模式):")
            for line in ss_output.split("\n")[:20]:
                print(f"    {line}")

    # 6d. DNS 配置
    # DNS 不通的话服务器无法解析域名，apt update 都会失败
    print("\n  --- DNS 配置 ---")
    dns_output = run_cmd("cat /etc/resolv.conf | grep '^nameserver'")
    if dns_output:
        for line in dns_output.split("\n"):
            print(f"  {line}")
    else:
        print("  ⚠ 未检测到 DNS 配置")

    # ================================================================
    # 7. 系统用户情况
    # ================================================================
    print("\n" + "=" * 40, "系统用户情况", "=" * 40)

    # 当前正在登录的用户
    active_users = list(set([u.name for u in psutil.users()]))
    print(f"当前在线登录用户: {', '.join(active_users) if active_users else '无'}")

    # 系统中存在的普通用户（排除 root 和系统伪账号）
    if pwd:
        # Debian 系统中，普通用户 UID >= 1000；UID 500-999 通常是系统用户
        human_users = [p.pw_name for p in pwd.getpwall() if p.pw_uid >= 1000 and p.pw_name != "nobody"]
        print(f"本机普通账号: {', '.join(human_users) if human_users else '无'}")
    else:
        print("提示: 当前系统不支持读取 Unix 用户列表。")

    # ! 检查 root 是否可直接 SSH 登录（安全审计重点）
    print("\n  --- SSH 安全配置 ---")
    sshd_config = run_cmd("cat /etc/ssh/sshd_config 2>/dev/null")
    if sshd_config:
        # 提取关键安全配置项，逐项检查
        def get_sshd_value(keyword, default="未显式配置（使用默认值）"):
            for line in sshd_config.split("\n"):
                stripped = line.strip()
                # 跳过注释行
                if stripped.startswith("#") or not stripped:
                    continue
                if stripped.lower().startswith(keyword.lower()):
                    return stripped.split(None, 1)[1] if len(stripped.split(None, 1)) > 1 else ""
            return default

        root_login = get_sshd_value("PermitRootLogin")
        pwd_auth = get_sshd_value("PasswordAuthentication")
        port = get_sshd_value("Port", "22（默认）")
        print(f"  SSH 端口: {port}")
        print(f"  允许 root 登录: {root_login}")
        print(f"  密码认证: {pwd_auth}")

        # 安全提醒：生产环境建议关闭 root 密码登录
        if "yes" in root_login.lower() or "未显式配置" in root_login:
            print("  ⚠ 建议关闭 root 密码登录：PermitRootLogin prohibit-password")
        if "yes" in pwd_auth.lower() or "未显式配置" in pwd_auth:
            print("  ⚠ 建议关闭密码认证，仅使用密钥登录：PasswordAuthentication no")
    else:
        print("  无法读取 SSH 配置文件（可能未安装 openssh-server）")

    # ================================================================
    # 8. 防火墙状态
    # ================================================================
    # ! warning: Debian 默认不开启防火墙，刚装完必须确认
    print("\n" + "=" * 40, "防火墙状态", "=" * 40)

    # 优先检查 ufw（Debian 常用的简化防火墙工具）
    ufw_status = run_cmd("ufw status 2>/dev/null")
    if ufw_status and "command not found" not in ufw_status:
        print(f"UFW 状态: {ufw_status.splitlines()[0]}")
    else:
        # 退回检查 iptables 规则数量
        iptables_output = run_cmd("iptables -L -n 2>/dev/null | wc -l")
        try:
            rule_count = int(iptables_output)
            # 默认 iptables 通常只有几行表头，> 10 说明有实际规则
            if rule_count > 10:
                print(f"iptables: 已配置自定义规则（共 {rule_count} 行）")
            else:
                print("iptables: 仅默认规则（未额外配置）")
                print("  ⚠ 防火墙未配置，建议使用 ufw 或 iptables 设置基本规则")
        except ValueError:
            print("无法检测防火墙状态")

    # 同时检查 nftables（新版 Debian 默认后端）
    nft_output = run_cmd("nft list ruleset 2>/dev/null | wc -l")
    try:
        if int(nft_output) > 5:
            print(f"nftables: 已配置规则集")
    except ValueError:
        pass

    # ================================================================
    # 9. 核心数据库服务检测
    # ================================================================
    print("\n" + "=" * 40, "数据库服务检测", "=" * 40)

    db_keywords = {
        'mysqld': 'MySQL / MariaDB',
        'postgres': 'PostgreSQL',
        'mongod': 'MongoDB',
        'redis-server': 'Redis',
        'oracle': 'Oracle DB',
        'memcached': 'Memcached'
    }
    found_db_services = set()
    for proc in psutil.process_iter(['name']):
        try:
            proc_name = proc.info['name']
            if proc_name:
                for kw, db_name in db_keywords.items():
                    if kw.lower() in proc_name.lower():
                        found_db_services.add(db_name)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass

    if found_db_services:
        print(f"检测到正在运行的数据库: {', '.join(found_db_services)}")
    else:
        print("当前未检测到常见的数据库正在运行。")

    # ================================================================
    # 10. 关键 systemd 服务状态
    # ================================================================
    # 检查服务器运维中最常见的服务是否在运行
    print("\n" + "=" * 40, "关键服务状态", "=" * 40)

    key_services = [
        "ssh", "sshd",           # 远程管理
        "nginx", "apache2",      # Web 服务
        "docker",                # 容器
        "cron", "crond",         # 定时任务
        "rsyslog",               # 系统日志
        "fail2ban",              # 防暴力破解
        "unattended-upgrades",   # 自动安全更新
    ]
    for svc in key_services:
        # systemctl is-active 静默检查服务是否在跑，失败不报错
        status = run_cmd(f"systemctl is-active {svc} 2>/dev/null")
        if status and status != "inactive" and status != "unknown":
            print(f"  {svc:<25} ✅ {status}")
        # 不打印 inactive 的，避免输出太长

    # ================================================================
    # 11. NTP 时间同步状态
    # ================================================================
    # 时间不准会导致证书校验失败、日志错乱、集群脑裂等问题
    print("\n" + "=" * 40, "时间同步状态", "=" * 40)

    # timedatectl 是 systemd 下最标准的时间状态查看方式
    ntp_status = run_cmd("timedatectl show --property=NTP --value 2>/dev/null")
    sync_status = run_cmd("timedatectl show --property=NTPSynchronized --value 2>/dev/null")
    print(f"NTP 已启用: {ntp_status or '无法检测'}")
    print(f"NTP 已同步: {sync_status or '无法检测'}")
    if sync_status == "no":
        print("  ⚠ 时间未同步，请运行: timedatectl set-ntp true")

    # 打印当前时区，方便确认是否正确
    timezone = run_cmd("timedatectl show --property=Timezone --value 2>/dev/null")
    if timezone:
        print(f"系统时区: {timezone}")

    # ================================================================
    # 12. APT 软件源 & 待更新包
    # ================================================================
    # 刚装完的系统需要确认源配置正确、是否有安全更新
    print("\n" + "=" * 40, "软件源 & 系统更新", "=" * 40)

    # 检查是否配置了国内镜像源（默认源在国外，下载慢）
    sources = run_cmd("cat /etc/apt/sources.list 2>/dev/null")
    if sources:
        # 只取第一个非空非注释的源行，展示当前用的是什么源
        for line in sources.split("\n"):
            line = line.strip()
            if line and not line.startswith("#"):
                print(f"APT 主源: {line}")
                break

    # 检查 sources.list.d 下的额外源（第三方仓库）
    extra_sources = run_cmd("ls /etc/apt/sources.list.d/ 2>/dev/null")
    if extra_sources:
        print(f"额外软件源: {extra_sources}")

    # 统计可更新的包（不实际执行更新，只做检查）
    # 这个命令比较慢，如果不需要可以注释掉
    upgradable = run_cmd("apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0")
    try:
        count = int(upgradable)
        if count > 0:
            print(f"可更新的包: {count} 个（建议尽快执行 apt upgrade）")
        else:
            print("所有包已是最新版本")
    except ValueError:
        pass

    # ================================================================
    # 13. Sudo 权限配置
    # ================================================================
    # 了解谁有 root 权限是安全审计的基础
    print("\n" + "=" * 40, "Sudo 权限", "=" * 40)

    # 检查 /etc/sudoers.d/ 下的额外配置（很多部署脚本会在这里加文件）
    sudoers_d = run_cmd("ls /etc/sudoers.d/ 2>/dev/null")
    if sudoers_d:
        print(f"sudoers.d 目录文件: {sudoers_d}")

    # 检查哪些用户在 sudo 组（Debian 中 sudo 组的成员拥有完整 root 权限）
    sudo_group = run_cmd("getent group sudo 2>/dev/null")
    if sudo_group:
        # getent group sudo 输出格式为 "sudo:x:27:user1,user2"
        members = sudo_group.split(":")[-1] if ":" in sudo_group else sudo_group
        print(f"sudo 组成员: {members or '无'}")
    else:
        # 某些系统用 wheel 组替代 sudo 组
        wheel_group = run_cmd("getent group wheel 2>/dev/null")
        if wheel_group:
            members = wheel_group.split(":")[-1] if ":" in wheel_group else wheel_group
            print(f"wheel 组成员: {members or '无'}")

    # ================================================================
    # 14. 环境变量（重点摘录）
    # ================================================================
    print("\n" + "=" * 40, "环境变量 (重点摘录)", "=" * 40)

    env_vars = os.environ
    print(f"系统共配置了 {len(env_vars)} 个环境变量，以下是关键变量：")
    important_envs = ['PATH', 'USER', 'HOME', 'SHELL', 'LANG',
                      'JAVA_HOME', 'PYTHONPATH', 'NODE_ENV',
                      'HTTP_PROXY', 'HTTPS_PROXY', 'DOCKER_HOST']
    for env in important_envs:
        if env in env_vars:
            val = env_vars[env]
            display_val = val if len(val) < 80 else val[:77] + "..."
            print(f"  {env}: {display_val}")


if __name__ == "__main__":
    get_server_info()
