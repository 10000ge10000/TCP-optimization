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
  [ -t 0 ] || { [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; }
}

prompt_read() {
  prompt="$1"
  printf "%s" "$prompt"
  if [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    IFS= read -r PROMPT_REPLY < /dev/tty || return 1
  else
    IFS= read -r PROMPT_REPLY || return 1
  fi
  return 0
}

pause_for_enter() {
  has_interactive_input || return 0
  printf "\n%s按回车返回菜单...%s" "$COLOR_DIM" "$COLOR_RESET"
  if [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
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

ui_rule() {
  printf "%s+----------------------------------------------------------+%s\n" "$COLOR_DIM" "$COLOR_RESET"
}

ui_row() {
  label="$1"
  value="$2"
  printf "| %-12s %-43s |\n" "$label" "$value"
}

ui_section() {
  title="$1"
  printf "%s%s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
  ui_rule
}

ui_note() {
  label="$1"
  text="$2"
  printf "%s%-8s%s %s\n" "$COLOR_DIM" "$label" "$COLOR_RESET" "$text"
}

ui_subtitle() {
  text="$1"
  printf "%s%s%s\n" "$COLOR_DIM" "$text" "$COLOR_RESET"
}

ui_mode_card() {
  number="$1"
  title="$2"
  desc="$3"
  target="$4"
  printf "  %s[%s]%s %s%-10s%s %s\n" "$COLOR_CYAN" "$number" "$COLOR_RESET" "$COLOR_BOLD" "$title" "$COLOR_RESET" "$desc"
  printf "      %s目标：%s%s\n" "$COLOR_DIM" "$target" "$COLOR_RESET"
}

metric_line() {
  label="$1"
  value="$2"
  state="${3:-}"
  case "$state" in
    good) color="$COLOR_GREEN" ;;
    warn) color="$COLOR_YELLOW" ;;
    bad) color="$COLOR_RED" ;;
    *) color="$COLOR_CYAN" ;;
  esac
  printf "  %-8s %s%s%s\n" "$label" "$color" "$value" "$COLOR_RESET"
}

trend_label() {
  current="$1"
  previous="$2"
  if [ -z "$previous" ]; then
    echo "建立基线"
  elif [ "$current" -lt "$previous" ]; then
    echo "重传下降"
  elif [ "$current" -gt "$previous" ]; then
    echo "重传上升"
  else
    echo "保持稳定"
  fi
}

next_action_label() {
  objective="$1"
  retr="$2"
  target_retr="$3"
  case "$objective" in
    throughput)
      if [ "$retr" -le "$target_retr" ]; then
        echo "重传可接受，继续尝试提高吞吐。"
      else
        echo "重传偏高，先收缩缓冲再测试。"
      fi
      ;;
    startup)
      echo "降低初始排队，优先改善短连接起速。"
      ;;
    *)
      if [ "$retr" -le "$target_retr" ]; then
        echo "已达到目标，保持当前参数。"
      else
        echo "降低排队和发送缓冲，继续压低重传。"
      fi
      ;;
  esac
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
  if [ "${TUNE_SIMPLE_OUTPUT:-0}" = "1" ]; then
    info "参数已调整并即时保存（已创建回滚备份）。"
  else
    info "已即时保存并加载 buffer：rmem=$rmem_max wmem=$wmem_max notsent=$notsent_lowat limit_output=$limit_output"
    info "备份目录：$backup_dir"
  fi
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

local_lan_ipv4() {
  if have_cmd ip; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "src" && (i + 1) <= NF) {
            print $(i + 1)
            exit
          }
        }
      }
    ' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}'
    return 0
  fi
  if have_cmd route && have_cmd ipconfig; then
    interface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
    if [ -n "$interface" ]; then
      ipconfig getifaddr "$interface" 2>/dev/null || true
      return 0
    fi
  fi
  hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}' || true
}

objective_label() {
  case "$1" in
    throughput) echo "吞吐优先" ;;
    startup) echo "快速起速" ;;
    *) echo "重传优先" ;;
  esac
}

direction_label() {
  [ "$1" = "1" ] && echo "下载（服务端 → 本机）" || echo "上传（本机 → 服务端）"
}

