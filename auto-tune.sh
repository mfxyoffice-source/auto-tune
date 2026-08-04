#!/usr/bin/env bash
# auto-tune.sh —— 一键安装/运行入口（bash 外壳 + 内嵌 Python payload）
#
# 用法：
#   bash <(curl -Ls https://raw.githubusercontent.com/mfxyoffice-source/auto-tune/main/auto-tune.sh)
#
set -euo pipefail
INSTALL_DIR="/opt/auto-tune"
CONFIG_DIR="/etc/auto-tune"
PY_PATH="$INSTALL_DIR/auto-tune.py"
if [[ "$(id -u)" -ne 0 ]]; then
    echo "请用 root 权限运行" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "未找到 python3，请先安装后重试" >&2
    exit 1
fi
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
cat > "$PY_PATH" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto-tune.py — 单文件版 VPS 网络调优工具

集成两部分能力：
  1. BBR / 拥塞控制调优（check / enable-bbr）
  2. 出口带宽 AIMD 动态调整（tune），基于 tc htb class 的 rate/ceil 实时调整

设计原则（延续之前的讨论）：
  - 默认只读、只打印计划，不改配置；任何真正下发变更的动作都需要显式 --apply。
  - 改 sysctl 前自动备份，可回滚。
  - 不自动创建 tc qdisc/class 拓扑，你需要先手动建好，脚本只负责"调"。
  - 单文件、无第三方依赖，装好 python3 就能跑，方便一键分发。

============================== 一键安装 ==============================
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/auto-tune.py | sudo python3 -
========================================================================
跑起来后会弹出数字菜单，直接回车 = 默认执行「全自动部署」，不需要再敲任何参数。

菜单：
  1) 全自动部署（默认）  探测网卡/带宽 -> 建拓扑 -> 开 BBR -> 写配置 -> 启动服务
  2) 只读检查            查看当前 BBR/qdisc/sysctl 状态，不改任何东西
  3) 卸载                停止并移除已安装的服务和文件
  0) 退出

也支持直接带子命令跑（脚本自动化 / CI 场景用，跳过菜单）：
  sudo python3 auto-tune.py check
  sudo python3 auto-tune.py enable-bbr --apply
  sudo python3 auto-tune.py tune --iface eth0 --classid 1:10 --min-rate 300mbit --max-ceil 950mbit
  sudo python3 auto-tune.py auto
  sudo python3 auto-tune.py uninstall
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import logging
import urllib.request
from datetime import datetime

LOG_PATH = "/var/log/auto-tune.log"
INSTALL_DIR = "/opt/auto-tune"
CONFIG_DIR = "/etc/auto-tune"
ENV_PATH = f"{CONFIG_DIR}/auto-tune.env"
STATE_PATH = f"{CONFIG_DIR}/last-known-speed.mbit"
SERVICE_PATH = "/etc/systemd/system/auto-tune.service"
SYSCTL_BACKUP_DIR = "/etc/auto-tune/sysctl-backup"
SYSCTL_TUNE_FILE = "/etc/sysctl.d/99-auto-tune.conf"
# 用独立文件名，避免跟网上一些同样叫 99-auto-tune.conf 的第三方脚本互相覆盖
SYSCTL_EXTRA_FILE = "/etc/sysctl.d/98-auto-tune-extra.conf"
MODULES_LOAD_FILE = "/etc/modules-load.d/auto-tune-nf-conntrack.conf"

# 通过 `curl ... | python3 - auto` 管道方式运行时，脚本自身没有本地文件路径可复制，
# 需要重新从这个地址下载一份落盘到 INSTALL_DIR，供 systemd service 长期引用。
# 可用环境变量 AUTO_TUNE_SCRIPT_URL 覆盖，避免和这里的占位地址不一致。
DEFAULT_SCRIPT_URL = "https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/main/auto-tune.py"

ENV_TEMPLATE = """\
# auto-tune 配置文件
# 改完后：sudo systemctl restart auto-tune

# 网卡名（用 `ip -br link` 或 `ip route get 1.1.1.1` 确认对外出口网卡）
IFACE=eth0

# htb classid，必须是你已经手动 `tc class add` 建好的那个
CLASSID=1:10

# 下限速率：任何情况下不会低于这个值
MIN_RATE=300mbit

# 上限速率：必须 <= 用 iperf3 实测出的稳定带宽，不要直接抄商家标称带宽
MAX_CEIL=950mbit

# 判断周期（秒），不建议低于 5
INTERVAL=8

# 无异常时每周期上调比例（加法慢升）
UP_STEP=0.05

# 检测到异常时每周期下调比例（乘法快降）
DOWN_STEP=0.15

# 重传率超过这个百分比视为异常（用比例而不是绝对数量，不会随这台机器
# 自身流量大小的正常波动而误判；一个周期里发送量太小时会自动跳过判断）
RETRANS_PCT_THRESHOLD=2.0

# 单周期新增 qdisc drop 超过这个数视为异常
DROP_THRESHOLD=1

# CPU 总体繁忙占比超过这个百分比视为异常（说明瓶颈可能不在网络，是算力扛不住了）
CPU_PCT_THRESHOLD=90.0

# 软中断（处理网卡收发/转发的那部分 CPU 开销）占比超过这个百分比视为异常
SOFTIRQ_PCT_THRESHOLD=30.0

# true 时直接跑满 MAX_CEIL，不再自动降速——重传率/丢包/CPU 超标也不会被拉回来，
# 只在日志里展示这些指标供你参考。适合『只要跑满带宽，不在乎稳不稳』的场景。
MAX_ONLY=false

# 是否真正下发 tc 命令。首次部署强烈建议先 false，观察日志确认判断合理再改 true。
APPLY=false
"""

SERVICE_TEMPLATE = """\
[Unit]
Description=auto-tune: BBR + AIMD dynamic bandwidth tuning for VPS egress
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 {install_path} tune --env-file {env_path}
Restart=on-failure
RestartSec=5
User=root

NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/log /etc/auto-tune

[Install]
WantedBy=multi-user.target
"""


# --------------------------------------------------------------------------
# 通用工具
# --------------------------------------------------------------------------

def setup_logging():
    handlers = [logging.StreamHandler(sys.stdout)]
    try:
        handlers.append(logging.FileHandler(LOG_PATH))
    except (PermissionError, FileNotFoundError):
        pass
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=handlers,
    )


def run(cmd, check=True, timeout=10):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        if check and result.returncode != 0:
            logging.warning("命令失败: %s\nstderr: %s", cmd, result.stderr.strip())
        return result.stdout
    except subprocess.TimeoutExpired:
        logging.warning("命令超时: %s", cmd)
        return ""


def require_root():
    if os.geteuid() != 0:
        logging.error("需要 root 权限，请用 sudo 运行")
        sys.exit(1)


def get_self_path():
    """通过 `curl | python3 -` 管道方式运行时 __file__ 未定义，会抛 NameError；
    这种情况下返回 None，交给调用方走"重新下载落盘"的路径。"""
    try:
        return os.path.realpath(__file__)
    except NameError:
        return None


def parse_rate_to_bps(rate_str):
    m = re.match(r"^([\d.]+)\s*(gbit|mbit|kbit|bit)$", rate_str.strip().lower())
    if not m:
        raise ValueError(f"无法解析速率: {rate_str}")
    val, unit = float(m.group(1)), m.group(2)
    mult = {"gbit": 1_000_000_000, "mbit": 1_000_000, "kbit": 1_000, "bit": 1}[unit]
    return val * mult


def bps_to_rate_str(bps):
    if bps >= 1_000_000_000:
        return f"{bps/1_000_000_000:.2f}gbit"
    if bps >= 1_000_000:
        return f"{bps/1_000_000:.1f}mbit"
    if bps >= 1_000:
        return f"{bps/1_000:.0f}kbit"
    return f"{bps:.0f}bit"


# --------------------------------------------------------------------------
# BBR / sysctl 部分
# --------------------------------------------------------------------------

def get_sysctl(key):
    out = run(f"sysctl -n {key}", check=False).strip()
    return out if out else None


def get_available_congestion_controls():
    val = get_sysctl("net.ipv4.tcp_available_congestion_control")
    return val.split() if val else []


def get_current_congestion_control():
    return get_sysctl("net.ipv4.tcp_congestion_control")


def get_default_qdisc():
    return get_sysctl("net.core.default_qdisc")


def get_kernel_version():
    return run("uname -r", check=False).strip()


