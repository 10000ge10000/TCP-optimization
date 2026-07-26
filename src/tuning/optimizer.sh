# Module: src/tuning/optimizer.sh
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
        notsent="$(awk -v n="$notsent" 'BEGIN {v=int(n*1.25); if(v>524288) v=524288; printf "%d", v}')"
        if [ "$adv" -gt 1 ]; then
          adv="$(awk -v a="$adv" 'BEGIN {v=a-1; if(v<1) v=1; printf "%d", v}')"
        fi
      fi
      ;;
    startup)
      notsent="$(awk -v n="$notsent" 'BEGIN {
        if (n > 65536) v=int(n*0.75); else v=int(n*0.90)
        if (v < 16384) v=16384
        if (v > 65536) v=65536
        printf "%d", v
      }')"
      wmem="$(awk -v w="$wmem" -v min="$min_wmem" 'BEGIN {v=w; if(v<min) v=min; printf "%d", v}')"
      rmem="$(awk -v r="$rmem" -v min="$min_rmem" 'BEGIN {v=r; if(v<min) v=min; printf "%d", v}')"
      adv="$(awk -v a="$adv" 'BEGIN {v=a; if(v<2) v=2; if(v>3) v=3; printf "%d", v}')"
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
  machine_role="endpoint"
  critical_direction="download"
  protocol_class="unknown"
  proxy_software=""
  traffic_path=""
  if [ "$#" -ge 10 ]; then
    shift 9
    memory_mb_value="${1:-}"
    [ "$#" -ge 2 ] && ramp_rate="${2:-0.79}"
    [ "$#" -ge 3 ] && aggressive="${3:-0}"
    [ "$#" -ge 4 ] && allow_same_public="${4:-0}"
    [ "$#" -ge 5 ] && machine_role="${5:-endpoint}"
    [ "$#" -ge 6 ] && critical_direction="${6:-download}"
    [ "$#" -ge 7 ] && protocol_class="${7:-unknown}"
    [ "$#" -ge 8 ] && proxy_software="${8:-}"
    [ "$#" -ge 9 ] && traffic_path="${9:-}"
  fi

  case "$objective" in
    retrans|throughput|startup) ;;
    *) die "--objective 只支持 retrans、throughput、startup" ;;
  esac
  context_line="$(normalize_link_context "$machine_role" "$critical_direction" "$protocol_class" "$proxy_software" "$traffic_path")"
  machine_role="$(printf '%s\n' "$context_line" | cut -f1)"
  critical_direction="$(printf '%s\n' "$context_line" | cut -f2)"
  protocol_class="$(printf '%s\n' "$context_line" | cut -f3)"
  proxy_software="$(printf '%s\n' "$context_line" | cut -f4)"
  traffic_path="$(printf '%s\n' "$context_line" | cut -f5)"
  if [ "$protocol_class" = "udp-quic" ]; then
    die "protocol-class=udp-quic 时不默认执行 TCP buffer 写入；请先运行 advanced-diagnose 获取 PMTU/qdisc/P1/P4 证据。"
  fi
  need_root
  install_runtime_deps
  detect_os
  [ "$OS_FAMILY" != "macos" ] || macos_write_unsupported
  ensure_tcp_baseline
  auto_initial_backup="$(manual_backup_begin "auto-$objective" 2>/dev/null || true)"
  [ -n "$memory_mb_value" ] || memory_mb_value="$(memory_mb)"
  local_public_ip="$(public_ip || true)"
  if [ "$allow_same_public" != "1" ] && [ -n "$local_public_ip" ] && [ "$host" = "$local_public_ip" ]; then
    warn "对端地址 $host 与本机公网出口 $local_public_ip 相同，可能是代理出口/NAT hairpin；已按真实链路继续测试。"
  fi

  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in
    127.*|localhost|"$bind_ip") bind_ip="" ;;
  esac
  route_iface="$(route_iface_for_host "$host")"
  route_mtu="$(iface_mtu "$route_iface")"
  route_pmtu="$(probe_pmtu "$host")"
  qdisc_before="$(qdisc_stats "$route_iface")"
  mode_name="$(objective_label "$objective")"
  transfer_name="$(direction_label "$reverse")"
  display_local_ip="${bind_ip:-$(local_lan_ipv4 || true)}"
  [ -n "$display_local_ip" ] || display_local_ip="未识别"
  TUNE_SIMPLE_OUTPUT=1

  clear_screen
  print_header "正在优化 · $mode_name"
  ui_subtitle "$transfer_name · 本机 $display_local_ip · 第 1/$rounds 轮"
  post_client_stage "auto" "running" "$mode_name"
  echo
  ui_section "优化概览"
  ui_row "模式" "$mode_name"
  ui_row "方向" "$transfer_name"
  ui_row "机器角色" "$machine_role"
  ui_row "协议类型" "$protocol_class"
  ui_row "本机地址" "$display_local_ip"
  ui_row "测速节点" "已连接的服务端"
  ui_row "PMTU/接口" "$route_pmtu / $route_iface mtu=$route_mtu"
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
  previous_rtt=""
  previous_qdisc="$qdisc_before"
  OBJECTIVE_GUARD_OK=1
  while [ "$i" -le "$rounds" ]; do
    echo
    ui_section "第 $i/$rounds 轮测试"
    progress_steps "$i" "$rounds"
    ui_note "状态" "正在执行 $TCP_TUNE_SAMPLE_COUNT 次 iperf3 测试并计算中位数..."
    sample_rc=0
    sample_metrics="$(measure_iperf_samples "$host" "$port" "$reverse" 20 "$bind_ip" 1 "$TCP_TUNE_SAMPLE_COUNT")" || sample_rc="$?"
    if [ "$sample_rc" != "0" ]; then
      if [ "$applied_change_count" -gt 0 ]; then
        rollback_last >/dev/null 2>&1 || true
      fi
      if [ "$sample_rc" = "2" ]; then
        DIE_EXIT_CODE="$EXIT_BENCHMARK" die "测速离散度超过 ${TCP_TUNE_MAX_SPREAD_PERCENT}%，结果不稳定，已回滚本轮参数。"
      fi
      DIE_EXIT_CODE="$EXIT_BENCHMARK" die "iperf3 多样本测速失败或关键指标未检测，已回滚本轮参数。"
    fi
    tab="$(printf '\t')"
    old_ifs="$IFS"; IFS="$tab"
    read -r bps retr startup_bps sample_spread <<EOF