format_rate() {
  awk -v bps="${1:-0}" 'BEGIN {
    if (bps >= 1000000000) printf "%.2f Gbps\n", bps / 1000000000
    else printf "%.1f Mbps\n", bps / 1000000
  }'
}

format_count() {
  awk -v value="${1:-0}" 'BEGIN {
    text = sprintf("%.0f", value)
    output = ""
    while (length(text) > 3) {
      output = "," substr(text, length(text) - 2) output
      text = substr(text, 1, length(text) - 3)
    }
    print text output
  }'
}

percent_delta() {
  before="$1"
  after="$2"
  awk -v before="$before" -v after="$after" 'BEGIN {
    if (before <= 0) {
      print "建立基线"
      exit
    }
    delta = (after - before) * 100 / before
    if (delta > 0) printf "+%.0f%%\n", delta
    else printf "%.0f%%\n", delta
  }'
}

progress_steps() {
  round="$1"
  rounds="$2"
  printf "  %s连接测试%s -> %s分析结果%s -> %s应用调整%s -> %s复测确认%s\n" \
    "$COLOR_GREEN" "$COLOR_RESET" \
    "$COLOR_GREEN" "$COLOR_RESET" \
    "$COLOR_CYAN" "$COLOR_RESET" \
    "$COLOR_DIM" "$COLOR_RESET"
  printf "  轮次 %s/%s\n" "$round" "$rounds"
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
  bind_ip="${5:-}"
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法测试。"
  if [ "$reverse" = "1" ]; then
    if [ -n "$bind_ip" ]; then
      iperf3 -c "$host" -p "$port" -B "$bind_ip" -R -t "$seconds" -J
    else
      iperf3 -c "$host" -p "$port" -R -t "$seconds" -J
    fi
  else
    if [ -n "$bind_ip" ]; then
      iperf3 -c "$host" -p "$port" -B "$bind_ip" -t "$seconds" -J
    else
      iperf3 -c "$host" -p "$port" -t "$seconds" -J
    fi
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

  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in
    127.*|localhost|"$bind_ip") bind_ip="" ;;
  esac
  mode_name="$(objective_label "$objective")"
  transfer_name="$(direction_label "$reverse")"
  display_local_ip="${bind_ip:-$(local_lan_ipv4 || true)}"
  [ -n "$display_local_ip" ] || display_local_ip="未识别"
  TUNE_SIMPLE_OUTPUT=1

  clear_screen
  print_header "正在优化 · $mode_name"
  ui_subtitle "$transfer_name · 本机 $display_local_ip · 第 1/$rounds 轮"
  echo
  ui_section "优化概览"
  ui_row "模式" "$mode_name"
  ui_row "方向" "$transfer_name"
  ui_row "本机地址" "$display_local_ip"
  ui_row "测速节点" "已连接的服务端"
  ui_row "最大轮数" "$rounds"
  ui_rule
  echo
  ui_note "说明" "测速使用本机局域网地址作为源地址，远端连接地址不会显示在界面中。"

  i=1
  previous_retr=""
  previous_bps=""
  first_retr=""
  first_bps=""
  final_retr="0"
  final_bps="0"
  while [ "$i" -le "$rounds" ]; do
    echo
    ui_section "第 $i/$rounds 轮测试"
    progress_steps "$i" "$rounds"
    ui_note "状态" "正在用 iperf3 测试真实链路..."
    json="$(run_iperf_client "$host" "$port" "$reverse" 15 "$bind_ip" || true)"
    [ -n "$json" ] || die "iperf3 测试失败。"
    retr="$(printf '%s\n' "$json" | extract_retransmits)"
    bps="$(printf '%s\n' "$json" | extract_bps)"
    retr="${retr:-0}"
    bps="${bps:-0}"
    final_retr="$retr"
    final_bps="$bps"
    [ -n "$first_retr" ] || first_retr="$retr"
    [ -n "$first_bps" ] || first_bps="$bps"
    readable_rate="$(format_rate "$bps")"
    readable_retr="$(format_count "$retr")"
    previous_rate="无"
    [ -n "$previous_bps" ] && previous_rate="$(format_rate "$previous_bps")"
    previous_retr_text="无"
    [ -n "$previous_retr" ] && previous_retr_text="$(format_count "$previous_retr") 次"
    retr_delta="$(percent_delta "$first_retr" "$retr")"
    if [ "$retr" -le "$target_retr" ]; then
      retr_state="good"
    else
      retr_state="bad"
    fi
    trend="$(trend_label "$retr" "$previous_retr")"
    action="$(next_action_label "$objective" "$retr" "$target_retr")"
    case "$trend" in
      重传下降|建立基线|保持稳定) trend_state="good" ;;
      *) trend_state="warn" ;;
    esac
    metric_line "当前速度" "$readable_rate（上轮 $previous_rate）" "info"
    metric_line "当前重传" "$readable_retr 次（上轮 $previous_retr_text）" "$retr_state"
    metric_line "改善幅度" "$retr_delta · $trend" "$trend_state"
    metric_line "当前动作" "$action" "warn"
    if [ -n "${TUNE_REPORT_PEER:-}" ] && [ -n "${TUNE_REPORT_TOKEN:-}" ]; then
      report_direction="download"
      [ "$reverse" = "0" ] && report_direction="upload"
      report_data="{\"role\":\"client-result\",\"lan_ip\":\"${TUNE_CLIENT_IP:-$display_local_ip}\",\"round\":$i,\"rounds\":$rounds,\"objective\":\"$objective\",\"direction\":\"$report_direction\",\"retransmits\":$retr,\"bits_per_second\":$bps,\"time\":$(date +%s)}"
      post_json "$TUNE_REPORT_PEER/report" "$TUNE_REPORT_TOKEN" "$report_data" >/dev/null 2>&1 || true
    fi

    measured_mbps="$(awk -v bps="$bps" 'BEGIN {v=bps/1000000; if (v < 1) v=1; printf "%d\n", v}')"
    [ "$peer_mbps" = "0" ] && peer_mbps="$measured_mbps"
    [ "$local_mbps" = "0" ] && local_mbps="$peer_mbps"

    if [ "$objective" = "retrans" ] && [ "$retr" -le "$target_retr" ]; then
      echo
      ui_note "结果" "目标已达成，进入结果页。"
      break
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
    elif [ "$objective" = "throughput" ]; then
      ramp_rate="$(awk -v r="$ramp_rate" -v retr="$retr" -v target="$target_retr" 'BEGIN {
        if (retr <= target) v = r * 1.08
        else v = r * 0.92
        if (v > 1.20) v = 1.20
        if (v < 0.45) v = 0.45
        printf "%.3f\n", v
      }')"
    fi
    previous_retr="$retr"
    previous_bps="$bps"
    i=$((i + 1))
  done
  echo
  ui_section "优化完成"
  final_rate="$(format_rate "$final_bps")"
  final_retr_text="$(format_count "$final_retr")"
  first_rate="$(format_rate "${first_bps:-0}")"
  first_retr_text="$(format_count "${first_retr:-0}")"
  speed_delta="$(percent_delta "${first_bps:-0}" "$final_bps")"
  retr_delta="$(percent_delta "${first_retr:-0}" "$final_retr")"
  if [ "$objective" = "retrans" ] && [ "$final_retr" -gt "$target_retr" ]; then
    warn "已完成 $rounds 轮，重传尚未降至目标值。"
    ui_row "结论" "重传尚未达到目标，建议检查链路质量后再试。"
  elif [ "$final_retr" -gt "$target_retr" ]; then
    warn "优化轮次已完成，但当前重传仍偏高。"
    ui_row "结论" "参数已保存，但当前重传仍偏高。"
  else
    ui_row "结论" "目标已达成：当前配置已即时保存。"
  fi
  ui_rule
  echo
  ui_section "优化前后"
  printf "  %-12s %-16s %-16s %-12s\n" "指标" "优化前" "优化后" "变化"
  printf "  %-12s %-16s %-16s %-12s\n" "传输速度" "$first_rate" "$final_rate" "$speed_delta"
  printf "  %-12s %-16s %-16s %-12s\n" "重传次数" "$first_retr_text" "$final_retr_text" "$retr_delta"
  echo
  ui_section "配置摘要"
  ui_note "已保存" "接收/发送缓冲和低排队参数已应用。"
  ui_note "回滚" "已创建备份，可在客户端菜单或 rollback 命令中恢复。"
  echo
  ui_section "下一步操作"
  printf "  %s[1]%s 返回客户端主页\n" "$COLOR_CYAN" "$COLOR_RESET"
  printf "  %s[2]%s 换一种模式继续优化\n" "$COLOR_CYAN" "$COLOR_RESET"
  printf "  %s[3]%s 查看详细参数\n" "$COLOR_CYAN" "$COLOR_RESET"
  printf "  %s[4]%s 回滚本次修改\n" "$COLOR_CYAN" "$COLOR_RESET"
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
}
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
            STATE["events"].append({
                "time": time.time(),
                "action": "peer-report",
                "role": payload.get("role", "unknown"),
                "lan_ip": payload.get("lan_ip", ""),
                "os": payload.get("os", ""),
                "round": payload.get("round"),
                "objective": payload.get("objective", ""),
                "direction": payload.get("direction", ""),
                "retransmits": payload.get("retransmits"),
                "bits_per_second": payload.get("bits_per_second"),
            })
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
        if path in {"/optimize", "/apply-profile", "/apply-buffers"}:
            write_json(self, 403, {"ok": False, "error": "server is read-only"})
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
  if [ "${SERVER_MONITOR_AFTER_LISTEN:-0}" != "1" ]; then
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
  for session_file in "$STATE_DIR"/agent-*.token "$STATE_DIR"/agent-*.url "$STATE_DIR"/tcp-tune-agent.py "$STATE_DIR"/server-dashboard-*.json; do
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