def backup_sysctl():
    os.makedirs(SYSCTL_BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = os.path.join(SYSCTL_BACKUP_DIR, f"sysctl-before-bbr-{ts}.txt")
    with open(backup_path, "w") as f:
        f.write(run("sysctl -a 2>/dev/null", check=False))
    logging.info("已备份当前 sysctl 全量输出到 %s", backup_path)
    return backup_path


def cmd_check(args):
    print("=" * 70)
    print("只读检查，不会修改任何配置")
    print("=" * 70)
    print(f"内核版本            : {get_kernel_version()}")
    print(f"当前拥塞控制算法    : {get_current_congestion_control()}")
    print(f"可用拥塞控制算法    : {', '.join(get_available_congestion_controls()) or '(读取失败)'}")
    print(f"当前默认 qdisc      : {get_default_qdisc()}")
    bbr_available = "bbr" in get_available_congestion_controls()
    bbr_active = get_current_congestion_control() == "bbr"
    print(f"BBR 是否可用        : {'是' if bbr_available else '否（内核可能未编译 BBR 模块）'}")
    print(f"BBR 是否已启用      : {'是' if bbr_active else '否'}")
    print()
    print("关键 sysctl 值：")
    for key in [
        "net.ipv4.tcp_rmem", "net.ipv4.tcp_wmem",
        "net.core.rmem_max", "net.core.wmem_max",
        "net.ipv4.tcp_fastopen", "net.ipv4.tcp_mtu_probing",
        "net.ipv4.tcp_syncookies", "net.core.somaxconn",
    ]:
        print(f"  {key} = {get_sysctl(key)}")
    print()
    if args.iface:
        print(f"网卡 {args.iface} 的 qdisc 状态：")
        print(run(f"tc -s qdisc show dev {args.iface}", check=False) or "  (读取失败或网卡不存在)")
    if args.classid:
        print(f"class {args.classid} 状态：")
        print(run(f"tc class show dev {args.iface} classid {args.classid}", check=False) or "  (读取失败)")


def do_enable_bbr(apply):
    """返回 True 表示 BBR+fq 已生效（本次写入或本来就是），False 表示不支持/未执行。"""
    available = get_available_congestion_controls()
    if "bbr" not in available:
        logging.error(
            "当前内核不支持 BBR（可用算法: %s）。BBR 需要内核 >= 4.9，"
            "低版本内核无法通过 sysctl 开启，需要更换内核，脚本不会帮你换内核。",
            ", ".join(available) or "未知",
        )
        return False

    current_cc = get_current_congestion_control()
    current_qdisc = get_default_qdisc()
    logging.info("当前: congestion_control=%s, default_qdisc=%s", current_cc, current_qdisc)

    if current_cc == "bbr" and current_qdisc == "fq":
        logging.info("BBR + fq 已经是当前配置，无需修改")
        return True

    plan = [
        "net.core.default_qdisc = fq",
        "net.ipv4.tcp_congestion_control = bbr",
    ]
    logging.info("计划写入 %s：\n  %s", SYSCTL_TUNE_FILE, "\n  ".join(plan))

    if not apply:
        logging.info("[dry-run] 未加 --apply，不会真正写入。确认无误后加 --apply 执行。")
        return False

    backup_sysctl()
    with open(SYSCTL_TUNE_FILE, "w") as f:
        f.write("# 由 auto-tune.py enable-bbr 写入\n")
        f.write("\n".join(plan) + "\n")
    run("sysctl --system")

    new_cc = get_current_congestion_control()
    new_qdisc = get_default_qdisc()
    if new_cc == "bbr" and new_qdisc == "fq":
        logging.info("BBR + fq 已生效：congestion_control=%s, default_qdisc=%s", new_cc, new_qdisc)
        return True
    else:
        logging.warning(
            "写入后校验未完全匹配（congestion_control=%s, default_qdisc=%s），"
            "请手动检查 %s 和 sysctl --system 输出", new_cc, new_qdisc, SYSCTL_TUNE_FILE
        )
        return False


def cmd_enable_bbr(args):
    require_root()
    do_enable_bbr(args.apply)


# --------------------------------------------------------------------------
# TCP buffer / conntrack / 其它常规 sysctl 调优（跟 BBR 分开管理，写不同的文件，
# 不互相覆盖，也方便你只想要其中一项时单独开关）
# --------------------------------------------------------------------------

def compute_buffer_bytes(speed_mbit):
    """按链路速率分档给 TCP 读写 buffer 定一个合理上限。
    档位越高不代表越好——buffer 太大在丢包网络里反而会加剧 bufferbloat（排队延迟），
    这里给的是常见的保守分档，不是越大越好。"""
    if speed_mbit is None or speed_mbit < 100:
        return 16 * 1024 * 1024   # 16MB
    if speed_mbit < 500:
        return 32 * 1024 * 1024   # 32MB
    return 64 * 1024 * 1024       # 64MB


def compute_conntrack_max(established):
    """按当前并发连接数分档给 conntrack 表定大小，而不是按带宽——
    conntrack 表满了会导致新连接建不起来，这个跟带宽大小没有直接关系，
    只跟『同时有多少条连接』有关，所以用 detect_established_connections() 的结果来定更合理。"""
    if established is None:
        return 262144
    if established >= 1000:
        return 1048576
    if established >= 200:
        return 524288
    return 262144


def do_tune_sysctl(apply, speed_mbit=None, established=None):
    """写 TCP buffer / conntrack / 常规网络参数，跟 BBR 是分开的独立文件（SYSCTL_EXTRA_FILE），
    不会覆盖 do_enable_bbr 写的那个文件，两者可以独立开关。"""
    buffer_bytes = compute_buffer_bytes(speed_mbit)
    conntrack_max = compute_conntrack_max(established)

    lines = [
        f"net.core.rmem_max = {buffer_bytes}",
        f"net.core.wmem_max = {buffer_bytes}",
        f"net.ipv4.tcp_rmem = 4096 87380 {buffer_bytes}",
        f"net.ipv4.tcp_wmem = 4096 87380 {buffer_bytes}",
        "net.ipv4.tcp_fastopen = 3",
        "net.ipv4.tcp_mtu_probing = 1",
        "net.ipv4.tcp_tw_reuse = 1",
        "net.ipv4.tcp_fin_timeout = 15",
        "net.ipv4.tcp_keepalive_time = 300",
        "net.ipv4.ip_local_port_range = 1024 65535",
        "net.core.somaxconn = 65535",
        "net.core.netdev_max_backlog = 4096",
        f"net.netfilter.nf_conntrack_max = {conntrack_max}",
    ]

    logging.info(
        "计划写入 %s（buffer=%s字节 conntrack_max=%s，依据：speed=%smbit established=%s）：\n  %s",
        SYSCTL_EXTRA_FILE, buffer_bytes, conntrack_max, speed_mbit, established,
        "\n  ".join(lines),
    )

    if not apply:
        logging.info("[dry-run] 未加 --apply，不会真正写入。确认无误后加 --apply 执行。")
        return False

    backup_sysctl()

    # nf_conntrack 内核模块要先加载，sysctl 才认识 net.netfilter.nf_conntrack_max 这个键；
    # 用 modules-load.d 持久化，重启也会自动加载，不用 legacy 的 /etc/modules 追加写法
    run("modprobe nf_conntrack", check=False)
    try:
        with open(MODULES_LOAD_FILE, "w") as f:
            f.write("nf_conntrack\n")
    except OSError as e:
        logging.warning("写 %s 失败: %s（不影响本次生效，只影响重启后是否自动加载模块）", MODULES_LOAD_FILE, e)

    with open(SYSCTL_EXTRA_FILE, "w") as f:
        f.write("# 由 auto-tune.py tune-sysctl 写入\n")
        f.write("\n".join(lines) + "\n")
    run("sysctl --system")

    logging.info("已写入并生效 %s", SYSCTL_EXTRA_FILE)
    return True


def cmd_tune_sysctl(args):
    require_root()
    speed_mbit = args.speed_mbit
    if speed_mbit is None:
        speed_mbit = read_last_known_speed()
        if speed_mbit:
            logging.info("未指定 --speed-mbit，使用历史记录里的 %smbit", speed_mbit)
        else:
            logging.info("未指定 --speed-mbit，也没有历史记录，按 <100mbit 档位处理（更保守的 buffer）")
    established = detect_established_connections()
    logging.info("探测到并发连接数: %s", established)
    do_tune_sysctl(args.apply, speed_mbit=speed_mbit, established=established)


# --------------------------------------------------------------------------
# 自动探测：网卡 / 链路速率 / 建 htb 拓扑（供 `auto` 全自动子命令使用）
# --------------------------------------------------------------------------

def detect_default_iface():
    """通过默认路由探测对外网卡，探测不到返回 None。"""
    out = run("ip route get 1.1.1.1 2>/dev/null", check=False)
    m = re.search(r"\bdev\s+(\S+)", out)
    return m.group(1) if m else None


def detect_link_speed_mbit(iface):
    """尽量探测链路速率（Mbit/s）。多数云厂商虚拟网卡（virtio/xen）不上报真实速率，
    探测失败时返回 None，由调用方决定保守默认值。"""
    out = run(f"ethtool {iface} 2>/dev/null", check=False)
    m = re.search(r"Speed:\s*(\d+)\s*Mb/s", out)
    if m:
        return int(m.group(1))
    # 退路：部分内核会在 sysfs 暴露 speed
    speed_path = f"/sys/class/net/{iface}/speed"
    if os.path.exists(speed_path):
        try:
            with open(speed_path) as f:
                val = int(f.read().strip())
            if val > 0:
                return val
        except (ValueError, OSError):
            pass
    return None


def ensure_ookla_speedtest_installed():
    """检查 Ookla 官方 Speedtest CLI（命令名叫 speedtest）是否已装，没有就自动装。

    注意：不是同名的 speedtest-cli（sivel 写的那个第三方开源工具）——那个项目已经在
    2026年1月被作者归档、停止维护，而且在较新的系统上有已知的『测出来永远是0』的
    坏结果，所以这里特意换成 Ookla 自己出的、持续维护的官方版本，命令名是 `speedtest`
    不是 `speedtest-cli`。

    安装方式：直接从 Ookla 自己的域名（install.speedtest.net）下载免安装二进制包，
    不走 apt 仓库/packagecloud.io——那条路依赖第三方托管平台 packagecloud.io，
    历史上出现过多次该平台计费/服务问题导致仓库返回 402 Payment Required 的先例
    （不止 Ookla 一家遇到过），不够稳定，直接用官方二进制更省心。"""
    def is_official_ookla():
        if not shutil.which("speedtest"):
            return False
        out = run("speedtest --version", check=False, timeout=15)
        return "ookla" in (out or "").lower()

    if is_official_ookla():
        return True

    logging.info("未检测到 Ookla 官方 Speedtest CLI，尝试从官方直链下载二进制安装...")

    # 先移除可能冲突的旧版第三方 speedtest-cli（已归档不维护，装了反而可能干扰）
    run("apt-get remove -y speedtest-cli", check=False, timeout=30)

    arch = run("uname -m", check=False).strip()
    arch_map = {
        "x86_64": "linux-x86_64",
        "amd64": "linux-x86_64",
        "i386": "linux-i386",
        "i686": "linux-i386",
        "aarch64": "linux-aarch64",
        "arm64": "linux-aarch64",
        "armv7l": "linux-armhf",
        "armv6l": "linux-armel",
    }
    tgz_arch = arch_map.get(arch)
    if not tgz_arch:
        logging.warning("未知的 CPU 架构 %s，没法确定该下载哪个二进制包，安装失败", arch)
        return False

    version = "1.2.0"
    url = f"https://install.speedtest.net/app/cli/ookla-speedtest-{version}-{tgz_arch}.tgz"
    tmp_dir = "/tmp/auto-tune-speedtest-install"
    run(f"rm -rf {tmp_dir} && mkdir -p {tmp_dir}", check=False)
    dl_ok = run(f"curl -fsSL {url} -o {tmp_dir}/speedtest.tgz && echo OK", check=False, timeout=60)
    if "OK" not in dl_ok:
        logging.warning("从 %s 下载失败", url)
        run(f"rm -rf {tmp_dir}", check=False)
        return False

    run(f"tar xzf {tmp_dir}/speedtest.tgz -C {tmp_dir}", check=False, timeout=30)
    run(f"install -m 755 {tmp_dir}/speedtest /usr/local/bin/speedtest", check=False)
    run(f"rm -rf {tmp_dir}", check=False)

    return is_official_ookla()


def run_speedtest(timeout=60):
    """用 Ookla 官方 Speedtest CLI 做一次真实的上传/下载测速。
    不需要你自己准备对端机器，它会自己在全球节点里选一个测。
    返回 (down_mbit, up_mbit)，任一项测不出来就是 None。

    注意：这仍然只是单次、单条连接的测速，跟文章里强调的"不要拿单一 peer 的数字当
    全局真相"是同一个道理——换成官方 Ookla CLI 能避开一些第三方工具的兼容性/连通性
    问题，但测不准的根本原因（这台机器同时有大量真实流量在抢带宽/CPU）换哪个测速
    服务都一样存在，不会因为换了工具就自动解决。"""
    if not ensure_ookla_speedtest_installed():
        logging.warning("Ookla Speedtest CLI 安装失败，无法测速（检查网络能不能访问包源）")
        return None, None

    # --accept-license --accept-gdpr 是必须的：第一次跑官方 CLI 默认会交互式提示你
    # 输入 YES 接受协议，脚本化场景下没有交互输入会直接卡住，加这两个参数跳过确认。
    # -f json 用机器可读格式，比解析人类可读文本更可靠。
    # 注意：这个 CLI 没有 --timeout 参数（不是 sivel 那个第三方工具），传了会被直接拒绝、
    # 打印帮助文档退出——超时控制交给下面 run() 的 timeout 参数，不在命令行里传。
    out = run(
        "speedtest --accept-license --accept-gdpr -f json",
        check=False, timeout=timeout + 15,
    )
    if not out:
        logging.warning("Speedtest CLI 没有返回任何结果（可能是找不到可用的测速节点，或超时）")
        return None, None

    if out.strip().startswith("Speedtest by Ookla") or "Usage: speedtest" in out:
        logging.warning(
            "Speedtest CLI 打印的是帮助文档而不是测速结果，说明命令行参数有问题被它拒绝了，"
            "不是网络/节点的问题。原始输出：\n%s", out.strip()
        )
        return None, None

    try:
        data = json.loads(out)
    except (ValueError, json.JSONDecodeError):
        logging.warning("Speedtest CLI 输出不是合法 JSON，原始输出：\n%s", out.strip())
        return None, None

    down_mbit, up_mbit = None, None
    down_bw = (data.get("download") or {}).get("bandwidth")
    up_bw = (data.get("upload") or {}).get("bandwidth")
    if down_bw:
        down_mbit = down_bw * 8 / 1_000_000  # Ookla JSON 单位是 字节/秒
    if up_bw:
        up_mbit = up_bw * 8 / 1_000_000

    if down_mbit is None and up_mbit is None:
        logging.warning("Speedtest CLI 结果里 download/upload 字段都是空，原始输出：\n%s", out.strip())

    return down_mbit, up_mbit


def read_last_known_speed():
    """读取上一次 auto 判定出来的『可信』链路速率（mbit），读不到返回 None。
    用来在这次实测结果明显异常偏低时做个理智检查，不轻易被单次失真的测速带偏。"""
    try:
        with open(STATE_PATH) as f:
            return float(f.read().strip())
    except (OSError, ValueError):
        return None


def write_last_known_speed(mbit):
    """记录这次判定出来的链路速率，供下次 auto 运行时做理智检查。
    写入失败不影响主流程，静默忽略。"""
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(STATE_PATH, "w") as f:
            f.write(f"{mbit}\n")
    except OSError:
        pass


def cmd_speedtest(args):
    logging.info("开始测速（用 Ookla Speedtest CLI，会消耗一些流量，耗时数秒到十几秒）...")
    down_mbit, up_mbit = run_speedtest()
    if down_mbit:
        print(f"下载: {down_mbit:.1f} Mbit/s")
    else:
        print("下载: 测速失败")
    if up_mbit:
        print(f"上传: {up_mbit:.1f} Mbit/s")
    else:
        print("上传: 测速失败")
    print()
    print("说明：这套脚本的 tc 限速管的是『出口』方向（这台机器往外发数据），")
    print("对应的是上面的『上传』这个数字，不是『下载』。")
    print("这只是单次、单条连接的粗略测速，比网卡自称的速率更接近真实，")
    print("但不如找你自己的真实业务 peer 用 iperf3 测得准，仅供参考。")


def detect_established_connections():
    """探测当前 established 状态的 TCP 连接数，用来判断这台机器是不是高并发中转/落地机。
    探测失败返回 None。"""
    out = run("ss -tan state established 2>/dev/null | wc -l", check=False).strip()
    try:
        n = int(out)
        return max(0, n - 1)  # ss 输出第一行是表头（用 state established 过滤后可能没有表头，这里做个保守扣减）
    except ValueError:
        return None


def pick_profile_by_concurrency(established):
    """根据并发连接数，自动挑一套 (interval, retrans_pct_threshold, min_pct, max_pct)。
    并发越高，说明这是台真实在扛大量用户流量的中转/落地机：
      - 判断周期要拉长，避免被瞬时流量突刺频繁打断（对应之前手动调过的 15s 那次）
      - 重传率阈值适当收紧，因为高并发下小比例的真实重传更值得警惕
      - min/max 占比可以更激进一点贴近真实带宽上限
    并发低的机器（个人小站、测试机）用更保守、更快响应的默认值。"""
    if established is None:
        # 探测不到就用中等保守的通用默认值
        return dict(interval=8.0, retrans_pct_threshold=2.0, min_pct=0.5, max_pct=0.9, label="未知（默认档）")
    if established >= 500:
        return dict(interval=20.0, retrans_pct_threshold=1.5, min_pct=0.6, max_pct=0.9, label=f"高并发（{established} 个连接）")
    if established >= 50:
        return dict(interval=10.0, retrans_pct_threshold=2.0, min_pct=0.55, max_pct=0.9, label=f"中等并发（{established} 个连接）")
    return dict(interval=8.0, retrans_pct_threshold=2.0, min_pct=0.5, max_pct=0.85, label=f"低并发（{established} 个连接）")


def htb_class_exists(iface, classid):
    out = run(f"tc class show dev {iface} classid {classid}", check=False)
    return bool(out.strip())


def ensure_htb_setup(iface, classid, rate_mbit, ceil_mbit, apply):
    """若目标 iface 上还没有 htb 根 qdisc / 对应 class，则建一个最小可用的拓扑。
    已存在则跳过，不重复建、不清空已有配置（避免破坏你手工搭好的复杂拓扑）。"""
    if htb_class_exists(iface, classid):
        logging.info("class %s 已存在于 %s，跳过自动建拓扑", classid, iface)
        return True

    root_handle = classid.split(":")[0] + ":"
    leaf_handle = classid.split(":")[1] + ":"
    cmds = [
        f"tc qdisc add dev {iface} root handle {root_handle} htb default {classid.split(':')[1]}",
        f"tc class add dev {iface} parent {root_handle} classid {classid} htb rate {rate_mbit}mbit ceil {ceil_mbit}mbit",
        f"tc qdisc add dev {iface} parent {classid} handle {leaf_handle} fq",
    ]
    logging.info("计划为 %s 建立 htb 拓扑（rate=%smbit ceil=%smbit）：\n  %s",
                 iface, rate_mbit, ceil_mbit, "\n  ".join(cmds))
    if not apply:
        logging.info("[dry-run] 未加 --apply，不会真正建立")
        return False
    for c in cmds:
        run(c)
    ok = htb_class_exists(iface, classid)
    if ok:
        logging.info("htb 拓扑已建立")
    else:
        logging.warning("建立后校验失败，请手动检查 tc qdisc show dev %s", iface)
    return ok


# --------------------------------------------------------------------------
# AIMD 动态带宽调整部分
# --------------------------------------------------------------------------

def get_qdisc_drops(iface):
    out = run(f"tc -s qdisc show dev {iface}", check=False)
    total = 0
    for line in out.splitlines():
        m = re.search(r"dropped\s+(\d+)", line)
        if m:
            total += int(m.group(1))
    return total


def get_tcp_stats():
    """返回 (retrans_segs, out_segs)，任一读取失败则对应项为 None。
    out_segs 用于把 retrans 换算成比例，而不是用绝对数量判断——这样不会
    随这台机器本身流量大小的自然波动而误判。"""
    retrans, out_segs = None, None

    out = run("nstat -az TcpRetransSegs TcpOutSegs 2>/dev/null", check=False)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] == "TcpRetransSegs":
            try:
                retrans = int(parts[1])
            except ValueError:
                pass
        elif parts[0] == "TcpOutSegs":
            try:
                out_segs = int(parts[1])
            except ValueError:
                pass

    if retrans is not None and out_segs is not None:
        return retrans, out_segs

    # 退路：直接读 /proc/net/snmp 用 Python 解析（不依赖 grep，
    # 避免 grep -A1 匹配到 Tcp 数值行本身导致多算一行的问题）
    fb_retrans, fb_out = read_proc_net_snmp_tcp()
    if retrans is None:
        retrans = fb_retrans
    if out_segs is None:
        out_segs = fb_out

    return retrans, out_segs


