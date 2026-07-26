# Module: src/cli/client-menu.sh
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
      --peer) require_option_value "$1" "${2:-}"; peer="$2"; shift 2 ;;
      --token) require_option_value "$1" "${2:-}"; token="$2"; shift 2 ;;
      --iperf-port) require_option_value "$1" "${2:-}"; iperf_port="$2"; shift 2 ;;
      --objective) require_option_value "$1" "${2:-}"; objective="$2"; shift 2 ;;
      --target-retr) require_option_value "$1" "${2:-}"; target_retr="$2"; shift 2 ;;
      --rounds) require_option_value "$1" "${2:-}"; rounds="$2"; shift 2 ;;
      --local-mbps) require_option_value "$1" "${2:-}"; local_mbps="$2"; shift 2 ;;
      --peer-mbps) require_option_value "$1" "${2:-}"; peer_mbps="$2"; shift 2 ;;
      --rtt-ms) require_option_value "$1" "${2:-}"; rtt_ms="$2"; shift 2 ;;
      --memory-mb) require_option_value "$1" "${2:-}"; memory_mb_value="$2"; shift 2 ;;
      --ramp) require_option_value "$1" "${2:-}"; ramp_rate="$2"; shift 2 ;;
      --aggressive) aggressive="1"; shift ;;
      --allow-same-public-ip) allow_same_public="1"; shift ;;
      --direction)
        require_option_value "$1" "${2:-}"
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
  # 多用户主机上 --token 会进入 shell history 与进程参数；支持从环境变量读取。
  [ -n "$token" ] || token="${TCP_TUNE_TOKEN:-}"
  [ -n "$token" ] || die "缺少 --token（也可通过环境变量 TCP_TUNE_TOKEN 提供）"
  validate_peer_url "$peer" || die "--peer 必须是无用户信息、query 和 fragment 的 http(s) URL。"
  if [ "${#token}" -lt 16 ] || [ "${#token}" -gt 512 ]; then die "--token 长度必须在 16 到 512 之间。"; fi
  validate_port_value "$iperf_port" || die "--iperf-port 必须在 1 和 65535 之间。"
  validate_objective "$objective" || die "--objective 只支持 retrans、throughput、startup。"
  validate_positive_int_range "$rounds" 1 10 || die "--rounds 必须在 1 和 10 之间。"
  validate_positive_int_range "$target_retr" 0 100000000 || die "--target-retr 必须是非负整数。"
  install_runtime_deps
  detect_os
  client_lan_ip="$(local_lan_ipv4 || true)"
  [ -n "$client_lan_ip" ] || client_lan_ip="unknown"
  TUNE_REPORT_PEER="$peer"
  TUNE_REPORT_TOKEN="$token"
  TUNE_CLIENT_IP="$client_lan_ip"
  ensure_initial_defaults_if_root "client" || true

  report_role="join"
  [ "${CLIENT_MENU:-0}" = "1" ] && report_role="client"
  report="{\"role\":$(json_string "$report_role"),\"os\":$(json_string "$OS_NAME"),\"architecture\":$(json_string "$(uname -m 2>/dev/null || echo unknown)"),\"lan_ip\":$(json_string "$client_lan_ip"),\"time\":$(date +%s)}"
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
  validate_host_value "$host" || die "对端 URL 中的 host 非法。"
  echo "已连接到服务端会话。"
  if [ "${CLIENT_MENU:-0}" = "1" ]; then
    client_menu "$peer" "$token" "$host" "$iperf_port" "$allow_same_public" "$client_lan_ip"
  else
    echo "准备启动$(objective_label "$objective")优化。"
    auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive" "$allow_same_public"
  fi
}

