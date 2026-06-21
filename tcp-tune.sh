#!/bin/sh
set -eu

APP_NAME="TCP 双端调优器"
APP_VERSION="0.1.0"
REPO_URL="https://github.com/10000ge10000/TCP-optimization"
RAW_BASE_URL="https://raw.githubusercontent.com/10000ge10000/TCP-optimization/main"
STATE_DIR="${TCP_TUNE_STATE_DIR:-/var/lib/tcp-tune}"
SYSCTL_FILE="${TCP_TUNE_SYSCTL_FILE:-/etc/sysctl.d/99-tcp-tune.conf}"
AGENT_PORT="${TCP_TUNE_AGENT_PORT:-39188}"
IPERF_PORT="${TCP_TUNE_IPERF_PORT:-5201}"
SESSION_TTL="${TCP_TUNE_SESSION_TTL:-1800}"
DRY_RUN="${TCP_TUNE_DRY_RUN:-0}"
LISTEN_PUBLIC_URL="${TCP_TUNE_PUBLIC_URL:-}"

COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""
PROMPT_REPLY=""

setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    COLOR_RESET="$(printf '\033[0m')"
    COLOR_BOLD="$(printf '\033[1m')"
    COLOR_DIM="$(printf '\033[2m')"
    COLOR_RED="$(printf '\033[31m')"
    COLOR_GREEN="$(printf '\033[32m')"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_BLUE="$(printf '\033[34m')"
    COLOR_CYAN="$(printf '\033[36m')"
  fi
}

setup_colors

clear_screen() {
  if [ -t 1 ]; then
    printf '\033[2J\033[H'
  fi
}

has_interactive_input() {
  [ -r /dev/tty ] || [ -t 0 ]
}

prompt_read() {
  prompt="$1"
  printf "%s" "$prompt"
  if [ -r /dev/tty ]; then
    IFS= read -r PROMPT_REPLY < /dev/tty || return 1
  else
    IFS= read -r PROMPT_REPLY || return 1
  fi
  return 0
}

pause_for_enter() {
  has_interactive_input || return 0
  printf "\n%s按回车返回菜单...%s" "$COLOR_DIM" "$COLOR_RESET"
  if [ -r /dev/tty ]; then
    IFS= read -r PROMPT_REPLY < /dev/tty || true
  else
    IFS= read -r PROMPT_REPLY || true
  fi
}

print_rule() {
  printf "%s%s%s\n" "$COLOR_DIM" "------------------------------------------------------------" "$COLOR_RESET"
}

print_header() {
  title="$1"
  printf "%s%s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
  print_rule
}

print_kv() {
  label="$1"
  value="$2"
  printf "  %s%-14s%s %s\n" "$COLOR_BLUE" "$label" "$COLOR_RESET" "$value"
}

die() {
  printf "%s错误：%s%s\n" "$COLOR_RED" "$*" "$COLOR_RESET" >&2
  exit 1
}

info() {
  printf "%s[INFO]%s %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
  printf "%s[WARN]%s %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    die "此操作需要 root 权限。请使用 root 用户或 sudo 运行。"
  fi
}

ensure_state_dir() {
  need_root
  mkdir -p "$STATE_DIR/backups" "$STATE_DIR/sessions" "$STATE_DIR/rolled-back"
}

detect_os() {
  OS_ID="unknown"
  OS_NAME="Unknown"
  OS_FAMILY="linux"
  PKG_MANAGER="none"

  if [ "$(uname -s 2>/dev/null || echo unknown)" = "Darwin" ]; then
    OS_ID="macos"
    OS_NAME="macOS"
    OS_FAMILY="macos"
    PKG_MANAGER="brew"
    return 0
  fi

  if [ -f /etc/openwrt_release ]; then
    OS_ID="openwrt"
    OS_NAME="OpenWrt"
    OS_FAMILY="openwrt"
    PKG_MANAGER="opkg"
    return 0
  fi

  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
  fi

  case "$OS_ID" in
    debian|ubuntu|linuxmint|raspbian)
      PKG_MANAGER="apt"
      ;;
    almalinux|rocky|centos|fedora|rhel)
      if have_cmd dnf; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
      ;;
    openwrt)
      OS_FAMILY="openwrt"
      PKG_MANAGER="opkg"
      ;;
    *)
      if have_cmd apt-get; then PKG_MANAGER="apt"; fi
      if have_cmd dnf; then PKG_MANAGER="dnf"; fi
      if have_cmd yum; then PKG_MANAGER="yum"; fi
      if have_cmd opkg; then PKG_MANAGER="opkg"; OS_FAMILY="openwrt"; fi
      ;;
  esac
}

install_pkg() {
  pkg="$1"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] 将通过 $PKG_MANAGER 安装 $pkg"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      apt-get install -y "$pkg"
      ;;
    dnf)
      dnf install -y "$pkg"
      ;;
    yum)
      yum install -y "$pkg"
      ;;
    opkg)
      opkg update
      opkg install "$pkg"
      ;;
    brew)
      brew install "$pkg"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_dependency() {
  cmd="$1"
  pkg="$2"
  if have_cmd "$cmd"; then
    return 0
  fi
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    info "缺少 $cmd，尝试通过 $PKG_MANAGER 安装 $pkg"
    install_pkg "$pkg" || die "无法自动安装 $pkg，请手动安装后重试。"
    return 0
  fi
  if has_interactive_input; then
    if ! prompt_read "缺少 $cmd，是否立即通过 $PKG_MANAGER 安装 $pkg？[y/N] "; then
      install_answer=""
    else
      install_answer="$PROMPT_REPLY"
    fi
    case "$install_answer" in
      y|Y)
        install_pkg "$pkg" || die "无法自动安装 $pkg，请手动安装后重试。"
        return 0
        ;;
    esac
  fi
  warn "缺少 $cmd。可使用 --yes 自动安装，或手动安装 $pkg。"
  return 1
}

install_runtime_deps() {
  detect_os
  case "$OS_FAMILY" in
    openwrt)
      ensure_dependency iperf3 iperf3 || true
      ensure_dependency curl curl || true
      if ! have_cmd tc; then
        warn "OpenWrt 缺少 tc。建议安装：opkg update && opkg install tc-full kmod-ifb kmod-sched-cake"
      fi
      ;;
    macos)
      ensure_dependency iperf3 iperf3 || true
      ensure_dependency curl curl || true
      ;;
    *)
      ensure_dependency iperf3 iperf3 || true
      ensure_dependency curl curl || true
      ;;
  esac
}

doctor() {
  detect_os
  echo "$APP_NAME $APP_VERSION"
  echo "仓库：$REPO_URL"
  echo "系统：$OS_NAME"
  echo "系统族：$OS_FAMILY"
  echo "包管理器：$PKG_MANAGER"
  echo "内核：$(uname -a 2>/dev/null || echo unknown)"
  echo
  echo "依赖状态："
  for cmd in iperf3 curl wget sysctl tc ip python3; do
    if have_cmd "$cmd"; then
      echo "  $cmd: $(command -v "$cmd")"
    else
      echo "  $cmd: 缺失"
    fi
  done
  echo
  echo "端口配置：Agent=$AGENT_PORT iperf3=$IPERF_PORT TTL=${SESSION_TTL}s"
  echo "状态目录：$STATE_DIR"
  echo "sysctl 文件：$SYSCTL_FILE"
  echo
  openwrt_advice
}

install_only() {
  need_root
  install_runtime_deps
  echo "依赖安装/检查完成。"
}

profile_exists() {
  case "$1" in
    "稳健入门"|"均衡通用"|"中距增强"|"高带宽增强"|"长距大带宽") return 0 ;;
    stable|balanced|medium|boost|longhaul) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_profile() {
  case "$1" in
    "稳健入门"|stable) echo "稳健入门" ;;
    "均衡通用"|balanced) echo "均衡通用" ;;
    "中距增强"|medium) echo "中距增强" ;;
    "高带宽增强"|boost) echo "高带宽增强" ;;
    "长距大带宽"|longhaul) echo "长距大带宽" ;;
    *) die "未知预设：$1" ;;
  esac
}

profile_values() {
  name="$(normalize_profile "$1")"
  case "$name" in
    "稳健入门")
      echo "6815744 67108864 33554432 4096 87380 67108864 4096 16384 33554432"
      ;;
    "均衡通用")
      echo "6815744 67108864 67108864 4096 87380 67108864 4096 16384 67108864"
      ;;
    "中距增强")
      echo "6815744 89653247 43033559 8192 87380 89653247 8192 65536 43033559"
      ;;
    "高带宽增强")
      echo "6815744 105062399 50429951 8192 87380 105062399 8192 65536 50429951"
      ;;
    "长距大带宽")
      echo "6815744 186777599 89653247 8192 87380 186777599 8192 65536 89653247"
      ;;
  esac
}

