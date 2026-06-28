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
NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com/v1}"
NVIDIA_MODEL="${NVIDIA_MODEL:-auto}"
TCP_TUNE_AI_TIMEOUT="${TCP_TUNE_AI_TIMEOUT:-20}"
TCP_TUNE_AI_MAX_ROUNDS="${TCP_TUNE_AI_MAX_ROUNDS:-5}"
TCP_TUNE_AI_RETRIES="${TCP_TUNE_AI_RETRIES:-4}"
TCP_TUNE_AI_CURL_IP_FAMILY="${TCP_TUNE_AI_CURL_IP_FAMILY:--4}"
TCP_TUNE_AI_MAX_NOTSENT="${TCP_TUNE_AI_MAX_NOTSENT:-1048576}"
TCP_TUNE_AI_GATEWAY_URL="${TCP_TUNE_AI_GATEWAY_URL:-}"
TCP_TUNE_AI_GATEWAY_TOKEN="${TCP_TUNE_AI_GATEWAY_TOKEN:-}"
TCP_TUNE_DEFAULT_AI_GATEWAY_URL="${TCP_TUNE_DEFAULT_AI_GATEWAY_URL:-https://tcp-optimization-ai-gateway.10454728.workers.dev/v1}"
if [ -z "${NVIDIA_API_KEY:-}" ] && [ -z "$TCP_TUNE_AI_GATEWAY_URL" ]; then
  TCP_TUNE_AI_GATEWAY_URL="$TCP_TUNE_DEFAULT_AI_GATEWAY_URL"
fi
AI_MODEL_CANDIDATES="${TCP_TUNE_AI_MODELS:-minimaxai/minimax-m3 moonshotai/kimi-k2.6 minimaxai/minimax-m2.7 z-ai/glm-5.1}"
VPS_ADAPT_FILE="${TCP_TUNE_VPS_ADAPT_FILE:-/etc/sysctl.d/98-tcp-ipv6-openwrt-peer.conf}"
OPENWRT_MINIMAL_FILE="${TCP_TUNE_OPENWRT_MINIMAL_FILE:-/etc/sysctl.d/zz-tcp-ipv6-local-peer.conf}"
LAST_MANUAL_BACKUP=""

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

# 显示宽度计算：中文等 CJK 字符占 2 列，ASCII 占 1 列
# 用 awk 按 UTF-8 字节范围统计 CJK 字符数，补齐到指定显示宽度
ui_pad() {
  text="$1"
  width="$2"
  # awk 仅返回显示宽度（CJK 字符算 2），补空格交给 shell printf，兼容 busybox awk
  disp=$(printf '%s' "$text" | awk '{
    s = $0
    disp = 0
    n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c < "\200") disp += 1
      else if (c >= "\300") disp += 2
    }
    print disp + 0
  }')
  [ -z "$disp" ] && disp=0
  pad=$((width - disp))
  if [ "$pad" -gt 0 ]; then
    printf '%s%*s' "$text" "$pad" ""
  else
    printf '%s' "$text"
  fi
}

print_rule() {
  printf "%s%s%s\n" "$COLOR_CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$COLOR_RESET"
}

print_header() {
  title="$1"
  printf "\n  %s%s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
  print_rule
}

print_kv() {
  label="$1"
  value="$2"
  printf "  %s%s%s  %s\n" "$COLOR_BLUE" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$value"
}

ui_rule() {
  printf "%s%s%s\n" "$COLOR_DIM" "────────────────────────────────────────────────────────────" "$COLOR_RESET"
}

ui_row() {
  label="$1"
  value="$2"
  printf "  %s%s%s  %s\n" "$COLOR_BOLD" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$value"
}

ui_section() {
  title="$1"
  printf "  %s▎%s %s%s%s\n" "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
}

ui_note() {
  label="$1"
  text="$2"
  printf "  %s%s%s  %s%s%s\n" "$COLOR_DIM" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$COLOR_DIM" "$text" "$COLOR_RESET"
}

ui_subtitle() {
  text="$1"
  printf "  %s%s%s\n" "$COLOR_DIM" "$text" "$COLOR_RESET"
}

ui_mode_card() {
  number="$1"
  title="$2"
  desc="$3"
  target="$4"
  printf "  %s[%s]%s %s%s%s  %s\n" "$COLOR_CYAN" "$number" "$COLOR_RESET" "$COLOR_BOLD" "$(ui_pad "$title" 10)" "$COLOR_RESET" "$desc"
  printf "           %s目标：%s%s\n" "$COLOR_DIM" "$target" "$COLOR_RESET"
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
  printf "  %s  %s%s%s\n" "$(ui_pad "$label" 10)" "$color" "$value" "$COLOR_RESET"
}

ui_menu_group() {
  text="$1"
  printf "  %s%s%s\n" "$COLOR_CYAN" "$text" "$COLOR_RESET"
}

ui_menu_item() {
  number="$1"
  title="$2"
  desc="$3"
  color="${4:-$COLOR_CYAN}"
  printf "  %s[%s]%s %s%s%s  %s%s%s\n" \
    "$color" "$number" "$COLOR_RESET" \
    "$COLOR_BOLD" "$(ui_pad "$title" 16)" "$COLOR_RESET" \
    "$COLOR_DIM" "$desc" "$COLOR_RESET"
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

is_integer() {
  value="${1:-}"
  [ -n "$value" ] || return 1
  case "$value" in
    -*) value="${value#-}" ;;
  esac
  [ -n "$value" ] || return 1
  case "$value" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

is_unsigned_integer() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}

is_positive_number() {
  awk -v value="$1" 'BEGIN {
    exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 > 0)
  }'
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
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "缺少 $cmd，预览通过 $PKG_MANAGER 安装 $pkg"
    install_pkg "$pkg" || die "当前系统无法自动安装 $pkg。"
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
    "超近距极速"|"近距均衡"|"近距极速"|"中距穿越"|"亚太长距"|"远距穿透"|"超远距极限") return 0 ;;
    ultra-close|near-balance|near-speed|mid-cross|apac-long|far-punch|ultra-far) return 0 ;;
    "稳健入门"|"均衡通用"|"中距增强"|"高带宽增强"|"长距大带宽") return 0 ;;
    stable|balanced|medium|boost|longhaul) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_profile() {
  case "$1" in
    "超近距极速"|ultra-close) echo "超近距极速" ;;
    "近距均衡"|near-balance) echo "近距均衡" ;;
    "近距极速"|near-speed) echo "近距极速" ;;
    "中距穿越"|mid-cross) echo "中距穿越" ;;
    "亚太长距"|apac-long) echo "亚太长距" ;;
    "远距穿透"|far-punch) echo "远距穿透" ;;
    "超远距极限"|ultra-far) echo "超远距极限" ;;
    "稳健入门"|stable) echo "近距均衡" ;;
    "均衡通用"|balanced) echo "近距极速" ;;
    "中距增强"|medium) echo "中距穿越" ;;
    "高带宽增强"|boost) echo "亚太长距" ;;
    "长距大带宽"|longhaul) echo "远距穿透" ;;
    *) die "未知预设：$1" ;;
  esac
}

profile_values() {
  name="$(normalize_profile "$1")"
  # 输出: file_max rmem_max wmem_max rmem_min rmem_default rmem_max
  #        wmem_min wmem_default wmem_max adv_win_scale notsent_lowat
  case "$name" in
    "超近距极速")
      echo "6815744 33554432 33554432 4096 87380 33554432 4096 16384 33554432 1 32768"
      ;;
    "近距均衡")
      echo "6815744 67108864 33554432 4096 87380 67108864 4096 16384 33554432 1 49152"
      ;;
    "近距极速")
      echo "6815744 67108864 67108864 4096 87380 67108864 4096 16384 67108864 1 65536"
      ;;
    "中距穿越")
      echo "6815744 89653247 43033559 8192 87380 89653247 8192 65536 43033559 1 98304"
      ;;
    "亚太长距")
      echo "6815744 105062399 50429951 8192 87380 105062399 8192 65536 50429951 1 131072"
      ;;
    "远距穿透")
      echo "6815744 186777599 89653247 8192 87380 186777599 8192 65536 89653247 1 196608"
      ;;
    "超远距极限")
      echo "6815744 268435456 134217728 8192 87380 268435456 8192 65536 134217728 1 262144"
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
TCP 预设（按距离/延迟从近到远排列）：

1. 超近距极速  (RTT < 10ms, 同城/同机房)
   接收 32MiB / 发送 32MiB，小缓冲极低延迟，适合局域网或同机房。

2. 近距均衡    (RTT 10~30ms, 近距精品线路)
   接收 64MiB / 发送 32MiB，保守非对称，适合省际精品链路。

3. 近距极速    (RTT 30~60ms, 同区域)
   接收 64MiB / 发送 64MiB，对称大缓冲，适合日韩/东南亚低延迟链路。

4. 中距穿越    (RTT 60~120ms, 港区跨境)
   接收约 85MiB / 发送约 41MiB，适合香港中转、中等 RTT 链路。

5. 亚太长距    (RTT 120~180ms, 跨境高带宽)
   接收约 100MiB / 发送约 48MiB，适合亚太区高带宽跨海链路。

6. 远距穿透    (RTT 180~250ms, 欧美)
   接收约 178MiB / 发送约 85MiB，适合欧美方向高 RTT 大 BDP 链路。

7. 超远距极限  (RTT > 250ms, 极远距)
   接收约 256MiB / 发送约 128MiB，适合非洲/南美等极端高延迟链路。

