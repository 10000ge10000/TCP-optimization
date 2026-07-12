# Module: src/tuning/benchmark.sh
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
  case "${1:-unknown}" in unknown|unsupported|failed) printf '%s\n' "${1:-unknown}"; return 0 ;; esac
  awk -v bps="$1" 'BEGIN {
    if (bps >= 1000000000) printf "%.2f Gbps\n", bps / 1000000000
    else printf "%.1f Mbps\n", bps / 1000000
  }'
}

format_count() {
  case "${1:-unknown}" in unknown|unsupported|failed) printf '%s\n' "${1:-unknown}"; return 0 ;; esac
  awk -v value="$1" 'BEGIN {
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
  iperf_pid="$!"
  atomic_write_line "$STATE_DIR/iperf3-$port.pid" "$iperf_pid"
  write_process_manifest "$STATE_DIR/iperf3-$port.manifest" "$iperf_pid" "${TCP_TUNE_SESSION_ID:-standalone}" "iperf3" "$port" || {
    kill "$iperf_pid" 2>/dev/null || true
    rm -f "$STATE_DIR/iperf3-$port.pid"
    die "无法记录 iperf3 进程身份。"
  }
  info "iperf3 server 已启动，端口：$port"
}

stop_iperf_server() {
  port="$1"
  if [ -f "$STATE_DIR/iperf3-$port.manifest" ]; then
    pid="$(manifest_value "$STATE_DIR/iperf3-$port.manifest" pid)"
    if stop_verified_process "$STATE_DIR/iperf3-$port.manifest" "${TCP_TUNE_SESSION_ID:-}"; then
      rm -f "$STATE_DIR/iperf3-$port.pid" "$STATE_DIR/iperf3-$port.manifest"
      info "已停止 iperf3 server：$pid"
    else
      warn "iperf3 进程身份不匹配，未终止 PID $pid。"
      return 1
    fi
  else
    info "未找到本工具记录的 iperf3 manifest，未停止端口 $port 上的其他进程。"
  fi
}

active_iperf_client_manifest() {
  printf '%s/iperf3-client-%s.manifest\n' "$STATE_DIR" "$$"
}

stop_active_iperf_client() {
  active_manifest="$(active_iperf_client_manifest)"
  [ -f "$active_manifest" ] || return 0
  stop_verified_process "$active_manifest" "client-$$" >/dev/null 2>&1 || return 1
  rm -f "$active_manifest"
}

run_owned_iperf_client() {
  ensure_state_dir
  active_manifest="$(active_iperf_client_manifest)"
  "$@" &
  client_pid=$!
  if ! write_process_manifest "$active_manifest" "$client_pid" "client-$$" iperf3 "$port"; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    return 1
  fi
  if wait "$client_pid"; then client_rc=0; else client_rc=$?; fi
  rm -f "$active_manifest"
  return "$client_rc"
}

run_iperf_client() {
  host="$1"
  port="$2"
  reverse="$3"
  seconds="$4"
  bind_ip="${5:-}"
  parallel="${6:-1}"
  [ -n "$host" ] || die "iperf3 需要 host"
  validate_port_value "$port" || die "iperf3 port 必须在 1 和 65535 之间。"
  case "$reverse" in 0|1) ;; *) die "iperf3 reverse 必须是 0 或 1。" ;; esac
  validate_positive_int_range "$seconds" 1 86400 || die "iperf3 seconds 必须是正整数。"
  validate_positive_int_range "$parallel" 1 64 || die "iperf3 parallel 必须是 1 到 64 的正整数。"
  ensure_dependency iperf3 iperf3 || die "缺少 iperf3，无法测试。"
  # 只在字面地址的地址族明确冲突时清空；合法 IPv6 bind 必须保留。
  if [ -n "$bind_ip" ]; then
    case "$host" in
      *:*) case "$bind_ip" in *:*) : ;; *) bind_ip="" ;; esac ;;
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) case "$bind_ip" in *:*) bind_ip="" ;; esac ;;
    esac
  fi
  set -- iperf3 -c "$host" -p "$port"
  [ -n "$bind_ip" ] && set -- "$@" -B "$bind_ip"
  [ "$reverse" = "1" ] && set -- "$@" -R
  set -- "$@" -t "$seconds"
  [ "$parallel" -gt 1 ] && set -- "$@" -P "$parallel"
  set -- "$@" -J
  # 不使用 -O，首个 interval 才能代表真实连接起速；随机波动由多样本中位数处理。
  run_owned_iperf_client "$@"
}

