# Module: src/tuning/diagnostics.sh
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
  if [ "${OUTPUT_MODE:-human}" = "json" ]; then
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || true)"
    wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || true)"
    data="{\"app_version\":$(json_string "$APP_VERSION"),\"os\":$(json_string "$OS_NAME"),\"platform\":$(json_string "$OS_FAMILY"),\"congestion_control\":$(if [ -n "$cc" ]; then json_string "$cc"; else printf null; fi),\"qdisc\":$(if [ -n "$qdisc" ]; then json_string "$qdisc"; else printf null; fi),\"rmem_max\":$(if is_unsigned_integer "$rmem"; then printf '%s' "$rmem"; else printf null; fi),\"wmem_max\":$(if is_unsigned_integer "$wmem"; then printf '%s' "$wmem"; else printf null; fi)}"
    json_envelope true status "$data" '[]'
    return 0
  fi
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
    echo "  - 当前内存低于 256MiB，不建议直接使用高缓冲预设。"
  fi
}

detect_rtt_ms() {
  host="$1"
  have_cmd ping || { echo 0; return 0; }
  output="$(ping -c 3 -W 1 "$host" 2>/dev/null || true)"
  avg="$(printf '%s\n' "$output" | awk -F'=' '/rtt|round-trip/ { split($2,a,"/"); printf "%d\n", a[2] + 0; found=1 } END { if (!found) print 0 }' | tail -n 1)"
  is_unsigned_integer "$avg" || avg=0
  echo "$avg"
}

route_iface_for_host() {
  host="$1"
  have_cmd ip || { echo unsupported; return 0; }
  route_output="$(ip route get "$host" 2>/dev/null)" || { echo failed; return 0; }
  printf '%s\n' "$route_output" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "dev" && (i + 1) <= NF) {
        print $(i + 1)
        exit
      }
    }
  }' | awk 'NF {print; found=1; exit} END {if (!found) print "unknown"}'
}

iface_mtu() {
  iface="$1"
  case "$iface" in
    ""|unknown) echo unknown; return 0 ;;
    unsupported|failed) echo "$iface"; return 0 ;;
  esac
  if [ -r "/sys/class/net/$iface/mtu" ]; then
    cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo failed
  else
    echo unsupported
  fi
}

qdisc_stats() {
  iface="$1"
  have_cmd tc || { echo "unsupported unsupported"; return 0; }
  case "$iface" in
    ""|unknown) echo "unknown unknown"; return 0 ;;
    unsupported) echo "unsupported unsupported"; return 0 ;;
    failed) echo "failed failed"; return 0 ;;
  esac
  qdisc_output="$(tc -s qdisc show dev "$iface" 2>/dev/null)" || { echo "failed failed"; return 0; }
  printf '%s\n' "$qdisc_output" | awk '
    BEGIN { drops = 0; backlog = 0; seen = 0 }
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/[(),]/, "", token)
        if (token == "dropped" && (i + 1) <= NF) {
          value = $(i + 1)
          gsub(/[^0-9]/, "", value)
          if (value != "") { drops += value + 0; seen = 1 }
        }
        if (token == "backlog" && (i + 1) <= NF) {
          value = $(i + 1)
          gsub(/[^0-9]/, "", value)
          if (value != "") { backlog += value + 0; seen = 1 }
        }
      }
    }
    END {
      if (seen) printf "%d %d\n", drops, backlog
      else print "unknown unknown"
    }
  '
}

qdisc_delta() {
  before="$1"
  after="$2"
  # shellcheck disable=SC2086
  set -- $before
  before_drop="${1:-unknown}"
  before_backlog="${2:-unknown}"
  # shellcheck disable=SC2086
  set -- $after
  after_drop="${1:-unknown}"
  after_backlog="${2:-unknown}"
  if is_unsigned_integer "$before_drop" && is_unsigned_integer "$after_drop"; then
    drop_delta=$((after_drop - before_drop))
    [ "$drop_delta" -lt 0 ] && drop_delta=0
  else
    case "$before_drop:$after_drop" in
      *failed*) drop_delta="failed" ;;
      *unsupported*) drop_delta="unsupported" ;;
      *) drop_delta="unknown" ;;
    esac
  fi
  if is_unsigned_integer "$before_backlog" && is_unsigned_integer "$after_backlog"; then
    backlog_delta=$((after_backlog - before_backlog))
    [ "$backlog_delta" -lt 0 ] && backlog_delta=0
  else
    case "$before_backlog:$after_backlog" in
      *failed*) backlog_delta="failed" ;;
      *unsupported*) backlog_delta="unsupported" ;;
      *) backlog_delta="unknown" ;;
    esac
  fi
  printf "%s %s\n" "$drop_delta" "$backlog_delta"
}