英文别名: ultra-close, near-balance, near-speed, mid-cross, apac-long, far-punch, ultra-far
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
      printf "%d\n", clamp(int(mem_bytes * ratio), 262144, 268435456)
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

  for numeric_value in "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate"; do
    if ! is_positive_number "$numeric_value"; then
      echo "ERR invalid numeric input"
      return 0
    fi
  done
  case "$objective" in
    retrans|throughput|startup) ;;
    *)
      echo "ERR invalid objective"
      return 0
      ;;
  esac

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
        exit
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
        recv_mult = high_latency ? 6.0 : 5.0
        send_mult = high_latency ? 3.0 : 2.5
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
      rmem_floor = int(base_bdp / 4)
      if (rmem_floor < 262144) rmem_floor = 262144
      wmem_floor = int(base_bdp / 4)
      if (wmem_floor < 262144) wmem_floor = 262144
      rmem = clamp(rmem, rmem_floor, mem_cap)
      wmem = clamp(wmem, wmem_floor, mem_cap)

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

unique_path() {
  base_path="$1"
  candidate_path="$base_path"
  suffix=1
  while [ -e "$candidate_path" ]; do
    candidate_path="${base_path}-$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate_path"
}

backup_state() {
  ensure_state_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(unique_path "$STATE_DIR/backups/$ts")"
  mkdir "$dir"
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
  adv_win_scale="${10:-1}"
  notsent_lowat="${11:-16384}"
  qdisc="$(preferred_qdisc)"
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
net.ipv4.tcp_adv_win_scale = $adv_win_scale
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
    limit_output="$(awk -v n="$notsent_lowat" 'BEGIN {
      v = int(n * 2)
      if (v < 131072) v = 131072
      if (v > 1048576) v = 1048576
      printf "%d\n", v
    }')"
  fi
  qdisc="$(preferred_qdisc)"
  case "$rmem_max$wmem_max" in
    *[!0-9]*) die "buffer 参数必须是数字。" ;;
  esac
  is_integer "$adv_win_scale" || die "tcp_adv_win_scale 必须是整数。"
  for tcp_numeric in "$notsent_lowat" "$backlog" "$somaxconn" "$synbacklog" "$optmem" "$limit_output"; do
    is_unsigned_integer "$tcp_numeric" || die "扩展 TCP 参数必须是数字。"
  done
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
  rollback_target="$(unique_path "$STATE_DIR/rolled-back/$(basename "$latest")")"
  mv "$latest" "$rollback_target"
  info "已回滚到最近备份：$latest"
}

manual_backup_begin() {
  label="$1"
  ensure_state_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(unique_path "$STATE_DIR/manual-$label-$ts")"
  mkdir -p "$dir"
  sysctl -a 2>/dev/null | grep -E '^(fs.file-max|net\.core\.|net\.ipv4\.tcp_|net\.ipv4\.udp_)' > "$dir/before-sysctl.txt" || true
  [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$dir/sysctl.conf.before" || true
  [ -f "$VPS_ADAPT_FILE" ] && cp "$VPS_ADAPT_FILE" "$dir/$(basename "$VPS_ADAPT_FILE").before" || true
  [ -f "$OPENWRT_MINIMAL_FILE" ] && cp "$OPENWRT_MINIMAL_FILE" "$dir/$(basename "$OPENWRT_MINIMAL_FILE").before" || true
  [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "$dir/$(basename "$SYSCTL_FILE").before" || true
  LAST_MANUAL_BACKUP="$dir"
  echo "$dir"
}

restore_manual_backup() {
  backup_dir="$1"
  [ -n "$backup_dir" ] || return 1
  [ -d "$backup_dir" ] || return 1
  if [ -f "$backup_dir/$(basename "$VPS_ADAPT_FILE").before" ]; then
    cp "$backup_dir/$(basename "$VPS_ADAPT_FILE").before" "$VPS_ADAPT_FILE"
  elif [ -f "$VPS_ADAPT_FILE" ]; then
    rm -f "$VPS_ADAPT_FILE"
  fi
  if [ -f "$backup_dir/$(basename "$OPENWRT_MINIMAL_FILE").before" ]; then
    cp "$backup_dir/$(basename "$OPENWRT_MINIMAL_FILE").before" "$OPENWRT_MINIMAL_FILE"
  elif [ -f "$OPENWRT_MINIMAL_FILE" ]; then
    rm -f "$OPENWRT_MINIMAL_FILE"
  fi
  if [ -f "$backup_dir/sysctl.conf.before" ]; then
    cp "$backup_dir/sysctl.conf.before" /etc/sysctl.conf
  fi
  for file in "$VPS_ADAPT_FILE" "$OPENWRT_MINIMAL_FILE" /etc/sysctl.conf; do
    [ -f "$file" ] && sysctl -e -p "$file" >/dev/null 2>&1 || true
  done
  info "已按手动备份回滚：$backup_dir"
}

validate_bool_number() {
  case "$1" in
    0|1) return 0 ;;
    *) return 1 ;;
  esac
}

validate_positive_int_range() {
  value="$1"
  min="$2"
  max="$3"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN { exit !(value + 0 >= min + 0 && value + 0 <= max + 0) }'
}

ai_max_notsent() {
  value="$TCP_TUNE_AI_MAX_NOTSENT"
  validate_positive_int_range "$value" 16384 2147483647 || value=1048576
  echo "$value"
}

apply_vps_adapt_values() {
  congestion="$1"
  mtu_probing="$2"
  slow_start="$3"
  rmem_max="$4"
  wmem_max="$5"
  notsent_lowat="$6"
  limit_output="$7"

  need_root
  case "$congestion" in bbr|cubic|reno) ;; *) die "非法拥塞控制：$congestion" ;; esac
  validate_bool_number "$mtu_probing" || die "非法 tcp_mtu_probing：$mtu_probing"
  validate_bool_number "$slow_start" || die "非法 tcp_slow_start_after_idle：$slow_start"
  validate_positive_int_range "$rmem_max" 1048576 268435456 || die "非法 rmem_max：$rmem_max"
  validate_positive_int_range "$wmem_max" 1048576 268435456 || die "非法 wmem_max：$wmem_max"
  validate_positive_int_range "$notsent_lowat" 16384 "$(ai_max_notsent)" || die "非法 tcp_notsent_lowat：$notsent_lowat"
  validate_positive_int_range "$limit_output" 131072 4194304 || die "非法 tcp_limit_output_bytes：$limit_output"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] VPS 将写入：cc=$congestion mtu=$mtu_probing slow_start=$slow_start rmem=$rmem_max wmem=$wmem_max notsent=$notsent_lowat limit=$limit_output"
    return 0
  fi

  backup_dir="$(manual_backup_begin "ipv6-vps")"
  cat > "$VPS_ADAPT_FILE" <<EOF
# TCP-optimization: IPv6 peer adaptation profile.
# This file is managed by tcp-tune.sh; rollback data: $backup_dir
net.ipv4.tcp_congestion_control = $congestion
net.ipv4.tcp_mtu_probing = $mtu_probing
net.ipv4.tcp_slow_start_after_idle = $slow_start
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 16384 $wmem_max
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.ipv4.tcp_limit_output_bytes = $limit_output
EOF
  sysctl -e -p "$VPS_ADAPT_FILE" >/dev/null || die "VPS 适配参数加载失败，备份目录：$backup_dir"
  LAST_MANUAL_BACKUP="$backup_dir"
  info "VPS 适配参数已保存并加载：$VPS_ADAPT_FILE"
  info "备份目录：$backup_dir"
}

apply_openwrt_minimal_values() {
  mtu_probing="$1"
  slow_start="$2"
  notsent_lowat="$3"
  limit_output="$4"

  need_root
  validate_bool_number "$mtu_probing" || die "非法 tcp_mtu_probing：$mtu_probing"
  validate_bool_number "$slow_start" || die "非法 tcp_slow_start_after_idle：$slow_start"
  validate_positive_int_range "$notsent_lowat" 16384 "$(ai_max_notsent)" || die "非法 tcp_notsent_lowat：$notsent_lowat"
  validate_positive_int_range "$limit_output" 131072 4194304 || die "非法 tcp_limit_output_bytes：$limit_output"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] OpenWrt 将最小写入：mtu=$mtu_probing slow_start=$slow_start notsent=$notsent_lowat limit=$limit_output"
    return 0
  fi

  backup_dir="$(manual_backup_begin "ipv6-openwrt")"
  cat > "$OPENWRT_MINIMAL_FILE" <<EOF
# TCP-optimization: minimal local overrides for verified IPv6 peer paths.
# This file does not touch firewall, WAN, DNS, DHCP or proxy services.
net.ipv4.tcp_slow_start_after_idle = $slow_start
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.ipv4.tcp_limit_output_bytes = $limit_output
EOF
  if [ -f /etc/sysctl.conf ]; then
    if grep -q '^net\.ipv4\.tcp_mtu_probing[[:space:]]*=' /etc/sysctl.conf; then
      sed -i "s|^net\\.ipv4\\.tcp_mtu_probing[[:space:]]*=.*|net.ipv4.tcp_mtu_probing=$mtu_probing|" /etc/sysctl.conf
    else
      printf '\nnet.ipv4.tcp_mtu_probing=%s\n' "$mtu_probing" >> /etc/sysctl.conf
    fi
  fi
  sysctl -w \
    net.ipv4.tcp_mtu_probing="$mtu_probing" \
    net.ipv4.tcp_slow_start_after_idle="$slow_start" \
    net.ipv4.tcp_notsent_lowat="$notsent_lowat" \
    net.ipv4.tcp_limit_output_bytes="$limit_output" >/dev/null || die "OpenWrt 最小参数加载失败，备份目录：$backup_dir"
  LAST_MANUAL_BACKUP="$backup_dir"
  info "OpenWrt 最小参数已保存并加载：$OPENWRT_MINIMAL_FILE"
  info "备份目录：$backup_dir"
}

vps_adapt_profile() {
  profile="$1"
  case "$profile" in
    cubic-safe|balanced)
      apply_vps_adapt_values cubic 1 0 67108864 67108864 "$(ai_max_notsent)" 1048576
      ;;
    bbr-fast)
      apply_vps_adapt_values bbr 1 0 67108864 67108864 "$(ai_max_notsent)" 1048576
      ;;
    *)
      die "未知 VPS 适配预设：$profile"
      ;;
  esac
}

