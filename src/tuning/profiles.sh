# Module: src/tuning/profiles.sh
profile_exists() {
  case "$1" in
    "近距轻载"|"近距高速"|"中距均衡"|"长距增强"|"远距大带宽") return 0 ;;
    near-light|near-fast|mid-balance|long-boost|far-bandwidth) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_profile() {
  case "$1" in
    "近距轻载"|near-light) echo "近距轻载" ;;
    "近距高速"|near-fast) echo "近距高速" ;;
    "中距均衡"|mid-balance) echo "中距均衡" ;;
    "长距增强"|long-boost) echo "长距增强" ;;
    "远距大带宽"|far-bandwidth) echo "远距大带宽" ;;
    *) die "未知预设：$1" ;;
  esac
}

profile_values() {
  name="$(normalize_profile "$1")"
  # 输出: file_max rmem_max wmem_max rmem_min rmem_default rmem_max
  #        wmem_min wmem_default wmem_max adv_win_scale notsent_lowat
  case "$name" in
    "近距轻载")
      echo "6815744 67108864 33554432 4096 87380 67108864 4096 16384 33554432 1 49152"
      ;;
    "近距高速")
      echo "6815744 67108864 67108864 4096 87380 67108864 4096 16384 67108864 1 65536"
      ;;
    "中距均衡")
      echo "6815744 89653247 43033559 8192 87380 89653247 8192 65536 43033559 1 98304"
      ;;
    "长距增强")
      echo "6815744 105062399 50429951 8192 87380 105062399 8192 65536 50429951 1 131072"
      ;;
    "远距大带宽")
      echo "6815744 186777599 89653247 8192 87380 186777599 8192 65536 89653247 1 196608"
      ;;
  esac
}

profile_rtt_hint() {
  case "$(normalize_profile "$1")" in
    "近距轻载") echo "RTT < 30ms" ;;
    "近距高速") echo "RTT 30~70ms" ;;
    "中距均衡") echo "RTT 70~130ms" ;;
    "长距增强") echo "RTT 130~190ms" ;;
    "远距大带宽") echo "RTT > 190ms" ;;
  esac
}

profile_comment() {
  case "$(normalize_profile "$1")" in
    "近距轻载") echo "低延迟链路，优先控制发送队列和重传。" ;;
    "近距高速") echo "同区域或精品线路，适合较高下行和稳定短中距链路。" ;;
    "中距均衡") echo "跨境中等延迟，接收缓冲略大于发送缓冲。" ;;
    "长距增强") echo "亚太/跨海高带宽链路，适合较大 BDP。" ;;
    "远距大带宽") echo "欧美等高延迟链路，缓冲更大，低内存设备需谨慎。" ;;
  esac
}

list_profiles() {
  cat <<'EOF'
TCP 预设（按距离/延迟从近到远排列）：

1. 近距轻载    (RTT < 30ms)
   接收 64MiB / 发送 32MiB。低延迟链路，优先控制发送队列和重传。

2. 近距高速    (RTT 30~70ms)
   接收 64MiB / 发送 64MiB。同区域或精品线路，适合较高下行和稳定短中距链路。

3. 中距均衡    (RTT 70~130ms)
   接收约 85MiB / 发送约 41MiB。跨境中等延迟，接收缓冲略大于发送缓冲。

4. 长距增强    (RTT 130~190ms)
   接收约 100MiB / 发送约 48MiB。亚太/跨海高带宽链路，适合较大 BDP。

5. 远距大带宽  (RTT > 190ms)
   接收约 178MiB / 发送约 85MiB。欧美等高延迟链路，缓冲更大，低内存设备需谨慎。

英文别名: near-light, near-fast, mid-balance, long-boost, far-bandwidth
EOF
}

profile_summary() {
  profile="$(normalize_profile "$1")"
  values="$(profile_values "$profile")"
  # shellcheck disable=SC2086
  set -- $values
  rmem_max="$2"
  wmem_max="$3"
  printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "$(profile_rtt_hint "$profile")" "$rmem_max" "$wmem_max" "$(profile_comment "$profile")"
}

format_mib() {
  bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.0fMiB", b / 1048576 }'
}

print_profile_summary() {
  profile="$(normalize_profile "$1")"
  values="$(profile_values "$profile")"
  # shellcheck disable=SC2086
  set -- $values
  rmem_max="$2"
  wmem_max="$3"
  ui_row "预设挡位" "$profile"
  ui_row "适用范围" "$(profile_rtt_hint "$profile")"
  ui_row "接收缓冲" "$(format_mib "$rmem_max")"
  ui_row "发送缓冲" "$(format_mib "$wmem_max")"
  ui_note "说明" "$(profile_comment "$profile")"
}