probe_pmtu() {
  host="$1"
  if have_cmd tracepath; then
    trace_output="$(tracepath -n -m 8 "$host" 2>/dev/null)" || { echo failed; return 0; }
    pmtu="$(printf '%s\n' "$trace_output" | awk '/pmtu/ {for (i=1;i<=NF;i++) if ($i=="pmtu" && (i+1)<=NF) print $(i+1)}' | tail -n 1)"
    if is_unsigned_integer "$pmtu"; then
      echo "$pmtu"
      return 0
    fi
  fi
  case "$host" in
    *:*) echo unsupported; return 0 ;;
  esac
  have_cmd ping || { echo unsupported; return 0; }
  for payload in 1472 1464 1452 1412 1372 1332 1292 1252 1212 1172; do
    if ping -c 1 -W 1 -M 'do' -s "$payload" "$host" >/dev/null 2>&1; then
      echo $((payload + 28))
      return 0
    fi
  done
  echo unknown
}

measure_iperf_pair() {
  host="$1"
  port="$2"
  seconds="${3:-8}"
  parallel="${4:-1}"
  bind_ip="${5:-}"
  upload_json="$(run_iperf_client "$host" "$port" 0 "$seconds" "$bind_ip" "$parallel" 2>/dev/null || true)"
  download_json="$(run_iperf_client "$host" "$port" 1 "$seconds" "$bind_ip" "$parallel" 2>/dev/null || true)"
  if ! printf '%s' "$upload_json" | grep -q '"end"'; then
    echo "ERR upload"
    return 1
  fi
  if ! printf '%s' "$download_json" | grep -q '"end"'; then
    echo "ERR download"
    return 1
  fi
  upload_bps="$(printf '%s\n' "$upload_json" | iperf_metric_or_unknown bps)"
  upload_retr="$(printf '%s\n' "$upload_json" | iperf_metric_or_unknown retrans)"
  upload_first="$(printf '%s\n' "$upload_json" | iperf_metric_or_unknown first)"
  download_bps="$(printf '%s\n' "$download_json" | iperf_metric_or_unknown bps)"
  download_retr="$(printf '%s\n' "$download_json" | iperf_metric_or_unknown retrans)"
  download_first="$(printf '%s\n' "$download_json" | iperf_metric_or_unknown first)"
  printf "%s %s %s %s %s %s\n" "$upload_bps" "$upload_retr" "$upload_first" "$download_bps" "$download_retr" "$download_first"
}

print_iperf_pair_rows() {
  pair_label="$1"
  values="$2"
  # shellcheck disable=SC2086
  set -- $values
  ui_row "$pair_label 上传" "$(format_rate "${1:-unknown}") / 重传 $(format_count "${2:-unknown}") 次 / 首秒 $(format_rate "${3:-unknown}")"
  ui_row "$pair_label 下载" "$(format_rate "${4:-unknown}") / 重传 $(format_count "${5:-unknown}") 次 / 首秒 $(format_rate "${6:-unknown}")"
}

write_tuning_profile() {
  title="$1"
  machine_role="$2"
  critical_direction="$3"
  protocol_class="$4"
  peer_label="$5"
  p1_result="$6"
  p4_result="$7"
  pmtu="$8"
  qdisc_delta_text="$9"
  params_text="${10:-}"
  backup_path="${11:-}"
  decision_text="${12:-}"
  ensure_state_dir
  mkdir -p "$(profiles_dir)"
  path="$(latest_profile_path)"
  {
    printf '# TCP-optimization 调参报告\n\n'
    printf -- '- 时间：%s\n' "$(date -Iseconds 2>/dev/null || date)"
    printf -- '- 标题：%s\n' "$(safe_report_text "$title")"
    printf -- '- 机器角色：%s\n' "$machine_role"
    printf -- '- 关键方向：%s\n' "$critical_direction"
    printf -- '- 协议类型：%s\n' "$protocol_class"
    printf -- '- 测试对端：%s\n' "$(mask_report_peer "$peer_label")"
    printf -- '- P1 结果：%s\n' "$(safe_report_text "$p1_result")"
    printf -- '- P4 结果：%s\n' "$(safe_report_text "$p4_result")"
    printf -- '- PMTU：%s\n' "$pmtu"
    printf -- '- qdisc delta：%s\n' "$(safe_report_text "$qdisc_delta_text")"
    printf -- '- 写入参数：%s\n' "$(safe_report_text "$params_text")"
    printf -- '- 备份路径：%s\n' "$(safe_report_text "$backup_path")"
    printf -- '- 保留原因：%s\n' "$(safe_report_text "$decision_text")"
    printf '\n> 本报告不保存 token、密码、SSH 私钥或 Cookie。\n'
  } > "$path"
  printf '%s\n' "$path"
}