render_server_dashboard() {
  peer_url="$1"
  token="$2"
  remaining="${3:-$SESSION_TTL}"
  ttl_text="$((remaining / 60))m $((remaining % 60))s"
  clear_screen
  print_header "TCP 双端调优器 · 服务端监控"
  ui_subtitle "服务端只负责接收客户端、展示过程和提供临时测速服务"
  echo
  ui_section "会话状态"
  ui_row "运行状态" "服务运行中"
  ui_row "运行模式" "只读监控"
  ui_row "Agent 端口" "$AGENT_PORT"
  ui_row "测速端口" "$IPERF_PORT"
  ui_row "剩余时间" "$ttl_text"
  ui_rule
  echo
  render_server_activity "$token"
  echo
  print_client_commands "$peer_url" "$token"
  echo
  ui_section "安全说明"
  ui_note "只读" "服务端不修改 TCP 参数，所有优化由客户端在本机执行。"
  ui_note "清理" "保持此窗口运行；按 Ctrl+C 会停止 Agent/iperf3 并清理凭据。"
}

render_server_activity() {
  token="$1"
  dashboard_file="$STATE_DIR/server-dashboard-$AGENT_PORT.json"
  if ! curl -fsS -H "X-TCP-Tune-Token: $token" "http://127.0.0.1:$AGENT_PORT/state" -o "$dashboard_file" 2>/dev/null; then
    printf "%s会话状态%s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    print_rule
    echo "  Agent 状态暂时不可读。"
    return 0
  fi
  python3 - "$dashboard_file" <<'PY'
import json
import sys
import time

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    state = json.load(handle).get("state", {})

reports = state.get("peer_reports", [])
devices = {}
results = []
for entry in reports:
    payload = entry.get("payload", {})
    ip = str(payload.get("lan_ip") or "").strip()
    role = str(payload.get("role") or "unknown")
    if payload.get("bits_per_second") is not None:
        results.append((entry.get("time", 0), payload))
    if ip:
        device = devices.setdefault(ip, {"ip": ip, "os": "Unknown", "role": role, "last": 0})
        if payload.get("os"):
            device["os"] = str(payload["os"])
        if role != "client-result":
            device["role"] = role
        device["last"] = max(device["last"], entry.get("time", 0))

print("已接入客户端")
print("+----------------------------------------------------------+")
if not devices:
    print("  暂无客户端，等待连接...")
else:
    for device in sorted(devices.values(), key=lambda item: item["last"], reverse=True):
        seen = time.strftime("%H:%M:%S", time.localtime(device["last"]))
        print(f"  ● {device['os']} · {device['ip']}  最近上报 {seen}")

print()
print("最近结果")
print("+----------------------------------------------------------+")
if not results:
    print("  尚未收到测速结果。")
else:
    _, payload = results[-1]
    objective = {"retrans": "重传优先", "throughput": "吞吐优先", "startup": "快速起速"}.get(str(payload.get("objective")), "未指定")
    direction = "上传" if payload.get("direction") == "upload" else "下载"
    bps = float(payload.get("bits_per_second") or 0)
    rate = f"{bps / 1_000_000_000:.2f} Gbps" if bps >= 1_000_000_000 else f"{bps / 1_000_000:.1f} Mbps"
    retransmits = int(float(payload.get("retransmits") or 0))
    round_no = payload.get("round") or "-"
    rounds = payload.get("rounds") or "-"
    print(f"  模式：{objective}  方向：{direction}  轮次：{round_no}/{rounds}")
    print(f"  速度：{rate}  重传：{retransmits:,} 次")

print()
print("最近事件")
print("+----------------------------------------------------------+")
events = state.get("events", [])[-5:]
if not events:
    print("  服务端已启动，等待客户端上报。")
else:
    for event in events:
        stamp = time.strftime("%H:%M:%S", time.localtime(event.get("time", 0)))
        if event.get("action") == "peer-report" and event.get("round") is not None:
            text = f"收到第 {event.get('round')} 轮测速结果"
        elif event.get("action") == "peer-report":
            text = f"客户端上报：{event.get('lan_ip') or event.get('role', 'unknown')}"
        elif event.get("action") == "test":
            text = "服务端测速任务完成"
        elif event.get("action") == "stop-request":
            text = "收到停止会话请求"
        else:
            text = str(event.get("action") or "事件")
        print(f"  {stamp}  {text}")
PY
}

