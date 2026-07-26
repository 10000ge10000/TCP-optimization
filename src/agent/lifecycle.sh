# Module: src/agent/lifecycle.sh
random_token() {
  if have_cmd openssl; then
    openssl rand -hex 32
    return
  fi
  if have_cmd python3; then
    python3 -c 'import secrets; print(secrets.token_hex(32))'
    return
  fi
  return 1
}

write_agent_py() {
  path="$1"
  (umask 077; cat > "$path" <<'PY'
@@TCP_TUNE_AGENT_SOURCE@@
PY
  )
  chmod 700 "$path"
}

# 用 curl --config 传递鉴权头：token 不进入进程 argv，同机其他用户无法通过 ps 读取。
curl_with_token() {
  curl_token_value="$1"
  shift
  curl_header_cfg="$( (umask 077; mktemp "${TMPDIR:-/tmp}/tcp-tune-hdr.XXXXXX") 2>/dev/null )" || curl_header_cfg=""
  if [ -z "$curl_header_cfg" ]; then
    # 极少数无 mktemp 的环境退回请求头方式，保持功能可用。
    curl -H "X-TCP-Tune-Token: $curl_token_value" "$@"
    return
  fi
  printf 'header = "X-TCP-Tune-Token: %s"\n' "$curl_token_value" > "$curl_header_cfg"
  curl --config "$curl_header_cfg" "$@"
  curl_with_token_rc=$?
  rm -f "$curl_header_cfg"
  return "$curl_with_token_rc"
}

