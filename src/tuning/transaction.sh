# Module: src/tuning/transaction.sh
snapshot_managed_file() {
  backup_dir="$1"
  target_file="$2"
  label="$3"
  if [ -f "$target_file" ]; then
    cp "$target_file" "$backup_dir/$label.original" || return 1
    printf '1\n' > "$backup_dir/$label.existed"
  else
    printf '0\n' > "$backup_dir/$label.existed"
  fi
  printf '%s\n' "$target_file" > "$backup_dir/$label.path"
}

restore_managed_file() {
  backup_dir="$1"
  label="$2"
  target_file="$(cat "$backup_dir/$label.path" 2>/dev/null || true)"
  existed="$(cat "$backup_dir/$label.existed" 2>/dev/null || true)"
  [ -n "$target_file" ] || return 1
  if [ "$existed" = "1" ]; then
    [ -f "$backup_dir/$label.original" ] || return 1
    atomic_copy_file "$backup_dir/$label.original" "$target_file" || return 1
  else
    rm -f "$target_file" || return 1
  fi
}

sysctl_key_allowed_for_platform() {
  key="$1"
  detect_os
  case "$OS_FAMILY" in
    macos) return 1 ;;
    openwrt) openwrt_key_allowed "$key" ;;
    *) return 0 ;;
  esac
}

restore_runtime_values() {
  values_file="$1"
  [ -f "$values_file" ] || return 0
  transaction_failed=0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//')"
    [ -n "$key" ] || continue
    sysctl -w "$key=$value" >/dev/null 2>&1 || transaction_failed=1
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    [ "$(printf '%s' "$actual" | tr -s ' ')" = "$(printf '%s' "$value" | tr -s ' ')" ] || transaction_failed=1
  done < "$values_file"
  [ "$transaction_failed" = "0" ]
}

apply_sysctl_transaction() {
  target_file="$1"
  candidate_file="$2"
  backup_dir="$3"
  label="$4"
  platform_is_read_only && macos_write_unsupported
  have_cmd sysctl || return 1
  snapshot_managed_file "$backup_dir" "$target_file" "$label" || return 1
  filtered="$backup_dir/$label.filtered"
  live="$backup_dir/$label.live"
  skipped="$backup_dir/$label.skipped"
  : > "$filtered"
  : > "$live"
  : > "$skipped"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$filtered"; continue ;; esac
    case "$line" in *=*) ;; *) printf '%s\n' "$line" >> "$skipped"; continue ;; esac
    key="$(printf '%s' "${line%%=*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if ! sysctl_key_allowed_for_platform "$key"; then
      printf '%s unsupported-platform\n' "$key" >> "$skipped"
      continue
    fi
    current="$(sysctl -n "$key" 2>/dev/null || true)"
    if [ -z "$current" ]; then
      printf '%s unsupported-kernel\n' "$key" >> "$skipped"
      continue
    fi
    printf '%s = %s\n' "$key" "$current" >> "$live"
    printf '%s = %s\n' "$key" "$value" >> "$filtered"
  done < "$candidate_file"
  atomic_copy_file "$filtered" "$target_file" || return 1
  transaction_failed=0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in ''|'#'*) continue ;; esac
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    sysctl -w "$key=$value" >/dev/null 2>&1 || { transaction_failed=1; break; }
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    [ "$(printf '%s' "$actual" | tr -s ' ')" = "$(printf '%s' "$value" | tr -s ' ')" ] || { transaction_failed=1; break; }
  done < "$filtered"
  if [ "$transaction_failed" != "0" ]; then
    restore_runtime_values "$live" >/dev/null 2>&1 || true
    restore_managed_file "$backup_dir" "$label" >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

backup_state() {
  ensure_state_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(unique_path "$STATE_DIR/backups/$ts")"
  mkdir "$dir"
  snapshot_managed_file "$dir" "$SYSCTL_FILE" sysctl-file || return 1
  snapshot_managed_file "$dir" "$BASELINE_FILE" baseline-file || return 1
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
  output_file="${2:-$SYSCTL_FILE}"
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
  congestion="$(preferred_congestion_control)"
  [ -n "$congestion" ] || congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
  limit_output=131072

  cat > "$output_file" <<EOF
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
net.ipv4.tcp_congestion_control = $congestion
EOF
  if sysctl -n net.ipv4.tcp_limit_output_bytes >/dev/null 2>&1; then
    echo "net.ipv4.tcp_limit_output_bytes = $limit_output" >> "$output_file"
  fi
  if sysctl -n net.ipv4.tcp_autocorking >/dev/null 2>&1; then
    echo "net.ipv4.tcp_autocorking = 1" >> "$output_file"
  fi
}