json_escape_string() {
  awk '
    BEGIN { first = 1 }
    {
      gsub(/\\/,"\\\\")
      gsub(/"/,"\\\"")
      gsub(/\r/,"")
      if (!first) printf "\\n"
      printf "%s", $0
      first = 0
    }
  '
}

ai_content_from_response() {
  awk '
    BEGIN { key="\"content\""; in_string=0; escaped=0; found=0; out="" }
    {
      text = text $0 "\n"
    }
    END {
      pos = index(text, key)
      if (!pos) exit 1
      text = substr(text, pos + length(key))
      colon = index(text, ":")
      if (!colon) exit 1
      text = substr(text, colon + 1)
      start = index(text, "\"")
      if (!start) exit 1
      text = substr(text, start + 1)
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (escaped) {
          if (ch == "n") out = out "\n"
          else if (ch == "r") out = out "\r"
          else if (ch == "t") out = out "\t"
          else out = out ch
          escaped = 0
        } else if (ch == "\\") {
          escaped = 1
        } else if (ch == "\"") {
          print out
          exit 0
        } else {
          out = out ch
        }
      }
      exit 1
    }
  '
}

extract_json_object_text() {
  awk '
    BEGIN { depth=0; started=0; in_string=0; escaped=0; out="" }
    {
      text = text $0 "\n"
    }
    END {
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (!started) {
          if (ch == "{") {
            started = 1
            depth = 1
            out = ch
          }
          continue
        }
        out = out ch
        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\") {
          escaped = 1
          continue
        }
        if (ch == "\"") {
          in_string = !in_string
          continue
        }
        if (!in_string && ch == "{") depth++
        if (!in_string && ch == "}") {
          depth--
          if (depth == 0) {
            print out
            exit 0
          }
        }
      }
      exit 1
    }
  '
}

json_number_field() {
  field="$1"
  default="$2"
  awk -v field="\"$field\"" -v default="$default" '
    BEGIN { value = default }
    {
      pos = index($0, field)
      if (pos) {
        rest = substr($0, pos + length(field))
        sub(/^[^:]*:/, "", rest)
        if (match(rest, /-?[0-9]+/)) value = substr(rest, RSTART, RLENGTH)
      }
    }
    END { print value }
  '
}

json_string_field() {
  field="$1"
  default="$2"
  awk -v field="\"$field\"" -v default="$default" '
    BEGIN { value = default }
    {
      pos = index($0, field)
      if (pos) {
        rest = substr($0, pos + length(field))
        sub(/^[^:]*:[[:space:]]*"/, "", rest)
        end = index(rest, "\"")
        if (end > 0) value = substr(rest, 1, end - 1)
      }
    }
    END { print value }
  '
}

clamp_int() {
  value="$1"
  default="$2"
  min="$3"
  max="$4"
  is_integer "$value" || value="$default"
  awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN {
    if (value < min) value = min
    if (value > max) value = max
    printf "%.0f\n", value
  }'
}

ai_curl_post_chat() {
  model="$1"
  prompt="$2"
  max_tokens="${3:-256}"
  base_url="${TCP_TUNE_AI_GATEWAY_URL:-$NVIDIA_BASE_URL}"
  base_url="${base_url%/}"
  escaped_prompt="$(printf '%s' "$prompt" | json_escape_string)"
  body="$(cat <<EOF
{"model":"$model","messages":[{"role":"user","content":"$escaped_prompt"}],"temperature":0,"max_tokens":$max_tokens}
EOF
)"
  auth_header=""
  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    auth_header="Authorization: Bearer $NVIDIA_API_KEY"
  elif [ -n "${TCP_TUNE_AI_GATEWAY_TOKEN:-}" ]; then
    auth_header="Authorization: Bearer $TCP_TUNE_AI_GATEWAY_TOKEN"
  fi
  curl_ip_arg=""
  case "${TCP_TUNE_AI_CURL_IP_FAMILY:-}" in
    -4|--ipv4) curl_ip_arg="-4" ;;
    -6|--ipv6) curl_ip_arg="-6" ;;
    *) curl_ip_arg="" ;;
  esac
  attempt=1
  max_attempts="$TCP_TUNE_AI_RETRIES"
  is_unsigned_integer "$max_attempts" || max_attempts=4
  [ "$max_attempts" -lt 1 ] && max_attempts=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$auth_header" ]; then
      curl -fsS $curl_ip_arg --connect-timeout 10 --retry 1 --retry-delay 1 --max-time "$TCP_TUNE_AI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "User-Agent: TCP-optimization/1.0" \
        -H "$auth_header" \
        -d "$body" \
        "$base_url/chat/completions" && return 0
    else
      curl -fsS $curl_ip_arg --connect-timeout 10 --retry 1 --retry-delay 1 --max-time "$TCP_TUNE_AI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "User-Agent: TCP-optimization/1.0" \
        -d "$body" \
        "$base_url/chat/completions" && return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

ai_curl_client() {
  mode="$1"
  shift || true
  have_cmd curl || die "AI 模式需要 curl。"
  case "$mode" in
    benchmark)
      models="$*"
      best_model=""
      best_ms=""
      for model in $models; do
        start="$(date +%s 2>/dev/null || echo 0)"
        if response="$(ai_curl_post_chat "$model" "Return only OK." 16 2>&1)"; then
          end="$(date +%s 2>/dev/null || echo "$start")"
          elapsed=$((end - start))
          printf '%s\tOK\t%ss\n' "$model" "$elapsed"
          if [ -z "$best_ms" ] || [ "$elapsed" -lt "$best_ms" ]; then
            best_ms="$elapsed"
            best_model="$model"
          fi
        else
          printf '%s\tFAIL\t%s\n' "$model" "$(printf '%s' "$response" | head -n 1 | cut -c 1-120)"
        fi
      done
      [ -n "$best_model" ] || return 2
      printf 'BEST\t%s\n' "$best_model"
      ;;
    select)
      configured="${NVIDIA_MODEL:-auto}"
      if [ -n "$configured" ] && [ "$configured" != "auto" ]; then
        echo "$configured"
        return 0
      fi
      models="$*"
      for model in $models; do
        if ai_curl_post_chat "$model" "Return only OK." 16 >/dev/null 2>&1; then
          echo "$model"
          return 0
        fi
      done
      return 2
      ;;
    decide)
      model="$1"
      objective="$2"
      role="$3"
      summary="$(cat)"
      max_notsent="$(ai_max_notsent)"
      prompt="$(cat <<EOF
You are a conservative TCP tuning controller. Return only one JSON object. Do not include shell commands.
Allowed congestion values: cubic,bbr,reno.
Allowed integer fields: mtu_probing 0/1, slow_start_after_idle 0/1, rmem_max,wmem_max between 1048576 and 268435456, notsent_lowat between 16384 and $max_notsent, limit_output_bytes between 131072 and 4194304.
OpenWrt may only use minimal=true plus mtu_probing, slow_start_after_idle, notsent_lowat, limit_output_bytes.
Objective: $objective
Role: $role
Prefer VPS-side adaptation. For high VPS->OpenWrt retransmits with good throughput, prefer cubic-safe. For OpenWrt upload bottlenecks that remain low across tests, do not over-increase buffers.
Return JSON shape: {"vps":{"congestion":"cubic","mtu_probing":1,"slow_start_after_idle":0,"rmem_max":67108864,"wmem_max":67108864,"notsent_lowat":$max_notsent,"limit_output_bytes":1048576},"openwrt":{"minimal":true,"mtu_probing":1,"slow_start_after_idle":0,"notsent_lowat":$max_notsent,"limit_output_bytes":1048576},"reason":"short Chinese reason"}.
Summary JSON:
$summary
EOF
)"
      response="$(ai_curl_post_chat "$model" "$prompt" 512)"
      content="$(printf '%s' "$response" | ai_content_from_response)"
      printf '%s' "$content" | extract_json_object_text
      ;;
    normalize)
      role="$1"
      raw="$(cat)"
      max_notsent="$(ai_max_notsent)"
      congestion="$(printf '%s' "$raw" | json_string_field congestion cubic)"
      case "$congestion" in cubic|bbr|reno) ;; *) congestion="cubic" ;; esac
      vps_mtu="$(clamp_int "$(printf '%s' "$raw" | json_number_field mtu_probing 1)" 1 0 1)"
      vps_slow="$(clamp_int "$(printf '%s' "$raw" | json_number_field slow_start_after_idle 0)" 0 0 1)"
      vps_rmem="$(clamp_int "$(printf '%s' "$raw" | json_number_field rmem_max 67108864)" 67108864 1048576 268435456)"
      vps_wmem="$(clamp_int "$(printf '%s' "$raw" | json_number_field wmem_max 67108864)" 67108864 1048576 268435456)"
      vps_notsent="$(clamp_int "$(printf '%s' "$raw" | json_number_field notsent_lowat "$max_notsent")" "$max_notsent" 16384 "$max_notsent")"
      vps_limit="$(clamp_int "$(printf '%s' "$raw" | json_number_field limit_output_bytes 1048576)" 1048576 131072 4194304)"
      reason="$(printf '%s' "$raw" | json_string_field reason 未提供 | tr "'" " " | cut -c 1-160)"
      case "$role" in
        vps)
          printf "vps_congestion='%s'\n" "$congestion"
          printf "vps_mtu_probing='%s'\n" "$vps_mtu"
          printf "vps_slow_start='%s'\n" "$vps_slow"
          printf "vps_rmem_max='%s'\n" "$vps_rmem"
          printf "vps_wmem_max='%s'\n" "$vps_wmem"
          printf "vps_notsent='%s'\n" "$vps_notsent"
          printf "vps_limit='%s'\n" "$vps_limit"
          printf "ai_reason='%s'\n" "$reason"
          ;;
        openwrt)
          printf "op_minimal='1'\n"
          printf "op_mtu_probing='%s'\n" "$vps_mtu"
          printf "op_slow_start='%s'\n" "$vps_slow"
          printf "op_notsent='%s'\n" "$vps_notsent"
          printf "op_limit='%s'\n" "$vps_limit"
          printf "ai_reason='%s'\n" "$reason"
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

