# Module: src/ai/schema.sh
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
  objective="$1"
  before="$2"
  after="$3"
  before_up="$(printf '%s\n' "$before" | metric_from_summary upload_bits_per_second)"
  after_up="$(printf '%s\n' "$after" | metric_from_summary upload_bits_per_second)"
  before_down="$(printf '%s\n' "$before" | metric_from_summary download_bits_per_second)"
  after_down="$(printf '%s\n' "$after" | metric_from_summary download_bits_per_second)"
  before_ur="$(printf '%s\n' "$before" | metric_from_summary upload_retransmits)"
  after_ur="$(printf '%s\n' "$after" | metric_from_summary upload_retransmits)"
  before_dr="$(printf '%s\n' "$before" | metric_from_summary download_retransmits)"
  after_dr="$(printf '%s\n' "$after" | metric_from_summary download_retransmits)"
  before_uf="$(printf '%s\n' "$before" | metric_from_summary upload_first_second_bits_per_second)"
  after_uf="$(printf '%s\n' "$after" | metric_from_summary upload_first_second_bits_per_second)"
  before_df="$(printf '%s\n' "$before" | metric_from_summary download_first_second_bits_per_second)"
  after_df="$(printf '%s\n' "$after" | metric_from_summary download_first_second_bits_per_second)"
  awk -v bu="${before_up:-0}" -v au="${after_up:-0}" -v bd="${before_down:-0}" -v ad="${after_down:-0}" \
      -v bur="${before_ur:-0}" -v aur="${after_ur:-0}" -v bdr="${before_dr:-0}" -v adr="${after_dr:-0}" \
      -v buf="${before_uf:-0}" -v auf="${after_uf:-0}" -v bdf="${before_df:-0}" -v adf="${after_df:-0}" \
      -v objective="$objective" '
    BEGIN {
      bad = 0
      before_speed = bu + bd
      after_speed = au + ad
      before_retr = bur + bdr
      after_retr = aur + adr
      before_first = buf + bdf
      after_first = auf + adf
      if (objective == "retrans") {
        if (before_retr > 100 && after_retr > before_retr * 1.20) bad = 1
        if (before_retr <= 100 && after_retr > before_retr + 200) bad = 1
        if (before_speed > 0 && after_speed < before_speed * 0.85) bad = 1
      } else if (objective == "throughput") {
        if (before_speed > 0 && after_speed < before_speed * 0.95) bad = 1
        if (before_speed > 0 && after_speed < before_speed * 1.03 && before_retr > 100 && after_retr > before_retr * 1.35) bad = 1
        if (before_retr <= 100 && after_retr > 1000 && before_speed > 0 && after_speed < before_speed * 1.05) bad = 1
      } else {
        if (buf > 0 && auf < buf * 0.90) bad = 1
        if (bdf > 0 && adf < bdf * 0.90) bad = 1
        if (before_first > 0 && after_first < before_first * 0.95) bad = 1
        if (before_speed > 0 && after_speed < before_speed * 0.80) bad = 1
        if (before_retr > 100 && after_retr > before_retr * 2.0 && after_retr > 500) bad = 1
      }
      exit !bad
    }
  '
}