preferred_qdisc() {
  detect_os
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [ "$OS_FAMILY" = "openwrt" ]; then
    case "$current_qdisc" in
      cake|fq_codel|fq) echo "$current_qdisc" ;;
      *) echo "fq_codel" ;;
    esac
    return 0
  fi
  echo "fq"
}

list_profiles() {
  cat <<'EOF'
可选 TCP 预设：

1. 稳健入门
   接收 64MiB / 发送 32MiB，保守非对称，适合首次尝试。

2. 均衡通用
   接收 64MiB / 发送 64MiB，默认推荐，适合大多数 VPS。

3. 中距增强
   接收约 85MiB / 发送约 41MiB，适合中等 RTT、中高带宽链路。

4. 高带宽增强
   接收约 100MiB / 发送约 48MiB，适合高带宽跨境链路。

5. 长距大带宽
   接收约 178MiB / 发送约 85MiB，适合高 RTT、高 BDP 链路。

英文别名：stable, balanced, medium, boost, longhaul
EOF
}

memory_mb() {
  awk '/MemTotal/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 1024}' /proc/meminfo 2>/dev/null || echo 1024
}

memory_cap_bytes() {
  memory_mb_value="$1"
  aggressive="${2:-0}"
  awk -v mem="$memory_mb_value" -v aggressive="$aggressive" '
    function clamp(v, min, max) {
      if (v < min) return min
      if (v > max) return max
      return v
    }
    BEGIN {
      mem_bytes = mem * 1024 * 1024
      if (mem <= 256) ratio = 0.06
      else if (mem <= 512) ratio = 0.08
      else if (mem <= 1024) ratio = 0.10
      else if (mem <= 2048) ratio = 0.12
      else ratio = 0.15
      if (aggressive == 1 && mem > 512) ratio += 0.03
      printf "%d\n", clamp(int(mem_bytes * ratio), 4 * 1024 * 1024, 256 * 1024 * 1024)
    }
  '
}

recommend_values() {
  local_mbps="$1"
  peer_mbps="$2"
  rtt_ms="$3"
  memory_mb_value="$4"
  objective="$5"
  ramp_rate="${6:-0.79}"
  aggressive="${7:-0}"

  awk -v local="$local_mbps" -v peer="$peer_mbps" -v rtt="$rtt_ms" -v mem="$memory_mb_value" \
      -v objective="$objective" -v ramp="$ramp_rate" -v aggressive="$aggressive" '
    function clamp(v, min, max) {
      if (v < min) return min
      if (v > max) return max
      return v
    }
    function ceil(v) {
      return int(v) == v ? v : int(v) + 1
    }
    BEGIN {
      if (local <= 0 || peer <= 0 || rtt <= 0 || mem <= 0) {
        print "ERR invalid numeric input"
        exit 2
      }

      min_bw = local < peer ? local : peer
      base_bdp = ceil((min_bw * 1024 * 1024 / 8) * rtt / 1000)
      if (base_bdp < 16384) base_bdp = 16384

      mem_bytes = mem * 1024 * 1024
      if (mem <= 256) {
        max_ratio = 0.06
        mem_class = "low"
      } else if (mem <= 512) {
        max_ratio = 0.08
        mem_class = "small"
      } else if (mem <= 1024) {
        max_ratio = 0.10
        mem_class = "medium"
      } else if (mem <= 2048) {
        max_ratio = 0.12
        mem_class = "high"
      } else {
        max_ratio = 0.15
        mem_class = "large"
      }
      if (aggressive == 1 && mem > 512) max_ratio += 0.03
      mem_cap = int(mem_bytes * max_ratio)
      mem_cap = clamp(mem_cap, 4 * 1024 * 1024, 256 * 1024 * 1024)

      latency_factor = clamp(rtt / 40, 1, 5)
      ratio = local / peer
      if (ratio <= 0) ratio = 1
      high_latency = rtt > 120 ? 1 : 0

      if (objective == "throughput") {
        recv_mult = high_latency ? 4.5 : 3.0
        send_mult = high_latency ? 2.2 : 1.5
      } else if (objective == "startup") {
        recv_mult = high_latency ? 2.8 : 2.0
        send_mult = high_latency ? 1.2 : 0.9
      } else {
        recv_mult = high_latency ? 3.2 : 2.0
        send_mult = high_latency ? 1.5 : 1.0
      }

      if (high_latency) {
        bandwidth_factor = clamp(2 * sqrt(ratio) * latency_factor, 1.5, 5)
        effective_bw = local * bandwidth_factor
        if (effective_bw > 2 * peer) effective_bw = 2 * peer
        model_bdp = ceil((effective_bw * 1024 * 1024 / 8) * rtt / 1000)
      } else {
        model_bdp = base_bdp
      }

      if (mem <= 256) {
        recv_mult *= 0.65
        send_mult *= 0.65
      } else if (mem <= 512) {
        recv_mult *= 0.8
        send_mult *= 0.8
      } else if (mem > 2048 && aggressive == 1) {
        recv_mult *= 1.2
        send_mult *= 1.15
      }

      if (ramp < 0.1) ramp = 0.1
      if (ramp > 1) ramp = 1
      if (objective == "startup") {
        recv_mult *= 0.9 + ramp * 0.25
        send_mult *= 0.85 + ramp * 0.20
      } else {
        recv_mult *= ramp
        send_mult *= ramp
      }

      rmem = int(model_bdp * recv_mult)
      wmem = int(model_bdp * send_mult)
      rmem = clamp(rmem, 4 * 1024 * 1024, mem_cap)
      wmem = clamp(wmem, 4 * 1024 * 1024, mem_cap)

      if (objective == "startup") {
        notsent = clamp(int(model_bdp / 32), 16384, 131072)
      } else if (objective == "retrans") {
        notsent = clamp(int(model_bdp / 16 * ramp), 32768, 524288)
      } else {
        notsent = clamp(int(model_bdp / 16), 16384, 524288)
      }
      adv = int(clamp(ceil(latency_factor * (objective == "throughput" ? 1.4 : 1.0)), 2, 8))
      backlog = int(clamp(8192 + model_bdp / 65536 * latency_factor, 8192, mem <= 512 ? 16384 : 32768))
      somaxconn = int(clamp(backlog * 0.5, 2560, mem <= 512 ? 8192 : 16384))
      synbacklog = int(clamp(backlog * 1.5, 8192, mem <= 512 ? 32768 : 65536))
      optmem = int(clamp(model_bdp / 32, 81920, 262144))

      printf "%d %d %d %d %d %d %d %d %s %d\n", rmem, wmem, adv, notsent, backlog, somaxconn, synbacklog, optmem, mem_class, base_bdp
    }
  '
}

print_recommendation() {
  local_mbps="$1"
  peer_mbps="$2"
  rtt_ms="$3"
  memory_mb_value="$4"
  objective="$5"
  ramp_rate="${6:-0.79}"
  aggressive="${7:-0}"

  values="$(recommend_values "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive")"
  case "$values" in
    ERR*) die "$values" ;;
  esac
  # shellcheck disable=SC2086
  set -- $values
  rmem="$1"
  wmem="$2"
  adv="$3"
  notsent="$4"
  backlog="$5"
  somaxconn="$6"
  synbacklog="$7"
  optmem="$8"
  mem_class="$9"
  shift 9
  base_bdp="$1"

  echo "智能推荐结果："
  echo "  目标：$objective"
  echo "  基础 BDP：$base_bdp bytes"
  echo "  内存档位：$mem_class (${memory_mb_value}MiB)"
  echo "  net.core.rmem_max = $rmem"
  echo "  net.core.wmem_max = $wmem"
  echo "  net.ipv4.tcp_rmem = 4096 87380 $rmem"
  echo "  net.ipv4.tcp_wmem = 4096 65536 $wmem"
  echo "  net.ipv4.tcp_adv_win_scale = $adv"
  echo "  net.ipv4.tcp_notsent_lowat = $notsent"
  echo "  net.core.netdev_max_backlog = $backlog"
  echo "  net.core.somaxconn = $somaxconn"
  echo "  net.ipv4.tcp_max_syn_backlog = $synbacklog"
  echo "  net.core.optmem_max = $optmem"
}