def read_proc_net_snmp_tcp():
    try:
        with open("/proc/net/snmp") as f:
            content = f.read()
    except OSError:
        return None, None
    tcp_lines = [ln for ln in content.splitlines() if ln.startswith("Tcp:")]
    if len(tcp_lines) < 2:
        return None, None
    headers = tcp_lines[0].split()
    values = tcp_lines[1].split()
    retrans, out_segs = None, None
    if "RetransSegs" in headers:
        try:
            retrans = int(values[headers.index("RetransSegs")])
        except (ValueError, IndexError):
            pass
    if "OutSegs" in headers:
        try:
            out_segs = int(values[headers.index("OutSegs")])
        except (ValueError, IndexError):
            pass
    return retrans, out_segs


def get_tcp_retrans_total():
    """兼容旧接口，仅返回重传总数（不换算比例的场景用，目前仅 check 之外无调用）。"""
    retrans, _ = get_tcp_stats()
    return retrans


# --------------------------------------------------------------------------
# CPU / 软中断占用监控（判断瓶颈是不是压根不在网络路径上，而是这台机器算力扛不住了）
# --------------------------------------------------------------------------

def get_cpu_times():
    """读 /proc/stat 第一行（所有核心汇总），返回累计 jiffies 的字典。
    返回的是『累计值』，跟 drop/retrans 一样需要调用方自己做前后两次采样的差值，
    读取失败返回 None。"""
    try:
        with open("/proc/stat") as f:
            line = f.readline()
    except OSError:
        return None
    parts = line.split()
    if not parts or parts[0] != "cpu":
        return None
    try:
        vals = [int(x) for x in parts[1:11]]
    except ValueError:
        return None
    while len(vals) < 10:
        vals.append(0)
    user, nice, system, idle, iowait, irq, softirq, steal = vals[:8]
    total = user + nice + system + idle + iowait + irq + softirq + steal
    busy = total - idle - iowait
    return {"total": total, "busy": busy, "softirq": softirq}