$sample_metrics
EOF
    IFS="$old_ifs"
    current_rtt="$(detect_rtt_ms "$host")"
    current_qdisc="$(qdisc_stats "$route_iface")"
    guard_delta="$(qdisc_delta "$previous_qdisc" "$current_qdisc")"
    old_ifs="$IFS"; IFS=' '
    read -r guard_drop guard_backlog <<EOF
$guard_delta
EOF
    IFS="$old_ifs"
    OBJECTIVE_GUARD_OK=1
    if is_unsigned_integer "$previous_rtt" && is_unsigned_integer "$current_rtt"; then
      if awk -v before="$previous_rtt" -v after="$current_rtt" 'BEGIN {exit !(before > 0 && after > before * 1.15 && after - before > 5)}'; then
        OBJECTIVE_GUARD_OK=0
      fi
    fi
    if is_unsigned_integer "$guard_drop" && [ "$guard_drop" -gt 10 ]; then OBJECTIVE_GUARD_OK=0; fi
    if is_unsigned_integer "$guard_backlog" && [ "$guard_backlog" -gt 65536 ]; then OBJECTIVE_GUARD_OK=0; fi
    if [ "$bps" = "0" ] && [ "$i" = "1" ]; then
      DIE_EXIT_CODE="$EXIT_BENCHMARK" die "iperf3 中位速率为 0，请检查网络连通性。"
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
    metric_line "样本离散" "${sample_spread}%" "info"
    metric_line "RTT" "${current_rtt:-unknown}ms" "info"
    metric_line "qdisc 增量" "drop=${guard_drop:-unknown} backlog=${guard_backlog:-unknown}" "info"
    if [ "$objective" = "startup" ]; then
      metric_line "首秒速度" "$(format_rate "$startup_bps")" "warn"
    fi
    if [ -n "${TUNE_REPORT_PEER:-}" ] && [ -n "${TUNE_REPORT_TOKEN:-}" ]; then
      report_direction="download"
      [ "$reverse" = "0" ] && report_direction="upload"
      report_data="{\"role\":\"client-result\",\"lan_ip\":$(json_string "${TUNE_CLIENT_IP:-$display_local_ip}"),\"round\":$i,\"rounds\":$rounds,\"objective\":$(json_string "$objective"),\"direction\":$(json_string "$report_direction"),\"retransmits\":$retr,\"bits_per_second\":$bps,\"first_second_bits_per_second\":$startup_bps,\"time\":$(date +%s)}"
      post_json "$TUNE_REPORT_PEER/report" "$TUNE_REPORT_TOKEN" "$report_data" >/dev/null 2>&1 || true
    fi

    if [ "$applied_change_count" -gt 0 ] && [ -n "$previous_retr" ]; then
      if objective_step_improved "$objective" "$previous_bps" "$bps" "$previous_retr" "$retr" "$previous_startup_bps" "$startup_bps" "$target_retr"; then
        ui_note "验证" "上一轮写入已让目标指标改善，保留本轮参数。"
      else
        warn "上一轮写入没有让目标指标改善，正在撤销这次参数调整。"
        rollback_last
        applied_change_count=$((applied_change_count - 1))
        rolled_back_regression="1"
        final_retr="$previous_retr"
        final_bps="$previous_bps"
        final_startup_bps="$previous_startup_bps"
        break
      fi
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
        echo
        if [ "$applied_change_count" -gt 0 ]; then
          ui_note "结果" "目标已达成，进入结果页。"
        else
          ui_note "结果" "基线已达到重传目标，不写入额外参数。"
        fi
        break
      fi
    fi
    if [ "$i" -ge "$rounds" ]; then
      echo
      if [ "$applied_change_count" -gt 0 ]; then
        ui_note "结果" "已达到最大轮数，保留最后一次已复测通过的参数。"
      else
        ui_note "结果" "已完成基线测试，本轮没有写入参数。"
      fi
      break
    fi

    step_values="$(tune_step "$objective" "$retr" "$bps" "$target_retr" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive")"
    old_ifs="$IFS"; IFS=' '
    read -r step_rmem step_wmem step_adv step_notsent step_backlog step_somax step_syn step_optmem <<EOF