summary_objective_succeeded() {
  objective="$1"
  before="$2"
  after="$3"
  target_retr="${4:-0}"
  before_up="$(printf '%s\n' "$before" | metric_from_summary upload_bits_per_second)"
  after_up="$(printf '%s\n' "$after" | metric_from_summary upload_bits_per_second)"
  before_down="$(printf '%s\n' "$before" | metric_from_summary download_bits_per_second)"
  after_down="$(printf '%s\n' "$after" | metric_from_summary download_bits_per_second)"
  before_ur="$(printf '%s\n' "$before" | metric_from_summary upload_retransmits)"
  after_ur="$(printf '%s\n' "$after" | metric_from_summary upload_retransmits)"
  before_dr="$(printf '%s\n' "$before" | metric_from_summary download_retransmits)"
  after_dr="$(printf '%s\n' "$after" | metric_from_summary download_retransmits)"
  before_uf="$(printf '%s\n' "$before" | metric_from_summary upload_first_second_bits_per_second)"
  after_uf="$(printf '%s\n' "$after" | metric_from_summary upload_first_second_bits_per_second)"
  before_df="$(printf '%s\n' "$before" | metric_from_summary download_first_second_bits_per_second)"
  after_df="$(printf '%s\n' "$after" | metric_from_summary download_first_second_bits_per_second)"
  before_speed="$(awk -v up="${before_up:-0}" -v down="${before_down:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  after_speed="$(awk -v up="${after_up:-0}" -v down="${after_down:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  before_retr="$(awk -v up="${before_ur:-0}" -v down="${before_dr:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  after_retr="$(awk -v up="${after_ur:-0}" -v down="${after_dr:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  before_first="$(awk -v up="${before_uf:-0}" -v down="${before_df:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  after_first="$(awk -v up="${after_uf:-0}" -v down="${after_df:-0}" 'BEGIN { printf "%.0f\n", up + down }')"
  objective_run_succeeded "$objective" "$before_speed" "$after_speed" "$before_retr" "$after_retr" "$before_first" "$after_first" "$target_retr"
}

summary_objective_note() {
  objective="$1"
  before="$2"
  after="$3"
  before_up="$(printf '%s\n' "$before" | metric_from_summary upload_bits_per_second)"
  after_up="$(printf '%s\n' "$after" | metric_from_summary upload_bits_per_second)"
  before_down="$(printf '%s\n' "$before" | metric_from_summary download_bits_per_second)"
  after_down="$(printf '%s\n' "$after" | metric_from_summary download_bits_per_second)"
  before_ur="$(printf '%s\n' "$before" | metric_from_summary upload_retransmits)"
  after_ur="$(printf '%s\n' "$after" | metric_from_summary upload_retransmits)"
  before_dr="$(printf '%s\n' "$before" | metric_from_summary download_retransmits)"
  after_dr="$(printf '%s\n' "$after" | metric_from_summary download_retransmits)"
  before_uf="$(printf '%s\n' "$before" | metric_from_summary upload_first_second_bits_per_second)"
  after_uf="$(printf '%s\n' "$after" | metric_from_summary upload_first_second_bits_per_second)"
  before_df="$(printf '%s\n' "$before" | metric_from_summary download_first_second_bits_per_second)"
  after_df="$(printf '%s\n' "$after" | metric_from_summary download_first_second_bits_per_second)"
  awk -v bu="${before_up:-0}" -v au="${after_up:-0}" -v bd="${before_down:-0}" -v ad="${after_down:-0}" \
      -v bur="${before_ur:-0}" -v aur="${after_ur:-0}" -v bdr="${before_dr:-0}" -v adr="${after_dr:-0}" \
      -v buf="${before_uf:-0}" -v auf="${after_uf:-0}" -v bdf="${before_df:-0}" -v adf="${after_df:-0}" \
      -v objective="$objective" '
    BEGIN {
      before_speed = bu + bd
      after_speed = au + ad
      before_retr = bur + bdr
      after_retr = aur + adr
      before_first = buf + bdf
      after_first = auf + adf
      speed_delta = before_speed > 0 ? (after_speed - before_speed) * 100 / before_speed : 0
      first_delta = before_first > 0 ? (after_first - before_first) * 100 / before_first : 0
      if (objective == "retrans") {
        if (after_retr <= before_retr || after_retr <= 100) print "重传未恶化或已压低，保留本轮参数。"
        else print "重传仍偏高，下一轮继续收缩排队。"
      } else if (objective == "throughput") {
        if (speed_delta >= 3) print "吞吐提升 " sprintf("%.0f%%", speed_delta) "，重传在可控范围内。"
        else print "吞吐未明显提升，下一轮会更保守。"
      } else {
        if (before_first > 0 && first_delta >= 0) print "首秒速度未下降，保留低排队参数。"
        else print "起速未显著改善，下一轮继续压低排队。"
      }
    }
  '
}

print_ai_summary_metrics() {
  title="$1"
  summary="$2"
  up="$(printf '%s\n' "$summary" | metric_from_summary upload_bits_per_second)"
  ur="$(printf '%s\n' "$summary" | metric_from_summary upload_retransmits)"
  uf="$(printf '%s\n' "$summary" | metric_from_summary upload_first_second_bits_per_second)"
  down="$(printf '%s\n' "$summary" | metric_from_summary download_bits_per_second)"
  dr="$(printf '%s\n' "$summary" | metric_from_summary download_retransmits)"
  df="$(printf '%s\n' "$summary" | metric_from_summary download_first_second_bits_per_second)"
  ui_section "$title"
  ui_row "上传速度" "$(format_rate "${up:-0}")"
  ui_row "上传重传" "$(format_count "${ur:-0}") 次"
  [ "${uf:-0}" = "0" ] || ui_row "上传首秒" "$(format_rate "$uf")"
  ui_row "下载速度" "$(format_rate "${down:-0}")"
  ui_row "下载重传" "$(format_count "${dr:-0}") 次"
  [ "${df:-0}" = "0" ] || ui_row "下载首秒" "$(format_rate "$df")"
}

print_ai_comparison_table() {
  before="$1"
  after="$2"
  before_up="$(printf '%s\n' "$before" | metric_from_summary upload_bits_per_second)"
  after_up="$(printf '%s\n' "$after" | metric_from_summary upload_bits_per_second)"
  before_ur="$(printf '%s\n' "$before" | metric_from_summary upload_retransmits)"
  after_ur="$(printf '%s\n' "$after" | metric_from_summary upload_retransmits)"
  before_uf="$(printf '%s\n' "$before" | metric_from_summary upload_first_second_bits_per_second)"
  after_uf="$(printf '%s\n' "$after" | metric_from_summary upload_first_second_bits_per_second)"
  before_down="$(printf '%s\n' "$before" | metric_from_summary download_bits_per_second)"
  after_down="$(printf '%s\n' "$after" | metric_from_summary download_bits_per_second)"
  before_dr="$(printf '%s\n' "$before" | metric_from_summary download_retransmits)"
  after_dr="$(printf '%s\n' "$after" | metric_from_summary download_retransmits)"
  before_df="$(printf '%s\n' "$before" | metric_from_summary download_first_second_bits_per_second)"
  after_df="$(printf '%s\n' "$after" | metric_from_summary download_first_second_bits_per_second)"

  ui_section "优化前后对比"
  printf "  %s%s │ %-14s │ %-14s │ %-10s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$(ui_pad "指标" 12)" "优化前" "优化后" "变化" "$COLOR_RESET"
  printf "  %s\n" "---------------------------------------------------------------"
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "上传速度" 12)" "$(format_rate "${before_up:-0}")" "$(format_rate "${after_up:-0}")" "$(percent_delta "${before_up:-0}" "${after_up:-0}")"
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "上传重传" 12)" "$(format_count "${before_ur:-0}") 次" "$(format_count "${after_ur:-0}") 次" "$(percent_delta "${before_ur:-0}" "${after_ur:-0}")"
  if [ "${before_uf:-0}" != "0" ] || [ "${after_uf:-0}" != "0" ]; then
    printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "上传首秒" 12)" "$(format_rate "${before_uf:-0}")" "$(format_rate "${after_uf:-0}")" "$(percent_delta "${before_uf:-0}" "${after_uf:-0}")"
  fi
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "下载速度" 12)" "$(format_rate "${before_down:-0}")" "$(format_rate "${after_down:-0}")" "$(percent_delta "${before_down:-0}" "${after_down:-0}")"
  printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "下载重传" 12)" "$(format_count "${before_dr:-0}") 次" "$(format_count "${after_dr:-0}") 次" "$(percent_delta "${before_dr:-0}" "${after_dr:-0}")"
  if [ "${before_df:-0}" != "0" ] || [ "${after_df:-0}" != "0" ]; then
    printf "  %s │ %-14s │ %-14s │ %-10s\n" "$(ui_pad "下载首秒" 12)" "$(format_rate "${before_df:-0}")" "$(format_rate "${after_df:-0}")" "$(percent_delta "${before_df:-0}" "${after_df:-0}")"
  fi
}