server_monitor() {
  token_file="$STATE_DIR/agent-$AGENT_PORT.token"
  url_file="$STATE_DIR/agent-$AGENT_PORT.url"
  agent_pid_file="$STATE_DIR/agent-$AGENT_PORT.pid"
  token="$(cat "$token_file" 2>/dev/null || true)"
  peer_url="$(cat "$url_file" 2>/dev/null || true)"
  [ -n "$token" ] || die "服务端 token 文件不存在。"
  deadline=$(( $(date +%s) + SESSION_TTL ))
  rendered_once=0
  while true; do
    if [ ! -f "$agent_pid_file" ]; then
      info "服务端会话已停止。"
      return 0
    fi
    agent_pid="$(cat "$agent_pid_file" 2>/dev/null || true)"
    if [ -z "$agent_pid" ] || ! kill -0 "$agent_pid" >/dev/null 2>&1; then
      warn "Agent 已退出，服务端监控结束。"
      return 0
    fi
    now="$(date +%s)"
    remaining=$((deadline - now))
    if [ "$remaining" -le 0 ]; then
      warn "会话已达到 TTL，正在安全停止。"
      return 0
    fi
    if [ -t 1 ] || [ "$rendered_once" = "0" ]; then
      render_server_dashboard "$peer_url" "$token" "$remaining"
      rendered_once=1
    fi
    sleep 2
  done
}