ai_require_env() {
  if ! have_cmd python3 && ! have_cmd curl; then
    die "AI 模式需要 curl；有 python3 时会使用更完整的解析路径。"
  fi
  if [ -z "${NVIDIA_API_KEY:-}" ] && [ -z "${TCP_TUNE_AI_GATEWAY_URL:-}" ]; then
    die "缺少 NVIDIA_API_KEY 或 TCP_TUNE_AI_GATEWAY_URL。请通过环境变量提供，不要把真实 Key 写入脚本或仓库。"
  fi
}

ai_python_client() {
  mode="$1"
  shift || true
  export NVIDIA_BASE_URL NVIDIA_MODEL TCP_TUNE_AI_TIMEOUT TCP_TUNE_AI_GATEWAY_URL TCP_TUNE_AI_GATEWAY_TOKEN TCP_TUNE_AI_MAX_NOTSENT
  if ! have_cmd python3; then
    ai_curl_client "$mode" "$@"
    return "$?"
  fi
  tmp_py="${TMPDIR:-/tmp}/tcp-tune-ai-$$.py"
  cat > "$tmp_py" <<'PY'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

mode = sys.argv[1]
gateway_url = os.environ.get("TCP_TUNE_AI_GATEWAY_URL", "").strip()
base_url = (gateway_url or os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")).rstrip("/")
api_key = os.environ.get("NVIDIA_API_KEY", "") or os.environ.get("TCP_TUNE_AI_GATEWAY_TOKEN", "")
timeout = float(os.environ.get("TCP_TUNE_AI_TIMEOUT", "20"))

def post_chat(model, messages, max_tokens=256):
    if not api_key and not gateway_url:
        raise RuntimeError("missing NVIDIA_API_KEY")
    body = {
        "model": model,
        "messages": messages,
        "temperature": 0,
        "max_tokens": max_tokens,
    }
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "TCP-optimization/1.0",
    }
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    req = urllib.request.Request(
        base_url + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("missing response choices")
    choice = choices[0]
    message = choice.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                parts.append(str(item.get("text") or item.get("content") or ""))
            else:
                parts.append(str(item))
        content = "".join(parts)
    if content is None:
        content = choice.get("text") or data.get("output_text") or message.get("reasoning_content")
    if content is None:
        keys = ",".join(sorted(message.keys() or choice.keys()))
        raise RuntimeError("missing response content: " + keys)
    return str(content)

def extract_json(text):
    text = text.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if fenced:
        text = fenced.group(1)
    else:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end >= start:
            text = text[start:end + 1]
    return json.loads(text)

if mode == "benchmark":
    models = sys.argv[2:]
    results = []
    for model in models:
        start = time.time()
        try:
            content = post_chat(model, [{"role": "user", "content": "Return only OK."}], 16)
            elapsed = time.time() - start
            ok = bool(content.strip())
            results.append((elapsed, model, ok, ""))
            print(f"{model}\tOK\t{elapsed:.3f}s")
        except Exception as exc:
            results.append((999999.0, model, False, str(exc).splitlines()[0][:120]))
            print(f"{model}\tFAIL\t{str(exc).splitlines()[0][:120]}")
    usable = [item for item in results if item[2]]
    if not usable:
        sys.exit(2)
    usable.sort()
    print("BEST\t" + usable[0][1])
elif mode == "select":
    configured = os.environ.get("NVIDIA_MODEL", "auto")
    if configured and configured != "auto":
        print(configured)
        sys.exit(0)
    models = sys.argv[2:]
    best = None
    for model in models:
        start = time.time()
        try:
            post_chat(model, [{"role": "user", "content": "Return only OK."}], 16)
            elapsed = time.time() - start
            if best is None or elapsed < best[0]:
                best = (elapsed, model)
        except Exception:
            continue
    if best is None:
        sys.exit(2)
    print(best[1])
elif mode == "decide":
    model = sys.argv[2]
    objective = sys.argv[3]
    role = sys.argv[4]
    summary = sys.stdin.read()
    max_notsent = int(os.environ.get("TCP_TUNE_AI_MAX_NOTSENT", "1048576"))
    max_notsent = max(16384, min(2147483647, max_notsent))
    system = (
        "You are a conservative TCP tuning controller. "
        "Return only one JSON object. Do not include shell commands. "
        "Allowed congestion values: cubic,bbr,reno. "
        "Allowed integer fields: mtu_probing 0/1, slow_start_after_idle 0/1, "
        "rmem_max,wmem_max between 1048576 and 268435456, "
        f"notsent_lowat between 16384 and {max_notsent}, "
        "limit_output_bytes between 131072 and 4194304. "
        "OpenWrt may only use minimal=true plus mtu_probing, slow_start_after_idle, notsent_lowat, limit_output_bytes."
    )
    user = (
        "Objective: " + objective + "\nRole: " + role + "\n"
        "Prefer VPS-side adaptation. For high VPS->OpenWrt retransmits with good throughput, prefer cubic-safe. "
        "For OpenWrt upload bottlenecks that remain low across tests, do not over-increase buffers.\n"
        "Return JSON shape: {\"vps\":{\"congestion\":\"cubic\",\"mtu_probing\":1,\"slow_start_after_idle\":0,"
        f"\"rmem_max\":67108864,\"wmem_max\":67108864,\"notsent_lowat\":{max_notsent},"
        "\"limit_output_bytes\":1048576},\"openwrt\":{\"minimal\":true,\"mtu_probing\":1,"
        f"\"slow_start_after_idle\":0,\"notsent_lowat\":{max_notsent},\"limit_output_bytes\":1048576},"
        "\"reason\":\"short Chinese reason\"}.\nSummary JSON:\n" + summary
    )
    content = post_chat(model, [{"role": "system", "content": system}, {"role": "user", "content": user}], 512)
    print(json.dumps(extract_json(content), ensure_ascii=False, separators=(",", ":")))
elif mode == "normalize":
    role = sys.argv[2]
    raw = sys.stdin.read()
    data = extract_json(raw)
    max_notsent = int(os.environ.get("TCP_TUNE_AI_MAX_NOTSENT", "1048576"))
    max_notsent = max(16384, min(2147483647, max_notsent))
    vps = data.get("vps") if isinstance(data.get("vps"), dict) else {}
    op = data.get("openwrt") if isinstance(data.get("openwrt"), dict) else {}
    reason = str(data.get("reason", ""))[:160].replace("'", "")

    def choice(value, allowed, default):
        value = str(value or default)
        return value if value in allowed else default

    def integer(value, default, low, high):
        try:
            value = int(value)
        except Exception:
            value = default
        return max(low, min(high, value))

    out = {
        "vps_congestion": choice(vps.get("congestion"), {"cubic", "bbr", "reno"}, "cubic"),
        "vps_mtu_probing": integer(vps.get("mtu_probing"), 1, 0, 1),
        "vps_slow_start": integer(vps.get("slow_start_after_idle"), 0, 0, 1),
        "vps_rmem_max": integer(vps.get("rmem_max"), 67108864, 1048576, 268435456),
        "vps_wmem_max": integer(vps.get("wmem_max"), 67108864, 1048576, 268435456),
        "vps_notsent": integer(vps.get("notsent_lowat"), max_notsent, 16384, max_notsent),
        "vps_limit": integer(vps.get("limit_output_bytes"), 1048576, 131072, 4194304),
        "op_minimal": 1 if op.get("minimal", True) else 0,
        "op_mtu_probing": integer(op.get("mtu_probing"), 1, 0, 1),
        "op_slow_start": integer(op.get("slow_start_after_idle"), 0, 0, 1),
        "op_notsent": integer(op.get("notsent_lowat"), max_notsent, 16384, max_notsent),
        "op_limit": integer(op.get("limit_output_bytes"), 1048576, 131072, 4194304),
        "ai_reason": reason,
    }
    if role == "vps":
        keys = ["vps_congestion", "vps_mtu_probing", "vps_slow_start", "vps_rmem_max", "vps_wmem_max", "vps_notsent", "vps_limit", "ai_reason"]
    elif role == "openwrt":
        keys = ["op_minimal", "op_mtu_probing", "op_slow_start", "op_notsent", "op_limit", "ai_reason"]
    else:
        keys = list(out.keys())
    for key in keys:
        print(f"{key}='{out[key]}'")
else:
    raise SystemExit("unknown mode")
PY
  python3 "$tmp_py" "$mode" "$@"
  rc="$?"
  rm -f "$tmp_py"
  return "$rc"
}

ai_select_model() {
  # shellcheck disable=SC2086
  ai_python_client select $AI_MODEL_CANDIDATES
}

ai_benchmark_models() {
  ai_require_env
  print_header "AI 模型测速"
  ui_subtitle "只发送短测试请求，不输出 API Key。"
  # shellcheck disable=SC2086
  ai_python_client benchmark $AI_MODEL_CANDIDATES
}

ai_measure_pair() {
  host="$1"
  port="$2"
  seconds="${3:-12}"
  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in *:*) bind_ip="" ;; esac

  ui_note "测速" "上传：本机 → 对端" >&2
  upload_json="$(run_iperf_client "$host" "$port" 0 "$seconds" "$bind_ip" || true)"
  [ -n "$upload_json" ] && printf '%s' "$upload_json" | grep -q '"end"' || die "上传测速失败。"
  if printf '%s' "$upload_json" | grep -q '"error"'; then
    die "上传测速失败：$(printf '%s' "$upload_json" | awk -F'"' '/"error"/ {print $4; exit}')"
  fi
  upload_bps="$(printf '%s\n' "$upload_json" | extract_bps)"
  upload_retr="$(printf '%s\n' "$upload_json" | extract_retransmits)"
  [ -n "$upload_bps" ] || die "上传测速失败：iperf3 未返回 bits_per_second。"
  upload_bps="${upload_bps:-0}"
  upload_retr="${upload_retr:-0}"

  ui_note "测速" "下载：对端 → 本机" >&2
  download_json="$(run_iperf_client "$host" "$port" 1 "$seconds" "$bind_ip" || true)"
  [ -n "$download_json" ] && printf '%s' "$download_json" | grep -q '"end"' || die "下载测速失败。"
  if printf '%s' "$download_json" | grep -q '"error"'; then
    die "下载测速失败：$(printf '%s' "$download_json" | awk -F'"' '/"error"/ {print $4; exit}')"
  fi
  download_bps="$(printf '%s\n' "$download_json" | extract_bps)"
  download_retr="$(printf '%s\n' "$download_json" | extract_retransmits)"
  [ -n "$download_bps" ] || die "下载测速失败：iperf3 未返回 bits_per_second。"
  download_bps="${download_bps:-0}"
  download_retr="${download_retr:-0}"

  cat <<EOF
{"upload_bits_per_second":$upload_bps,"upload_retransmits":$upload_retr,"download_bits_per_second":$download_bps,"download_retransmits":$download_retr}
EOF
}

