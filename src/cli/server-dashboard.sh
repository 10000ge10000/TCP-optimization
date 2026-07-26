# Module: src/cli/server-dashboard.sh
post_json() {
  url="$1"
  token="$2"
  data="$3"
  curl -fsS -H "X-TCP-Tune-Token: $token" -H "Content-Type: application/json" -d "$data" "$url"
}

post_client_stage() {
  stage="$1"
  result="$2"
  detail="${3:-}"
  [ -n "${TUNE_REPORT_PEER:-}" ] || return 0
  [ -n "${TUNE_REPORT_TOKEN:-}" ] || return 0
  now="$(date +%s)"
  lan_ip="${TUNE_CLIENT_IP:-$(local_lan_ipv4 || true)}"
  data="{\"role\":\"client-stage\",\"lan_ip\":$(json_string "$lan_ip"),\"stage\":$(json_string "$stage"),\"result\":$(json_string "$result"),\"detail\":$(json_string "$detail"),\"time\":$now}"
  post_json "$TUNE_REPORT_PEER/report" "$TUNE_REPORT_TOKEN" "$data" >/dev/null 2>&1 || true
}

get_agent_json() {
  url="$1"
  token="$2"
  curl -fsS -H "X-TCP-Tune-Token: $token" "$url"
}

remote_defaults_available() {
  peer="$1"
  token="$2"
  curl -fsS --max-time 3 -H "X-TCP-Tune-Token: $token" "$peer/defaults" 2>/dev/null | grep -q '"available": true'
}

defaults_menu_tag() {
  peer="$1"
  token="$2"
  if initial_defaults_available; then
    local_tag="本机已记录"
  else
    local_tag="本机未记录"
  fi
  if remote_defaults_available "$peer" "$token"; then
    remote_tag="服务端已记录"
  else
    remote_tag="服务端未知"
  fi
  printf '[%s / %s]\n' "$local_tag" "$remote_tag"
}

restore_defaults_menu() {
  peer="$1"
  token="$2"
  clear_screen
  print_header "恢复默认值"
  ui_subtitle "恢复客户端首次运行时记录的本机参数，并请求服务端恢复启动时快照。"
  echo
  ui_section "快照状态"
  if initial_defaults_available; then
    ui_row "本机快照" "已记录"
  else
    ui_row "本机快照" "未记录"
  fi
  if remote_defaults_available "$peer" "$token"; then
    ui_row "服务端快照" "已记录"
  else
    ui_row "服务端快照" "未知或不可用"
  fi
  echo
  ui_note "范围" "只恢复本工具首次运行记录的 TCP/sysctl 相关参数，不修改防火墙、DNS、代理或路由策略。"
  ui_note "区别" "回滚最近修改只撤销最近一次写入；恢复默认值会回到首次连接时记录的基线。"
  echo
  if ! prompt_read "确认恢复默认值？输入 yes 继续，其他返回："; then
    return 1
  fi
  [ "$PROMPT_REPLY" = "yes" ] || return 0

  local_ok="0"
  remote_ok="0"
  if initial_defaults_available; then
    if restore_initial_defaults; then
      local_ok="1"
    else
      warn "本机默认值恢复失败。"
    fi
  else
    warn "本机没有首次默认值快照，跳过本机恢复。"
  fi

  if post_json "$peer/restore-defaults" "$token" "{}" >/dev/null 2>&1; then
    remote_ok="1"
  else
    warn "服务端默认值恢复请求失败。"
  fi

  if [ "$local_ok" = "1" ] || [ "$remote_ok" = "1" ]; then
    post_client_stage "restore-defaults" "success" "本机:$local_ok 服务端:$remote_ok"
    ui_note "结果" "恢复默认值流程已执行。本机=$local_ok，服务端=$remote_ok。"
    return 0
  fi
  post_client_stage "restore-defaults" "failed" "没有可恢复快照"
  return 1
}

