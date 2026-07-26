# Module: src/platform/linux.sh
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

preferred_congestion_control() {
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  case " $available " in
    *" bbr "*) ;;
    *) ;;
  esac
  case " $available " in
    *" bbr "*) echo "bbr"; return 0 ;;
  esac
  case "$current" in
    bbr|cubic|reno) echo "$current"; return 0 ;;
  esac
  case " $available " in
    *" cubic "*) echo "cubic"; return 0 ;;
    *" reno "*) echo "reno"; return 0 ;;
  esac
  echo ""
}

ensure_tcp_baseline() {
  # 基础拥塞控制和 qdisc 必须与其他参数一起进入事务，不能在基线测速前单独写入。
  return 0
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
  validate_positive_int_range "$notsent_lowat" 16384 "$(max_notsent_lowat)" || die "非法 tcp_notsent_lowat：$notsent_lowat"
  validate_positive_int_range "$limit_output" 131072 4194304 || die "非法 tcp_limit_output_bytes：$limit_output"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] VPS 将写入：cc=$congestion mtu=$mtu_probing slow_start=$slow_start rmem=$rmem_max wmem=$wmem_max notsent=$notsent_lowat limit=$limit_output"
    return 0
  fi

  backup_dir="$(manual_backup_begin "ipv6-vps")"
  candidate="$backup_dir/vps-adapt.candidate"
  cat > "$candidate" <<EOF
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
  if ! apply_sysctl_transaction "$VPS_ADAPT_FILE" "$candidate" "$backup_dir" vps-adapt-target; then
    restore_manual_backup "$backup_dir" >/dev/null 2>&1 || true
    DIE_EXIT_CODE="$EXIT_APPLY" die "VPS 适配事务加载或验证失败，已回滚；备份目录：$backup_dir"
  fi
  info "VPS 适配参数已保存并加载：$VPS_ADAPT_FILE"
  info "备份目录：$backup_dir"
}

vps_adapt_profile() {
  profile="$1"
  case "$profile" in
    cubic-safe|balanced)
      apply_vps_adapt_values cubic 1 0 67108864 67108864 "$(max_notsent_lowat)" 1048576
      ;;
    bbr-fast)
      apply_vps_adapt_values bbr 1 0 67108864 67108864 "$(max_notsent_lowat)" 1048576
      ;;
    *)
      die "未知 VPS 适配预设：$profile"
      ;;
  esac
}