backup_state() {
  ensure_state_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$STATE_DIR/backups/$ts"
  mkdir -p "$dir"
  if [ -f "$SYSCTL_FILE" ]; then
    cp "$SYSCTL_FILE" "$dir/99-tcp-tune.conf"
  fi
  : > "$dir/restore-current.conf"
  for key in \
    fs.file-max \
    net.ipv4.tcp_no_metrics_save \
    net.ipv4.tcp_ecn \
    net.ipv4.tcp_frto \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_rfc1337 \
    net.ipv4.tcp_sack \
    net.ipv4.tcp_fack \
    net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_adv_win_scale \
    net.ipv4.tcp_moderate_rcvbuf \
    net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_notsent_lowat \
    net.ipv4.tcp_limit_output_bytes \
    net.ipv4.tcp_autocorking \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.core.optmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control
  do
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    [ -n "$value" ] || continue
    echo "$key = $value" >> "$dir/restore-current.conf"
  done
  sysctl -a 2>/dev/null | grep -E '^(fs.file-max|net\.core\.rmem_max|net\.core\.wmem_max|net\.ipv4\.tcp_|net\.ipv4\.udp_|net\.core\.default_qdisc|net\.ipv[46]\.conf\.)' > "$dir/sysctl-current.txt" || true
  if have_cmd tc && have_cmd ip; then
    ip link show > "$dir/ip-link.txt" 2>/dev/null || true
    tc qdisc show > "$dir/tc-qdisc.txt" 2>/dev/null || true
  fi
  echo "$dir"
}

write_sysctl_config() {
  profile="$1"
  values="$(profile_values "$profile")"
  # shellcheck disable=SC2086
  set -- $values
  fs_file_max="$1"
  rmem_max="$2"
  wmem_max="$3"
  tcp_rmem_min="$4"
  tcp_rmem_default="$5"
  tcp_rmem_max="$6"
  tcp_wmem_min="$7"
  tcp_wmem_default="$8"
  tcp_wmem_max="$9"
  qdisc="$(preferred_qdisc)"
  notsent_lowat="16384"
  limit_output=131072

  cat > "$SYSCTL_FILE" <<EOF
# Managed by TCP 双端调优器. Do not edit this block manually.
fs.file-max = $fs_file_max
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.core.optmem_max = 81920
net.ipv4.tcp_rmem = $tcp_rmem_min $tcp_rmem_default $tcp_rmem_max
net.ipv4.tcp_wmem = $tcp_wmem_min $tcp_wmem_default $tcp_wmem_max
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = bbr
EOF
  if sysctl -n net.ipv4.tcp_limit_output_bytes >/dev/null 2>&1; then
    echo "net.ipv4.tcp_limit_output_bytes = $limit_output" >> "$SYSCTL_FILE"
  fi
  if sysctl -n net.ipv4.tcp_autocorking >/dev/null 2>&1; then
    echo "net.ipv4.tcp_autocorking = 1" >> "$SYSCTL_FILE"
  fi
}

apply_profile() {
  need_root
  profile="$(normalize_profile "$1")"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] 将应用预设：$profile"
    profile_values "$profile"
    return 0
  fi
  backup_dir="$(backup_state)"
  write_sysctl_config "$profile"
  if have_cmd sysctl; then
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || die "sysctl 配置加载失败，备份目录：$backup_dir"
  else
    die "当前系统缺少 sysctl。"
  fi
  echo "$profile" > "$STATE_DIR/last-profile"
  info "已即时保存并加载预设：$profile"
  info "备份目录：$backup_dir"
  status_short
}

apply_buffers() {
  need_root
  rmem_max="$1"
  wmem_max="$2"
  adv_win_scale="${3:-2}"
  notsent_lowat="${4:-16384}"
  backlog="${5:-16384}"
  somaxconn="${6:-32768}"
  synbacklog="${7:-8192}"
  optmem="${8:-81920}"
  tcp_rmem_min="${TCP_TUNE_RMEM_MIN:-4096}"
  tcp_rmem_default="${TCP_TUNE_RMEM_DEFAULT:-87380}"
  tcp_wmem_min="${TCP_TUNE_WMEM_MIN:-4096}"
  tcp_wmem_default="${TCP_TUNE_WMEM_DEFAULT:-65536}"
  limit_output=""
  if [ "$#" -ge 9 ]; then
    limit_output="$9"
  else
    limit_output=$((notsent_lowat * 2))
    [ "$limit_output" -lt 131072 ] && limit_output=131072
    [ "$limit_output" -gt 1048576 ] && limit_output=1048576
  fi
  qdisc="$(preferred_qdisc)"
  case "$rmem_max$wmem_max" in
    *[!0-9]*) die "buffer 参数必须是数字。" ;;
  esac
  case "$adv_win_scale$notsent_lowat$backlog$somaxconn$synbacklog$optmem$limit_output" in
    *[!0-9]*) die "扩展 TCP 参数必须是数字。" ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] 将写入：rmem=$rmem_max wmem=$wmem_max adv=$adv_win_scale notsent=$notsent_lowat limit_output=$limit_output"
    return 0
  fi
  backup_dir="$(backup_state)"
  cat > "$SYSCTL_FILE" <<EOF
# Managed by TCP 双端调优器. Auto-tuned buffers.
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = $adv_win_scale
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = $somaxconn
net.core.optmem_max = $optmem
net.ipv4.tcp_rmem = $tcp_rmem_min $tcp_rmem_default $rmem_max
net.ipv4.tcp_wmem = $tcp_wmem_min $tcp_wmem_default $wmem_max
net.ipv4.tcp_max_syn_backlog = $synbacklog
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = bbr
EOF
  if sysctl -n net.ipv4.tcp_limit_output_bytes >/dev/null 2>&1; then
    echo "net.ipv4.tcp_limit_output_bytes = $limit_output" >> "$SYSCTL_FILE"
  fi
  if sysctl -n net.ipv4.tcp_autocorking >/dev/null 2>&1; then
    echo "net.ipv4.tcp_autocorking = 1" >> "$SYSCTL_FILE"
  fi
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || die "sysctl 配置加载失败，备份目录：$backup_dir"
  info "已即时保存并加载 buffer：rmem=$rmem_max wmem=$wmem_max notsent=$notsent_lowat limit_output=$limit_output"
  info "备份目录：$backup_dir"
}

apply_smart() {
  need_root
  local_mbps="$1"
  peer_mbps="$2"
  rtt_ms="$3"
  memory_mb_value="$4"
  objective="$5"
  ramp_rate="${6:-0.79}"
  aggressive="${7:-0}"

  values="$(recommend_values "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive")"
  case "$values" in
    ERR*) die "$values" ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then
    print_recommendation "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive"
    info "[dry-run] 不写入 sysctl。"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $values
  apply_buffers "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

rollback_last() {
  need_root
  latest="$(find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$latest" ] || die "未找到可回滚备份。"
  if [ -f "$latest/restore-current.conf" ]; then
    cp "$latest/restore-current.conf" "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  elif [ -f "$latest/99-tcp-tune.conf" ]; then
    cp "$latest/99-tcp-tune.conf" "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  else
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  mkdir -p "$STATE_DIR/rolled-back"
  mv "$latest" "$STATE_DIR/rolled-back/$(basename "$latest")" 2>/dev/null || true
  info "已回滚到最近备份：$latest"
}

status_short() {
  echo "当前关键参数："
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  sysctl net.ipv4.tcp_rmem 2>/dev/null || true
  sysctl net.ipv4.tcp_wmem 2>/dev/null || true
  sysctl net.core.rmem_max 2>/dev/null || true
  sysctl net.core.wmem_max 2>/dev/null || true
  sysctl net.ipv4.tcp_notsent_lowat 2>/dev/null || true
  sysctl net.ipv4.tcp_limit_output_bytes 2>/dev/null || true
  sysctl net.ipv4.tcp_autocorking 2>/dev/null || true
}

status_full() {
  detect_os
  echo "$APP_NAME $APP_VERSION"
  echo "系统：$OS_NAME"
  echo "包管理器：$PKG_MANAGER"
  echo "内核：$(uname -a 2>/dev/null || echo unknown)"
  echo
  status_short
  echo
  echo "命令依赖："
  for cmd in iperf3 curl wget sysctl tc ip python3; do
    if have_cmd "$cmd"; then
      echo "  $cmd: $(command -v "$cmd")"
    else
      echo "  $cmd: 缺失"
    fi
  done
  echo
  openwrt_advice
}