render_client_dashboard() {
  peer_url="$1"
  local_ip="$2"
  iperf_port="$3"
  clear_screen
  print_header "TCP 双端调优器 · 客户端"
  ui_subtitle "${OS_NAME:-本机} 设备已连接，可直接选择优化目标"
  echo
  ui_section "连接状态"
  ui_row "会话" "已连接"
  ui_row "本机" "${OS_NAME:-Unknown} · ${local_ip:-未识别}"
  ui_row "测速节点" "已连接的服务端"
  ui_row "测试端口" "$iperf_port"
  ui_rule
  echo
  ui_note "提示" "代理/公网地址仅用于脚本通讯，界面和测试源地址优先使用本机局域网 IP。"
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
  client_lan_ip="$(local_lan_ipv4 || true)"
  [ -n "$client_lan_ip" ] || client_lan_ip="unknown"
  TUNE_REPORT_PEER="$peer"
  TUNE_REPORT_TOKEN="$token"
  TUNE_CLIENT_IP="$client_lan_ip"

  report_role="join"
  [ "${CLIENT_MENU:-0}" = "1" ] && report_role="client"
  report="{\"role\":\"$report_role\",\"os\":\"$OS_NAME\",\"family\":\"$OS_FAMILY\",\"lan_ip\":\"$client_lan_ip\",\"time\":$(date +%s)}"
  post_json "$peer/report" "$token" "$report" >/dev/null || warn "无法向对端上报状态，但将继续本地测试。"

  host="$(printf '%s\n' "$peer" | sed 's#^http://##; s#^https://##; s#:.*##; s#/.*##')"
  echo "已连接到服务端会话。"
  if [ "${CLIENT_MENU:-0}" = "1" ]; then
    client_menu "$peer" "$token" "$host" "$iperf_port" "$allow_same_public" "$client_lan_ip"
  else
    echo "准备启动$(objective_label "$objective")优化。"
    auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive" "$allow_same_public"
  fi
}

