# Module: src/platform/openwrt.sh
ensure_openwrt_tcp_accel_deps() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ "${OS_FAMILY:-}" = "openwrt" ] || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  have_cmd opkg || return 0
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  case " $available " in
    *" bbr "*) return 0 ;;
  esac
  opkg update >/dev/null 2>&1 || true
  opkg install kmod-tcp-bbr >/dev/null 2>&1 || true
  if have_cmd modprobe; then modprobe tcp_bbr >/dev/null 2>&1 || true; fi
}

openwrt_key_allowed() {
  case "$1" in
    net.ipv4.tcp_mtu_probing|net.ipv4.tcp_slow_start_after_idle|net.ipv4.tcp_notsent_lowat|net.ipv4.tcp_limit_output_bytes|net.ipv4.tcp_congestion_control|net.core.default_qdisc) return 0 ;;
    *) return 1 ;;
  esac
}

apply_openwrt_minimal_values() {
  mtu_probing="$1"
  slow_start="$2"
  notsent_lowat="$3"
  limit_output="$4"

  need_root
  validate_bool_number "$mtu_probing" || die "非法 tcp_mtu_probing：$mtu_probing"
  validate_bool_number "$slow_start" || die "非法 tcp_slow_start_after_idle：$slow_start"
  validate_positive_int_range "$notsent_lowat" 16384 "$(max_notsent_lowat)" || die "非法 tcp_notsent_lowat：$notsent_lowat"
  validate_positive_int_range "$limit_output" 131072 4194304 || die "非法 tcp_limit_output_bytes：$limit_output"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] OpenWrt 将最小写入：mtu=$mtu_probing slow_start=$slow_start notsent=$notsent_lowat limit=$limit_output"
    return 0
  fi

  backup_dir="$(manual_backup_begin "ipv6-openwrt")"
  candidate="$backup_dir/openwrt-minimal.candidate"
  cat > "$candidate" <<EOF
# TCP-optimization: minimal local overrides for verified IPv6 peer paths.
# This file does not touch firewall, WAN, DNS, DHCP or proxy services.
net.ipv4.tcp_mtu_probing = $mtu_probing
net.ipv4.tcp_slow_start_after_idle = $slow_start
net.ipv4.tcp_notsent_lowat = $notsent_lowat
net.ipv4.tcp_limit_output_bytes = $limit_output
EOF
  if ! apply_sysctl_transaction "$OPENWRT_MINIMAL_FILE" "$candidate" "$backup_dir" openwrt-minimal-target; then
    restore_manual_backup "$backup_dir" >/dev/null 2>&1 || true
    DIE_EXIT_CODE="$EXIT_APPLY" die "OpenWrt 最小参数事务加载或验证失败，已回滚；备份目录：$backup_dir"
  fi
  info "OpenWrt 最小参数已保存并加载：$OPENWRT_MINIMAL_FILE"
  info "备份目录：$backup_dir"
}