openwrt_advice() {
  detect_os
  [ "$OS_FAMILY" = "openwrt" ] || return 0
  echo "OpenWrt 优化建议："
  if ! have_cmd iperf3; then
    echo "  - 建议安装 iperf3：opkg update && opkg install iperf3"
  fi
  if ! have_cmd curl; then
    echo "  - 建议安装 curl：opkg update && opkg install curl"
  fi
  if ! have_cmd tc; then
    echo "  - 如需自动调 cake/fq，建议安装：opkg install tc-full kmod-ifb kmod-sched-cake"
  fi
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 262144 ]; then
    echo "  - 当前内存低于 256MiB，不建议直接使用“长距大带宽”预设。"
  fi
}

public_ip() {
  if have_cmd curl; then
    curl -4fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d ' \r\n' || true
  elif have_cmd wget; then
    wget -qO- --timeout=5 https://icanhazip.com 2>/dev/null | tr -d ' \r\n' || true
  fi
}

start_iperf_server() {
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法启动测试服务。"
  port="$1"
  if pgrep -f "iperf3 .* -s .* -p $port" >/dev/null 2>&1; then
    info "iperf3 server 已在端口 $port 运行。"
    return 0
  fi
  nohup iperf3 -s -p "$port" > "$STATE_DIR/iperf3-$port.log" 2>&1 &
  echo "$!" > "$STATE_DIR/iperf3-$port.pid"
  info "iperf3 server 已启动，端口：$port"
}

stop_iperf_server() {
  port="$1"
  if [ -f "$STATE_DIR/iperf3-$port.pid" ]; then
    pid="$(cat "$STATE_DIR/iperf3-$port.pid")"
    kill "$pid" >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/iperf3-$port.pid"
    info "已停止 iperf3 server：$pid"
  else
    pkill -f "iperf3 .* -s .* -p $port" >/dev/null 2>&1 || true
    info "已尝试停止端口 $port 的 iperf3 server。"
  fi
}

run_iperf_client() {
  host="$1"
  port="$2"
  reverse="$3"
  seconds="$4"
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法测试。"
  if [ "$reverse" = "1" ]; then
    iperf3 -c "$host" -p "$port" -R -t "$seconds" -J
  else
    iperf3 -c "$host" -p "$port" -t "$seconds" -J
  fi
}

json_number() {
  key="$1"
  awk -v key="\"$key\"" '
    index($0, key) {
      gsub(/[,]/, "", $0)
      for (i = 1; i <= NF; i++) {
        if ($i ~ key) {
          if ((i + 1) <= NF) {
            gsub(/[^0-9.]/, "", $(i + 1))
            print $(i + 1)
            exit
          }
        }
      }
    }
  '
}

extract_retransmits() {
  awk '
    /"retransmits"/ {
      gsub(/[,]/, "", $0)
      for (i = 1; i <= NF; i++) {
        if ($i ~ /"retransmits"/) {
          gsub(/[^0-9]/, "", $(i + 1))
          value=$(i + 1)
        }
      }
    }
    END { if (value != "") print value; }
  '
}

extract_bps() {
  awk '
    /"bits_per_second"/ {
      gsub(/[,]/, "", $0)
      for (i = 1; i <= NF; i++) {
        if ($i ~ /"bits_per_second"/) {
          gsub(/[^0-9.]/, "", $(i + 1))
          value=$(i + 1)
        }
      }
    }
    END { if (value != "") print value; }
  '
}

current_max_buffers() {
  rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 67108864)"
  wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 67108864)"
  echo "$rmem $wmem"
}

tune_step() {
  objective="$1"
  retr="$2"
  bps="$3"
  target_retr="$4"
  local_mbps="$5"
  peer_mbps="$6"
  rtt_ms="$7"
  memory_mb_value="$8"
  ramp_rate="${9:-0.79}"
  aggressive="0"
  if [ "$#" -ge 10 ]; then
    shift 9
    aggressive="${1:-0}"
  fi

  values="$(recommend_values "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive")"
  case "$values" in
    ERR*) die "$values" ;;
  esac

  # shellcheck disable=SC2086
  set -- $values
  rmem="$1"
  wmem="$2"
  adv="$3"
  notsent="$4"
  backlog="$5"
  somaxconn="$6"
  synbacklog="$7"
  optmem="$8"

  if [ "$retr" -gt "$target_retr" ]; then
    adjusted="$(awk -v r="$rmem" -v w="$wmem" 'BEGIN {printf "%d %d\n", r * 0.85, w * 0.85}')"
    # shellcheck disable=SC2086
    set -- $adjusted
    rmem="$1"
    wmem="$2"
  elif [ "$objective" = "throughput" ] && [ "$bps" != "0" ]; then
    adjusted="$(awk -v r="$rmem" -v w="$wmem" 'BEGIN {printf "%d %d\n", r * 1.08, w * 1.08}')"
    # shellcheck disable=SC2086
    set -- $adjusted
    rmem="$1"
    wmem="$2"
  fi

  cap="$(memory_cap_bytes "$memory_mb_value" "$aggressive")"
  min=$((4 * 1024 * 1024))
  [ "$rmem" -lt "$min" ] && rmem="$min"
  [ "$wmem" -lt "$min" ] && wmem="$min"
  [ "$rmem" -gt "$cap" ] && rmem="$cap"
  [ "$wmem" -gt "$cap" ] && wmem="$cap"

  echo "$rmem $wmem $adv $notsent $backlog $somaxconn $synbacklog $optmem"
}

auto_tune() {
  host="$1"
  port="$2"
  objective="$3"
  target_retr="$4"
  rounds="$5"
  reverse="${6:-1}"
  local_mbps="${7:-0}"
  peer_mbps="${8:-0}"
  rtt_ms="${9:-100}"
  memory_mb_value=""
  ramp_rate="0.79"
  aggressive="0"
  allow_same_public="0"
  if [ "$#" -ge 10 ]; then
    shift 9
    memory_mb_value="${1:-}"
    [ "$#" -gt 0 ] && shift
    ramp_rate="${1:-0.79}"
    [ "$#" -gt 0 ] && shift
    aggressive="${1:-0}"
    [ "$#" -gt 0 ] && shift
    allow_same_public="${1:-0}"
  fi

  need_root
  install_runtime_deps
  [ -n "$memory_mb_value" ] || memory_mb_value="$(memory_mb)"
  local_public_ip="$(public_ip || true)"
  if [ "$allow_same_public" != "1" ] && [ -n "$local_public_ip" ] && [ "$host" = "$local_public_ip" ]; then
    die "对端地址 $host 与本机公网出口 $local_public_ip 相同，疑似 NAT hairpin/自测链路。请换用真实对端公网地址，或添加 --allow-same-public-ip 强制测试。"
  fi

  i=1
  while [ "$i" -le "$rounds" ]; do
    info "第 $i 轮测试：host=$host port=$port objective=$objective"
    json="$(run_iperf_client "$host" "$port" "$reverse" 15 || true)"
    [ -n "$json" ] || die "iperf3 测试失败。"
    retr="$(printf '%s\n' "$json" | extract_retransmits)"
    bps="$(printf '%s\n' "$json" | extract_bps)"
    retr="${retr:-0}"
    bps="${bps:-0}"
    info "本轮结果：Retr=$retr, bits_per_second=$bps"

    measured_mbps="$(awk -v bps="$bps" 'BEGIN {v=bps/1000000; if (v < 1) v=1; printf "%d\n", v}')"
    [ "$peer_mbps" = "0" ] && peer_mbps="$measured_mbps"
    [ "$local_mbps" = "0" ] && local_mbps="$peer_mbps"

    if [ "$objective" = "retrans" ] && [ "$retr" -le "$target_retr" ]; then
      info "已达到重传目标：$retr <= $target_retr"
      return 0
    fi

    # shellcheck disable=SC2086
    set -- $(tune_step "$objective" "$retr" "$bps" "$target_retr" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive")
    apply_buffers "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    if [ "$objective" = "retrans" ] && [ "$retr" -gt "$target_retr" ]; then
      ramp_rate="$(awk -v r="$ramp_rate" -v retr="$retr" -v target="$target_retr" 'BEGIN {
        factor = 0.92
        if (retr > target + 20) factor = 0.78
        else if (retr > target + 5) factor = 0.85
        v = r * factor
        if (v < 0.35) v = 0.35
        printf "%.3f\n", v
      }')"
      info "下一轮重传收敛 ramp=$ramp_rate"
    elif [ "$objective" = "throughput" ]; then
      ramp_rate="$(awk -v r="$ramp_rate" -v retr="$retr" -v target="$target_retr" 'BEGIN {
        if (retr <= target) v = r * 1.08
        else v = r * 0.92
        if (v > 1.20) v = 1.20
        if (v < 0.45) v = 0.45
        printf "%.3f\n", v
      }')"
      info "下一轮速率探索 ramp=$ramp_rate"
    fi
    i=$((i + 1))
  done
  warn "已达到最大轮数，停止自动优化。"
}