numeric_median() {
  sort -n | awk '{v[NR]=$1} END {if (NR==0) exit 1; if (NR%2) print v[(NR+1)/2]; else printf "%.0f\n", (v[NR/2]+v[NR/2+1])/2}'
}

sample_spread_percent() {
  sort -n | awk 'NR==1{min=$1} {max=$1; sum+=$1; n++} END {if(!n||sum<=0){print 0; exit}; mean=sum/n; printf "%.0f\n", (max-min)*100/mean}'
}

measure_iperf_samples() {
  host="$1"; port="$2"; reverse="$3"; seconds="$4"; bind_ip="${5:-}"; parallel="${6:-1}"
  count="${7:-$TCP_TUNE_SAMPLE_COUNT}"
  validate_positive_int_range "$count" 1 7 || return 1
  temp_dir="$(secure_temp_dir tcp-tune-samples)" || return 1
  samples="$temp_dir/metrics.tsv"
  : > "$samples"
  run=1
  while [ "$run" -le "$count" ]; do
    json="$(run_iperf_client "$host" "$port" "$reverse" "$seconds" "$bind_ip" "$parallel" 2>/dev/null || true)"
    if [ -z "$json" ] || ! printf '%s' "$json" | grep -q '"end"'; then rm -f "$samples"; rmdir "$temp_dir" 2>/dev/null || true; return 1; fi
    bps="$(printf '%s\n' "$json" | extract_bps 2>/dev/null || true)"
    retr="$(printf '%s\n' "$json" | extract_retransmits 2>/dev/null || true)"
    first="$(printf '%s\n' "$json" | extract_first_interval_bps 2>/dev/null || true)"
    if ! is_unsigned_integer "$bps" || ! is_unsigned_integer "$retr" || ! is_unsigned_integer "$first"; then rm -f "$samples"; rmdir "$temp_dir" 2>/dev/null || true; return 1; fi
    printf '%s\t%s\t%s\n' "$bps" "$retr" "$first" >> "$samples"
    run=$((run + 1))
  done
  spread="$(cut -f1 "$samples" | sample_spread_percent)"
  if [ "$spread" -gt "$TCP_TUNE_MAX_SPREAD_PERCENT" ] && [ "$count" -ge 3 ]; then
    extra=0
    while [ "$extra" -lt 2 ]; do
      json="$(run_iperf_client "$host" "$port" "$reverse" "$seconds" "$bind_ip" "$parallel" 2>/dev/null || true)"
      bps="$(printf '%s\n' "$json" | extract_bps 2>/dev/null || true)"
      retr="$(printf '%s\n' "$json" | extract_retransmits 2>/dev/null || true)"
      first="$(printf '%s\n' "$json" | extract_first_interval_bps 2>/dev/null || true)"
      if ! is_unsigned_integer "$bps" || ! is_unsigned_integer "$retr" || ! is_unsigned_integer "$first"; then break; fi
      printf '%s\t%s\t%s\n' "$bps" "$retr" "$first" >> "$samples"
      extra=$((extra + 1))
    done
    spread="$(cut -f1 "$samples" | sample_spread_percent)"
  fi
  if [ "$spread" -gt "$TCP_TUNE_MAX_SPREAD_PERCENT" ]; then
    rm -f "$samples"; rmdir "$temp_dir" 2>/dev/null || true
    return 2
  fi
  median_bps="$(cut -f1 "$samples" | numeric_median)"
  median_retr="$(cut -f2 "$samples" | numeric_median)"
  median_first="$(cut -f3 "$samples" | numeric_median)"
  rm -f "$samples"; rmdir "$temp_dir" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$median_bps" "$median_retr" "$median_first" "$spread"
}

run_iperf3_speedtest() {
  host="$1"
  port="$2"
  clear_screen
  print_header "iperf3 速度测试"
  ui_subtitle "简单测速，不修改任何参数"
  echo
  ui_section "测试参数"
  ui_row "对端地址" "$host"
  ui_row "端口" "$port"
  ui_row "测试方向" "下载（服务端 → 本机）"
  ui_row "测试时长" "10秒"
  case "$host" in
    *:*) ui_note "IPv6" "检测到 IPv6 地址，使用 IPv6 测速" ;;
  esac
  echo
  ui_note "状态" "正在测速..."
  ensure_dependency iperf3 iperf3 || { warn "缺少 iperf3"; return 1; }
  echo
  if iperf3 -c "$host" -p "$port" -R -t 10; then
    echo
    ui_section "测速完成"
  else
    echo
    warn "测速失败，请检查对端 iperf3 服务是否运行。"
  fi
}