normalized_value() {
  normalized_text="$1"
  normalized_key="$2"
  normalized_default="$3"
  value="$(printf '%s\n' "$normalized_text" | awk -F= -v key="$normalized_key" '$1 == key {sub(/^[^=]*=/, ""); sub(/^\047/, ""); sub(/\047$/, ""); print; exit}')"
  [ -n "$value" ] || value="$normalized_default"
  printf '%s\n' "$value"
}

load_normalized_decision() {
  normalized_text="$1"
  vps_congestion="$(normalized_value "$normalized_text" vps_congestion cubic)"
  vps_mtu_probing="$(normalized_value "$normalized_text" vps_mtu_probing 1)"
  vps_slow_start="$(normalized_value "$normalized_text" vps_slow_start 0)"
  vps_rmem_max="$(normalized_value "$normalized_text" vps_rmem_max 67108864)"
  vps_wmem_max="$(normalized_value "$normalized_text" vps_wmem_max 67108864)"
  vps_notsent="$(normalized_value "$normalized_text" vps_notsent 1048576)"
  vps_limit="$(normalized_value "$normalized_text" vps_limit 1048576)"
  op_minimal="$(normalized_value "$normalized_text" op_minimal 1)"
  op_mtu_probing="$(normalized_value "$normalized_text" op_mtu_probing 1)"
  op_slow_start="$(normalized_value "$normalized_text" op_slow_start 0)"
  op_notsent="$(normalized_value "$normalized_text" op_notsent 1048576)"
  op_limit="$(normalized_value "$normalized_text" op_limit 1048576)"
  ai_reason="$(normalized_value "$normalized_text" ai_reason 未提供)"
}