random_token() {
  if have_cmd openssl; then
    openssl rand -hex 24
  else
    date +%s | awk '{srand(); printf "%d%06d\n", $1, rand()*1000000}'
  fi
}

write_agent_py() {
  path="$1"
  cat > "$path" <<'PY'
#!/usr/bin/env python3
import http.server
import json
import os
import secrets
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ["TCP_TUNE_TOKEN"]
SCRIPT = os.environ["TCP_TUNE_SCRIPT"]
IPERF_PORT = os.environ.get("TCP_TUNE_IPERF_PORT", "5201")
STARTED = time.time()
TTL = int(os.environ.get("TCP_TUNE_SESSION_TTL", "1800"))
STATE = {
    "started_at": STARTED,
    "peer_reports": [],
    "events": [],
    "jobs": {},
}
OPTIMIZE_LOCK = threading.Lock()
ACTIVE_PROCESSES = set()
ACTIVE_PROCESSES_LOCK = threading.Lock()

def check_token(handler):
    token = handler.headers.get("X-TCP-Tune-Token", "")
    if token == TOKEN:
        return True
    query = parse_qs(urlparse(handler.path).query)
    return query.get("token", [""])[0] == TOKEN

def write_json(handler, code, payload):
    body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionResetError):
        pass

def write_text(handler, code, payload):
    body = payload.encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "text/plain; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    try:
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionResetError):
        pass

def run_cmd(args):
    proc = subprocess.Popen(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    with ACTIVE_PROCESSES_LOCK:
        ACTIVE_PROCESSES.add(proc)
    try:
        stdout, stderr = proc.communicate()
        return {
            "code": proc.returncode,
            "stdout": stdout[-4000:],
            "stderr": stderr[-4000:],
        }
    finally:
        with ACTIVE_PROCESSES_LOCK:
            ACTIVE_PROCESSES.discard(proc)

def terminate_active_processes():
    with ACTIVE_PROCESSES_LOCK:
        processes = list(ACTIVE_PROCESSES)
    for proc in processes:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

def safe_int(value, default, min_value=None, max_value=None):
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    if min_value is not None and number < min_value:
        number = min_value
    if max_value is not None and number > max_value:
        number = max_value
    return number

def safe_choice(value, allowed, default):
    value = str(value or default)
    return value if value in allowed else default

def run_optimize_job(job_id, args):
    job = STATE["jobs"][job_id]
    with OPTIMIZE_LOCK:
        job["status"] = "running"
        job["started_at"] = time.time()
        STATE["events"].append({"time": time.time(), "action": "optimize-running", "job_id": job_id})
        try:
            result = run_cmd(args)
        except OSError as exc:
            result = {"code": 127, "stdout": "", "stderr": f"启动优化进程失败：{exc}"}
        job["result"] = result
        job["status"] = "completed" if result["code"] == 0 else "failed"
        job["finished_at"] = time.time()
        STATE["events"].append({
            "time": time.time(),
            "action": "optimize-completed",
            "job_id": job_id,
            "host": job["host"],
            "direction": job["direction"],
            "objective": job["objective"],
            "result": result["code"],
        })

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "tcp-tune-agent/0.1"

    def log_message(self, fmt, *args):
        return

    def blocked_if_expired(self):
        if time.time() - STARTED > TTL:
            write_json(self, 410, {"ok": False, "error": "session expired"})
            return True
        return False

    def do_GET(self):
        if self.blocked_if_expired():
            return
        if not check_token(self):
            write_json(self, 403, {"ok": False, "error": "invalid token"})
            return
        path = urlparse(self.path).path
        if path == "/state":
            write_json(self, 200, {"ok": True, "iperf_port": IPERF_PORT, "state": STATE})
            return
        if path == "/events":
            write_json(self, 200, {"ok": True, "events": STATE["events"][-100:], "peer_reports": STATE["peer_reports"][-20:]})
            return
        if path == "/status":
            result = run_cmd([SCRIPT, "status"])
            write_json(self, 200, {"ok": result["code"] == 0, "result": result})
            return
        if path.startswith("/jobs/"):
            parts = path.strip("/").split("/")
            job_id = parts[1] if len(parts) >= 2 else ""
            job = STATE["jobs"].get(job_id)
            if not job:
                write_json(self, 404, {"ok": False, "error": "job not found"})
                return
            if len(parts) == 3 and parts[2] == "output":
                result = job.get("result", {})
                output = result.get("stdout", "")
                if result.get("stderr"):
                    output += ("\n" if output else "") + result["stderr"]
                write_text(self, 200, output or "任务尚未产生输出。\n")
                return
            if len(parts) == 2:
                public_job = {key: value for key, value in job.items() if key != "result"}
                if "result" in job:
                    public_job["result_code"] = job["result"]["code"]
                write_json(self, 200, {"ok": True, "job": public_job})
                return
            write_json(self, 404, {"ok": False, "error": "not found"})
            return
        write_json(self, 404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.blocked_if_expired():
            return
        if not check_token(self):
            write_json(self, 403, {"ok": False, "error": "invalid token"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        path = urlparse(self.path).path
        if path == "/report":
            STATE["peer_reports"].append({"time": time.time(), "payload": payload})
            STATE["events"].append({"time": time.time(), "action": "peer-report", "role": payload.get("role", "unknown")})
            write_json(self, 200, {"ok": True})
            return
        if path == "/test":
            host = str(payload.get("host", "")).strip()
            if not host:
                write_json(self, 400, {"ok": False, "error": "host is required"})
                return
            port = str(safe_int(payload.get("port"), int(IPERF_PORT), 1, 65535))
            seconds = str(safe_int(payload.get("seconds"), 10, 1, 60))
            direction = safe_choice(payload.get("direction"), {"download", "upload"}, "download")
            reverse = "1" if direction == "download" else "0"
            result = run_cmd([SCRIPT, "_iperf-json", host, port, reverse, seconds])
            STATE["events"].append({"time": time.time(), "action": "test", "host": host, "direction": direction, "result": result["code"]})
            write_json(self, 200, {"ok": result["code"] == 0, "result": result})
            return
        if path == "/optimize":
            host = str(payload.get("host", "")).strip()
            if not host:
                write_json(self, 400, {"ok": False, "error": "host is required"})
                return
            direction = safe_choice(payload.get("direction"), {"download", "upload"}, "download")
            objective = safe_choice(payload.get("objective"), {"retrans", "throughput", "startup"}, "retrans")
            args = [
                SCRIPT, "--yes", "auto",
                "--host", host,
                "--port", str(safe_int(payload.get("port"), int(IPERF_PORT), 1, 65535)),
                "--direction", direction,
                "--objective", objective,
                "--target-retr", str(safe_int(payload.get("target_retr"), 0, 0, 100000)),
                "--rounds", str(safe_int(payload.get("rounds"), 3, 1, 20)),
                "--local-mbps", str(safe_int(payload.get("local_mbps"), 0, 0, 100000)),
                "--peer-mbps", str(safe_int(payload.get("peer_mbps"), 0, 0, 100000)),
                "--rtt-ms", str(safe_int(payload.get("rtt_ms"), 100, 1, 10000)),
            ]
            if payload.get("allow_same_public_ip"):
                args.append("--allow-same-public-ip")
            job_id = secrets.token_hex(8)
            STATE["jobs"][job_id] = {
                "id": job_id,
                "status": "queued",
                "created_at": time.time(),
                "host": host,
                "direction": direction,
                "objective": objective,
            }
            STATE["events"].append({"time": time.time(), "action": "optimize-queued", "job_id": job_id, "host": host, "direction": direction, "objective": objective})
            threading.Thread(target=run_optimize_job, args=(job_id, args), daemon=True).start()
            write_json(self, 202, {"ok": True, "accepted": True, "job_id": job_id})
            return
        if path == "/stop":
            STATE["events"].append({"time": time.time(), "action": "stop-request"})
            write_json(self, 200, {"ok": True, "message": "agent stopping"})
            def stop_all():
                terminate_active_processes()
                subprocess.run([SCRIPT, "stop-agent"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                os._exit(0)
            threading.Timer(0.3, stop_all).start()
            return
        if path == "/apply-profile":
            profile = payload.get("profile", "")
            result = run_cmd([SCRIPT, "--yes", "apply-profile", profile])
            STATE["events"].append({"time": time.time(), "action": "apply-profile", "profile": profile, "result": result["code"]})
            write_json(self, 200, {"ok": result["code"] == 0, "result": result})
            return
        if path == "/apply-buffers":
            rmem = str(payload.get("rmem", ""))
            wmem = str(payload.get("wmem", ""))
            if not rmem.isdigit() or not wmem.isdigit():
                write_json(self, 400, {"ok": False, "error": "rmem/wmem must be numeric"})
                return
            result = run_cmd([SCRIPT, "--yes", "apply-buffers", rmem, wmem])
            STATE["events"].append({"time": time.time(), "action": "apply-buffers", "rmem": rmem, "wmem": wmem, "result": result["code"]})
            write_json(self, 200, {"ok": result["code"] == 0, "result": result})
            return
        write_json(self, 404, {"ok": False, "error": "not found"})

if __name__ == "__main__":
    port = int(os.environ.get("TCP_TUNE_AGENT_PORT", "39188"))
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
  chmod +x "$path"
}

listen_mode() {
  need_root
  install_runtime_deps
  ensure_dependency python3 python3 || die "listen 模式需要 python3 运行临时 HTTP Agent。"
  ensure_state_dir
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ -n "$LISTEN_PUBLIC_URL" ]; then
      peer_url="$LISTEN_PUBLIC_URL"
    else
      peer_url="http://<公网IP>:$AGENT_PORT"
    fi
    token="<启动后自动生成>"
    echo "[dry-run] 将启动临时 HTTP Agent：0.0.0.0:$AGENT_PORT"
    echo "[dry-run] 将启动 iperf3 server：0.0.0.0:$IPERF_PORT"
    echo "[dry-run] 会话 TTL：$SESSION_TTL 秒"
    print_client_commands "$peer_url" "$token"
    return 0
  fi

  token="$(random_token)"
  script_path="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
  agent_py="$STATE_DIR/tcp-tune-agent.py"
  write_agent_py "$agent_py"
  start_iperf_server "$IPERF_PORT"

  export TCP_TUNE_TOKEN="$token"
  export TCP_TUNE_SCRIPT="$script_path"
  export TCP_TUNE_AGENT_PORT="$AGENT_PORT"
  export TCP_TUNE_IPERF_PORT="$IPERF_PORT"
  export TCP_TUNE_SESSION_TTL="$SESSION_TTL"

  nohup python3 "$agent_py" > "$STATE_DIR/agent-$AGENT_PORT.log" 2>&1 &
  echo "$!" > "$STATE_DIR/agent-$AGENT_PORT.pid"

  if [ -n "$LISTEN_PUBLIC_URL" ]; then
    peer_url="$LISTEN_PUBLIC_URL"
  else
    ip="$(public_ip)"
    [ -n "$ip" ] || ip="<公网IP>"
    peer_url="http://$ip:$AGENT_PORT"
  fi
  echo "$token" > "$STATE_DIR/agent-$AGENT_PORT.token"
  echo "$peer_url" > "$STATE_DIR/agent-$AGENT_PORT.url"
  if [ "${SERVER_MENU_AFTER_LISTEN:-0}" != "1" ]; then
    render_server_dashboard "$peer_url" "$token"
  fi
}

stop_agent() {
  need_root
  ensure_state_dir
  stopped=0
  for pid_file in "$STATE_DIR"/agent-*.pid "$STATE_DIR"/iperf3-*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      stopped=1
    fi
    rm -f "$pid_file"
  done
  for session_file in "$STATE_DIR"/agent-*.token "$STATE_DIR"/agent-*.url "$STATE_DIR"/tcp-tune-agent.py; do
    [ -f "$session_file" ] || continue
    rm -f "$session_file"
  done
  if [ "$stopped" = "0" ]; then
    info "未发现本工具记录的临时 Agent/iperf3 pid。"
  else
    info "已停止本工具创建的临时 Agent 和 iperf3。"
  fi
}

post_json() {
  url="$1"
  token="$2"
  data="$3"
  curl -fsS -H "X-TCP-Tune-Token: $token" -H "Content-Type: application/json" -d "$data" "$url"
}

get_agent_json() {
  url="$1"
  token="$2"
  curl -fsS -H "X-TCP-Tune-Token: $token" "$url"
}

wait_agent_job() {
  peer="$1"
  token="$2"
  job_id="$3"
  waited=0
  max_wait="${4:-900}"
  while [ "$waited" -lt "$max_wait" ]; do
    response="$(get_agent_json "$peer/jobs/$job_id" "$token")" || return 1
    status="$(printf '%s\n' "$response" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    case "$status" in
      queued|running)
        printf '\r远程优化任务：%-8s 已等待 %ss' "$status" "$waited"
        sleep 2
        waited=$((waited + 2))
        ;;
      completed)
        printf '\r远程优化任务：completed                    \n'
        get_agent_json "$peer/jobs/$job_id/output" "$token"
        return 0
        ;;
      failed)
        printf '\r远程优化任务：failed                       \n'
        get_agent_json "$peer/jobs/$job_id/output" "$token" || true
        return 1
        ;;
      *)
        warn "无法识别远程任务状态。"
        printf '%s\n' "$response"
        return 1
        ;;
    esac
  done
  echo
  warn "等待远程优化任务超时，可通过服务端事件继续查看。"
  return 1
}