preset_write_menu() {
  host="$1"
  iperf_port="$2"
  allow_same_public="$3"
  clear_screen
  print_header "预制参数写入"
  ui_subtitle "先检测本机和对端链路，再推荐一个可快速套用的 TCP 参数挡位。"
  echo
  need_root
  install_runtime_deps
  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in
    127.*|localhost|"$bind_ip") bind_ip="" ;;
  esac
  display_local_ip="${bind_ip:-$(local_lan_ipv4 || true)}"
  [ -n "$display_local_ip" ] || display_local_ip="未识别"
  post_client_stage "preset-probe" "running" "正在检测链路"
  ui_section "检测中"
  ui_note "动作" "正在检测 RTT、iperf3 上传/下载、重传和本机 TCP 基线..."
  metrics="$(profile_probe_metrics "$host" "$iperf_port" "$bind_ip")"
  # shellcheck disable=SC2086
  set -- $metrics
  rtt_ms="$1"
  memory_mb_value="$2"
  upload_bps="$3"
  upload_retr="$4"
  upload_first="$5"
  download_bps="$6"
  download_retr="$7"
  download_first="$8"
  total_retr="$9"
  recommended="${10:-近距轻载}"
  reason="$(recommend_preset_reason "$rtt_ms" "$memory_mb_value" "$total_retr" "$download_bps")"
  post_client_stage "preset-probe" "ok" "$recommended"

  clear_screen
  print_header "预制参数写入"
  ui_section "检测结果"
  ui_row "本机地址" "$display_local_ip"
  ui_row "系统" "${OS_NAME:-Unknown}"
  ui_row "内存" "${memory_mb_value}MiB"
  ui_row "RTT" "${rtt_ms}ms"
  ui_row "上传" "$(format_rate "$upload_bps") / 重传 $(format_count "$upload_retr") 次 / 首秒 $(format_rate "$upload_first")"
  ui_row "下载" "$(format_rate "$download_bps") / 重传 $(format_count "$download_retr") 次 / 首秒 $(format_rate "$download_first")"
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未识别)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未识别)"
  ui_row "当前基线" "$current_cc / $current_qdisc"
  echo
  ui_section "推荐挡位"
  print_profile_summary "$recommended"
  ui_note "判断依据" "$reason"
  echo
  ui_section "可选挡位"
  ui_mode_card "1" "近距轻载" "RTT < 30ms" "低延迟链路，优先控制重传"
  ui_mode_card "2" "近距高速" "RTT 30~70ms" "短中距高下行，缓冲对称"
  ui_mode_card "3" "中距均衡" "RTT 70~130ms" "跨境中等延迟，接收略大"
  ui_mode_card "4" "长距增强" "RTT 130~190ms" "跨海高带宽，较大 BDP"
  ui_mode_card "5" "远距大带宽" "RTT > 190ms" "高延迟大带宽，低内存谨慎"
  ui_back_item
  echo
  if ! prompt_read "请选择要写入的挡位 [1-5/0]，直接回车使用推荐："; then return 1; fi
  choice="$PROMPT_REPLY"
  [ -n "$choice" ] || choice="$recommended"
  if is_back_choice "$choice"; then
    return_to_menu
    return 0
  fi
  if profile_exists "$choice"; then
    selected="$(normalize_profile "$choice")"
  else
    selected="$(preset_by_number "$choice" 2>/dev/null || true)"
    [ -n "$selected" ] || { warn "无效挡位。"; pause_for_enter; return 0; }
  fi
  if [ "$memory_mb_value" -lt 256 ]; then
    case "$selected" in
      "长距增强"|"远距大带宽")
        warn "当前内存低于 256MiB，不建议写入高挡位；已返回选择页。"
        pause_for_enter
        return 0
        ;;
    esac
  fi
  clear_screen
  print_header "确认写入"
  print_profile_summary "$selected"
  ui_note "安全" "写入前会创建备份，失败会自动回滚。"
  ui_note "范围" "只修改本机 TCP/sysctl 参数，不改防火墙、DNS、代理或网络服务。"
  echo
  if ! prompt_read "按回车确认写入，输入 0 返回主菜单："; then return 1; fi
  if is_back_choice "$PROMPT_REPLY"; then
    return_to_menu
    return 0
  fi
  post_client_stage "preset-apply" "running" "$selected"
  if apply_profile "$selected"; then
    post_client_stage "preset-apply" "success" "$selected"
    echo
    ui_section "写入完成"
    ui_row "已写入" "$selected"
    ui_note "下一步" "如效果不理想，可在客户端菜单选择回滚最近修改。"
  else
    post_client_stage "preset-apply" "rollback" "$selected"
    return 1
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
  ui_back_item
  echo
  if ! prompt_read "请选择优化目标 [1-3/0]："; then return 1; fi
  if is_back_choice "$PROMPT_REPLY"; then
    return_to_menu
    return 0
  fi
  case "$PROMPT_REPLY" in
    2) objective="throughput"; target_retr="10"; rounds="4" ;;
    3) objective="startup"; target_retr="5"; rounds="3" ;;
    1) objective="retrans"; target_retr="0"; rounds="5" ;;
    *) warn "无效优化目标。"; return_to_menu; return 0 ;;
  esac
  selected_label="$(objective_label "$objective")"

  echo
  ui_section "测试方向"
  ui_menu_item "1" "下载" "服务端 → 本机"
  ui_menu_item "2" "上传" "本机 → 服务端"
  ui_back_item
  echo
  ui_note "当前选择" "$selected_label · 默认下载方向"
  if ! prompt_read "请选择测试方向 [1-2/0]："; then return 1; fi
  if is_back_choice "$PROMPT_REPLY"; then
    return_to_menu
    return 0
  fi
  case "$PROMPT_REPLY" in
    2) reverse="0" ;;
    1) reverse="1" ;;
    *) warn "无效测试方向。"; return_to_menu; return 0 ;;
  esac

  auto_tune "$host" "$iperf_port" "$objective" "$target_retr" "$rounds" "$reverse" 0 0 100 "" 0.79 0 "$allow_same_public"
}