run_client_optimization() {
  host="$1"
  iperf_port="$2"
  allow_same_public="$3"
  clear_screen
  print_header "选择优化目标"
  ui_subtitle "先选目标，再选测试方向。所有修改都可以回滚。"
  echo
  ui_section "优化模式"
  ui_mode_card "1" "重传优先" "适合游戏、语音、远程桌面。" "尽量把重传降到 0"
  ui_mode_card "2" "吞吐优先" "适合下载、备份、大文件。" "优先提升稳定传输速率"
  ui_mode_card "3" "快速起速" "适合网页、短连接、小文件。" "缩短连接初期的提速时间"
  echo
  if ! prompt_read "请选择优化目标 [1-3]："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) objective="throughput"; target_retr="10"; rounds="4" ;;
    3) objective="startup"; target_retr="5"; rounds="3" ;;
    *) objective="retrans"; target_retr="0"; rounds="5" ;;
  esac
  selected_label="$(objective_label "$objective")"

  echo
  ui_section "测试方向"
  printf "  %s[1]%s 下载  服务端 -> 本机\n" "$COLOR_CYAN" "$COLOR_RESET"
  printf "  %s[2]%s 上传  本机 -> 服务端\n" "$COLOR_CYAN" "$COLOR_RESET"
  ui_note "当前选择" "$selected_label · 默认下载方向"
  if ! prompt_read "请选择测试方向 [1-2]："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) reverse="0" ;;
    *) reverse="1" ;;
  esac

  auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" 0 0 100 "" 0.79 0 "$allow_same_public"
}

client_menu() {
  peer="$1"
  token="$2"
  host="$3"
  iperf_port="$4"
  allow_same_public="$5"
  client_lan_ip="$6"
  while true; do
    render_client_dashboard "$peer" "$client_lan_ip" "$iperf_port"
    echo
    ui_section "选择操作"
    printf "  %s[1]%s %s开始优化%s\n" "$COLOR_GREEN" "$COLOR_RESET" "$COLOR_BOLD" "$COLOR_RESET"
    printf "      %s选择重传、吞吐或快速起速%s\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "  %s[2]%s 查看本机状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "      %s查看系统与 TCP 参数摘要%s\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "  %s[3]%s 查看服务端状态\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "      %s检查会话与测速服务%s\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "  %s[4]%s 查看过程记录\n" "$COLOR_CYAN" "$COLOR_RESET"
    printf "      %s查看最近任务与结果%s\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "  %s[5]%s 停止双方会话并退出\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %s[0]%s 退出客户端\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "      %s不停止服务端会话%s\n" "$COLOR_DIM" "$COLOR_RESET"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入，客户端已保持连接上报后退出菜单。"
      return 0
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1) run_client_optimization "$host" "$iperf_port" "$allow_same_public"; pause_for_enter ;;
      2) clear_screen; print_header "本机状态"; status_full; pause_for_enter ;;
      3) clear_screen; print_header "服务端状态"; get_agent_json "$peer/status" "$token" || warn "读取服务端状态失败。"; pause_for_enter ;;
      4) clear_screen; print_header "过程记录"; get_agent_json "$peer/events" "$token" || warn "读取服务端事件失败。"; pause_for_enter ;;
      5) post_json "$peer/stop" "$token" "{}" || true; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}

server_mode() {
  trap 'exit 130' INT TERM
  trap 'if [ "${DRY_RUN:-0}" != "1" ]; then stop_agent; fi' 0
  SERVER_MONITOR_AFTER_LISTEN=1
  export SERVER_MONITOR_AFTER_LISTEN
  listen_mode
  unset SERVER_MONITOR_AFTER_LISTEN
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  server_monitor
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
