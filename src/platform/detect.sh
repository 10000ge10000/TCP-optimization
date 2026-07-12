# Module: src/platform/detect.sh
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

platform_is_read_only() {
  detect_os
  [ "$OS_FAMILY" = "macos" ]
}

install_pkg() {
  pkg="$1"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] 将通过 $PKG_MANAGER 安装 $pkg"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      if [ "$pkg" = "iperf3" ] && have_cmd debconf-set-selections; then
        printf '%s\n' "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
      fi
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1 \
        apt-get install -y \
          -o Dpkg::Options::=--force-confdef \
          -o Dpkg::Options::=--force-confold \
          "$pkg"
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
      ensure_openwrt_tcp_accel_deps
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