render_agent_events_summary() {
  peer="$1"
  token="$2"
  json="$(get_agent_json "$peer/events" "$token")" || return 1
  if have_cmd python3; then
    tmp_events="$STATE_DIR/events-summary.json"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s' "$json" > "$tmp_events"
    python3 - "$tmp_events" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
summaries = data.get("summaries") or []
if not summaries:
    print("  暂无过程记录。")
else:
    for line in summaries[-30:]:
        print(f"  {line}")
PY
    return 0
  fi
  printf '%s\n' "$json" | awk '
    /"summaries"[[:space:]]*:/ { in_summaries=1; next }
    in_summaries && /\]/ { in_summaries=0; next }
    in_summaries {
      line=$0
      sub(/^[[:space:]]*"/, "", line)
      sub(/",?[[:space:]]*$/, "", line)
      gsub(/\\"/, "\"", line)
      if (line != "") print "  " line
      found=1
    }
    END {
      if (!found) print "  暂无过程记录。"
    }
  '
}

render_server_dashboard() {
  peer_url="$1"
  token="$2"
  remaining="${3:-$SESSION_TTL}"
  ttl_text="$((remaining / 60))m $((remaining % 60))s"
  clear_screen
  print_header "TCP 双端调优器 · 服务端监控"
  ui_subtitle "服务端只负责接收客户端、展示过程和提供临时测速服务"
  echo
  ui_section "会话状态"
  ui_row "运行状态" "服务运行中"
  ui_row "运行模式" "只读监控"
  ui_row "Agent 端口" "$AGENT_PORT"
  ui_row "测速端口" "$IPERF_PORT"
  ui_row "剩余时间" "$ttl_text"
  echo
  render_server_activity "$token"
  echo
  print_client_commands "$peer_url" "$token"
  echo
  ui_section "安全说明"
  ui_note "只读" "服务端不修改 TCP 参数，所有优化由客户端在本机执行。"
  ui_note "刷新" "连接命令不会反复重绘；底部状态行会原地刷新，方便复制。"
  ui_note "清理" "保持此窗口运行；按 Ctrl+C 会停止 Agent/iperf3 并清理凭据。"
}

render_server_activity() {
  token="$1"
  dashboard_file="$STATE_DIR/server-dashboard-$AGENT_PORT.json"
  if ! curl -fsS -H "X-TCP-Tune-Token: $token" "http://127.0.0.1:$AGENT_PORT/state" -o "$dashboard_file" 2>/dev/null; then
    printf "%s会话状态%s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    print_rule
    echo "  Agent 状态暂时不可读。"
    return 0
  fi
  python3 - "$dashboard_file" <<'PY'
import json
import sys
import time

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    state = json.load(handle).get("state", {})

reports = state.get("peer_reports", [])
devices = {}
results = []
stages = []
for entry in reports:
    payload = entry.get("payload", {})
    ip = str(payload.get("lan_ip") or "").strip()
    role = str(payload.get("role") or "unknown")
    if payload.get("bits_per_second") is not None:
        results.append((entry.get("time", 0), payload))
    if payload.get("stage"):
        stages.append((entry.get("time", 0), payload))
    if ip:
        device = devices.setdefault(ip, {"ip": ip, "os": "Unknown", "role": role, "last": 0})
        if payload.get("os"):
            device["os"] = str(payload["os"])
        if role != "client-result":
            device["role"] = role
        device["last"] = max(device["last"], entry.get("time", 0))

print("  ▎ 已接入客户端")
if not devices:
    print("  暂无客户端，等待连接...")
else:
    for device in sorted(devices.values(), key=lambda item: item["last"], reverse=True):
        seen = time.strftime("%H:%M:%S", time.localtime(device["last"]))
        print(f"  ● {device['os']} · {device['ip']}  最近上报 {seen}")

print()
print("  ▎ 客户端状态")
if not stages:
    print("  当前状态  空闲 / 未开始")
    print("  最近结论  未开始")
else:
    _, payload = stages[-1]
    stage_name = {
        "preset-probe": "预制参数检测",
        "preset-apply": "预制参数写入",
        "rollback": "回滚",
        "auto": "稳定自动优化",
    }.get(str(payload.get("stage") or ""), str(payload.get("stage") or "任务"))
    result_name = {
        "running": "进行中",
        "ok": "完成",
        "success": "成功",
        "rollback": "已回滚",
        "failed": "失败",
    }.get(str(payload.get("result") or ""), str(payload.get("result") or ""))
    detail = str(payload.get("detail") or "")
    print(f"  当前状态  {stage_name} {result_name}".rstrip())
    print(f"  最近结论  {detail or result_name or '未开始'}")

print()
print("  ▎ 最近结果")
if not results:
    print("  尚未收到测速结果。")
else:
    _, payload = results[-1]
    objective = {"retrans": "重传优先", "throughput": "吞吐优先", "startup": "快速起速"}.get(str(payload.get("objective")), "未指定")
    direction = {"upload": "上传", "download": "下载", "both": "双向"}.get(payload.get("direction"), "未检测")
    bps = payload.get("bits_per_second") if isinstance(payload.get("bits_per_second"), (int, float)) and not isinstance(payload.get("bits_per_second"), bool) else None
    rate = "未检测" if bps is None else (f"{bps / 1_000_000_000:.2f} Gbps" if bps >= 1_000_000_000 else f"{bps / 1_000_000:.1f} Mbps")
    retransmits = payload.get("retransmits") if isinstance(payload.get("retransmits"), int) and not isinstance(payload.get("retransmits"), bool) else None
    first_bps = payload.get("first_second_bits_per_second") if isinstance(payload.get("first_second_bits_per_second"), (int, float)) and not isinstance(payload.get("first_second_bits_per_second"), bool) else None
    first_rate = "未检测" if first_bps is None else (f"{first_bps / 1_000_000_000:.2f} Gbps" if first_bps >= 1_000_000_000 else f"{first_bps / 1_000_000:.1f} Mbps")
    round_no = payload.get("round") or "-"
    rounds = payload.get("rounds") or "-"
    print(f"  模式  {objective}")
    print(f"  方向  {direction}")
    print(f"  轮次  {round_no}/{rounds}")
    print(f"  速度  {rate}")
    print(f"  重传  {'未检测' if retransmits is None else format(retransmits, ',') + ' 次'}")
    if first_bps is not None:
        print(f"  首秒  {first_rate}")
    print("  判定  已收到结果，等待客户端复测或下一步操作")

print()
print("  ▎ 最近事件")
events = state.get("events", [])[-5:]
if not events:
    print("  服务端已启动，等待客户端上报。")
else:
    for event in events:
        stamp = time.strftime("%H:%M:%S", time.localtime(event.get("time", 0)))
        if event.get("action") == "peer-report" and event.get("stage"):
            stage = {"preset-probe": "预制参数检测", "preset-apply": "预制参数写入", "rollback": "回滚"}.get(event.get("stage"), event.get("stage"))
            status = {"running": "进行中", "ok": "完成", "success": "成功", "rollback": "已回滚", "failed": "失败"}.get(event.get("result"), event.get("result"))
            text = f"{stage} {status}".strip()
        elif event.get("action") == "peer-report" and event.get("round") is not None:
            text = f"收到第 {event.get('round')} 轮测速结果"
        elif event.get("action") == "peer-report":
            text = f"客户端上报：{event.get('lan_ip') or event.get('role', 'unknown')}"
        elif event.get("action") == "test":
            text = "服务端测速任务完成"
        elif event.get("action") == "stop-request":
            text = "收到停止会话请求"
        else:
            text = str(event.get("action") or "事件")
        print(f"  {stamp}  {text}")
PY
}

server_compact_status_line() {
  token="$1"
  remaining="${2:-0}"
  ttl_text="$((remaining / 60))m $((remaining % 60))s"
  dashboard_file="$STATE_DIR/server-compact-$AGENT_PORT.json"
  if ! curl -fsS -H "X-TCP-Tune-Token: $token" "http://127.0.0.1:$AGENT_PORT/state" -o "$dashboard_file" 2>/dev/null; then
    printf "刷新 %s | 剩余 %s | Agent 状态暂不可读" "$(date '+%H:%M:%S')" "$ttl_text"
    return 0
  fi
  python3 - "$dashboard_file" "$ttl_text" <<'PY'
import json
import sys
import time

path, ttl_text = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        state = json.load(handle).get("state", {})
except Exception:
    state = {}

reports = state.get("peer_reports", [])
devices = {}
latest_result = None
latest_stage = None
for entry in reports:
    payload = entry.get("payload", {})
    stamp = entry.get("time", 0)
    ip = str(payload.get("lan_ip") or "").strip()
    if ip:
        devices[ip] = max(devices.get(ip, 0), stamp)
    if payload.get("bits_per_second") is not None:
        latest_result = payload
    if payload.get("stage"):
        latest_stage = payload

status = "空闲"
conclusion = "未开始"
if latest_stage:
    stage_map = {
        "preset-probe": "预制检测",
        "preset-apply": "预制写入",
        "rollback": "回滚中",
        "auto": "稳定优化",
    }
    result_map = {
        "running": "进行中",
        "ok": "完成",
        "success": "成功",
        "rollback": "已回滚",
        "failed": "失败",
    }
    status = stage_map.get(str(latest_stage.get("stage") or ""), str(latest_stage.get("stage") or "任务"))
    conclusion = result_map.get(str(latest_stage.get("result") or ""), str(latest_stage.get("result") or "进行中"))

result_text = "暂无测速"
if latest_result:
    raw_bps = latest_result.get("bits_per_second")
    bps = raw_bps if isinstance(raw_bps, (int, float)) and not isinstance(raw_bps, bool) else None
    rate = "未检测" if bps is None else (f"{bps / 1_000_000_000:.2f}Gbps" if bps >= 1_000_000_000 else f"{bps / 1_000_000:.1f}Mbps")
    raw_retrans = latest_result.get("retransmits")
    retransmits = raw_retrans if isinstance(raw_retrans, int) and not isinstance(raw_retrans, bool) else None
    direction = {"upload": "上传", "download": "下载", "both": "双向"}.get(latest_result.get("direction"), "未检测")
    retrans_text = "未检测" if retransmits is None else f"{retransmits:,} 次"
    result_text = f"{direction} {rate} / 重传 {retrans_text}"

print(
    f"刷新 {time.strftime('%H:%M:%S')} | 剩余 {ttl_text} | "
    f"客户端 {len(devices)} | 状态 {status} | 最近 {result_text} | 判定 {conclusion}",
    end="",
)
PY
}

server_monitor() {
  token_file="$STATE_DIR/agent-$AGENT_PORT.token"
  url_file="$STATE_DIR/agent-$AGENT_PORT.url"
  agent_pid_file="$STATE_DIR/agent-$AGENT_PORT.pid"
  token="$(cat "$token_file" 2>/dev/null || true)"
  peer_url="$(cat "$url_file" 2>/dev/null || true)"
  [ -n "$token" ] || die "服务端 token 文件不存在。"
  deadline=$(( $(date +%s) + SESSION_TTL ))
  rendered_once=0
  while true; do
    if [ ! -f "$agent_pid_file" ]; then
      [ -t 1 ] && [ "$rendered_once" = "1" ] && echo
      info "服务端会话已停止。"
      return 0
    fi
    agent_pid="$(cat "$agent_pid_file" 2>/dev/null || true)"
    if [ -z "$agent_pid" ] || ! kill -0 "$agent_pid" >/dev/null 2>&1; then
      [ -t 1 ] && [ "$rendered_once" = "1" ] && echo
      warn "Agent 已退出，服务端监控结束。"
      return 0
    fi
    now="$(date +%s)"
    remaining=$((deadline - now))
    if [ "$remaining" -le 0 ]; then
      [ -t 1 ] && [ "$rendered_once" = "1" ] && echo
      warn "会话已达到 TTL，正在安全停止。"
      return 0
    fi
    if [ -t 1 ]; then
      if [ "$rendered_once" = "0" ]; then
        render_server_dashboard "$peer_url" "$token" "$remaining"
        echo
        rendered_once=1
      fi
      printf "\r\033[K%s" "$(server_compact_status_line "$token" "$remaining")"
    elif [ "$rendered_once" = "0" ]; then
      render_server_dashboard "$peer_url" "$token" "$remaining"
      rendered_once=1
    fi
    sleep 2
  done
}

render_client_dashboard() {
  peer_url="$1"
  local_ip="$2"
  iperf_port="$3"
  clear_screen
  print_header "TCP 双端调优器 · 客户端"
  ui_subtitle "${OS_NAME:-本机} 设备已连接，可直接选择优化目标"
  echo
  ui_section "连接状态"
  ui_row "会话" "已连接"
  ui_row "本机" "${OS_NAME:-Unknown} · ${local_ip:-未识别}"
  ui_row "测速节点" "已连接的服务端"
  ui_row "测试端口" "$iperf_port"
  echo
  ui_note "提示" "代理/公网地址仅用于脚本通讯，界面和测试源地址优先使用本机局域网 IP。"
}

print_client_commands() {
  peer_url="$1"
  token="$2"
  display_token="$token"
  case "$display_token" in
    \<*\>) ;;
    *)
      if [ ! -t 1 ]; then
        display_token="<会话令牌已隐藏>"
      fi
      ;;
  esac
  ui_section "客户端连接命令"
  ui_note "令牌" "交互终端显示完整 token；非交互输出会隐藏 token。"
  printf "%sOpenWrt / Linux / macOS%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  cat <<EOF
  curl -fsSL $RAW_BASE_URL/tcp-tune.sh | \\
    sh -s -- --yes client \\
      --peer $peer_url \\
      --token $display_token \\
      --iperf-port $IPERF_PORT
EOF
  echo
  printf "%s短命令模式%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  cat <<EOF
  curl -fsSL $RAW_BASE_URL/tcp-tune.sh -o tcp-tune.sh
  sh tcp-tune.sh --yes client \\
    --peer $peer_url \\
    --token $display_token \\
    --iperf-port $IPERF_PORT
EOF
  echo
  printf "%sWindows PowerShell%s\n" "$COLOR_CYAN" "$COLOR_RESET"
  cat <<EOF
  iwr -UseBasicParsing $RAW_BASE_URL/tcp-tune.ps1 -OutFile tcp-tune.ps1
  .\\tcp-tune.ps1 client \`
    -Peer $peer_url \`
    -Token $display_token \`
    -IperfPort $IPERF_PORT \`
    -Direction download -Yes
EOF
}