advanced_diagnose_mode() {
  host=""
  port="$IPERF_PORT"
  seconds="8"
  machine_role="endpoint"
  critical_direction="download"
  protocol_class="unknown"
  proxy_software=""
  traffic_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --peer|--host) require_option_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --port|--iperf-port) require_option_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --seconds) require_option_value "$1" "${2:-}"; seconds="$2"; shift 2 ;;
      --machine-role) require_option_value "$1" "${2:-}"; machine_role="$2"; shift 2 ;;
      --critical-direction) require_option_value "$1" "${2:-}"; critical_direction="$2"; shift 2 ;;
      --protocol-class) require_option_value "$1" "${2:-}"; protocol_class="$2"; shift 2 ;;
      --proxy-software) require_option_value "$1" "${2:-}"; proxy_software="$2"; shift 2 ;;
      --traffic-path) require_option_value "$1" "${2:-}"; traffic_path="$2"; shift 2 ;;
      *) die "未知 advanced-diagnose 参数：$1" ;;
    esac
  done
  [ -n "$host" ] || die "advanced-diagnose 需要 --host"
  validate_port_value "$port" || die "--port 必须在 1 和 65535 之间。"
  validate_positive_int_range "$seconds" 3 60 || die "--seconds 必须在 3 和 60 之间。"
  context_line="$(normalize_link_context "$machine_role" "$critical_direction" "$protocol_class" "$proxy_software" "$traffic_path")"
  machine_role="$(printf '%s\n' "$context_line" | cut -f1)"
  critical_direction="$(printf '%s\n' "$context_line" | cut -f2)"
  protocol_class="$(printf '%s\n' "$context_line" | cut -f3)"
  proxy_software="$(printf '%s\n' "$context_line" | cut -f4)"
  traffic_path="$(printf '%s\n' "$context_line" | cut -f5)"
  detect_os
  iface="$(route_iface_for_host "$host")"
  mtu="$(iface_mtu "$iface")"
  pmtu="$(probe_pmtu "$host")"
  rtt_ms="$(detect_rtt_ms "$host")"
  clear_screen
  print_header "高级链路诊断"
  ui_section "上下文"
  ui_row "机器角色" "$machine_role"
  ui_row "关键方向" "$critical_direction"
  ui_row "协议类型" "$protocol_class"
  [ -n "$proxy_software" ] && ui_row "代理软件" "$proxy_software"
  [ -n "$traffic_path" ] && ui_row "业务路径" "$traffic_path"
  ui_row "出口接口" "$iface"
  ui_row "接口 MTU" "$mtu"
  ui_row "PMTU" "$pmtu"
  ui_row "RTT" "${rtt_ms}ms"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    ui_note "Dry Run" "只展示会采集的诊断项，不运行 iperf3，不写入系统。"
    return 0
  fi
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法进行高级诊断。"
  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in *:*) bind_ip="" ;; esac
  qdisc_before="$(qdisc_stats "$iface")"
  ui_section "P1 单流测试"
  p1_result="$(measure_iperf_pair "$host" "$port" "$seconds" 1 "$bind_ip")"
  print_iperf_pair_rows "P1" "$p1_result"
  ui_section "P4 多流容量探测"
  p4_result="$(measure_iperf_pair "$host" "$port" "$seconds" 4 "$bind_ip")"
  print_iperf_pair_rows "P4" "$p4_result"
  qdisc_after="$(qdisc_stats "$iface")"
  qdisc_delta_values="$(qdisc_delta "$qdisc_before" "$qdisc_after")"
  # shellcheck disable=SC2086
  set -- $qdisc_delta_values
  drop_delta="${1:-unknown}"
  backlog_delta="${2:-unknown}"
  ui_section "qdisc 测试窗口"
  ui_row "drop delta" "$drop_delta"
  ui_row "backlog delta" "$backlog_delta"
  ui_section "判断"
  if [ "$protocol_class" = "udp-quic" ]; then
    ui_note "协议" "UDP/QUIC 场景不应把 TCP iperf3 结论直接当成最终调参依据。"
  fi
  if [ "$drop_delta" = "0" ] && [ "$backlog_delta" = "0" ]; then
    ui_note "队列" "重传若仍偏高，更可能来自路径、对端或上游拥塞，不建议盲目堆大 buffer。"
  fi
  ui_note "强干预" "MTU、TBF/HTB、qos-agent 只给建议，不在本诊断中写入。"
}