def compute_cpu_pct(cpu_before, cpu_after):
    """根据前后两次 get_cpu_times() 采样，算出这段时间内的『总体繁忙占比』和『软中断占比』（百分比）。
    任一采样缺失或时间没走，返回 (0.0, 0.0)（不误判为异常，避免因为读取失败反而触发降速）。"""
    if not cpu_before or not cpu_after:
        return 0.0, 0.0
    total_delta = cpu_after["total"] - cpu_before["total"]
    if total_delta <= 0:
        return 0.0, 0.0
    busy_pct = (cpu_after["busy"] - cpu_before["busy"]) / total_delta * 100
    softirq_pct = (cpu_after["softirq"] - cpu_before["softirq"]) / total_delta * 100
    return max(0.0, busy_pct), max(0.0, softirq_pct)


def get_class_current_rate(iface, classid):
    out = run(f"tc class show dev {iface} classid {classid}", check=False)
    m = re.search(r"ceil\s+(\S+)", out)
    if not m:
        return None
    try:
        return parse_rate_to_bps(m.group(1).lower())
    except ValueError:
        return None


def apply_rate(iface, classid, rate_bps, ceil_bps, dry_run):
    rate_str = bps_to_rate_str(rate_bps)
    ceil_str = bps_to_rate_str(ceil_bps)
    cmd = f"tc class change dev {iface} classid {classid} htb rate {rate_str} ceil {ceil_str}"
    if dry_run:
        logging.info("[dry-run] 计划执行: %s", cmd)
    else:
        run(cmd)
        logging.info("已执行: %s", cmd)


def load_env_file(path):
    """极简 KEY=VALUE 解析，忽略注释和空行。"""
    values = {}
    if not os.path.exists(path):
        return values
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()
    return values