metric_from_summary() {
  key="$1"
  awk -v key="\"$key\"" '
    {
      line = $0
      gsub(/[{}]/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        split(parts[i], kv, ":")
        gsub(/[" ]/, "", kv[1])
        gsub(/[" ]/, "", kv[2])
        if ("\"" kv[1] "\"" == key || kv[1] == substr(key, 2, length(key) - 2)) {
          print kv[2]
          exit
        }
      }
    }
  '
}

summary_regressed() {
  before="$1"
  after="$2"
  before_up="$(printf '%s\n' "$before" | metric_from_summary upload_bits_per_second)"
  after_up="$(printf '%s\n' "$after" | metric_from_summary upload_bits_per_second)"
  before_down="$(printf '%s\n' "$before" | metric_from_summary download_bits_per_second)"
  after_down="$(printf '%s\n' "$after" | metric_from_summary download_bits_per_second)"
  before_ur="$(printf '%s\n' "$before" | metric_from_summary upload_retransmits)"
  after_ur="$(printf '%s\n' "$after" | metric_from_summary upload_retransmits)"
  before_dr="$(printf '%s\n' "$before" | metric_from_summary download_retransmits)"
  after_dr="$(printf '%s\n' "$after" | metric_from_summary download_retransmits)"
  awk -v bu="${before_up:-0}" -v au="${after_up:-0}" -v bd="${before_down:-0}" -v ad="${after_down:-0}" \
      -v bur="${before_ur:-0}" -v aur="${after_ur:-0}" -v bdr="${before_dr:-0}" -v adr="${after_dr:-0}" '
    BEGIN {
      bad = 0
      if (bu > 0 && au < bu * 0.95) bad = 1
      if (bd > 0 && ad < bd * 0.95) bad = 1
      if (bur > 100 && aur > bur * 1.5) bad = 1
      if (bdr > 100 && adr > bdr * 1.5) bad = 1
      exit !bad
    }
  '
}

print_ai_summary_metrics() {
  title="$1"
  summary="$2"
  up="$(printf '%s\n' "$summary" | metric_from_summary upload_bits_per_second)"
  ur="$(printf '%s\n' "$summary" | metric_from_summary upload_retransmits)"
  down="$(printf '%s\n' "$summary" | metric_from_summary download_bits_per_second)"
  dr="$(printf '%s\n' "$summary" | metric_from_summary download_retransmits)"
  ui_section "$title"
  ui_row "上传速度" "$(format_rate "${up:-0}")"
  ui_row "上传重传" "$(format_count "${ur:-0}") 次"
  ui_row "下载速度" "$(format_rate "${down:-0}")"
  ui_row "下载重传" "$(format_count "${dr:-0}") 次"
}

print_ai_decision_summary() {
  role="$1"
  normalized="$2"
  # normalize 只输出白名单 key='value'，值已做枚举/数值边界校验。
  eval "$normalized"
  ui_section "AI 建议摘要"
  case "$role" in
    vps)
      metric_line "调整位置" "VPS 对端" "info"
      metric_line "拥塞控制" "${vps_congestion:-cubic}" "good"
      metric_line "发送低水位" "${vps_notsent:-未提供}" "warn"
      metric_line "输出限制" "${vps_limit:-未提供}" "warn"
      ;;
    openwrt)
      metric_line "调整位置" "本机 OpenWrt（最小修改）" "info"
      metric_line "发送低水位" "${op_notsent:-未提供}" "warn"
      metric_line "输出限制" "${op_limit:-未提供}" "warn"
      metric_line "系统范围" "不改防火墙 / DNS / 代理" "good"
      ;;
  esac
  metric_line "AI 理由" "${ai_reason:-未提供}" "info"
}

ai_decision_for_summary() {
  summary="$1"
  objective="$2"
  role="$3"
  model="$4"
  prompt_summary="$(cat <<EOF
{"objective":"$objective","role":"$role","os":"${OS_NAME:-unknown}","family":"${OS_FAMILY:-unknown}","metrics":$summary,"current":{"congestion":"$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)","qdisc":"$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)","rmem_max":$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0),"wmem_max":$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0),"notsent_lowat":$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 0),"limit_output_bytes":$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo 0)}}
EOF
)"
  printf '%s' "$prompt_summary" | ai_python_client decide "$model" "$objective" "$role"
}

apply_ai_decision() {
  role="$1"
  normalized="$2"
  # normalize 只输出白名单 key='value'，值已做枚举/数值边界校验。
  eval "$normalized"
  case "$role" in
    vps)
      apply_vps_adapt_values "$vps_congestion" "$vps_mtu_probing" "$vps_slow_start" "$vps_rmem_max" "$vps_wmem_max" "$vps_notsent" "$vps_limit"
      ;;
    openwrt)
      [ "${op_minimal:-1}" = "1" ] || die "OpenWrt 侧只允许 minimal 调整。"
      apply_openwrt_minimal_values "$op_mtu_probing" "$op_slow_start" "$op_notsent" "$op_limit"
      ;;
    *)
      die "未知 AI 执行角色：$role"
      ;;
  esac
}

ai_auto_mode() {
  host=""
  port="$IPERF_PORT"
  objective="startup"
  rounds="$TCP_TUNE_AI_MAX_ROUNDS"
  role="auto"
  seconds="12"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --peer|--host|--对端|--主机) host="$2"; shift 2 ;;
      --port|--iperf-port|--端口|--测速端口) port="$2"; shift 2 ;;
      --objective|--目标) objective="$2"; shift 2 ;;
      --rounds|--轮数) rounds="$2"; shift 2 ;;
      --role|--角色) role="$2"; shift 2 ;;
      --seconds|--时长) seconds="$2"; shift 2 ;;
      *) die "未知 AI自动优化 参数：$1" ;;
    esac
  done
  [ -n "$host" ] || die "AI自动优化 需要 --对端"
  # 兼容旧版本的 balanced；新语义统一为“快速起速”。
  [ "$objective" = "balanced" ] && objective="startup"
  case "$objective" in startup|throughput|retrans) ;; *) die "--objective 只支持 startup、throughput、retrans" ;; esac
  validate_positive_int_range "$rounds" 1 "$TCP_TUNE_AI_MAX_ROUNDS" || die "--rounds 必须在 1 和 $TCP_TUNE_AI_MAX_ROUNDS 之间。"
  validate_positive_int_range "$seconds" 5 60 || die "--seconds 必须在 5 和 60 之间。"

  need_root
  ai_require_env
  install_runtime_deps
  detect_os
  if [ "$role" = "auto" ]; then
    if [ "$OS_FAMILY" = "openwrt" ]; then role="openwrt"; else role="vps"; fi
  fi
  case "$role" in vps|openwrt) ;; *) die "--role 只支持 auto、vps、openwrt" ;; esac

  clear_screen
  print_header "AI 自动调参"
  ui_row "角色" "$role"
  ui_row "对端" "$host"
  ui_row "目标" "$objective"
  ui_row "轮数" "$rounds"
  ui_note "安全边界" "AI 不能执行任意命令，只能触发脚本内置白名单动作。"

  model="$(ai_select_model)" || die "没有可用 AI 模型。"
  ui_row "模型" "$model"

  round=1
  previous_summary=""
  while [ "$round" -le "$rounds" ]; do
    echo
    ui_section "第 $round/$rounds 轮基线"
    summary="$(ai_measure_pair "$host" "$port" "$seconds")"
    print_ai_summary_metrics "测速摘要" "$summary"
    decision="$(ai_decision_for_summary "$summary" "$objective" "$role" "$model")" || die "AI 决策请求失败。"
    normalized_decision="$(printf '%s' "$decision" | ai_python_client normalize "$role")" || die "AI 决策解析失败。"
    print_ai_decision_summary "$role" "$normalized_decision"
    previous_summary="$summary"
    previous_backup="$LAST_MANUAL_BACKUP"
    apply_ai_decision "$role" "$normalized_decision"
    current_backup="$LAST_MANUAL_BACKUP"

    echo
    ui_section "复测"
    after_summary="$(ai_measure_pair "$host" "$port" "$seconds")"
    print_ai_summary_metrics "复测摘要" "$after_summary"
    if summary_regressed "$previous_summary" "$after_summary"; then
      warn "复测指标退化超过阈值，正在回滚本轮 AI 调整。"
      restore_manual_backup "$current_backup"
      break
    fi
    ui_note "结果" "本轮调整通过复测，继续下一轮或结束。"
    round=$((round + 1))
  done
  echo
  ui_section "完成"
  ui_row "最终角色" "$role"
  ui_row "模型" "$model"
  ui_note "回滚" "如需撤销最近保留的手动适配，可使用备份目录中的 before 文件恢复。"
}