preset_by_number() {
  case "$1" in
    1) echo "近距轻载" ;;
    2) echo "近距高速" ;;
    3) echo "中距均衡" ;;
    4) echo "长距增强" ;;
    5) echo "远距大带宽" ;;
    *) return 1 ;;
  esac
}

memory_mb() {
  awk '/MemTotal/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 1024}' /proc/meminfo 2>/dev/null || echo 1024
}

memory_cap_bytes() {
  memory_mb_value="$1"
  aggressive="${2:-0}"
  detect_os
  awk -v mem="$memory_mb_value" -v aggressive="$aggressive" -v platform="$OS_FAMILY" '
    function clamp(v, min, max) {
      if (v < min) return min
      if (v > max) return max
      return v
    }
    BEGIN {
      mem_bytes = mem * 1024 * 1024
      if (platform == "openwrt") {
        if (mem <= 128) cap = 4 * 1024 * 1024
        else if (mem <= 256) cap = 8 * 1024 * 1024
        else if (mem <= 512) cap = 16 * 1024 * 1024
        else if (mem <= 1024) cap = 32 * 1024 * 1024
        else cap = clamp(int(mem_bytes * 0.05), 4 * 1024 * 1024, 64 * 1024 * 1024)
        printf "%d\n", cap
        exit
      }
      if (mem <= 256) ratio = 0.06
      else if (mem <= 512) ratio = 0.08
      else if (mem <= 1024) ratio = 0.10
      else if (mem <= 2048) ratio = 0.12
      else ratio = 0.15
      if (aggressive == 1 && mem > 512) ratio += 0.03
      printf "%d\n", clamp(int(mem_bytes * ratio), 262144, 268435456)
    }
  '
}