prompt_link_context() {
  CONTEXT_MACHINE_ROLE="endpoint"
  CONTEXT_CRITICAL_DIRECTION="download"
  CONTEXT_PROTOCOL_CLASS="unknown"
  CONTEXT_PROXY_SOFTWARE=""
  CONTEXT_TRAFFIC_PATH=""
  echo
  ui_section "链路上下文"
  ui_menu_item "1" "endpoint" "普通客户端/落地应用默认选择"
  ui_menu_item "2" "relay" "中转机，重点看转发方向"
  ui_menu_item "3" "landing" "落地机，重点看入站到用户"
  ui_menu_item "4" "mixed" "同机多角色"
  if ! prompt_read "机器角色 [1-4]，默认 1："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) CONTEXT_MACHINE_ROLE="relay" ;;
    3) CONTEXT_MACHINE_ROLE="landing" ;;
    4) CONTEXT_MACHINE_ROLE="mixed" ;;
    ""|1) CONTEXT_MACHINE_ROLE="endpoint" ;;
    0|q|Q|b|B) return_to_menu; return 1 ;;
    *) warn "无效机器角色，已使用 endpoint。" ;;
  esac
  echo
  ui_menu_item "1" "download" "服务端 → 本机"
  ui_menu_item "2" "upload" "本机 → 服务端"
  ui_menu_item "3" "both" "双向都关键"
  if ! prompt_read "关键方向 [1-3]，默认 1："; then return 1; fi
  case "$PROMPT_REPLY" in
    2) CONTEXT_CRITICAL_DIRECTION="upload" ;;
    3) CONTEXT_CRITICAL_DIRECTION="both" ;;
    ""|1) CONTEXT_CRITICAL_DIRECTION="download" ;;
    0|q|Q|b|B) return_to_menu; return 1 ;;
    *) warn "无效关键方向，已使用 download。" ;;
  esac
  echo
  ui_menu_item "1" "tcp" "TCP 代理/转发"
  ui_menu_item "2" "udp-quic" "HY2/TUIC/QUIC 等 UDP/QUIC"
  ui_menu_item "3" "mixed" "TCP 与 UDP/QUIC 都有"
  ui_menu_item "4" "unknown" "不确定"
  if ! prompt_read "协议类型 [1-4]，默认 4："; then return 1; fi
  case "$PROMPT_REPLY" in
    1) CONTEXT_PROTOCOL_CLASS="tcp" ;;
    2) CONTEXT_PROTOCOL_CLASS="udp-quic" ;;
    3) CONTEXT_PROTOCOL_CLASS="mixed" ;;
    ""|4) CONTEXT_PROTOCOL_CLASS="unknown" ;;
    0|q|Q|b|B) return_to_menu; return 1 ;;
    *) warn "无效协议类型，已使用 unknown。" ;;
  esac
  if ! prompt_read "代理/业务软件名称，可留空："; then return 1; fi
  CONTEXT_PROXY_SOFTWARE="$(safe_report_text "$PROMPT_REPLY")"
  if ! prompt_read "业务路径描述，可留空："; then return 1; fi
  CONTEXT_TRAFFIC_PATH="$(safe_report_text "$PROMPT_REPLY")"
  normalize_link_context "$CONTEXT_MACHINE_ROLE" "$CONTEXT_CRITICAL_DIRECTION" "$CONTEXT_PROTOCOL_CLASS" "$CONTEXT_PROXY_SOFTWARE" "$CONTEXT_TRAFFIC_PATH" >/dev/null
}