ai_diagnose_mode() {
  summary_file=""
  objective="startup"
  role="vps"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary|--摘要) summary_file="$2"; shift 2 ;;
      --objective|--目标) objective="$2"; shift 2 ;;
      --role|--角色) role="$2"; shift 2 ;;
      *) die "未知 AI诊断 参数：$1" ;;
    esac
  done
  [ -n "$summary_file" ] || die "AI诊断 需要 --摘要 FILE"
  [ -f "$summary_file" ] || die "summary 文件不存在：$summary_file"
  ai_require_env
  detect_os
  model="$(ai_select_model)" || die "没有可用 AI 模型。"
  summary="$(cat "$summary_file")"
  ai_decision_for_summary "$summary" "$objective" "$role" "$model"
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
    echo "  - 当前内存低于 256MiB，不建议直接使用“远距穿透”或“超远距极限”预设。"
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
  if [ "${OS_FAMILY:-}" = "openwrt" ] || [ -f /etc/openwrt_release ]; then
    found_lan_ip=""
    if have_cmd ip; then
      found_lan_ip="$(for dev in br-lan lan eth0 eth1; do ip -4 addr show dev "$dev" 2>/dev/null; done | awk '/inet / {split($2,a,"/"); if (a[1] !~ /^127[.]/ && a[1] !~ /^169[.]254[.]/) {print a[1]; exit}}')"
    fi
    if [ -n "$found_lan_ip" ]; then
      echo "$found_lan_ip"
      return 0
    fi
  fi
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
  printf "  %s%s连接测试%s → %s分析结果%s → %s应用调整%s → %s复测确认%s\n" \
    "$COLOR_BOLD" "$COLOR_GREEN" "$COLOR_RESET" \
    "$COLOR_CYAN" "$COLOR_RESET" \
    "$COLOR_CYAN" "$COLOR_RESET" \
    "$COLOR_DIM" "$COLOR_RESET"
  printf "  %s轮次 %s/%s%s\n" "$COLOR_DIM" "$round" "$rounds" "$COLOR_RESET"
}

start_iperf_server() {
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法启动测试服务。"
  port="$1"
  if pgrep -f "iperf3.*-s.*-p[[:space:]]+$port" >/dev/null 2>&1; then
    info "检测到端口 $port 已有 iperf3 server，将复用且不会由本工具停止。"
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
    info "未找到本工具记录的 iperf3 pid，未停止端口 $port 上的其他进程。"
  fi
}

run_iperf_client() {
  host="$1"
  port="$2"
  reverse="$3"
  seconds="$4"
  bind_ip="${5:-}"
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法测试。"
  # host 是 IPv6 地址（含冒号）时不能用 IPv4 源地址绑定，否则 iperf3 报 Invalid argument
  case "$host" in
    *:*)
      bind_ip=""
      ;;
  esac
  # -O 3: 3秒预热不纳入统计，减少连接建立阶段的波动
  if [ "$reverse" = "1" ]; then
    if [ -n "$bind_ip" ]; then
      iperf3 -c "$host" -p "$port" -B "$bind_ip" -R -t "$seconds" -O 3 -J
    else
      iperf3 -c "$host" -p "$port" -R -t "$seconds" -O 3 -J
    fi
  else
    if [ -n "$bind_ip" ]; then
      iperf3 -c "$host" -p "$port" -B "$bind_ip" -t "$seconds" -O 3 -J
    else
      iperf3 -c "$host" -p "$port" -t "$seconds" -O 3 -J
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