$step_values
EOF
    IFS="$old_ifs"
    apply_buffers "$step_rmem" "$step_wmem" "$step_adv" "$step_notsent" "$step_backlog" "$step_somax" "$step_syn" "$step_optmem"
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
    previous_rtt="$current_rtt"
    previous_qdisc="$current_qdisc"
    i=$((i + 1))
  done
  [ "$completed_rounds" = "0" ] && completed_rounds="$rounds"
  if [ "$applied_change_count" -gt 0 ] && [ -n "${auto_initial_backup:-}" ]; then
    if objective_numbers_regressed "$objective" "${first_bps:-0}" "$final_bps" "${first_retr:-0}" "$final_retr" "${first_startup_bps:-0}" "$final_startup_bps" "$target_retr"; then
      restore_manual_backup "$auto_initial_backup" >/dev/null 2>&1 || true
      rolled_back_regression="1"
      applied_change_count="0"
      final_retr="${first_retr:-0}"
      final_bps="${first_bps:-0}"
      final_startup_bps="${first_startup_bps:-0}"
    fi
  fi
  if [ "$applied_change_count" -gt 0 ] && [ -n "${auto_initial_backup:-}" ]; then
    if ! objective_run_succeeded "$objective" "${first_bps:-0}" "$final_bps" "${first_retr:-0}" "$final_retr" "${first_startup_bps:-0}" "$final_startup_bps" "$target_retr"; then
      restore_manual_backup "$auto_initial_backup" >/dev/null 2>&1 || true
      rolled_back_regression="1"
      applied_change_count="0"
      final_retr="${first_retr:-0}"
      final_bps="${first_bps:-0}"
      final_startup_bps="${first_startup_bps:-0}"
    fi
  fi
  qdisc_after="$(qdisc_stats "$route_iface")"
  qdisc_delta_values="$(qdisc_delta "$qdisc_before" "$qdisc_after")"
  # shellcheck disable=SC2086
  set -- $qdisc_delta_values
  qdisc_drop_delta="${1:-unknown}"
  qdisc_backlog_delta="${2:-unknown}"
  if [ "$rolled_back_regression" = "1" ]; then
    post_client_stage "auto" "rollback" "$mode_name"
  else
    post_client_stage "auto" "success" "$mode_name"
  fi
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
        warn "已完成 $completed_rounds 轮，重传尚未降至目标值。"
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
  ui_note "qdisc delta" "drop=$qdisc_drop_delta backlog=$qdisc_backlog_delta"
  if [ "$final_retr" -gt "$target_retr" ] && [ "$qdisc_drop_delta" = "0" ] && [ "$qdisc_backlog_delta" = "0" ]; then
    ui_note "诊断" "重传仍高但本机 qdisc 无 drop/backlog 增量，更可能是路径、对端或上游拥塞。"
  fi
  if [ "$rolled_back_regression" = "1" ] && [ "$applied_change_count" -eq 0 ]; then
    ui_note "已回退" "最新调整表现退化，已恢复优化前配置。"
    ui_note "回滚" "没有保留本次参数修改。"
  elif [ "$rolled_back_regression" = "1" ]; then
    ui_note "已回退" "已撤销最新退化调整，保留前一轮更优配置。"
    ui_note "回滚" "保留的调整仍可通过 rollback 命令恢复。"
  elif [ "$applied_change_count" -gt 0 ]; then
    ui_note "已保存" "仅保留经过下一轮复测的参数调整。"
    ui_note "回滚" "已创建备份，可在客户端菜单或 rollback 命令中恢复。"
    params_text="rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown) wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown) notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo unknown) limit=$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo unknown)"
    report_path="$(write_tuning_profile "$mode_name" "$machine_role" "$critical_direction" "$protocol_class" "$host" "$transfer_name $(format_rate "$final_bps") retr=$final_retr first=$(format_rate "$final_startup_bps")" "not-run" "$route_pmtu" "drop=$qdisc_drop_delta backlog=$qdisc_backlog_delta" "$params_text" "$auto_initial_backup" "目标指标通过复测，保留本轮参数。")"
    ui_note "报告" "$report_path"
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