recommend_values() {
  local_mbps="$1"
  peer_mbps="$2"
  rtt_ms="$3"
  memory_mb_value="$4"
  objective="$5"
  ramp_rate="${6:-0.79}"
  aggressive="${7:-0}"

  for numeric_value in "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate"; do
    if ! is_positive_number "$numeric_value"; then
      echo "ERR invalid numeric input"
      return 0
    fi
  done
  case "$objective" in
    retrans|throughput|startup) ;;
    *)
      echo "ERR invalid objective"
      return 0
      ;;
  esac

  detect_os
  awk -v local="$local_mbps" -v peer="$peer_mbps" -v rtt="$rtt_ms" -v mem="$memory_mb_value" \
      -v objective="$objective" -v ramp="$ramp_rate" -v aggressive="$aggressive" -v platform="$OS_FAMILY" '
    function clamp(v, min, max) {
      if (v < min) return min
      if (v > max) return max
      return v
    }
    function ceil(v) {
      return int(v) == v ? v : int(v) + 1
    }
    BEGIN {
      if (local <= 0 || peer <= 0 || rtt <= 0 || mem <= 0) {
        print "ERR invalid numeric input"
        exit
      }

      min_bw = local < peer ? local : peer
      # Mbps 使用 SI 单位（1 Mbps = 10^6 bit/s），不能按 2^20 计算。
      base_bdp = ceil((min_bw * 1000 * 1000 / 8) * rtt / 1000)
      if (base_bdp < 16384) base_bdp = 16384

      mem_bytes = mem * 1024 * 1024
      if (platform == "openwrt") {
        if (mem <= 128) mem_cap = 4 * 1024 * 1024
        else if (mem <= 256) mem_cap = 8 * 1024 * 1024
        else if (mem <= 512) mem_cap = 16 * 1024 * 1024
        else if (mem <= 1024) mem_cap = 32 * 1024 * 1024
        else mem_cap = clamp(int(mem_bytes * 0.05), 4 * 1024 * 1024, 64 * 1024 * 1024)
        mem_class = "openwrt-guarded"
        max_ratio = mem_cap / mem_bytes
      } else if (mem <= 256) {
        max_ratio = 0.06
        mem_class = "low"
      } else if (mem <= 512) {
        max_ratio = 0.08
        mem_class = "small"
      } else if (mem <= 1024) {
        max_ratio = 0.10
        mem_class = "medium"
      } else if (mem <= 2048) {
        max_ratio = 0.12
        mem_class = "high"
      } else {
        max_ratio = 0.15
        mem_class = "large"
      }
      if (platform != "openwrt" && aggressive == 1 && mem > 512) max_ratio += 0.03
      mem_cap = int(mem_bytes * max_ratio)
      if (platform == "openwrt") mem_cap = clamp(mem_cap, 4 * 1024 * 1024, 64 * 1024 * 1024)
      else mem_cap = clamp(mem_cap, 4 * 1024 * 1024, 256 * 1024 * 1024)

      latency_factor = clamp(rtt / 40, 1, 5)
      ratio = local / peer
      if (ratio <= 0) ratio = 1
      high_latency = rtt > 120 ? 1 : 0

      if (objective == "throughput") {
        recv_mult = high_latency ? 6.0 : 5.0
        send_mult = high_latency ? 3.0 : 2.5
      } else if (objective == "startup") {
        recv_mult = high_latency ? 2.8 : 2.0
        send_mult = high_latency ? 1.2 : 0.9
      } else {
        recv_mult = high_latency ? 3.2 : 2.0
        send_mult = high_latency ? 1.5 : 1.0
      }

      if (high_latency) {
        bandwidth_factor = clamp(2 * sqrt(ratio) * latency_factor, 1.5, 5)
        effective_bw = local * bandwidth_factor
        if (effective_bw > 2 * peer) effective_bw = 2 * peer
        model_bdp = ceil((effective_bw * 1024 * 1024 / 8) * rtt / 1000)
      } else {
        model_bdp = base_bdp
      }

      if (mem <= 256) {
        recv_mult *= 0.65
        send_mult *= 0.65
      } else if (mem <= 512) {
        recv_mult *= 0.8
        send_mult *= 0.8
      } else if (mem > 2048 && aggressive == 1) {
        recv_mult *= 1.2
        send_mult *= 1.15
      }

      if (ramp < 0.1) ramp = 0.1
      if (ramp > 1) ramp = 1
      if (objective == "startup") {
        recv_mult *= 0.9 + ramp * 0.25
        send_mult *= 0.85 + ramp * 0.20
      } else {
        recv_mult *= ramp
        send_mult *= ramp
      }

      rmem = int(model_bdp * recv_mult)
      wmem = int(model_bdp * send_mult)
      rmem_floor = int(base_bdp / 4)
      if (rmem_floor < 262144) rmem_floor = 262144
      wmem_floor = int(base_bdp / 4)
      if (wmem_floor < 262144) wmem_floor = 262144
      rmem = clamp(rmem, rmem_floor, mem_cap)
      wmem = clamp(wmem, wmem_floor, mem_cap)

      if (objective == "startup") {
        notsent = clamp(int(model_bdp / 32), 16384, 131072)
      } else if (objective == "retrans") {
        notsent = clamp(int(model_bdp / 16 * ramp), 32768, 524288)
      } else {
        notsent = clamp(int(model_bdp / 16), 16384, 524288)
      }
      adv = int(clamp(ceil(latency_factor * (objective == "throughput" ? 1.4 : 1.0)), 2, 8))
      backlog = int(clamp(8192 + model_bdp / 65536 * latency_factor, 8192, mem <= 512 ? 16384 : 32768))
      somaxconn = int(clamp(backlog * 0.5, 2560, mem <= 512 ? 8192 : 16384))
      synbacklog = int(clamp(backlog * 1.5, 8192, mem <= 512 ? 32768 : 65536))
      optmem = int(clamp(model_bdp / 32, 81920, 262144))

      printf "%d %d %d %d %d %d %d %d %s %d\n", rmem, wmem, adv, notsent, backlog, somaxconn, synbacklog, optmem, mem_class, base_bdp
    }
  '
}

print_recommendation() {
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
  # shellcheck disable=SC2086
  set -- $values
  rmem="$1"
  wmem="$2"
  adv="$3"
  notsent="$4"
  backlog="$5"
  somaxconn="$6"
  synbacklog="$7"
  optmem="$8"
  mem_class="$9"
  shift 9
  base_bdp="$1"

  echo "智能推荐结果："
  echo "  目标：$objective"
  echo "  基础 BDP：$base_bdp bytes"
  echo "  内存档位：$mem_class (${memory_mb_value}MiB)"
  echo "  net.core.rmem_max = $rmem"
  echo "  net.core.wmem_max = $wmem"
  echo "  net.ipv4.tcp_rmem = 4096 87380 $rmem"
  echo "  net.ipv4.tcp_wmem = 4096 65536 $wmem"
  echo "  net.ipv4.tcp_adv_win_scale = $adv"
  echo "  net.ipv4.tcp_notsent_lowat = $notsent"
  echo "  net.core.netdev_max_backlog = $backlog"
  echo "  net.core.somaxconn = $somaxconn"
  echo "  net.ipv4.tcp_max_syn_backlog = $synbacklog"
  echo "  net.core.optmem_max = $optmem"
}