extract_first_interval_bps() {
  awk '
    /"intervals"/ { in_intervals=1; next }
    in_intervals && /"sum"[[:space:]]*:/ { in_sum=1; next }
    in_sum && /"bits_per_second"/ {
      gsub(/[,]/, "", $0)
      for (i = 1; i <= NF; i++) {
        if ($i ~ /"bits_per_second"/) {
          gsub(/[^0-9.]/, "", $(i + 1))
          print $(i + 1)
          exit
        }
      }
    }
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

  cap="$(memory_cap_bytes "$memory_mb_value" "$aggressive")"
  bdp_bytes="$(awk -v bw="$peer_mbps" -v rtt="$rtt_ms" 'BEGIN {b=bw*1024*1024/8*rtt/1000; if(b<32768) b=32768; printf "%d", b}')"

  cur_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 4194304)"
  cur_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 4194304)"
  cur_notsent="$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 131072)"
  cur_adv="$(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null || echo 2)"
  is_unsigned_integer "$cur_rmem" || cur_rmem=4194304
  is_unsigned_integer "$cur_wmem" || cur_wmem=4194304
  is_unsigned_integer "$cur_notsent" || cur_notsent=131072
  is_integer "$cur_adv" || cur_adv=2

  values="$(recommend_values "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive")"
  case "$values" in
    ERR*) die "$values" ;;
  esac
  # shellcheck disable=SC2086
  set -- $values
  rmem="$1"; wmem="$2"; adv="$3"; notsent="$4"
  backlog="$5"; somaxconn="$6"; synbacklog="$7"; optmem="$8"
  is_unsigned_integer "$backlog" || backlog=16384
  is_unsigned_integer "$somaxconn" || somaxconn=8192
  is_unsigned_integer "$synbacklog" || synbacklog=32768
  is_unsigned_integer "$optmem" || optmem=81920

  rmem="$cur_rmem"
  wmem="$cur_wmem"
  notsent="$cur_notsent"
  adv="$cur_adv"

  min_rmem=$((bdp_bytes / 2))
  min_wmem=$((bdp_bytes / 4))
  [ "$min_rmem" -lt 65536 ] && min_rmem=65536
  [ "$min_wmem" -lt 65536 ] && min_wmem=65536

  case "$objective" in
    retrans)
      if [ "$retr" -gt "$target_retr" ]; then
        notsent="$(awk -v n="$notsent" 'BEGIN {v=int(n*0.80); if(v<16384) v=16384; printf "%d", v}')"
        if [ "$retr" -gt 2000 ]; then
          rmem="$(awk -v r="$rmem" 'BEGIN {v=int(r*0.95); if(v<65536) v=65536; printf "%d", v}')"
          wmem="$(awk -v w="$wmem" 'BEGIN {v=int(w*0.95); if(v<65536) v=65536; printf "%d", v}')"
        fi
      fi
      ;;
    throughput)
      if [ "$bps" != "0" ]; then
        rmem="$(awk -v r="$rmem" -v b="$bdp_bytes" 'BEGIN {v=int(r*1.35); if(v<b*4) v=int(b*4); printf "%d", v}')"
        wmem="$(awk -v w="$wmem" -v b="$bdp_bytes" 'BEGIN {v=int(w*1.35); if(v<b*4) v=int(b*4); printf "%d", v}')"
        notsent="$(awk -v n="$notsent" 'BEGIN {v=int(n*1.25); if(v>262144) v=262144; printf "%d", v}')"
        if [ "$adv" -gt 1 ]; then
          adv="$(awk -v a="$adv" 'BEGIN {v=a-1; if(v<1) v=1; printf "%d", v}')"
        fi
      fi
      ;;
    startup)
      notsent="$(awk -v n="$notsent" 'BEGIN {v=int(n*1.15); if(v>131072) v=131072; printf "%d", v}')"
      wmem="$(awk -v w="$wmem" 'BEGIN {v=int(w*1.15); if(v<65536) v=65536; printf "%d", v}')"
      rmem="$(awk -v r="$rmem" 'BEGIN {v=int(r*1.1); if(v<65536) v=65536; printf "%d", v}')"
      adv="$(awk -v a="$adv" 'BEGIN {v=a+1; if(v>5) v=5; printf "%d", v}')"
      ;;
  esac

  [ "$rmem" -lt "$min_rmem" ] && rmem="$min_rmem"
  [ "$wmem" -lt "$min_wmem" ] && wmem="$min_wmem"
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
  [ "$#" -ge 10 ] && eval "memory_mb_value=\${10:-}"
  [ "$#" -ge 11 ] && eval "ramp_rate=\${11:-0.79}"
  [ "$#" -ge 12 ] && eval "aggressive=\${12:-0}"
  [ "$#" -ge 13 ] && eval "allow_same_public=\${13:-0}"

  need_root
  install_runtime_deps
  [ -n "$memory_mb_value" ] || memory_mb_value="$(memory_mb)"
  local_public_ip="$(public_ip || true)"
  if [ "$allow_same_public" != "1" ] && [ -n "$local_public_ip" ] && [ "$host" = "$local_public_ip" ]; then
    warn "对端地址 $host 与本机公网出口 $local_public_ip 相同，可能是代理出口/NAT hairpin；已按真实链路继续测试。"
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
  echo
  ui_note "说明" "测速使用本机局域网地址作为源地址，远端连接地址不会显示在界面中。"

  i=1
  previous_retr=""
  previous_bps=""
  previous_startup_bps=""
  first_retr=""
  first_bps=""
  first_startup_bps=""
  final_retr="0"
  final_bps="0"
  final_startup_bps="0"
  best_bps="0"
  applied_change_count="0"
  rolled_back_regression="0"
  completed_rounds="0"
  while [ "$i" -le "$rounds" ]; do
    echo
    ui_section "第 $i/$rounds 轮测试"
    progress_steps "$i" "$rounds"
    ui_note "状态" "正在用 iperf3 测试真实链路..."
    json="$(run_iperf_client "$host" "$port" "$reverse" 20 "$bind_ip" || true)"
    [ -n "$json" ] || die "iperf3 测试失败：未获得输出，请检查对端 iperf3 是否运行、端口是否可达。"
    if ! printf '%s' "$json" | grep -q '"end"'; then
      die "iperf3 测试失败：未获得有效结果。"
    fi
    retr="$(printf '%s\n' "$json" | extract_retransmits)"
    bps="$(printf '%s\n' "$json" | extract_bps)"
    startup_bps="$(printf '%s\n' "$json" | extract_first_interval_bps)"
    retr="${retr:-0}"
    bps="${bps:-0}"
    startup_bps="${startup_bps:-0}"
    if [ "$bps" = "0" ] && [ "$i" = "1" ]; then
      die "iperf3 返回 0 速率，测速可能失败。请检查网络连通性。"
    fi
    final_retr="$retr"
    final_bps="$bps"
    final_startup_bps="$startup_bps"
    completed_rounds="$i"
    [ -n "$first_retr" ] || first_retr="$retr"
    [ -n "$first_bps" ] || first_bps="$bps"
    [ -n "$first_startup_bps" ] || first_startup_bps="$startup_bps"
    if awk -v current="$bps" -v best="$best_bps" 'BEGIN { exit !(current > best) }'; then
      best_bps="$bps"
    fi
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
    if [ "$objective" = "startup" ]; then
      metric_line "首秒速度" "$(format_rate "$startup_bps")" "warn"
    fi
    if [ -n "${TUNE_REPORT_PEER:-}" ] && [ -n "${TUNE_REPORT_TOKEN:-}" ]; then
      report_direction="download"
      [ "$reverse" = "0" ] && report_direction="upload"
      report_data="{\"role\":\"client-result\",\"lan_ip\":\"${TUNE_CLIENT_IP:-$display_local_ip}\",\"round\":$i,\"rounds\":$rounds,\"objective\":\"$objective\",\"direction\":\"$report_direction\",\"retransmits\":$retr,\"bits_per_second\":$bps,\"first_second_bits_per_second\":$startup_bps,\"time\":$(date +%s)}"
      post_json "$TUNE_REPORT_PEER/report" "$TUNE_REPORT_TOKEN" "$report_data" >/dev/null 2>&1 || true
    fi

    regressed="0"
    if [ "$applied_change_count" -gt 0 ] && [ -n "$previous_retr" ]; then
      case "$objective" in
        retrans)
          if awk -v current="$retr" -v previous="$previous_retr" 'BEGIN { exit !(previous > 0 && current > previous * 1.50) }'; then
            regressed="1"
          fi
          ;;
        throughput)
          if awk -v current="$bps" -v previous="$previous_bps" 'BEGIN { exit !(previous > 0 && current < previous * 0.80) }'; then
            regressed="1"
          fi
          ;;
        startup)
          if awk -v current="$startup_bps" -v previous="$previous_startup_bps" 'BEGIN { exit !(previous > 0 && current < previous * 0.75) }'; then
            regressed="1"
          fi
          if awk -v current="$retr" -v previous="$previous_retr" 'BEGIN { exit !(previous > 100 && current > previous * 3.0 && current > 500) }'; then
            regressed="1"
          fi
          ;;
      esac
    fi
    if [ "$regressed" = "1" ]; then
      consecutive_regression="${consecutive_regression:-0}"
      consecutive_regression=$((consecutive_regression + 1))
      if [ "$consecutive_regression" -ge 2 ]; then
        warn "连续 2 轮退化，正在回滚最新参数调整。"
        rollback_last
        applied_change_count=$((applied_change_count - 1))
        rolled_back_regression="1"
        final_retr="$previous_retr"
        final_bps="$previous_bps"
        final_startup_bps="$previous_startup_bps"
        break
      else
        warn "本轮表现波动，暂不回滚，下一轮继续观察。"
      fi
    else
      consecutive_regression="0"
    fi

    measured_mbps="$(awk -v bps="$bps" 'BEGIN {v=bps/1000000; if (v < 1) v=1; printf "%d\n", v}')"
    [ "$peer_mbps" = "0" ] && peer_mbps="$measured_mbps"
    [ "$local_mbps" = "0" ] && local_mbps="$peer_mbps"

    if [ "$objective" = "retrans" ] && [ "$bps" != "0" ]; then
      retrans_target_met="0"
      if [ "$retr" -le "$target_retr" ]; then
        retrans_target_met="1"
      fi
      if [ -n "$first_retr" ] && [ "$first_retr" -gt 0 ]; then
        if awk -v r="$retr" -v fir="$first_retr" 'BEGIN { exit !(r < fir * 0.50 && r < 500) }'; then
          retrans_target_met="1"
        fi
      fi
      if [ "$retrans_target_met" = "1" ]; then
        if [ "$i" -gt 1 ] || [ "$applied_change_count" -gt 0 ]; then
          echo
          ui_note "结果" "目标已达成，进入结果页。"
          break
        fi
      fi
    fi
    if [ "$i" -ge "$rounds" ]; then
      echo
      ui_note "结果" "已达到最大轮数，保留最后一次已验证参数。"
      break
    fi

    # shellcheck disable=SC2086
    set -- $(tune_step "$objective" "$retr" "$bps" "$target_retr" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive")
    apply_buffers "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    applied_change_count=$((applied_change_count + 1))
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
        if (retr <= target) v = r * 1.15
        else v = r * 0.90
        if (v > 1.20) v = 1.20
        if (v < 0.45) v = 0.45
        printf "%.3f\n", v
      }')"
    fi
    previous_retr="$retr"
    previous_bps="$bps"
    previous_startup_bps="$startup_bps"
    i=$((i + 1))
  done
  [ "$completed_rounds" = "0" ] && completed_rounds="$rounds"
  clear_screen
  print_header "优化完成"
  ui_subtitle "$mode_name · $transfer_name · 共测试 $completed_rounds 轮"
  echo
  ui_section "结论"
  final_rate="$(format_rate "$final_bps")"
  final_retr_text="$(format_count "$final_retr")"
  first_rate="$(format_rate "${first_bps:-0}")"
  first_startup_rate="$(format_rate "${first_startup_bps:-0}")"
  final_startup_rate="$(format_rate "$final_startup_bps")"
  best_rate="$(format_rate "$best_bps")"
  first_retr_text="$(format_count "${first_retr:-0}")"
  speed_delta="$(percent_delta "${first_bps:-0}" "$final_bps")"
  retr_delta="$(percent_delta "${first_retr:-0}" "$final_retr")"
  case "$objective" in
    throughput)
      ui_row "结论" "吞吐测试完成，最高速度 $best_rate，末轮重传 $final_retr_text 次。"
      ;;
    startup)
      ui_row "结论" "起速测试完成，末轮首秒速度 $final_startup_rate。"
      ;;
    *)
      retr_significantly_reduced="0"
      if [ -n "${first_retr:-}" ] && [ "${first_retr:-0}" -gt 0 ]; then
        if awk -v r="$final_retr" -v fir="$first_retr" 'BEGIN { exit !(r < fir * 0.50) }'; then
          retr_significantly_reduced="1"
        fi
      fi
      if [ "$final_retr" -le "$target_retr" ] || [ "$retr_significantly_reduced" = "1" ]; then
        ui_row "结论" "重传已显著改善，保持当前配置。"
      else
        warn "已完成 $rounds 轮，重传尚未降至目标值。"
        ui_row "结论" "重传尚未达到目标，建议检查链路质量后再试。"
      fi
      ;;
  esac
  echo
  ui_section "优化前后"
  printf "  %s%s │ %-14s │ %-14s │ %-10s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$(ui_pad "指标" 12)" "优化前" "优化后" "变化" "$COLOR_RESET"
  printf "  %s─────────────┼────────────────┼────────────────┼──────────%s\n" "$COLOR_DIM" "$COLOR_RESET"
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "传输速度" 12)" "$first_rate" "$final_rate" "$speed_delta"
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "重传次数" 12)" "$first_retr_text" "$final_retr_text" "$retr_delta"
  if [ "$objective" = "startup" ]; then
    startup_delta="$(percent_delta "${first_startup_bps:-0}" "$final_startup_bps")"
    printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "首秒速度" 12)" "$first_startup_rate" "$final_startup_rate" "$startup_delta"
  fi
  echo
  ui_section "配置摘要"
  if [ "$rolled_back_regression" = "1" ] && [ "$applied_change_count" -eq 0 ]; then
    ui_note "已回退" "最新调整表现退化，已恢复优化前配置。"
    ui_note "回滚" "没有保留本次参数修改。"
  elif [ "$rolled_back_regression" = "1" ]; then
    ui_note "已回退" "已撤销最新退化调整，保留前一轮更优配置。"
    ui_note "回滚" "保留的调整仍可通过 rollback 命令恢复。"
  elif [ "$applied_change_count" -gt 0 ]; then
    ui_note "已保存" "仅保留经过下一轮复测的参数调整。"
    ui_note "回滚" "已创建备份，可在客户端菜单或 rollback 命令中恢复。"
  else
    ui_note "未修改" "本次只完成基线测试，没有保存未经复测的参数。"
    ui_note "回滚" "本轮未创建新的参数修改。"
  fi
  echo
  ui_section "下一步操作"
  ui_menu_item "1" "返回客户端主页" "回到操作菜单"
  ui_menu_item "2" "换一种模式继续" "重新选择优化目标"
  ui_menu_item "3" "查看详细参数" "检查当前 TCP 配置"
  ui_menu_item "4" "回滚本次修改" "恢复优化前的系统参数" "$COLOR_YELLOW"
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
import socket
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

class DualStackThreadingHTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()

if __name__ == "__main__":
    port = int(os.environ.get("TCP_TUNE_AGENT_PORT", "39188"))
    try:
        DualStackThreadingHTTPServer(("::", port), Handler).serve_forever()
    except OSError:
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
    echo "[dry-run] 将启动临时 HTTP Agent：[::]:$AGENT_PORT（失败时回退 0.0.0.0）"
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
    info "已停止本工具记录的临时进程。"
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

print("  ▎ 已接入客户端")
if not devices:
    print("  暂无客户端，等待连接...")
