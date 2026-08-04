#!/usr/bin/env bash
# auto-tune.sh —— 一键安装/运行入口（bash 外壳 + 内嵌 Python payload）
#
# 用法：
#   bash <(curl -Ls https://raw.githubusercontent.com/mfxyoffice-source/auto-tune/main/auto-tune.sh)
#
# 这个 bash 脚本本身不做网络调优的实际逻辑，只负责三件事：
#   1. 检查 root 权限 / python3 是否存在
#   2. 把内嵌的 Python 源码落盘到 /opt/auto-tune/auto-tune.py
#   3. exec 执行它，把命令行参数原样透传（不带参数时会进入数字菜单）

set -euo pipefail

INSTALL_DIR="/opt/auto-tune"
CONFIG_DIR="/etc/auto-tune"
PY_PATH="$INSTALL_DIR/auto-tune.py"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "请用 root 权限运行" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "未找到 python3，请先安装后重试，例如：" >&2
    echo "  apt update && apt install -y python3   # Debian/Ubuntu" >&2
    echo "  yum install -y python3                 # CentOS/RHEL" >&2
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
SERVICE_PATH = "/etc/systemd/system/auto-tune.service"
SYSCTL_BACKUP_DIR = "/etc/auto-tune/sysctl-backup"
SYSCTL_TUNE_FILE = "/etc/sysctl.d/99-auto-tune.conf"

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


def run(cmd, check=True):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
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

    logging.info(
        "启动 AIMD 调优 | iface=%s classid=%s 起点=%s 范围=[%s, %s] 周期=%ss "
        "重传率阈值=%.2f%% 模式=%s",
        iface, classid, bps_to_rate_str(current), min_rate, max_ceil, interval,
        retrans_pct_threshold,
        "APPLY" if apply_flag else "DRY-RUN（不会下发配置）",
    )

    last_drops = get_qdisc_drops(iface)
    last_retrans, last_outsegs = get_tcp_stats()
    iteration = 0

    try:
        while True:
            time.sleep(interval)
            iteration += 1

            drops_now = get_qdisc_drops(iface)
            retrans_now, outsegs_now = get_tcp_stats()

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

            anomaly = (drop_delta > drop_threshold) or (retrans_pct > retrans_pct_threshold)

            if anomaly:
                new_rate = max(min_bps, current * (1 - down_step))
                logging.info(
                    "[周期 %d] 异常: drop+%d 重传率=%.2f%%(retrans+%d/out+%d) -> 下调 %s -> %s",
                    iteration, drop_delta, retrans_pct, retrans_delta, outsegs_delta,
                    bps_to_rate_str(current), bps_to_rate_str(new_rate),
                )
            else:
                new_rate = min(max_bps, current * (1 + up_step))
                if new_rate != current:
                    logging.info(
                        "[周期 %d] 正常: drop+%d 重传率=%.2f%%(retrans+%d/out+%d) -> 上调 %s -> %s",
                        iteration, drop_delta, retrans_pct, retrans_delta, outsegs_delta,
                        bps_to_rate_str(current), bps_to_rate_str(new_rate),
                    )
                else:
                    logging.info(
                        "[周期 %d] 正常，已在上限 %s，保持不变（重传率=%.2f%%）",
                        iteration, bps_to_rate_str(current), retrans_pct,
                    )

            if abs(new_rate - current) / current > 0.005:
                apply_rate(iface, classid, new_rate * 0.9, new_rate, dry_run)
                current = new_rate

            last_drops = drops_now
            last_retrans = retrans_now if retrans_now is not None else last_retrans
            last_outsegs = outsegs_now if outsegs_now is not None else last_outsegs

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
    """全自动：探测网卡/带宽 -> 建 htb 拓扑 -> 开 BBR -> 写配置(APPLY=true) -> 装+启动 systemd。
    全程不需要手动确认，适合『一条 curl 命令跑完』的场景。"""
    require_root()

    logging.info("===== 全自动模式：以下所有变更会直接生效，不再逐步确认 =====")

    # 1. 探测网卡
    iface = args.iface or detect_default_iface()
    if not iface:
        logging.error("自动探测网卡失败，请用 --iface 指定，例如 --iface eth0")
        sys.exit(1)
    logging.info("使用网卡: %s", iface)

    # 2. 探测链路速率，探测不到就用保守默认值
    speed_mbit = args.link_mbit or detect_link_speed_mbit(iface)
    if not speed_mbit:
        speed_mbit = 1000
        logging.warning(
            "无法探测 %s 的真实链路速率（云厂商虚拟网卡常见），"
            "使用保守默认值 %smbit。如果你清楚实际带宽，用 --link-mbit 指定更准确。",
            iface, speed_mbit,
        )
    else:
        logging.info("探测到链路速率: %smbit", speed_mbit)

    classid = args.classid or "1:10"
    min_rate_mbit = max(10, int(speed_mbit * 0.5))
    max_ceil_mbit = max(min_rate_mbit + 10, int(speed_mbit * 0.9))
    logging.info("自动计算范围: min-rate=%smbit max-ceil=%smbit（链路速率的 50%%~90%%）",
                 min_rate_mbit, max_ceil_mbit)

    # 3. 建 htb 拓扑（已存在则跳过）
    ensure_htb_setup(iface, classid, min_rate_mbit, max_ceil_mbit, apply=True)

    # 4. 开 BBR
    do_enable_bbr(apply=True)

    # 5. 写配置文件（直接 APPLY=true，全自动模式不留 dry-run 缓冲）
    env_content = (
        f"IFACE={iface}\n"
        f"CLASSID={classid}\n"
        f"MIN_RATE={min_rate_mbit}mbit\n"
        f"MAX_CEIL={max_ceil_mbit}mbit\n"
        f"INTERVAL=8\n"
        f"UP_STEP=0.05\n"
        f"DOWN_STEP=0.15\n"
        f"RETRANS_PCT_THRESHOLD=2.0\n"
        f"DROP_THRESHOLD=1\n"
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
        cmd_auto(argparse.Namespace(iface=None, classid=None, link_mbit=None))
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
    p_tune.add_argument("--apply", action="store_true", help="真正下发 tc 命令；不加则只打印计划")
    p_tune.add_argument("--env-file", dest="env_file", help="从配置文件读取参数（CLI 参数优先级更高）")
    p_tune.add_argument("--max-iterations", dest="max_iterations", type=int, default=0)
    p_tune.set_defaults(func=cmd_tune)

    p_install = sub.add_parser("install-service", help="把自己安装为 systemd 常驻服务（手动模式，需要你自己确认再开火）")
    p_install.set_defaults(func=cmd_install_service)

    p_auto = sub.add_parser("auto", help="全自动：探测网卡/带宽、建拓扑、开 BBR、写配置、启动服务，一步到位")
    p_auto.add_argument("--iface", help="手动指定网卡，不给则自动探测默认路由网卡")
    p_auto.add_argument("--classid", help="手动指定 classid，默认 1:10")
    p_auto.add_argument("--link-mbit", dest="link_mbit", type=int,
                         help="手动指定链路速率(Mbit)，不给则尝试自动探测，探测不到则用保守默认值 1000")
    p_auto.set_defaults(func=cmd_auto)

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