def cmd_tune(args):
    env = load_env_file(args.env_file) if args.env_file else {}

    def pick(cli_val, env_key, default=None, cast=str):
        if cli_val is not None:
            return cli_val
        if env_key in env:
            return cast(env[env_key])
        return default

    iface = pick(args.iface, "IFACE")
    classid = pick(args.classid, "CLASSID")
    min_rate = pick(args.min_rate, "MIN_RATE")
    max_ceil = pick(args.max_ceil, "MAX_CEIL")
    interval = float(pick(args.interval, "INTERVAL", 8.0, float))
    up_step = float(pick(args.up_step, "UP_STEP", 0.05, float))
    down_step = float(pick(args.down_step, "DOWN_STEP", 0.15, float))
    retrans_pct_threshold = float(pick(args.retrans_pct_threshold, "RETRANS_PCT_THRESHOLD", 2.0, float))
    drop_threshold = int(pick(args.drop_threshold, "DROP_THRESHOLD", 1, int))
    cpu_pct_threshold = float(pick(args.cpu_pct_threshold, "CPU_PCT_THRESHOLD", 90.0, float))
    softirq_pct_threshold = float(pick(args.softirq_pct_threshold, "SOFTIRQ_PCT_THRESHOLD", 30.0, float))
    max_only = args.max_only or (env.get("MAX_ONLY", "false").lower() == "true")
    apply_flag = args.apply or (env.get("APPLY", "false").lower() == "true")

    for name, val in [("iface", iface), ("classid", classid), ("min_rate", min_rate), ("max_ceil", max_ceil)]:
        if not val:
            logging.error("缺少必要参数: %s（可通过 --%s 或 --env-file 提供）", name, name.replace("_", "-"))
            sys.exit(1)

    dry_run = not apply_flag
    min_bps = parse_rate_to_bps(min_rate)
    max_bps = parse_rate_to_bps(max_ceil)
    if min_bps >= max_bps:
        logging.error("min-rate 必须小于 max-ceil")
        sys.exit(1)

    current = get_class_current_rate(iface, classid)
    if current is None:
        logging.warning(
            "读取不到 class %s 当前 ceil，可能尚未创建。将以 min-rate 作为起点。"
            "请先手动 tc class add 建好该 class。", classid
        )
        current = min_bps
    current = max(min_bps, min(current, max_bps))

    if max_only:
        # 跑满模式：直接顶到 max_ceil，之后只监控展示，不再根据重传/丢包/CPU 自动降速。
        logging.info(
            "MAX_ONLY 模式 | iface=%s classid=%s 直接跑满 %s（不再自动降速，仅监控展示）模式=%s",
            iface, classid, bps_to_rate_str(max_bps),
            "APPLY" if apply_flag else "DRY-RUN（不会下发配置）",
        )
        apply_rate(iface, classid, min_bps, max_bps, dry_run)
        current = max_bps

        last_drops = get_qdisc_drops(iface)
        last_retrans, last_outsegs = get_tcp_stats()
        last_cpu = get_cpu_times()
        iteration = 0
        try:
            while True:
                time.sleep(interval)
                iteration += 1

                drops_now = get_qdisc_drops(iface)
                retrans_now, outsegs_now = get_tcp_stats()
                cpu_now = get_cpu_times()

                drop_delta = drops_now - last_drops
                retrans_delta = max(0, (retrans_now or 0) - (last_retrans or 0)) if last_retrans is not None else 0
                outsegs_delta = max(0, (outsegs_now or 0) - (last_outsegs or 0)) if last_outsegs is not None else 0
                retrans_pct = (retrans_delta / outsegs_delta * 100) if outsegs_delta >= 200 else 0.0
                cpu_pct, softirq_pct = compute_cpu_pct(last_cpu, cpu_now)

                logging.info(
                    "[周期 %d] MAX_ONLY 维持满速 %s（drop+%d 重传率=%.2f%% CPU=%.0f%%/软中断=%.0f%%，仅展示不调整）",
                    iteration, bps_to_rate_str(max_bps), drop_delta, retrans_pct, cpu_pct, softirq_pct,
                )

                # 确保速率没有被外部其它进程改动过，MAX_ONLY 模式下始终把它顶回满速
                actual = get_class_current_rate(iface, classid)
                if actual is not None and abs(actual - max_bps) / max_bps > 0.01:
                    logging.info("检测到速率被改动（当前 %s），重新顶回满速 %s", bps_to_rate_str(actual), bps_to_rate_str(max_bps))
                    apply_rate(iface, classid, min_bps, max_bps, dry_run)

                last_drops = drops_now
                last_retrans = retrans_now if retrans_now is not None else last_retrans
                last_outsegs = outsegs_now if outsegs_now is not None else last_outsegs
                last_cpu = cpu_now if cpu_now is not None else last_cpu

                if args.max_iterations and iteration >= args.max_iterations:
                    logging.info("达到 --max-iterations=%d，退出", args.max_iterations)
                    break
        except KeyboardInterrupt:
            logging.info("收到中断信号，退出。当前速率保持在满速 %s。", bps_to_rate_str(max_bps))
        return

    logging.info(
        "启动 AIMD 调优 | iface=%s classid=%s 起点=%s 范围=[%s, %s] 周期=%ss "
        "重传率阈值=%.2f%% CPU阈值=%.0f%% 软中断阈值=%.0f%% 模式=%s",
        iface, classid, bps_to_rate_str(current), min_rate, max_ceil, interval,
        retrans_pct_threshold, cpu_pct_threshold, softirq_pct_threshold,
        "APPLY" if apply_flag else "DRY-RUN（不会下发配置）",
    )

    last_drops = get_qdisc_drops(iface)
    last_retrans, last_outsegs = get_tcp_stats()
    last_cpu = get_cpu_times()
    iteration = 0

    try:
        while True:
            time.sleep(interval)
            iteration += 1

            drops_now = get_qdisc_drops(iface)
            retrans_now, outsegs_now = get_tcp_stats()
            cpu_now = get_cpu_times()

            drop_delta = drops_now - last_drops

            retrans_delta = 0
            outsegs_delta = 0
            if retrans_now is not None and last_retrans is not None:
                retrans_delta = max(0, retrans_now - last_retrans)
            if outsegs_now is not None and last_outsegs is not None:
                outsegs_delta = max(0, outsegs_now - last_outsegs)

            # 用比例而不是绝对数量判断：流量大的时候重传绝对数自然会多，
            # 只有"重传占发送总量的比例"升高才说明真的在丢包/拥塞。
            # 这个周期几乎没有新发送数据时（outsegs_delta 太小），比例噪音很大，
            # 直接跳过本轮异常判断，避免误报。
            if outsegs_delta >= 200:
                retrans_pct = (retrans_delta / outsegs_delta) * 100
            else:
                retrans_pct = 0.0

            cpu_pct, softirq_pct = compute_cpu_pct(last_cpu, cpu_now)

            # 网络指标正常不代表可以继续加速：如果这台机器整体 CPU 或者软中断
            # （处理网卡收发中断/转发的那部分开销）已经顶到阈值，说明瓶颈根本不在
            # 网络路径上，而是算力扛不住了，继续升速只会让延迟和丢包变得更差。
            cpu_saturated = (cpu_pct > cpu_pct_threshold) or (softirq_pct > softirq_pct_threshold)

            anomaly = (drop_delta > drop_threshold) or (retrans_pct > retrans_pct_threshold) or cpu_saturated

            if anomaly:
                new_rate = max(min_bps, current * (1 - down_step))
                reason = []
                if drop_delta > drop_threshold:
                    reason.append(f"drop+{drop_delta}")
                if retrans_pct > retrans_pct_threshold:
                    reason.append(f"重传率={retrans_pct:.2f}%")
                if cpu_saturated:
                    reason.append(f"CPU={cpu_pct:.0f}%/软中断={softirq_pct:.0f}%")
                logging.info(
                    "[周期 %d] 异常: %s -> 下调 %s -> %s",
                    iteration, " ".join(reason),
                    bps_to_rate_str(current), bps_to_rate_str(new_rate),
                )
            else:
                new_rate = min(max_bps, current * (1 + up_step))
                if new_rate != current:
                    logging.info(
                        "[周期 %d] 正常: drop+%d 重传率=%.2f%% CPU=%.0f%%/软中断=%.0f%% -> 上调 %s -> %s",
                        iteration, drop_delta, retrans_pct, cpu_pct, softirq_pct,
                        bps_to_rate_str(current), bps_to_rate_str(new_rate),
                    )
                else:
                    logging.info(
                        "[周期 %d] 正常，已在上限 %s，保持不变（重传率=%.2f%% CPU=%.0f%%/软中断=%.0f%%）",
                        iteration, bps_to_rate_str(current), retrans_pct, cpu_pct, softirq_pct,
                    )

            if abs(new_rate - current) / current > 0.005:
                apply_rate(iface, classid, new_rate * 0.9, new_rate, dry_run)
                current = new_rate

            last_drops = drops_now
            last_retrans = retrans_now if retrans_now is not None else last_retrans
            last_outsegs = outsegs_now if outsegs_now is not None else last_outsegs
            last_cpu = cpu_now if cpu_now is not None else last_cpu

            if args.max_iterations and iteration >= args.max_iterations:
                logging.info("达到 --max-iterations=%d，退出", args.max_iterations)
                break

    except KeyboardInterrupt:
        logging.info("收到中断信号，退出。当前速率保持在 %s（未回滚）。", bps_to_rate_str(current))


