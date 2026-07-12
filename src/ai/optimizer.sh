# Module: src/ai/optimizer.sh
ai_decision_for_summary() {
  summary="$1"
  objective="$2"
  role="$3"
  model="$4"
  prompt_summary="$summary"
  printf '%s' "$prompt_summary" | ai_python_client decide "$model" "$objective" "$role"
}

apply_ai_decision() {
  role="$1"
  normalized="$2"
  load_normalized_decision "$normalized"
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
  machine_role="endpoint"
  critical_direction="download"
  protocol_class="unknown"
  proxy_software=""
  traffic_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --peer|--host) require_option_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --port|--iperf-port) require_option_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --objective) require_option_value "$1" "${2:-}"; objective="$2"; shift 2 ;;
      --rounds) require_option_value "$1" "${2:-}"; rounds="$2"; shift 2 ;;
      --role) require_option_value "$1" "${2:-}"; role="$2"; shift 2 ;;
      --seconds) require_option_value "$1" "${2:-}"; seconds="$2"; shift 2 ;;
      --machine-role) require_option_value "$1" "${2:-}"; machine_role="$2"; shift 2 ;;
      --critical-direction) require_option_value "$1" "${2:-}"; critical_direction="$2"; shift 2 ;;
      --protocol-class) require_option_value "$1" "${2:-}"; protocol_class="$2"; shift 2 ;;
      --proxy-software) require_option_value "$1" "${2:-}"; proxy_software="$2"; shift 2 ;;
      --traffic-path) require_option_value "$1" "${2:-}"; traffic_path="$2"; shift 2 ;;
      *) die "未知 AI自动优化 参数：$1" ;;
    esac
  done
  [ -n "$host" ] || die "AI自动优化 需要 --host"
  # 兼容旧版本的 balanced；新语义统一为“快速起速”。
  [ "$objective" = "balanced" ] && objective="startup"
  case "$objective" in startup|throughput|retrans) ;; *) die "--objective 只支持 startup、throughput、retrans" ;; esac
  case "$objective" in
    retrans) target_retr="0" ;;
    throughput) target_retr="10" ;;
    startup) target_retr="5" ;;
  esac
  context_line="$(normalize_link_context "$machine_role" "$critical_direction" "$protocol_class" "$proxy_software" "$traffic_path")"
  machine_role="$(printf '%s\n' "$context_line" | cut -f1)"
  critical_direction="$(printf '%s\n' "$context_line" | cut -f2)"
  protocol_class="$(printf '%s\n' "$context_line" | cut -f3)"
  proxy_software="$(printf '%s\n' "$context_line" | cut -f4)"
  traffic_path="$(printf '%s\n' "$context_line" | cut -f5)"
  validate_port_value "$port" || die "--port 必须在 1 和 65535 之间。"
  validate_positive_int_range "$rounds" 1 "$TCP_TUNE_AI_MAX_ROUNDS" || die "--rounds 必须在 1 和 $TCP_TUNE_AI_MAX_ROUNDS 之间。"
  validate_positive_int_range "$seconds" 5 60 || die "--seconds 必须在 5 和 60 之间。"

  need_root
  ai_require_env
  install_runtime_deps
  detect_os
  [ "$OS_FAMILY" != "macos" ] || macos_write_unsupported
  ensure_tcp_baseline
  if [ "$role" = "auto" ]; then
    if [ "$OS_FAMILY" = "openwrt" ]; then role="openwrt"; else role="vps"; fi
  fi
  case "$role" in vps|openwrt) ;; *) die "--role 只支持 auto、vps、openwrt" ;; esac

  clear_screen
  print_header "AI 自动调参"
  ui_row "角色" "$role"
  ui_row "业务角色" "$machine_role"
  ui_row "关键方向" "$critical_direction"
  ui_row "协议类型" "$protocol_class"
  ui_row "对端" "$host"
  ui_row "目标" "$objective"
  ui_row "轮数" "$rounds"
  ui_note "安全边界" "AI 不能执行任意命令，只能触发脚本内置白名单动作。"
  post_client_stage "ai" "running" "$(objective_label "$objective")"

  if model="$(ai_select_model 2>/dev/null)"; then
    :
  else
    model="内置保守策略"
    warn "AI 网关暂时不可用，将使用内置保守策略继续。"
  fi
  ui_row "模型" "$model"

  round=1
  previous_summary=""
  ai_rolled_back="0"
  ai_write_skipped="0"
  while [ "$round" -le "$rounds" ]; do
    echo
    ui_section "第 $round/$rounds 轮基线"
    rtt_round_before="$(detect_rtt_ms "$host")"
    if [ "$round" = "1" ]; then iface="$(route_iface_for_host "$host")"; fi
    qdisc_round_before="$(qdisc_stats "${iface:-unknown}")"
    summary="$(ai_measure_pair "$host" "$port" "$seconds")"
    if [ "$round" = "1" ]; then
      iface="$(route_iface_for_host "$host")"
      pmtu="$(probe_pmtu "$host")"
      qdisc_before="$(qdisc_stats "$iface")"
      ui_note "链路证据" "iface=$iface pmtu=$pmtu qdisc=$(printf '%s' "$qdisc_before")"
      if [ "$protocol_class" = "udp-quic" ]; then
        ui_note "协议提醒" "UDP/QUIC 场景下 TCP 调参只作为间接建议，重点看 PMTU/qdisc/CPU。"
      fi
    fi
    summary_for_ai="$(printf '%s' "$summary" | sed 's/}$//')"
    proxy_software_json="$(printf '%s' "$proxy_software" | json_escape_string)"
    traffic_path_json="$(printf '%s' "$traffic_path" | json_escape_string)"
    qdisc_before_json="$(safe_report_text "${qdisc_before:-unknown unknown}" | json_escape_string)"
    summary_for_ai="$summary_for_ai,\"machine_role\":\"$machine_role\",\"critical_direction\":\"$critical_direction\",\"protocol_class\":\"$protocol_class\",\"proxy_software\":\"$proxy_software_json\",\"traffic_path\":\"$traffic_path_json\",\"pmtu\":\"${pmtu:-unknown}\",\"qdisc_before\":\"$qdisc_before_json\"}"
    print_ai_summary_metrics "测速摘要" "$summary"
    if [ "$model" = "内置保守策略" ]; then
      decision="$(ai_fallback_decision_json "$objective" "$role")"
      ui_note "AI 状态" "未连接到 AI 网关，本轮使用内置保守策略。"
    elif decision="$(ai_decision_for_summary "$summary_for_ai" "$objective" "$role" "$model" 2>/dev/null)"; then
      :
    else
      decision="$(ai_fallback_decision_json "$objective" "$role")"
      ui_note "AI 状态" "AI 网关超时或返回异常，本轮使用内置保守策略。"
    fi
    normalized_decision="$(printf '%s' "$decision" | ai_python_client normalize "$role" 2>/dev/null)" || {
      decision="$(ai_fallback_decision_json "$objective" "$role")"
      normalized_decision="$(printf '%s' "$decision" | ai_python_client normalize "$role")" || die "内置策略解析失败。"
    }
    normalized_decision="$(objective_clamp_ai_decision "$role" "$objective" "$normalized_decision")"
    print_ai_decision_summary "$role" "$objective" "$normalized_decision"
    if [ "$protocol_class" = "udp-quic" ]; then
      ui_note "写入策略" "当前协议类型为 UDP/QUIC，本轮只输出建议，不写 TCP sysctl。"
      ai_write_skipped="1"
      break
    fi
    previous_summary="$summary"
    apply_ai_decision "$role" "$normalized_decision"
    current_backup="$LAST_MANUAL_BACKUP"

    echo
    ui_section "复测"
    after_summary="$(ai_measure_pair "$host" "$port" "$seconds")"
    rtt_round_after="$(detect_rtt_ms "$host")"
    qdisc_round_after="$(qdisc_stats "${iface:-unknown}")"
    qdisc_round_delta="$(qdisc_delta "$qdisc_round_before" "$qdisc_round_after")"
    old_ifs="$IFS"; IFS=' '
    read -r round_drop round_backlog <<EOF