render_server_dashboard() {
  peer_url="$1"
  token="$2"
  clear_screen
  print_header "$APP_NAME $APP_VERSION - 服务端会话"
  print_kv "仓库" "$REPO_URL"
  print_kv "Agent 端口" "$AGENT_PORT"
  print_kv "iperf3 端口" "$IPERF_PORT"
  print_kv "会话 TTL" "${SESSION_TTL}s"
  print_kv "连接地址" "$peer_url"
  print_kv "状态目录" "$STATE_DIR"
  echo
  print_client_commands "$peer_url" "$token"
  echo
  printf "%s安全提示：%s token 只发给可信对端；调优结束后选择菜单 5 或执行 sh tcp-tune.sh stop-agent。\n" "$COLOR_YELLOW" "$COLOR_RESET"
}

render_client_dashboard() {
  peer_url="$1"
  host="$2"
  iperf_port="$3"
  clear_screen
  print_header "$APP_NAME $APP_VERSION - 客户端会话"
  print_kv "服务端" "$peer_url"
  print_kv "iperf3 主机" "$host"
  print_kv "iperf3 端口" "$iperf_port"
  print_kv "本机系统" "${OS_NAME:-Unknown}"
  echo
  printf "%s当前会话已连接。%s 可直接选择测速、优化或查看服务端状态。\n" "$COLOR_GREEN" "$COLOR_RESET"
}

print_client_commands() {
  peer_url="$1"
  token="$2"
  printf "%s客户端连接命令%s\n" "$COLOR_BOLD$COLOR_GREEN" "$COLOR_RESET"
  print_rule
  printf "%sOpenWrt / Linux / macOS 一键运行：%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  curl -fsSL $RAW_BASE_URL/tcp-tune.sh | sh -s -- --yes client --peer $peer_url --token $token --iperf-port $IPERF_PORT"
  echo
  printf "%s已有脚本本地运行：%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  sh tcp-tune.sh --yes client --peer $peer_url --token $token --iperf-port $IPERF_PORT"
  echo
  printf "%sWindows PowerShell：%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  iwr -UseBasicParsing $RAW_BASE_URL/tcp-tune.ps1 -OutFile tcp-tune.ps1"
  printf '  .\\tcp-tune.ps1 client -Peer %s -Token %s -IperfPort %s -Direction download -Yes\n' "$peer_url" "$token" "$IPERF_PORT"
}