# --------------------------------------------------------------------------
# 自装 / 卸载
# --------------------------------------------------------------------------

def install_self_and_service():
    """把脚本落盘到 INSTALL_DIR，写 systemd service 文件，daemon-reload。返回 install_path。
    不写配置文件、不 enable/start，由调用方决定。

    兼容两种运行方式：
      1. 本地文件运行（python3 auto-tune.py ...）：直接复制自身。
      2. 管道运行（curl ... | python3 - auto）：__file__ 不存在，改为从
         AUTO_TUNE_SCRIPT_URL / DEFAULT_SCRIPT_URL 重新下载一份落盘。
    """
    os.makedirs(INSTALL_DIR, exist_ok=True)
    os.makedirs(CONFIG_DIR, exist_ok=True)

    install_path = os.path.join(INSTALL_DIR, "auto-tune.py")
    self_path = get_self_path()

    if self_path and os.path.isfile(self_path) and self_path != install_path:
        shutil.copy2(self_path, install_path)
        os.chmod(install_path, 0o755)
        logging.info("已复制自身到 %s", install_path)
    elif self_path and self_path == install_path:
        logging.info("已在目标安装路径运行，跳过复制")
    else:
        script_url = os.environ.get("AUTO_TUNE_SCRIPT_URL", DEFAULT_SCRIPT_URL)
        logging.info("检测到通过管道方式运行（无本地文件路径），从 %s 重新下载一份落盘", script_url)
        try:
            urllib.request.urlretrieve(script_url, install_path)
            os.chmod(install_path, 0o755)
        except Exception as e:
            logging.error(
                "下载失败: %s\n"
                "请确认 %s 是否可访问，或用 AUTO_TUNE_SCRIPT_URL=<正确地址> 环境变量覆盖后重试，例如：\n"
                "  curl -fsSL <你的raw地址> | sudo env AUTO_TUNE_SCRIPT_URL=<你的raw地址> python3 - auto",
                e, script_url,
            )
            sys.exit(1)

    with open(SERVICE_PATH, "w") as f:
        f.write(SERVICE_TEMPLATE.format(install_path=install_path, env_path=ENV_PATH))
    run("systemctl daemon-reload")
    logging.info("systemd service 已安装到 %s", SERVICE_PATH)
    return install_path


def cmd_install_service(args):
    require_root()

    install_path = install_self_and_service()

    if os.path.exists(ENV_PATH):
        logging.info("检测到已有配置 %s，保留不覆盖", ENV_PATH)
    else:
        with open(ENV_PATH, "w") as f:
            f.write(ENV_TEMPLATE)
        os.chmod(ENV_PATH, 0o640)
        logging.info("已生成配置文件模板: %s（默认 APPLY=false）", ENV_PATH)

    print(f"""
======================================================================
安装完成，还需要你手动确认以下几步：

1. 检查现状（不改任何东西）：
     sudo python3 {install_path} check --iface <你的网卡>

2. 编辑配置文件，填入网卡名 / classid / min-rate / max-ceil：
     sudo nano {ENV_PATH}

3. 确认已手动建好 htb class（脚本不会帮你建，避免误改现有网络配置）：
     tc qdisc add dev <网卡> root handle 1: htb default 10
     tc class add dev <网卡> parent 1: classid 1:10 htb rate 500mbit ceil 950mbit
     tc qdisc add dev <网卡> parent 1:10 handle 10: fq

4. （可选）检查/开启 BBR：
     sudo python3 {install_path} check
     sudo python3 {install_path} enable-bbr --apply

5. 先手动跑一次确认 dry-run 输出合理（默认 APPLY=false）：
     sudo python3 {install_path} tune --env-file {ENV_PATH}

6. 确认没问题后改成 APPLY=true 再用 systemd 常驻：
     sudo sed -i 's/^APPLY=false/APPLY=true/' {ENV_PATH}
     sudo systemctl enable --now auto-tune
     journalctl -u auto-tune -f

卸载：sudo python3 {install_path} uninstall
======================================================================
""")


def cmd_auto(args):
    """全自动：探测网卡/带宽/并发连接数 -> 按画像自动挑参数 -> 建 htb 拓扑 -> 开 BBR -> 写配置(APPLY=true) -> 装+启动 systemd。
    全程不需要手动确认，也不需要手动传参数，适合『一条 curl 命令跑完』的场景。

    以下参数如果不传，会根据探测到的并发连接数自动挑一套合适的值；传了就以传的为准：
      --min-pct / --max-pct       min-rate / max-ceil 占探测到的链路速率的比例
      --interval                  判断周期（秒）
      --retrans-pct-threshold     判定异常的重传率阈值（百分比）
    以下几个目前没有自动画像，用固定默认值，传了才会变：
      --up-step / --down-step     AIMD 每周期涨跌的比例
      --drop-threshold            判定异常的单周期 qdisc drop 数量阈值
      --cpu-pct-threshold          CPU 总体繁忙占比异常阈值
      --softirq-pct-threshold      软中断占比异常阈值
    带宽探测顺序：--link-mbit 手动指定 > 网卡自报速率(ethtool/sysfs) > 实测测速(Ookla Speedtest CLI) > 历史记录 > 保守默认值 1000。
    默认探测不到网卡速率就会自动测速一次，测出什么就用什么，不做额外判断。
    不想测的话用 --no-speedtest 关掉。
    """
    require_root()

    logging.info("===== 全自动模式：以下所有变更会直接生效，不再逐步确认 =====")

    # 1. 探测网卡
    iface = args.iface or detect_default_iface()
    if not iface:
        logging.error("自动探测网卡失败，请用 --iface 指定，例如 --iface eth0")
        sys.exit(1)
    logging.info("使用网卡: %s", iface)

    established = detect_established_connections()
    profile = pick_profile_by_concurrency(established)

    # 2. 探测链路速率：手动指定 > 网卡自报 > 实测测速 > 历史记录 > 保守默认值
    last_known = read_last_known_speed()
    speed_mbit = args.link_mbit or detect_link_speed_mbit(iface)
    trust_this_value = bool(speed_mbit)  # 手动指定/网卡自报的值直接信

    if speed_mbit:
        logging.info("探测到链路速率: %smbit", speed_mbit)
    elif args.no_speedtest:
        logging.info("网卡没有上报真实速率，且已用 --no-speedtest 关闭实测测速")
    else:
        logging.info("尝试实测一次（用 Ookla Speedtest CLI，会消耗一些流量，耗时数秒到十几秒）...")
        down_mbit, up_mbit = run_speedtest()
        if up_mbit:
            speed_mbit = int(up_mbit)
            trust_this_value = True
            logging.info(
                "实测完成: 上传≈%.1fmbit 下载≈%.1fmbit（出口限速用上传值作参考）",
                up_mbit, down_mbit or 0,
            )
        else:
            logging.warning(
                "实测失败（Speedtest CLI 没找到能连上的测速节点，可能是这台机器出不了公网、"
                "被墙、或者这条路径本身就不通），不采信任何结果"
            )

    if not speed_mbit and last_known:
        speed_mbit = int(last_known)
        trust_this_value = True
        logging.warning("这次没能探测到任何真实速率，沿用上次记录的 %smbit", speed_mbit)

    if not speed_mbit:
        speed_mbit = 1000
        trust_this_value = False
        logging.warning("最终没能测出真实速率，使用保守默认值 %smbit。可以用 --link-mbit 手动指定更准确的值。", speed_mbit)

    # 只记录『有依据』的判断结果，不把没有任何信息支撑的保守默认值当成历史基准存下来
    if trust_this_value:
        write_last_known_speed(speed_mbit)

    classid = args.classid or "1:10"

    logging.info("机器画像: %s -> 建议参数 interval=%ss retrans_pct_threshold=%s%% min_pct=%s max_pct=%s",
                 profile["label"], profile["interval"], profile["retrans_pct_threshold"],
                 profile["min_pct"], profile["max_pct"])

    min_pct = args.min_pct if args.min_pct is not None else profile["min_pct"]
    max_pct = args.max_pct if args.max_pct is not None else profile["max_pct"]
    min_rate_mbit = max(10, int(speed_mbit * min_pct))
    max_ceil_mbit = max(min_rate_mbit + 10, int(speed_mbit * max_pct))
    logging.info("自动计算范围: min-rate=%smbit(%.0f%%) max-ceil=%smbit(%.0f%%)",
                 min_rate_mbit, min_pct * 100, max_ceil_mbit, max_pct * 100)

    interval = args.interval if args.interval is not None else profile["interval"]
    up_step = args.up_step if args.up_step is not None else 0.05
    down_step = args.down_step if args.down_step is not None else 0.15
    retrans_pct_threshold = (
        args.retrans_pct_threshold if args.retrans_pct_threshold is not None
        else profile["retrans_pct_threshold"]
    )
    drop_threshold = args.drop_threshold if args.drop_threshold is not None else 1
    cpu_pct_threshold = args.cpu_pct_threshold if args.cpu_pct_threshold is not None else 90.0
    softirq_pct_threshold = args.softirq_pct_threshold if args.softirq_pct_threshold is not None else 30.0

    # 3. 建 htb 拓扑（已存在则跳过）
    ensure_htb_setup(iface, classid, min_rate_mbit, max_ceil_mbit, apply=True)

    # 4. 开 BBR + TCP buffer/conntrack 常规调优（各自写独立文件，互不覆盖）
    do_enable_bbr(apply=True)
    if not args.no_sysctl_tune:
        do_tune_sysctl(apply=True, speed_mbit=speed_mbit, established=established)

    # 5. 写配置文件（直接 APPLY=true，全自动模式不留 dry-run 缓冲）
    env_content = (
        f"IFACE={iface}\n"
        f"CLASSID={classid}\n"
        f"MIN_RATE={min_rate_mbit}mbit\n"
        f"MAX_CEIL={max_ceil_mbit}mbit\n"
        f"INTERVAL={interval}\n"
        f"UP_STEP={up_step}\n"
        f"DOWN_STEP={down_step}\n"
        f"RETRANS_PCT_THRESHOLD={retrans_pct_threshold}\n"
        f"DROP_THRESHOLD={drop_threshold}\n"
        f"CPU_PCT_THRESHOLD={cpu_pct_threshold}\n"
        f"SOFTIRQ_PCT_THRESHOLD={softirq_pct_threshold}\n"
        f"MAX_ONLY={'true' if args.max_only else 'false'}\n"
        f"APPLY=true\n"
    )
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(ENV_PATH, "w") as f:
        f.write(env_content)
    os.chmod(ENV_PATH, 0o640)
    logging.info("已写入配置 %s（APPLY=true）", ENV_PATH)

    # 6. 装自身 + systemd service，然后直接启动
    install_self_and_service()
    run("systemctl enable --now auto-tune")

    print(f"""
======================================================================
全自动部署完成，服务已启动。

查看实时日志: journalctl -u auto-tune -f
查看服务状态: systemctl status auto-tune
修改参数    : nano {ENV_PATH} && systemctl restart auto-tune
卸载        : {os.path.join(INSTALL_DIR, "auto-tune.py")} uninstall

注意：MAX_CEIL 是按探测到的网卡速率打折估算的，不是用 iperf3 实测出的真实
稳定带宽。如果后续发现重传/丢包频繁被触发下调，说明这个估算偏乐观，建议
找真实 peer 跑一次 iperf3，再用 --link-mbit 手动指定更准的值重新跑一次
auto，或者直接改配置文件里的 MAX_CEIL。
======================================================================
""")