$qdisc_round_delta
EOF
    IFS="$old_ifs"
    round_guard_ok=1
    if is_unsigned_integer "$rtt_round_before" && is_unsigned_integer "$rtt_round_after"; then
      if awk -v before="$rtt_round_before" -v after="$rtt_round_after" 'BEGIN {exit !(before > 0 && after > before * 1.15 && after - before > 5)}'; then round_guard_ok=0; fi
    fi
    if is_unsigned_integer "$round_drop" && [ "$round_drop" -gt 10 ]; then round_guard_ok=0; fi
    if is_unsigned_integer "$round_backlog" && [ "$round_backlog" -gt 65536 ]; then round_guard_ok=0; fi
    print_ai_summary_metrics "复测摘要" "$after_summary"
    print_ai_comparison_table "$previous_summary" "$after_summary"
    ui_note "RTT/qdisc" "${rtt_round_before:-unknown}ms → ${rtt_round_after:-unknown}ms；drop=${round_drop:-unknown} backlog=${round_backlog:-unknown}"
    if [ "$round_guard_ok" != "1" ]; then
      warn "RTT 或 qdisc 护栏触发，正在回滚本轮 AI 调整。"
      restore_manual_backup "$current_backup"
      post_client_stage "ai" "rollback" "$(objective_label "$objective")"
      ai_rolled_back="1"
      break
    fi
    if summary_regressed "$objective" "$previous_summary" "$after_summary"; then
      warn "复测指标退化超过阈值，正在回滚本轮 AI 调整。"
      restore_manual_backup "$current_backup"
      post_client_stage "ai" "rollback" "$(objective_label "$objective")"
      ai_rolled_back="1"
      break
    fi
    if ! summary_objective_succeeded "$objective" "$previous_summary" "$after_summary" "$target_retr"; then
      warn "本轮 AI 调整没有达成目标指标，正在回滚本轮参数。"
      restore_manual_backup "$current_backup"
      post_client_stage "ai" "rollback" "$(objective_label "$objective")"
      ai_rolled_back="1"
      break
    fi
    ui_note "目标判定" "$(summary_objective_note "$objective" "$previous_summary" "$after_summary")"
    ui_note "结果" "本轮调整通过复测，继续下一轮或结束。"
    round=$((round + 1))
  done
  echo
  ui_section "完成"
  ui_row "最终角色" "$role"
  ui_row "模型" "$model"
  if [ "$ai_write_skipped" = "1" ]; then
    post_client_stage "ai" "ok" "UDP/QUIC 仅诊断"
    report_path="$(write_tuning_profile "AI $(objective_label "$objective") 建议" "$machine_role" "$critical_direction" "$protocol_class" "$host" "$objective summary" "not-run" "${pmtu:-unknown}" "drop=unknown backlog=unknown" "no-write protocol-class=udp-quic" "" "UDP/QUIC 场景未写 TCP sysctl，仅输出诊断建议。")"
    ui_note "报告" "$report_path"
  elif [ "$ai_rolled_back" = "1" ]; then
    :
  else
    post_client_stage "ai" "success" "$(objective_label "$objective")"
    qdisc_after="$(qdisc_stats "${iface:-unknown}")"
    qdisc_delta_values="$(qdisc_delta "${qdisc_before:-unknown unknown}" "$qdisc_after")"
    # shellcheck disable=SC2086
    set -- $qdisc_delta_values
    drop_delta="${1:-unknown}"
    backlog_delta="${2:-unknown}"
    report_path="$(write_tuning_profile "AI $(objective_label "$objective")" "$machine_role" "$critical_direction" "$protocol_class" "$host" "$objective summary" "not-run" "${pmtu:-unknown}" "drop=$drop_delta backlog=$backlog_delta" "AI role=$role model=$model" "$LAST_MANUAL_BACKUP" "AI 调整通过目标复测。")"
    ui_note "报告" "$report_path"
  fi
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
  summary="$(cat "$summary_file")"
  if model="$(ai_select_model 2>/dev/null)"; then
    ai_decision_for_summary "$summary" "$objective" "$role" "$model" 2>/dev/null || ai_fallback_decision_json "$objective" "$role"
  else
    warn "AI 网关暂时不可用，输出内置保守策略。"
    ai_fallback_decision_json "$objective" "$role"
  fi
}