else:
    for device in sorted(devices.values(), key=lambda item: item["last"], reverse=True):
        seen = time.strftime("%H:%M:%S", time.localtime(device["last"]))
        print(f"  ● {device['os']} · {device['ip']}  最近上报 {seen}")

print()
print("  ▎ 最近结果")
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
    print(f"  模式  {objective}")
    print(f"  方向  {direction}")
    print(f"  轮次  {round_no}/{rounds}")
    print(f"  速度  {rate}")
    print(f"  重传  {retransmits:,} 次")

print()
print("  ▎ 最近事件")
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
  echo
  ui_note "提示" "代理/公网地址仅用于脚本通讯，界面和测试源地址优先使用本机局域网 IP。"
}

print_client_commands() {
  peer_url="$1"
  token="$2"
  display_token="$token"
  case "$display_token" in
    \<*\>) ;;
    *)
      if [ ! -t 1 ]; then
        display_token="<会话令牌已隐藏>"
      fi
      ;;
  esac
  ui_section "客户端连接命令"
  printf "%sOpenWrt / Linux / macOS%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  curl -fsSL $RAW_BASE_URL/tcp-tune.sh | sh -s -- --yes client --peer $peer_url --token $display_token --iperf-port $IPERF_PORT"
  echo
  printf "%s已有脚本本地运行%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  sh tcp-tune.sh --yes client --peer $peer_url --token $display_token --iperf-port $IPERF_PORT"
  echo
  printf "%sWindows PowerShell%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  echo "  iwr -UseBasicParsing $RAW_BASE_URL/tcp-tune.ps1 -OutFile tcp-tune.ps1"
  printf '  .\\tcp-tune.ps1 client -Peer %s -Token %s -IperfPort %s -Direction download -Yes\n' "$peer_url" "$display_token" "$IPERF_PORT"
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

  peer_no_scheme="$(printf '%s\n' "$peer" | sed 's#^http://##; s#^https://##')"
  case "$peer_no_scheme" in
    \[*\]*)
      host="$(printf '%s\n' "$peer_no_scheme" | sed 's#^\[\([^]]*\)\].*#\1#')"
      ;;
    *)
      host="$(printf '%s\n' "$peer_no_scheme" | sed 's#:.*##; s#/.*##')"
      ;;
  esac
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
  ui_menu_item "1" "下载" "服务端 → 本机"
  ui_menu_item "2" "上传" "本机 → 服务端"
  echo
  ui_note "当前选择" "$selected_label · 默认下载方向"
  ui_note "AI 说明" "此菜单使用确定性自动调参；AI 只在 AI自动优化 / AI测速 / AI诊断 命令中介入。"
  if ! prompt_read "请选择测试方向 [1-2]："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) reverse="0" ;;
    *) reverse="1" ;;
  esac

  auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" 0 0 100 "" 0.79 0 "$allow_same_public"
}

run_client_ai_optimization() {
  host="$1"
  iperf_port="$2"
  clear_screen
  print_header "AI 智能调参"
  ui_subtitle "先真实测速，再让 AI 给出白名单内的参数调整，写入后会自动复测。"
  echo
  ui_section "AI 调参目标"
  ui_mode_card "1" "快速起速" "适合网页、短连接、小文件。" "缩短连接初期提速时间"
  ui_mode_card "2" "吞吐优先" "适合下载、备份、大文件。" "优先提高稳定传输速度"
  ui_mode_card "3" "重传优先" "适合游戏、语音、远程桌面。" "优先压低重传"
  echo
  if ! prompt_read "请选择 AI 调参目标 [1-3]："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) objective="throughput" ;;
    3) objective="retrans" ;;
    *) objective="startup" ;;
  esac

  echo
  ui_section "测试轮数"
  ui_note "建议" "OpenWrt 建议先用 2 轮，确认稳定后再增加轮数。"
  if ! prompt_read "请输入 AI 调参轮数 [1-${TCP_TUNE_AI_MAX_ROUNDS}]，默认 2："; then return 1; fi
  rounds="$PROMPT_REPLY"
  [ -n "$rounds" ] || rounds="2"
  validate_positive_int_range "$rounds" 1 "$TCP_TUNE_AI_MAX_ROUNDS" || {
    warn "轮数无效，已使用默认 2。"
    rounds="2"
  }

  echo
  ui_section "安全说明"
  ui_note "执行范围" "AI 只能返回结构化建议，脚本只执行内置白名单参数。"
  ui_note "OpenWrt" "本机只做最小必要调整，不修改防火墙、DNS、代理或网络服务。"
  ui_note "依赖" "OpenWrt 不需要 python3；没有 python3 时会自动使用 curl 调用 AI 网关。"
  echo
  if ! prompt_read "按回车开始 AI 智能调参，输入 n 取消："; then return 1; fi
  case "$PROMPT_REPLY" in
    n|N) return 0 ;;
  esac

  # 这里复用命令行 AI 自动优化入口，避免面板和命令行维护两套调参逻辑。
  ai_auto_mode --对端 "$host" --端口 "$iperf_port" --目标 "$objective" --轮数 "$rounds" --角色 auto
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
    ui_section "操作菜单"
    ui_menu_group "优化"
    ui_menu_item "1" "开始优化" "确定性调参：重传 / 吞吐 / 快速起速" "$COLOR_GREEN"
    ui_menu_item "2" "AI 智能调参" "AI 辅助：快速起速 / 吞吐 / 重传" "$COLOR_CYAN"
    echo
    ui_menu_group "状态"
    ui_menu_item "3" "查看本机状态" "系统 / TCP 参数"
    ui_menu_item "4" "查看服务端状态" "会话 / 测速服务"
    ui_menu_item "5" "查看过程记录" "任务 / 结果"
    echo
    ui_menu_group "退出"
    ui_menu_item "6" "停止会话并退出" "清理 Agent / iperf3" "$COLOR_YELLOW"
    ui_menu_item "0" "退出客户端" "不停止服务端会话" "$COLOR_DIM"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入，客户端已保持连接上报后退出菜单。"
      return 0
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1) run_client_optimization "$host" "$iperf_port" "$allow_same_public"; pause_for_enter ;;
      2) run_client_ai_optimization "$host" "$iperf_port"; pause_for_enter ;;
      3) clear_screen; print_header "本机状态"; status_full; pause_for_enter ;;
      4) clear_screen; print_header "服务端状态"; get_agent_json "$peer/status" "$token" || warn "读取服务端状态失败。"; pause_for_enter ;;
      5) clear_screen; print_header "过程记录"; get_agent_json "$peer/events" "$token" || warn "读取服务端事件失败。"; pause_for_enter ;;
      6) post_json "$peer/stop" "$token" "{}" || true; exit 0 ;;
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
    echo
    ui_menu_group "会话"
    ui_menu_item "1" "启动调优会话" "作为服务端，等待客户端连接" "$COLOR_GREEN"
    ui_menu_item "2" "加入调优会话" "作为客户端，连接已有服务端"
    echo
    ui_menu_group "调优"
    ui_menu_item "3" "自动优化" "选择目标，自动测速迭代调参"
    ui_menu_item "4" "查看状态" "双方 / 本机 TCP 参数"
    ui_menu_item "5" "智能推荐参数" "根据带宽、RTT、内存生成建议"
    ui_menu_item "6" "选择固定预设" "从预设配置列表中选择"
    echo
    ui_menu_group "管理"
    ui_menu_item "7" "回滚最近修改" "恢复优化前的系统参数" "$COLOR_YELLOW"
    ui_menu_item "0" "退出" "关闭脚本" "$COLOR_DIM"
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
  sh tcp-tune.sh apply-profile 近距极速
  sh tcp-tune.sh apply-buffers RMEM_MAX WMEM_MAX
  sh tcp-tune.sh auto --host IP --direction download --objective retrans --target-retr 0 --rtt-ms 100
  sh tcp-tune.sh AI测速
  sh tcp-tune.sh AI自动优化 --对端 IPV6 --目标 startup --轮数 5
  sh tcp-tune.sh AI诊断 --摘要 SUMMARY.json
  sh tcp-tune.sh local-minimal --ipv6-peer IPV6
  sh tcp-tune.sh vps-adapt --peer-ipv6 IPV6 --profile cubic-safe
  sh tcp-tune.sh rollback
  sh tcp-tune.sh stop-agent

全局选项：
  --yes    允许自动安装缺失依赖
  --dry-run    只展示将执行的动作，不写入系统

AI 环境变量：
  NVIDIA_API_KEY    必填，只从环境变量读取，不写入仓库或日志
  NVIDIA_BASE_URL   默认 https://integrate.api.nvidia.com/v1
  NVIDIA_MODEL      默认 auto，会在候选模型中选择最快可用项
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
    # 中文 AI 命令是面向普通用户的主入口；英文命令保留给旧文档和自动化脚本。
    AI测速|ai-benchmark-models)
      ai_benchmark_models
      ;;
    AI诊断|ai-diagnose)
      ai_diagnose_mode "$@"
      ;;
    AI自动优化|ai-auto)
      ai_auto_mode "$@"
      ;;
    local-minimal)
      ipv6_peer=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --ipv6-peer|--peer) ipv6_peer="$2"; shift 2 ;;
          *) die "未知 local-minimal 参数：$1" ;;
        esac
      done
      [ -n "$ipv6_peer" ] || warn "未提供 --ipv6-peer，将仅应用本机最小修正。"
      apply_openwrt_minimal_values 1 0 "$(ai_max_notsent)" 1048576
      ;;
    vps-adapt)
      profile="cubic-safe"
      peer_ipv6=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --peer-ipv6|--peer) peer_ipv6="$2"; shift 2 ;;
          --profile) profile="$2"; shift 2 ;;
          *) die "未知 vps-adapt 参数：$1" ;;
        esac
      done
      [ -n "$peer_ipv6" ] || warn "未提供 --peer-ipv6，将仅应用 VPS 适配预设。"
      vps_adapt_profile "$profile"
      ;;
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