def cmd_priority_ip(args):
    """给指定 IP（比如你自己固定用来测速的出口 IP）单独建一个高优先级的 htb class，
    不用再跟其他所有连接公平分带宽——htb 的 prio 数值越小优先级越高，当链路整体
    紧张时，这个 class 会被优先服务，其他流量走默认 class，排在它后面。

    这跟『整体不限速』不冲突：两个 class 的 ceil 都设成物理链路速率，平时没人抢的时候
    大家都能跑满；只有当总需求超过物理带宽、出现真实拥塞时，优先级才会体现出来——
    指定 IP 优先吃到带宽，其他流量分剩下的。"""
    require_root()

    iface = args.iface or detect_default_iface()
    if not iface:
        logging.error("自动探测网卡失败，请用 --iface 指定")
        sys.exit(1)

    line_rate_mbit = args.line_rate_mbit
    priority_rate_mbit = args.priority_rate_mbit or max(50, int(line_rate_mbit * 0.2))
    default_rate_mbit = max(10, line_rate_mbit - priority_rate_mbit)
    ip = args.ip

    cmds = [
        f"tc qdisc del dev {iface} root",  # 先清掉已有的，不管是不是本脚本建的（失败忽略，可能本来就没有）
        f"tc qdisc add dev {iface} root handle 1: htb default 20",
        f"tc class add dev {iface} parent 1: classid 1:1 htb rate {line_rate_mbit}mbit ceil {line_rate_mbit}mbit",
        f"tc class add dev {iface} parent 1:1 classid 1:10 htb rate {priority_rate_mbit}mbit ceil {line_rate_mbit}mbit prio 0",
        f"tc class add dev {iface} parent 1:1 classid 1:20 htb rate {default_rate_mbit}mbit ceil {line_rate_mbit}mbit prio 1",
        f"tc qdisc add dev {iface} parent 1:10 handle 10: fq",
        f"tc qdisc add dev {iface} parent 1:20 handle 20: fq",
        f"tc filter add dev {iface} parent 1: protocol ip prio 1 u32 match ip src {ip} flowid 1:10",
    ]

    logging.info(
        "计划为 %s 建立优先级拓扑：IP %s 单独进 1:10（prio 0，保底 %smbit，可借用到全速 %smbit），"
        "其他流量走 1:20（prio 1，保底 %smbit，同样可借用到全速）",
        iface, ip, priority_rate_mbit, line_rate_mbit, default_rate_mbit,
    )
    for c in cmds:
        logging.info("  %s", c)

    if not args.apply:
        logging.info("[dry-run] 未加 --apply，不会真正执行。确认无误后加 --apply 执行。")
        return

    for c in cmds:
        run(c, check=False)  # qdisc del 那条大概率会因为『本来就没有』报错，忽略即可

    logging.info("完成。用 `tc -s qdisc show dev %s` 和 `tc filter show dev %s` 确认状态。", iface, iface)
    logging.info("撤销：tc qdisc del dev %s root（会把这套优先级拓扑连同分类一起清空，回到无 tc 限制状态）", iface)


def cmd_uninstall(args):
    require_root()
    run("systemctl stop auto-tune", check=False)
    run("systemctl disable auto-tune", check=False)
    if os.path.exists(SERVICE_PATH):
        os.remove(SERVICE_PATH)
        logging.info("已删除 %s", SERVICE_PATH)
    run("systemctl daemon-reload")

    if os.path.exists(INSTALL_DIR):
        shutil.rmtree(INSTALL_DIR)
        logging.info("已删除 %s", INSTALL_DIR)

    if args.purge_config and os.path.exists(CONFIG_DIR):
        shutil.rmtree(CONFIG_DIR)
        logging.info("已删除配置目录 %s", CONFIG_DIR)
    elif os.path.exists(CONFIG_DIR):
        logging.info("保留配置目录 %s（加 --purge-config 可一并删除）", CONFIG_DIR)

    logging.info("完成。如需清除之前手动建的 tc qdisc/class 或 sysctl 调优文件，请自行处理，例如：")
    logging.info("  tc qdisc del dev <网卡> root")
    logging.info("  rm -f %s && sysctl --system", SYSCTL_TUNE_FILE)


# --------------------------------------------------------------------------
# 入口
# --------------------------------------------------------------------------

def read_tty_line(prompt):
    """从 /dev/tty 直接读一行，绕开 `curl | python3 -` 模式下已经被脚本内容占用/耗尽的 stdin。
    没有可用终端（比如非交互式 CI）时返回 None。"""
    try:
        with open("/dev/tty", "r") as tty:
            sys.stdout.write(prompt)
            sys.stdout.flush()
            line = tty.readline()
        return line.rstrip("\n")
    except OSError:
        return None