join_mode() {
  peer=""
  token=""
  iperf_port="$IPERF_PORT"
  objective="retrans"
  target_retr="0"
  rounds="5"
  local_mbps="0"
  peer_mbps="0"
  rtt_ms="100"
  memory_mb_value=""
  ramp_rate="0.79"
  aggressive="0"
  allow_same_public="0"
  reverse="1"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --peer) peer="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      --iperf-port) iperf_port="$2"; shift 2 ;;
      --objective) objective="$2"; shift 2 ;;
      --target-retr) target_retr="$2"; shift 2 ;;
      --rounds) rounds="$2"; shift 2 ;;
      --local-mbps) local_mbps="$2"; shift 2 ;;
      --peer-mbps) peer_mbps="$2"; shift 2 ;;
      --rtt-ms) rtt_ms="$2"; shift 2 ;;
      --memory-mb) memory_mb_value="$2"; shift 2 ;;
      --ramp) ramp_rate="$2"; shift 2 ;;
      --aggressive) aggressive="1"; shift ;;
      --allow-same-public-ip) allow_same_public="1"; shift ;;
      --direction)
        case "$2" in
          download|reverse) reverse="1" ;;
          upload|forward) reverse="0" ;;
          *) die "--direction 只支持 download 或 upload" ;;
        esac
        shift 2
        ;;
      --download|--reverse) reverse="1"; shift ;;
      --upload|--forward) reverse="0"; shift ;;
      *) die "未知 join 参数：$1" ;;
    esac
  done

  [ -n "$peer" ] || die "缺少 --peer"
  [ -n "$token" ] || die "缺少 --token"
  install_runtime_deps
  detect_os

  report_role="join"
  [ "${CLIENT_MENU:-0}" = "1" ] && report_role="client"
  report="{\"role\":\"$report_role\",\"os\":\"$OS_NAME\",\"family\":\"$OS_FAMILY\",\"time\":$(date +%s)}"
  post_json "$peer/report" "$token" "$report" >/dev/null || warn "无法向对端上报状态，但将继续本地测试。"

  host="$(printf '%s\n' "$peer" | sed 's#^http://##; s#^https://##; s#:.*##; s#/.*##')"
  echo "已加入会话：$peer"
  if [ "${CLIENT_MENU:-0}" = "1" ]; then
    client_menu "$peer" "$token" "$host" "$iperf_port" "$allow_same_public"
  else
    echo "开始本端自动优化：objective=$objective target_retr=$target_retr rounds=$rounds"
    auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive" "$allow_same_public"
  fi
}

server_menu() {
  token_file="$STATE_DIR/agent-$AGENT_PORT.token"
  url_file="$STATE_DIR/agent-$AGENT_PORT.url"
  token="$(cat "$token_file" 2>/dev/null || true)"
  peer_url="$(cat "$url_file" 2>/dev/null || true)"
  while true; do
    render_server_dashboard "$peer_url" "$token"
    echo
    printf "%s服务端菜单%s\n" "$COLOR_BOLD$COLOR_GREEN" "$COLOR_RESET"
    print_rule
    printf "  %s1%s 查看服务端状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s2%s 查看客户端上报/事件\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s3%s 运行服务端本机优化\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s4%s 重新显示客户端运行命令\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s5%s 停止会话并退出\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %s0%s 退出菜单但保留服务\n" "$COLOR_DIM" "$COLOR_RESET"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入，服务端继续保留运行。"
      return 0
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1)
        clear_screen
        print_header "服务端状态"
        status_full
        pause_for_enter
        ;;
      2)
        clear_screen
        print_header "客户端上报/事件"
        if [ -n "$token" ]; then
          get_agent_json "http://127.0.0.1:$AGENT_PORT/events" "$token" || warn "读取事件失败。"
        else
          warn "未找到 token 文件。"
        fi
        pause_for_enter
        ;;
      3)
        clear_screen
        print_header "服务端本机优化"
        if ! prompt_read "请输入测试对端 host/IP："; then pause_for_enter; continue; fi
        host="$PROMPT_REPLY"
        if ! prompt_read "方向：1 download / 2 upload："; then pause_for_enter; continue; fi
        direction_ans="$PROMPT_REPLY"
        case "$direction_ans" in 2) direction="upload"; reverse="0" ;; *) direction="download"; reverse="1" ;; esac
        if ! prompt_read "目标：1 重传 / 2 吞吐 / 3 启动："; then pause_for_enter; continue; fi
        obj="$PROMPT_REPLY"
        case "$obj" in 2) objective="throughput" ;; 3) objective="startup" ;; *) objective="retrans" ;; esac
        auto_tune "$host" "$IPERF_PORT" "$objective" 0 3 "$reverse" 0 0 100 "" 0.79 0 1
        pause_for_enter
        ;;
      4)
        clear_screen
        print_header "客户端连接命令"
        if [ -n "$peer_url" ] && [ -n "$token" ]; then
          print_client_commands "$peer_url" "$token"
        else
          warn "未找到会话连接信息。"
        fi
        pause_for_enter
        ;;
      5) stop_agent; exit 0 ;;
      0) return 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}

client_menu() {
  peer="$1"
  token="$2"
  host="$3"
  iperf_port="$4"
  allow_same_public="$5"
  while true; do
    render_client_dashboard "$peer" "$host" "$iperf_port"
    echo
    printf "%s客户端菜单%s\n" "$COLOR_BOLD$COLOR_GREEN" "$COLOR_RESET"
    print_rule
    printf "  %s1%s 查看本机状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s2%s 下载方向优化（服务端 -> 本机）\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s3%s 上传方向优化（本机 -> 服务端）\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s4%s 查看服务端状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s5%s 查看服务端事件\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s6%s 请求服务端优化\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s7%s 通知服务端停止会话并退出\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %s0%s 退出客户端\n" "$COLOR_DIM" "$COLOR_RESET"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入，客户端已保持连接上报后退出菜单。"
      return 0
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1)
        clear_screen
        print_header "本机状态"
        status_full
        pause_for_enter
        ;;
      2)
        clear_screen
        print_header "下载方向优化"
        auto_tune "$host" "$iperf_port" retrans 0 3 1 0 0 100 "" 0.79 0 "$allow_same_public"
        pause_for_enter
        ;;
      3)
        clear_screen
        print_header "上传方向优化"
        auto_tune "$host" "$iperf_port" retrans 0 3 0 0 0 100 "" 0.79 0 "$allow_same_public"
        pause_for_enter
        ;;
      4)
        clear_screen
        print_header "服务端状态"
        get_agent_json "$peer/status" "$token" || warn "读取服务端状态失败。"
        pause_for_enter
        ;;
      5)
        clear_screen
        print_header "服务端事件"
        get_agent_json "$peer/events" "$token" || warn "读取服务端事件失败。"
        pause_for_enter
        ;;
      6)
        clear_screen
        print_header "请求服务端优化"
        if ! prompt_read "请输入服务端可连接的本机 host/IP："; then pause_for_enter; continue; fi
        target_host="$PROMPT_REPLY"
        if ! prompt_read "方向：1 download / 2 upload："; then pause_for_enter; continue; fi
        direction_ans="$PROMPT_REPLY"
        case "$direction_ans" in 2) direction="upload" ;; *) direction="download" ;; esac
        data="{\"host\":\"$target_host\",\"port\":$iperf_port,\"direction\":\"$direction\",\"objective\":\"retrans\",\"target_retr\":0,\"rounds\":3,\"allow_same_public_ip\":true}"
        response="$(post_json "$peer/optimize" "$token" "$data")" || {
          warn "请求服务端优化失败。"
          pause_for_enter
          continue
        }
        job_id="$(printf '%s\n' "$response" | sed -n 's/.*"job_id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
        if [ -z "$job_id" ]; then
          warn "服务端未返回任务 ID。"
          printf '%s\n' "$response"
        else
          info "服务端已接受优化任务：$job_id"
          wait_agent_job "$peer" "$token" "$job_id" || warn "远程优化任务未成功完成。"
        fi
        pause_for_enter
        ;;
      7) post_json "$peer/stop" "$token" "{}" || true; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}

server_mode() {
  trap 'stop_agent; exit 130' INT TERM
  SERVER_MENU_AFTER_LISTEN=1
  export SERVER_MENU_AFTER_LISTEN
  listen_mode
  unset SERVER_MENU_AFTER_LISTEN
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if has_interactive_input; then
    server_menu
  else
    token_file="$STATE_DIR/agent-$AGENT_PORT.token"
    url_file="$STATE_DIR/agent-$AGENT_PORT.url"
    token="$(cat "$token_file" 2>/dev/null || true)"
    peer_url="$(cat "$url_file" 2>/dev/null || true)"
    render_server_dashboard "$peer_url" "$token"
    warn "当前环境没有可用交互输入，服务端已在后台保留运行。"
  fi
}

client_mode() {
  trap 'exit 130' INT TERM
  CLIENT_MENU=1
  export CLIENT_MENU
  join_mode "$@"
}