run_client_advanced_diagnosis() {
  host="$1"
  iperf_port="$2"
  clear_screen
  print_header "高级链路诊断"
  ui_subtitle "只读采集 PMTU、qdisc drop/backlog、P1 单流和 P4 多流容量，不写系统参数。"
  prompt_link_context || {
    [ "$MENU_RETURNED" = "1" ] && return 0
    return 1
  }
  echo
  ui_note "强干预" "不会修改 MTU、防火墙、路由、TBF/HTB 或 qos-agent。"
  if ! prompt_read "按回车开始高级诊断，输入 0 返回主菜单："; then return 1; fi
  if is_back_choice "$PROMPT_REPLY"; then
    return_to_menu
    return 0
  fi
  advanced_diagnose_mode --host "$host" --port "$iperf_port" \
    --machine-role "$CONTEXT_MACHINE_ROLE" --critical-direction "$CONTEXT_CRITICAL_DIRECTION" \
    --protocol-class "$CONTEXT_PROTOCOL_CLASS" --proxy-software "$CONTEXT_PROXY_SOFTWARE" \
    --traffic-path "$CONTEXT_TRAFFIC_PATH"
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
    ui_menu_item "0" "预制参数写入" "先检测双端基础信息，再推荐五档参数" "$COLOR_YELLOW"
    ui_menu_item "1" "稳定自动优化" "规则固定，自动测速迭代" "$COLOR_GREEN"
    echo
    ui_menu_group "状态"
    ui_menu_item "3" "查看本机状态" "系统 / TCP 参数"
    ui_menu_item "4" "查看服务端状态" "会话 / 测速服务"
    ui_menu_item "5" "查看过程记录" "中文摘要日志"
    ui_menu_item "a" "高级链路诊断" "PMTU / qdisc / P1 / P4，只读不写入"
    echo
    ui_menu_group "测速"
    ui_menu_item "8" "iperf3 速度测试" "简单测速，不修改参数" "$COLOR_CYAN"
    echo
    ui_menu_group "退出"
    ui_menu_item "6" "回滚最近修改" "恢复最近一次参数写入" "$COLOR_YELLOW"
    ui_menu_item "9" "恢复默认值" "$(defaults_menu_tag "$peer" "$token")" "$COLOR_YELLOW"
    ui_menu_item "7" "停止会话并退出" "清理 Agent / iperf3" "$COLOR_YELLOW"
    ui_menu_item "q" "退出客户端" "不停止服务端会话" "$COLOR_DIM"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入，客户端已保持连接上报后退出菜单。"
      return 0
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      0) MENU_RETURNED="0"; preset_write_menu "$host" "$iperf_port" "$allow_same_public" || warn "预制参数流程未完成。"; [ "$MENU_RETURNED" = "1" ] || pause_for_enter ;;
      1) MENU_RETURNED="0"; run_client_optimization "$host" "$iperf_port" "$allow_same_public" || warn "自动优化流程未完成。"; [ "$MENU_RETURNED" = "1" ] || pause_for_enter ;;
      3) clear_screen; print_header "本机状态"; status_full || warn "读取本机状态失败。"; pause_for_enter ;;
      4) clear_screen; print_header "服务端状态"; get_agent_json "$peer/status" "$token" || warn "读取服务端状态失败。"; pause_for_enter ;;
      5) clear_screen; print_header "过程记录"; render_agent_events_summary "$peer" "$token" || warn "读取服务端事件失败。"; pause_for_enter ;;
      a|A) MENU_RETURNED="0"; run_client_advanced_diagnosis "$host" "$iperf_port" || warn "高级诊断流程未完成。"; [ "$MENU_RETURNED" = "1" ] || pause_for_enter ;;
      6)
        clear_screen
        print_header "回滚最近修改"
        if ( rollback_last ); then
          post_client_stage "rollback" "success" "已回滚最近修改"
        else
          warn "回滚失败或没有可用备份。"
          post_client_stage "rollback" "failed" "没有可用备份"
        fi
        pause_for_enter
        ;;
      7) post_json "$peer/stop" "$token" "{}" || true; exit 0 ;;
      8) run_iperf3_speedtest "$host" "$iperf_port" || warn "iperf3 测速未完成。"; pause_for_enter ;;
      9) restore_defaults_menu "$peer" "$token" || warn "恢复默认值流程未完成。"; pause_for_enter ;;
      q|Q) exit 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}