def run_menu():
    require_root()
    print("""
======================================================================
  auto-tune — VPS 网络调优（BBR + 出口带宽 AIMD 动态调整）
======================================================================
  1) 全自动部署   探测网卡/带宽 -> 建拓扑 -> 开 BBR -> 写配置 -> 启动服务  [默认]
  2) 只读检查     查看当前 BBR / qdisc / sysctl 状态，不改任何东西
  3) 卸载         停止并移除已安装的服务和文件
  0) 退出
======================================================================""")
    raw = read_tty_line("请输入数字后回车（直接回车 = 1）: ")
    if raw is None:
        logging.warning("没有检测到可用终端（/dev/tty 不可用），无法交互，默认执行「全自动部署」")
        choice = "1"
    else:
        choice = raw.strip() or "1"

    if choice == "1":
        cmd_auto(argparse.Namespace(
            iface=None, classid=None, link_mbit=None,
            min_pct=None, max_pct=None, interval=None,
            up_step=None, down_step=None,
            retrans_pct_threshold=None, drop_threshold=None,
            cpu_pct_threshold=None, softirq_pct_threshold=None,
            no_speedtest=False, max_only=False, no_sysctl_tune=False,
        ))
    elif choice == "2":
        cmd_check(argparse.Namespace(iface=None, classid=None))
    elif choice == "3":
        cmd_uninstall(argparse.Namespace(purge_config=False))
    elif choice == "0":
        print("已退出，未做任何修改。")
        sys.exit(0)
    else:
        print(f"无效输入: {choice!r}，未做任何修改。")
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="auto-tune: BBR 调优 + AIMD 动态带宽调整（单文件版）")
    sub = ap.add_subparsers(dest="command")

    p_check = sub.add_parser("check", help="只读检查当前 BBR/qdisc/sysctl/tc 状态")
    p_check.add_argument("--iface", help="网卡名，附带查看 qdisc 状态")
    p_check.add_argument("--classid", help="附带查看指定 class 状态，需配合 --iface")
    p_check.set_defaults(func=cmd_check)

    p_bbr = sub.add_parser("enable-bbr", help="开启 BBR + fq")
    p_bbr.add_argument("--apply", action="store_true", help="真正写入并生效；不加则只打印计划")
    p_bbr.set_defaults(func=cmd_enable_bbr)

    p_sysctl = sub.add_parser("tune-sysctl", help="调 TCP buffer / conntrack 表大小 / 常规网络参数（跟 BBR 分开管理）")
    p_sysctl.add_argument("--speed-mbit", dest="speed_mbit", type=int,
                           help="按这个链路速率决定 buffer 大小，不给则用历史记录，都没有则按保守档位处理")
    p_sysctl.add_argument("--apply", action="store_true", help="真正写入并生效；不加则只打印计划")
    p_sysctl.set_defaults(func=cmd_tune_sysctl)

    p_tune = sub.add_parser("tune", help="运行 AIMD 动态带宽调整循环")
    p_tune.add_argument("--iface")
    p_tune.add_argument("--classid")
    p_tune.add_argument("--min-rate", dest="min_rate")
    p_tune.add_argument("--max-ceil", dest="max_ceil")
    p_tune.add_argument("--interval", type=float)
    p_tune.add_argument("--up-step", dest="up_step", type=float)
    p_tune.add_argument("--down-step", dest="down_step", type=float)
    p_tune.add_argument("--retrans-pct-threshold", dest="retrans_pct_threshold", type=float,
                         help="重传率超过这个百分比视为异常，默认 2.0（即 2%%）")
    p_tune.add_argument("--drop-threshold", dest="drop_threshold", type=int)
    p_tune.add_argument("--cpu-pct-threshold", dest="cpu_pct_threshold", type=float,
                         help="CPU 总体繁忙占比异常阈值(%%)，默认 90")
    p_tune.add_argument("--softirq-pct-threshold", dest="softirq_pct_threshold", type=float,
                         help="软中断占比异常阈值(%%)，默认 30")
    p_tune.add_argument("--apply", action="store_true", help="真正下发 tc 命令；不加则只打印计划")
    p_tune.add_argument("--env-file", dest="env_file", help="从配置文件读取参数（CLI 参数优先级更高）")
    p_tune.add_argument("--max-only", dest="max_only", action="store_true",
                         help="直接跑满 max-ceil，不再自动降速，只监控展示（不在乎稳不稳、只要跑满带宽时用）")
    p_tune.add_argument("--max-iterations", dest="max_iterations", type=int, default=0)
    p_tune.set_defaults(func=cmd_tune)

    p_install = sub.add_parser("install-service", help="把自己安装为 systemd 常驻服务（手动模式，需要你自己确认再开火）")
    p_install.set_defaults(func=cmd_install_service)

    p_auto = sub.add_parser("auto", help="全自动：探测网卡/带宽、建拓扑、开 BBR、写配置、启动服务，一步到位")
    p_auto.add_argument("--iface", help="手动指定网卡，不给则自动探测默认路由网卡")
    p_auto.add_argument("--classid", help="手动指定 classid，默认 1:10")
    p_auto.add_argument("--link-mbit", dest="link_mbit", type=int,
                         help="手动指定链路速率(Mbit)，不给则尝试自动探测，探测不到则用保守默认值 1000")
    p_auto.add_argument("--min-pct", dest="min_pct", type=float,
                         help="min-rate 占链路速率的比例，不给则按探测到的并发连接数自动挑（低并发 0.5，高并发 0.6）")
    p_auto.add_argument("--max-pct", dest="max_pct", type=float,
                         help="max-ceil 占链路速率的比例，不给则按并发自动挑（低并发 0.85，中高并发 0.9）")
    p_auto.add_argument("--interval", type=float,
                         help="判断周期（秒），不给则按并发自动挑（低并发 8s，中并发 10s，高并发 20s）")
    p_auto.add_argument("--up-step", dest="up_step", type=float, help="无异常时每周期上调比例，默认 0.05")
    p_auto.add_argument("--down-step", dest="down_step", type=float, help="异常时每周期下调比例，默认 0.15")
    p_auto.add_argument("--retrans-pct-threshold", dest="retrans_pct_threshold", type=float,
                         help="重传率异常阈值(%%)，不给则按并发自动挑（低/中并发 2.0，高并发 1.5）")
    p_auto.add_argument("--drop-threshold", dest="drop_threshold", type=int,
                         help="单周期 qdisc drop 异常阈值，默认 1")
    p_auto.add_argument("--cpu-pct-threshold", dest="cpu_pct_threshold", type=float,
                         help="CPU 总体繁忙占比异常阈值(%%)，默认 90")
    p_auto.add_argument("--softirq-pct-threshold", dest="softirq_pct_threshold", type=float,
                         help="软中断占比异常阈值(%%)，默认 30")
    p_auto.add_argument("--no-speedtest", dest="no_speedtest", action="store_true",
                         help="网卡探测不到真实速率时，不要额外做一次实测（默认会做）")
    p_auto.add_argument("--max-only", dest="max_only", action="store_true",
                         help="直接跑满 max-ceil，不再自动降速，只监控展示（不在乎稳不稳、只要跑满带宽时用）")
    p_auto.add_argument("--no-sysctl-tune", dest="no_sysctl_tune", action="store_true",
                         help="不要自动调 TCP buffer/conntrack 表大小等常规 sysctl 参数（默认会调）")
    p_auto.set_defaults(func=cmd_auto)

    p_speedtest = sub.add_parser("speedtest", help="单独测一次上传/下载速度（用 Ookla Speedtest CLI，不需要你自己准备对端）")
    p_speedtest.set_defaults(func=cmd_speedtest)

    p_priority = sub.add_parser("priority-ip", help="给指定 IP 单独建高优先级 htb class，不用跟其他连接公平分带宽")
    p_priority.add_argument("--ip", required=True, help="要给优先级的源 IP（比如你固定用来测速的出口 IP），支持 CIDR 如 1.2.3.4/32")
    p_priority.add_argument("--iface", help="网卡名，不给则自动探测")
    p_priority.add_argument("--line-rate-mbit", dest="line_rate_mbit", type=int, required=True,
                             help="这台机器物理链路速率上限(Mbit)，两个 class 的 ceil 都设成这个值，不建议超过真实带宽")
    p_priority.add_argument("--priority-rate-mbit", dest="priority_rate_mbit", type=int,
                             help="优先级 class 的保底速率(Mbit)，不给则默认取 line-rate 的 20%%")
    p_priority.add_argument("--apply", action="store_true", help="真正执行 tc 命令；不加则只打印计划")
    p_priority.set_defaults(func=cmd_priority_ip)

    p_uninstall = sub.add_parser("uninstall", help="卸载 systemd 服务和安装的文件")
    p_uninstall.add_argument("--purge-config", action="store_true", help="连配置文件一起删除")
    p_uninstall.set_defaults(func=cmd_uninstall)

    args = ap.parse_args()
    setup_logging()

    if args.command is None:
        # 没带任何子命令 —— 典型场景就是 `curl ... | sudo python3 -`，直接进数字菜单
        run_menu()
    else:
        args.func(args)


if __name__ == "__main__":
    main()

PYEOF
chmod +x "$PY_PATH"
exec python3 "$PY_PATH" "$@"