post_json() {
  url="$1"
  token="$2"
  data="$3"
  curl_with_token "$token" -fsS -H "Content-Type: application/json" -d "$data" "$url"
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

listen_mode() {
  need_root
  install_runtime_deps
  ensure_dependency python3 python3 || die "listen 模式需要 python3 运行临时 HTTP Agent。"
  ensure_state_dir
  umask 077
  lock_root="$STATE_DIR/locks"
  lock_dir="$lock_root/agent-$AGENT_PORT.lock"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root" 2>/dev/null || true
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # dry-run 只检查、不获取会话锁：中途任何异常（如输出管道被关闭）都不会遗留锁。
    if [ -d "$lock_dir" ]; then
      DIE_EXIT_CODE="$EXIT_NETWORK" die "Agent 端口 $AGENT_PORT 已有会话锁；请先运行 stop-agent 并确认旧会话已结束。"
    fi
    ensure_initial_defaults_snapshot "server" >/dev/null || warn "无法记录服务端首次默认值快照，恢复默认值菜单将只恢复客户端。"
    if [ -n "$LISTEN_PUBLIC_URL" ]; then
      peer_url="$LISTEN_PUBLIC_URL"
    else
      peer_url="http://<公网IP>:$AGENT_PORT"
    fi
    token="<启动后自动生成>"
    echo "[dry-run] 将启动临时 HTTP Agent：${TCP_TUNE_AGENT_BIND:-[::]}:$AGENT_PORT（未设 TCP_TUNE_AGENT_BIND 时失败回退 0.0.0.0）"
    echo "[dry-run] 将启动 iperf3 server：0.0.0.0:$IPERF_PORT"
    echo "[dry-run] 会话 TTL：$SESSION_TTL 秒"
    print_client_commands "$peer_url" "$token"
    return 0
  fi
  if ! mkdir "$lock_dir" 2>/dev/null; then
    DIE_EXIT_CODE="$EXIT_NETWORK" die "Agent 端口 $AGENT_PORT 已有会话锁；请先运行 stop-agent 并确认旧会话已结束。"
  fi
  ensure_initial_defaults_snapshot "server" >/dev/null || warn "无法记录服务端首次默认值快照，恢复默认值菜单将只恢复客户端。"

  token="$(random_token)" || { rmdir "$lock_dir" 2>/dev/null || true; DIE_EXIT_CODE="$EXIT_DEPENDENCY" die "无法获得安全随机源，拒绝启动 Agent。"; }
  session_id="$(random_token)" || { rmdir "$lock_dir" 2>/dev/null || true; DIE_EXIT_CODE="$EXIT_DEPENDENCY" die "无法生成会话标识。"; }
  script_path="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
  agent_py="$STATE_DIR/tcp-tune-agent-$AGENT_PORT.py"
  write_agent_py "$agent_py"
  TCP_TUNE_SESSION_ID="$session_id"
  export TCP_TUNE_SESSION_ID
  start_iperf_server "$IPERF_PORT"

  export TCP_TUNE_TOKEN="$token"
  export TCP_TUNE_SCRIPT="$script_path"
  export TCP_TUNE_AGENT_PORT="$AGENT_PORT"
  export TCP_TUNE_IPERF_PORT="$IPERF_PORT"
  export TCP_TUNE_SESSION_TTL="$SESSION_TTL"
  export TCP_TUNE_STATE_DIR="$STATE_DIR"
  export TCP_TUNE_AGENT_BODY_LIMIT TCP_TUNE_AGENT_MAX_CONCURRENCY TCP_TUNE_AGENT_TEST_ALLOWLIST TCP_TUNE_ALLOW_QUERY_TOKEN
  export TCP_TUNE_AGENT_BIND="${TCP_TUNE_AGENT_BIND:-}"

  nohup python3 "$agent_py" > "$STATE_DIR/agent-$AGENT_PORT.log" 2>&1 &
  agent_pid="$!"
  atomic_write_line "$STATE_DIR/agent-$AGENT_PORT.pid" "$agent_pid"
  write_process_manifest "$STATE_DIR/agent-$AGENT_PORT.manifest" "$agent_pid" "$session_id" "$agent_py" "$AGENT_PORT" || {
    kill "$agent_pid" 2>/dev/null || true
    stop_iperf_server "$IPERF_PORT" >/dev/null 2>&1 || true
    rm -f "$lock_dir/session" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    DIE_EXIT_CODE="$EXIT_NETWORK" die "无法记录 Agent 进程身份。"
  }

  if [ -n "$LISTEN_PUBLIC_URL" ]; then
    peer_url="$LISTEN_PUBLIC_URL"
  else
    ip="$(public_ip)"
    [ -n "$ip" ] || ip="<公网IP>"
    peer_url="http://$ip:$AGENT_PORT"
  fi
  atomic_write_line "$STATE_DIR/agent-$AGENT_PORT.token" "$token"
  atomic_write_line "$STATE_DIR/agent-$AGENT_PORT.url" "$peer_url"
  atomic_write_line "$lock_dir/session" "$session_id"
  ready=0
  check_url="http://127.0.0.1:$AGENT_PORT/state"
  ready_try=0
  while [ "$ready_try" -lt 10 ]; do
    if curl_with_token "$token" -fsS --max-time 2 "$check_url" >/dev/null 2>&1; then
      ready=1
      break
    fi
    kill -0 "$agent_pid" 2>/dev/null || break
    sleep 1
    ready_try=$((ready_try + 1))
  done
  if [ "$ready" != "1" ]; then
    stop_agent --session "$session_id" >/dev/null 2>&1 || true
    DIE_EXIT_CODE="$EXIT_NETWORK" die "Agent 未通过启动就绪检查，请查看 $STATE_DIR/agent-$AGENT_PORT.log。"
  fi
  if [ "${SERVER_MONITOR_AFTER_LISTEN:-0}" != "1" ]; then
    render_server_dashboard "$peer_url" "$token"
  fi
}

stop_agent() {
  need_root
  ensure_state_dir
  expected_session=""
  if [ "${1:-}" = "--session" ]; then
    expected_session="${2:-}"
    [ -n "$expected_session" ] || return 2
  fi
  stopped=0
  cleaned_agent_ports=""
  cleaned_sessions=""
  for manifest in "$STATE_DIR"/agent-*.manifest "$STATE_DIR"/iperf3-*.manifest; do
    [ -f "$manifest" ] || continue
    session="$(manifest_value "$manifest" session)"
    [ -z "$expected_session" ] || [ "$session" = "$expected_session" ] || continue
    pid="$(manifest_value "$manifest" pid)"
    process_port="$(manifest_value "$manifest" port)"
    if stop_verified_process "$manifest" "$expected_session"; then
      rm -f "$manifest"
      case "$manifest" in
        *agent-*) rm -f "${manifest%.manifest}.pid"; cleaned_agent_ports="$cleaned_agent_ports $process_port" ;;
        *iperf3-*) rm -f "${manifest%.manifest}.pid" ;;
      esac
      cleaned_sessions="$cleaned_sessions $session"
      stopped=1
    elif ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$manifest" "${manifest%.manifest}.pid"
      case "$manifest" in *agent-*) cleaned_agent_ports="$cleaned_agent_ports $process_port" ;; esac
      cleaned_sessions="$cleaned_sessions $session"
    fi
  done
  for process_port in $cleaned_agent_ports; do
    rm -f "$STATE_DIR/agent-$process_port.token" "$STATE_DIR/agent-$process_port.url" \
      "$STATE_DIR/tcp-tune-agent-$process_port.py" "$STATE_DIR/server-dashboard-$process_port.json"
  done
  for lock_dir in "$STATE_DIR"/locks/agent-*.lock; do
    [ -d "$lock_dir" ] || continue
    lock_session="$(cat "$lock_dir/session" 2>/dev/null || true)"
    clean_lock=0
    for session in $cleaned_sessions; do [ "$lock_session" = "$session" ] && clean_lock=1; done
    [ "$clean_lock" = "1" ] || continue
    rm -f "$lock_dir/session"
    rmdir "$lock_dir" 2>/dev/null || true
  done
  if [ "$stopped" = "0" ]; then
    info "未发现本工具记录的临时 Agent/iperf3 pid。"
  else
    info "已停止本工具记录的临时进程。"
  fi
}