print_ai_decision_summary() {
  role="$1"
  objective="$2"
  normalized="$3"
  load_normalized_decision "$normalized"
  ui_section "AI 建议摘要"
  case "$objective" in
    retrans) action="收紧发送队列，优先压低重传" ;;
    throughput) action="在可控重传下放宽吞吐空间" ;;
    startup) action="压低排队，优先改善首秒速度" ;;
    *) action="按链路结果做保守调整" ;;
  esac
  metric_line "本轮动作" "$action" "warn"
  case "$role" in
    vps)
      metric_line "调整范围" "VPS 对端 TCP 参数" "info"
      ;;
    openwrt)
      metric_line "调整范围" "本机 OpenWrt 最小 TCP 参数" "info"
      ;;
  esac
  metric_line "安全边界" "不执行任意命令，写入前备份，复测失败回滚" "good"
  metric_line "简要理由" "${ai_reason:-未提供}" "info"
}

objective_clamp_ai_decision() {
  role="$1"
  objective="$2"
  normalized="$3"
  # 逐字段读取白名单值，不把模型数据交给 shell eval。
  load_normalized_decision "$normalized"
  case "$role:$objective" in
    openwrt:startup)
      [ "${op_notsent:-0}" -gt 65536 ] && op_notsent=65536
      [ "${op_limit:-0}" -gt 262144 ] && op_limit=262144
      ai_reason="${ai_reason:-未提供}；已按快速起速目标收紧本机发送队列。"
      ;;
    openwrt:retrans)
      [ "${op_notsent:-0}" -gt 262144 ] && op_notsent=262144
      [ "${op_limit:-0}" -gt 524288 ] && op_limit=524288
      ai_reason="${ai_reason:-未提供}；已按重传优先目标收紧本机发送队列。"
      ;;
    vps:startup)
      [ "${vps_notsent:-0}" -gt 131072 ] && vps_notsent=131072
      [ "${vps_limit:-0}" -gt 262144 ] && vps_limit=262144
      ai_reason="${ai_reason:-未提供}；已按快速起速目标收紧 VPS 发送队列。"
      ;;
    vps:retrans)
      [ "${vps_notsent:-0}" -gt 262144 ] && vps_notsent=262144
      [ "${vps_limit:-0}" -gt 524288 ] && vps_limit=524288
      ai_reason="${ai_reason:-未提供}；已按重传优先目标收紧 VPS 发送队列。"
      ;;
  esac

  case "$role" in
    vps)
      printf "vps_congestion='%s'\n" "${vps_congestion:-cubic}"
      printf "vps_mtu_probing='%s'\n" "${vps_mtu_probing:-1}"
      printf "vps_slow_start='%s'\n" "${vps_slow_start:-0}"
      printf "vps_rmem_max='%s'\n" "${vps_rmem_max:-67108864}"
      printf "vps_wmem_max='%s'\n" "${vps_wmem_max:-67108864}"
      printf "vps_notsent='%s'\n" "${vps_notsent:-1048576}"
      printf "vps_limit='%s'\n" "${vps_limit:-1048576}"
      printf "ai_reason='%s'\n" "$(printf '%s' "${ai_reason:-未提供}" | tr "'" " " | cut -c 1-220)"
      ;;
    openwrt)
      printf "op_minimal='%s'\n" "${op_minimal:-1}"
      printf "op_mtu_probing='%s'\n" "${op_mtu_probing:-1}"
      printf "op_slow_start='%s'\n" "${op_slow_start:-0}"
      printf "op_notsent='%s'\n" "${op_notsent:-1048576}"
      printf "op_limit='%s'\n" "${op_limit:-1048576}"
      printf "ai_reason='%s'\n" "$(printf '%s' "${ai_reason:-未提供}" | tr "'" " " | cut -c 1-220)"
      ;;
  esac
}

ai_fallback_decision_json() {
  objective="$1"
  role="$2"
  max_notsent="$(ai_max_notsent)"
  case "$objective" in
    throughput)
      vps_cc="bbr"
      op_notsent="$max_notsent"
      op_limit="1048576"
      ;;
    retrans)
      vps_cc="cubic"
      op_notsent="262144"
      op_limit="262144"
      ;;
    *)
      vps_cc="bbr"
      op_notsent="131072"
      op_limit="262144"
      ;;
  esac
  case "$role" in
    openwrt)
      cat <<EOF
{"openwrt":{"minimal":true,"mtu_probing":1,"slow_start_after_idle":0,"notsent_lowat":$op_notsent,"limit_output_bytes":$op_limit},"reason":"AI 网关超时，已使用内置保守策略继续。"}
EOF
      ;;
    *)
      cat <<EOF
{"vps":{"congestion":"$vps_cc","mtu_probing":1,"slow_start_after_idle":0,"rmem_max":67108864,"wmem_max":67108864,"notsent_lowat":$max_notsent,"limit_output_bytes":1048576},"reason":"AI 网关超时，已使用内置保守策略继续。"}
EOF
      ;;
  esac
}