menu() {
  while true; do
    clear_screen
    print_header "$APP_NAME $APP_VERSION"
    printf "  %s1%s 启动调优会话\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s2%s 加入调优会话\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s3%s 自动优化\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s4%s 查看双方/本机状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s5%s 智能推荐参数\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s6%s 选择固定预设\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "  %s7%s 回滚最近修改\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %s0%s 退出\n" "$COLOR_DIM" "$COLOR_RESET"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入。"
      exit 1
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1) listen_mode ;;
      2)
        if ! prompt_read "请输入对端 Agent 地址：http://"; then pause_for_enter; continue; fi
        peer_host="$PROMPT_REPLY"
        if ! prompt_read "请输入 token："; then pause_for_enter; continue; fi
        token="$PROMPT_REPLY"
        join_mode --peer "http://$peer_host" --token "$token" --iperf-port "$IPERF_PORT"
        ;;
      3)
        if ! prompt_read "请输入 iperf3 对端主机："; then pause_for_enter; continue; fi
        host="$PROMPT_REPLY"
        if ! prompt_read "目标：1 重传优先 / 2 速率优先 / 3 启动速度优先："; then pause_for_enter; continue; fi
        obj="$PROMPT_REPLY"
        case "$obj" in
          1) objective="retrans" ;;
          2) objective="throughput" ;;
          3) objective="startup" ;;
          *) objective="retrans" ;;
        esac
        auto_tune "$host" "$IPERF_PORT" "$objective" 0 5 1
        ;;
      4) clear_screen; print_header "状态"; status_full; pause_for_enter ;;
      5)
        if ! prompt_read "请输入本地带宽 Mbps："; then pause_for_enter; continue; fi
        local_mbps="$PROMPT_REPLY"
        if ! prompt_read "请输入对端带宽 Mbps："; then pause_for_enter; continue; fi
        peer_mbps="$PROMPT_REPLY"
        if ! prompt_read "请输入 RTT 延迟 ms："; then pause_for_enter; continue; fi
        rtt_ms="$PROMPT_REPLY"
        if ! prompt_read "请输入内存 MiB，直接回车自动识别："; then pause_for_enter; continue; fi
        mem_input="$PROMPT_REPLY"
        [ -n "$mem_input" ] || mem_input="$(memory_mb)"
        if ! prompt_read "目标：1 重传优先 / 2 速率优先 / 3 启动速度优先："; then pause_for_enter; continue; fi
        obj="$PROMPT_REPLY"
        case "$obj" in
          1) objective="retrans" ;;
          2) objective="throughput" ;;
          3) objective="startup" ;;
          *) objective="retrans" ;;
        esac
        print_recommendation "$local_mbps" "$peer_mbps" "$rtt_ms" "$mem_input" "$objective" 0.79 0
        if ! prompt_read "是否即时保存这组智能参数？[y/N] "; then save_ans=""; else save_ans="$PROMPT_REPLY"; fi
        case "$save_ans" in
          y|Y) apply_smart "$local_mbps" "$peer_mbps" "$rtt_ms" "$mem_input" "$objective" 0.79 0 ;;
        esac
        pause_for_enter
        ;;
      6)
        clear_screen
        print_header "TCP 预设"
        list_profiles
        if ! prompt_read "请输入中文预设名或英文别名："; then pause_for_enter; continue; fi
        profile="$PROMPT_REPLY"
        apply_profile "$profile"
        pause_for_enter
        ;;
      7) clear_screen; print_header "回滚"; rollback_last; pause_for_enter ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}

usage() {
  cat <<EOF
$APP_NAME $APP_VERSION

用法：
  sh tcp-tune.sh
  sh tcp-tune.sh --yes server [--public-url http://IP:39188]
  sh tcp-tune.sh --yes client --peer http://IP:PORT --token TOKEN
  sh tcp-tune.sh doctor
  sh tcp-tune.sh install
  sh tcp-tune.sh status
  sh tcp-tune.sh profiles
  sh tcp-tune.sh listen [--port 39188] [--iperf-port 5201] [--ttl 1800]
  sh tcp-tune.sh join --peer http://IP:PORT --token TOKEN [--direction download|upload] [--objective retrans|throughput|startup]
  sh tcp-tune.sh recommend --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024
  sh tcp-tune.sh apply-smart --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024
  sh tcp-tune.sh apply-profile 均衡通用
  sh tcp-tune.sh apply-buffers RMEM_MAX WMEM_MAX
  sh tcp-tune.sh auto --host IP --direction download --objective retrans --target-retr 0 --rtt-ms 100
  sh tcp-tune.sh rollback
  sh tcp-tune.sh stop-agent

全局选项：
  --yes    允许自动安装缺失依赖
  --dry-run    只展示将执行的动作，不写入系统
EOF
}

main() {
  ASSUME_YES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) break ;;
    esac
  done
  export ASSUME_YES DRY_RUN

  cmd="${1:-menu}"
  [ "$#" -gt 0 ] && shift || true

  case "$cmd" in
    menu) menu ;;
    help|-h|--help) usage ;;
    doctor) doctor ;;
    install) install_only ;;
    status) status_full ;;
    profiles|list-profiles) list_profiles ;;
    apply-profile) [ "$#" -eq 1 ] || die "apply-profile 需要一个预设名。"; apply_profile "$1" ;;
    apply-buffers) [ "$#" -ge 2 ] || die "apply-buffers 需要 RMEM_MAX 和 WMEM_MAX。"; apply_buffers "$@" ;;
    recommend|apply-smart)
      local_mbps=""
      peer_mbps=""
      rtt_ms=""
      memory_mb_value=""
      objective="retrans"
      ramp_rate="0.79"
      aggressive="0"
      allow_same_public="0"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --local-mbps) local_mbps="$2"; shift 2 ;;
          --peer-mbps) peer_mbps="$2"; shift 2 ;;
          --rtt-ms) rtt_ms="$2"; shift 2 ;;
          --memory-mb) memory_mb_value="$2"; shift 2 ;;
          --objective) objective="$2"; shift 2 ;;
          --ramp) ramp_rate="$2"; shift 2 ;;
          --aggressive) aggressive="1"; shift ;;
          *) die "未知 $cmd 参数：$1" ;;
        esac
      done
      [ -n "$local_mbps" ] || die "$cmd 需要 --local-mbps"
      [ -n "$peer_mbps" ] || die "$cmd 需要 --peer-mbps"
      [ -n "$rtt_ms" ] || die "$cmd 需要 --rtt-ms"
      [ -n "$memory_mb_value" ] || memory_mb_value="$(memory_mb)"
      if [ "$cmd" = "recommend" ]; then
        print_recommendation "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive"
      else
        apply_smart "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive"
      fi
      ;;
    rollback) rollback_last ;;
    server|listen)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --port) AGENT_PORT="$2"; shift 2 ;;
          --iperf-port) IPERF_PORT="$2"; shift 2 ;;
          --ttl) SESSION_TTL="$2"; shift 2 ;;
          --public-url) LISTEN_PUBLIC_URL="$2"; shift 2 ;;
          *) die "未知 $cmd 参数：$1" ;;
        esac
      done
      if [ "$cmd" = "server" ]; then
        server_mode
      else
        listen_mode
      fi
      ;;
    client) client_mode "$@" ;;
    join) join_mode "$@" ;;
    _iperf-json)
      [ "$#" -eq 4 ] || die "_iperf-json 需要 host port reverse seconds"
      run_iperf_client "$1" "$2" "$3" "$4"
      ;;
    auto)
      host=""
      objective="retrans"
      target_retr="0"
      rounds="5"
      port="$IPERF_PORT"
      local_mbps="0"
      peer_mbps="0"
      rtt_ms="100"
      memory_mb_value=""
      ramp_rate="0.79"
      aggressive="0"
      allow_same_public="0"
      reverse="1"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --host) host="$2"; shift 2 ;;
          --port) port="$2"; shift 2 ;;
          --direction)
            case "$2" in
              download|reverse) reverse="1" ;;
              upload|forward) reverse="0" ;;
              *) die "--direction 只支持 download 或 upload" ;;
            esac
            shift 2
            ;;
          --download|--reverse) reverse="1"; shift ;;
          --upload|--forward) reverse="0"; shift ;;
          --objective) objective="$2"; shift 2 ;;
          --target-retr) target_retr="$2"; shift 2 ;;
          --rounds) rounds="$2"; shift 2 ;;
          --local-mbps) local_mbps="$2"; shift 2 ;;
          --peer-mbps) peer_mbps="$2"; shift 2 ;;
          --rtt-ms) rtt_ms="$2"; shift 2 ;;
          --memory-mb) memory_mb_value="$2"; shift 2 ;;
          --ramp) ramp_rate="$2"; shift 2 ;;
          --aggressive) aggressive="1"; shift ;;
          --allow-same-public-ip) allow_same_public="1"; shift ;;
          *) die "未知 auto 参数：$1" ;;
        esac
      done
      [ -n "$host" ] || die "auto 需要 --host"
      auto_tune "$host" "$port" "$objective" "$target_retr" "$rounds" "$reverse" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive" "$allow_same_public"
      ;;
    stop-agent) stop_agent ;;
    *) usage; die "未知命令：$cmd" ;;
  esac
}

main "$@"