apply_profile() {
  profile="$(normalize_profile "$1")"
  detect_os
  case "$OS_FAMILY" in
    macos) macos_write_unsupported ;;
    openwrt) DIE_EXIT_CODE="$EXIT_DEPENDENCY" die "OpenWrt 不允许写入大缓冲预设；请使用稳定优化或 local-minimal。" ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then
    print_header "预制参数写入 · Dry Run"
    print_profile_summary "$profile"
    ui_note "动作" "只展示将写入的参数，不修改系统。"
    values="$(profile_values "$profile")"
    # shellcheck disable=SC2086
    set -- $values
    ui_row "tcp_rmem" "$4 $5 $6"
    ui_row "tcp_wmem" "$7 $8 $9"
    ui_row "BBR/qdisc" "bbr / $(preferred_qdisc)"
    return 0
  fi
  need_root
  backup_dir="$(backup_state)"
  candidate="$backup_dir/profile.candidate"
  write_sysctl_config "$profile" "$candidate"
  if ! apply_sysctl_transaction "$SYSCTL_FILE" "$candidate" "$backup_dir" profile-target; then
    restore_backup_dir "$backup_dir" >/dev/null 2>&1 || true
    DIE_EXIT_CODE="$EXIT_APPLY" die "sysctl 事务加载或验证失败，已回滚；备份目录：$backup_dir"
  fi
  atomic_write_line "$STATE_DIR/last-profile" "$profile"
  info "已即时保存并加载预设：$profile"
  info "备份目录：$backup_dir"
  status_short
}

apply_buffers() {
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
  congestion="$(preferred_congestion_control)"
  [ -n "$congestion" ] || congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
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
  need_root
  detect_os
  case "$OS_FAMILY" in
    macos) macos_write_unsupported ;;
    openwrt)
      apply_openwrt_minimal_values 1 0 "$notsent_lowat" "$limit_output"
      return 0
      ;;
  esac
  backup_dir="$(backup_state)"
  candidate="$backup_dir/buffers.candidate"
  cat > "$candidate" <<EOF
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
net.ipv4.tcp_congestion_control = $congestion
EOF
  if sysctl -n net.ipv4.tcp_limit_output_bytes >/dev/null 2>&1; then
    echo "net.ipv4.tcp_limit_output_bytes = $limit_output" >> "$candidate"
  fi
  if sysctl -n net.ipv4.tcp_autocorking >/dev/null 2>&1; then
    echo "net.ipv4.tcp_autocorking = 1" >> "$candidate"
  fi
  if ! apply_sysctl_transaction "$SYSCTL_FILE" "$candidate" "$backup_dir" buffers-target; then
    restore_backup_dir "$backup_dir" >/dev/null 2>&1 || true
    DIE_EXIT_CODE="$EXIT_APPLY" die "sysctl 事务加载或验证失败，已回滚；备份目录：$backup_dir"
  fi
  if [ "${TUNE_SIMPLE_OUTPUT:-0}" = "1" ]; then
    info "参数已调整并即时保存（已创建回滚备份）。"
  else
    info "已即时保存并加载 buffer：rmem=$rmem_max wmem=$wmem_max notsent=$notsent_lowat limit_output=$limit_output"
    info "备份目录：$backup_dir"
  fi
}

apply_smart() {
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
  need_root
  # shellcheck disable=SC2086
  set -- $values
  apply_buffers "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

manual_backup_begin() {
  label="$1"
  ensure_state_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(unique_path "$STATE_DIR/manual-$label-$ts")"
  mkdir -p "$dir"
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
  sysctl -a 2>/dev/null | grep -E '^(fs.file-max|net\.core\.|net\.ipv4\.tcp_|net\.ipv4\.udp_)' > "$dir/before-sysctl.txt" || true
  snapshot_managed_file "$dir" "$VPS_ADAPT_FILE" vps-adapt || return 1
  snapshot_managed_file "$dir" "$OPENWRT_MINIMAL_FILE" openwrt-minimal || return 1
  snapshot_managed_file "$dir" "$SYSCTL_FILE" sysctl-file || return 1
  snapshot_managed_file "$dir" "$BASELINE_FILE" baseline-file || return 1
  echo "$dir"
}

ensure_initial_defaults_snapshot() {
  ensure_state_dir
  path_file="$(initial_defaults_path_file)"
  dir="$(cat "$path_file" 2>/dev/null || true)"
  if [ -n "$dir" ] && [ -d "$dir" ] && [ -f "$dir/restore-current.conf" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  dir="$(initial_defaults_dir)"
  if [ -d "$dir" ] && [ -f "$dir/restore-current.conf" ]; then
    atomic_write_line "$path_file" "$dir"
    printf '%s\n' "$dir"
    return 0
  fi
  tmp_dir="$(manual_backup_begin "initial-defaults")" || return 1
  if [ -e "$dir" ]; then
    dir="$(unique_path "$dir")"
  fi
  mv "$tmp_dir" "$dir"
  {
    printf 'created_at=%s\n' "$(date +%s)"
    printf 'role=%s\n' "${1:-local}"
    printf 'note=%s\n' "Initial TCP-optimization defaults snapshot. Restore only through restore-defaults."
  } > "$dir/metadata"
  atomic_write_line "$path_file" "$dir"
  printf '%s\n' "$dir"
}

ensure_initial_defaults_if_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    return 1
  fi
  ensure_initial_defaults_snapshot "${1:-local}" >/dev/null 2>&1
}

restore_initial_defaults() {
  need_root
  path_file="$(initial_defaults_path_file)"
  dir="$(cat "$path_file" 2>/dev/null || true)"
  [ -n "$dir" ] || dir="$(initial_defaults_dir)"
  if [ ! -d "$dir" ] || [ ! -f "$dir/restore-current.conf" ]; then die "未找到首次运行默认值快照。"; fi
  restore_manual_backup "$dir"
  info "已恢复首次运行记录的默认值：$dir"
}