recommend_preset_name() {
  rtt_ms="${1:-0}"
  memory_mb_value="${2:-1024}"
  retransmits="${3:-0}"
  download_bps="${4:-0}"
  if [ "$rtt_ms" -lt 30 ]; then
    index=1
  elif [ "$rtt_ms" -lt 70 ]; then
    index=2
  elif [ "$rtt_ms" -lt 130 ]; then
    index=3
  elif [ "$rtt_ms" -lt 190 ]; then
    index=4
  else
    index=5
  fi
  if [ "$memory_mb_value" -lt 256 ] && [ "$index" -gt 3 ]; then
    index=3
  fi
  if [ "$retransmits" -gt 500 ] && [ "$index" -gt 1 ]; then
    index=$((index - 1))
  fi
  if awk -v bps="$download_bps" 'BEGIN { exit !(bps > 0 && bps < 20000000) }' && [ "$index" -gt 3 ]; then
    index=3
  fi
  preset_by_number "$index"
}

recommend_preset_reason() {
  rtt_ms="${1:-0}"
  memory_mb_value="${2:-1024}"
  retransmits="${3:-0}"
  download_bps="${4:-0}"
  reason="RTT ${rtt_ms}ms / 内存 ${memory_mb_value}MiB / 重传 $(format_count "$retransmits") 次"
  if [ "$memory_mb_value" -lt 256 ]; then
    reason="$reason；低内存设备不推荐高挡位"
  fi
  if [ "$retransmits" -gt 500 ]; then
    reason="$reason；重传偏高，已降低推荐挡位"
  fi
  if awk -v bps="$download_bps" 'BEGIN { exit !(bps > 0 && bps < 20000000) }'; then
    reason="$reason；吞吐较低，可能是链路或限速问题"
  fi
  echo "$reason"
}

profile_probe_metrics() {
  host="$1"
  port="$2"
  bind_ip="$3"
  rtt_ms="$(detect_rtt_ms "$host")"
  upload_json="$(run_iperf_client "$host" "$port" 0 8 "$bind_ip" 2>/dev/null || true)"
  download_json="$(run_iperf_client "$host" "$port" 1 8 "$bind_ip" 2>/dev/null || true)"
  if ! printf '%s' "$upload_json" | grep -q '"end"'; then
    die "预制参数检测失败：上传 iperf3 未返回有效结果，请先确认服务端测速端口可达。"
  fi
  if ! printf '%s' "$download_json" | grep -q '"end"'; then
    die "预制参数检测失败：下载 iperf3 未返回有效结果，请先确认服务端测速端口可达。"
  fi
  upload_bps="$(printf '%s\n' "$upload_json" | extract_bps 2>/dev/null || true)"
  upload_retr="$(printf '%s\n' "$upload_json" | extract_retransmits 2>/dev/null || true)"
  upload_first="$(printf '%s\n' "$upload_json" | extract_first_interval_bps 2>/dev/null || true)"
  download_bps="$(printf '%s\n' "$download_json" | extract_bps 2>/dev/null || true)"
  download_retr="$(printf '%s\n' "$download_json" | extract_retransmits 2>/dev/null || true)"
  download_first="$(printf '%s\n' "$download_json" | extract_first_interval_bps 2>/dev/null || true)"
  for metric in "$upload_bps" "$upload_retr" "$upload_first" "$download_bps" "$download_retr" "$download_first"; do
    is_unsigned_integer "$metric" || die "预制参数检测失败：iperf3 JSON 缺少必要指标，未使用 0 代替。"
  done
  total_retr=$((upload_retr + download_retr))
  memory_mb_value="$(memory_mb)"
  recommended="$(recommend_preset_name "$rtt_ms" "$memory_mb_value" "$total_retr" "$download_bps")"
  cat <<EOF
$rtt_ms $memory_mb_value $upload_bps $upload_retr $upload_first $download_bps $download_retr $download_first $total_retr $recommended
EOF
}
