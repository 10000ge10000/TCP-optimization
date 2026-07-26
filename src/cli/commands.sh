# Module: src/cli/commands.sh
server_mode() {
  trap 'exit 130' INT TERM
  trap 'if [ "${DRY_RUN:-0}" != "1" ]; then stop_agent; fi' 0
  SERVER_MONITOR_AFTER_LISTEN=1
  export SERVER_MONITOR_AFTER_LISTEN
  listen_mode
  unset SERVER_MONITOR_AFTER_LISTEN
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  server_monitor
}

client_mode() {
  trap 'exit 130' INT TERM
  CLIENT_MENU=1
  export CLIENT_MENU
  join_mode "$@"
}

menu() {
  while true; do
    clear_screen
    print_header "$APP_NAME $APP_VERSION"
    echo
    ui_menu_group "会话"
    ui_menu_item "1" "启动调优会话" "作为服务端，等待客户端连接" "$COLOR_GREEN"
    ui_menu_item "2" "加入调优会话" "作为客户端，连接已有服务端"
    echo
    ui_menu_group "调优"
    ui_menu_item "3" "自动优化" "选择目标，自动测速迭代调参"
    ui_menu_item "4" "查看状态" "双方 / 本机 TCP 参数"
    ui_menu_item "5" "智能推荐参数" "根据带宽、RTT、内存生成建议"
    ui_menu_item "6" "预制参数写入" "从五档预制参数中选择"
    echo
    ui_menu_group "管理"
    ui_menu_item "7" "回滚最近修改" "恢复优化前的系统参数" "$COLOR_YELLOW"
    ui_menu_item "0" "退出" "关闭脚本" "$COLOR_DIM"
    echo
    if ! prompt_read "${COLOR_BOLD}请选择：${COLOR_RESET}"; then
      warn "当前环境没有可用交互输入。"
      exit 1
    fi
    ans="$PROMPT_REPLY"
    case "$ans" in
      1) listen_mode || warn "服务端会话未正常结束。" ;;
      2)
        if ! prompt_read "请输入对端 Agent 地址，输入 0 返回：http://"; then pause_for_enter; continue; fi
        peer_host="$PROMPT_REPLY"
        is_back_choice "$peer_host" && continue
        if ! prompt_read "请输入 token，输入 0 返回："; then pause_for_enter; continue; fi
        token="$PROMPT_REPLY"
        is_back_choice "$token" && continue
        case "$peer_host" in
          http://*|https://*) peer_url="$peer_host" ;;
          *) peer_url="http://$peer_host" ;;
        esac
        join_mode --peer "$peer_url" --token "$token" --iperf-port "$IPERF_PORT" || warn "客户端会话未正常结束。"
        ;;
      3)
        if ! prompt_read "请输入 iperf3 对端主机，输入 0 返回："; then pause_for_enter; continue; fi
        host="$PROMPT_REPLY"
        is_back_choice "$host" && continue
        if ! validate_host_value "$host"; then warn "主机格式非法或以 '-' 开头。"; pause_for_enter; continue; fi
        if ! prompt_read "目标：1 重传优先 / 2 速率优先 / 3 启动速度优先 / 0 返回："; then pause_for_enter; continue; fi
        obj="$PROMPT_REPLY"
        is_back_choice "$obj" && continue
        case "$obj" in
          1) objective="retrans" ;;
          2) objective="throughput" ;;
          3) objective="startup" ;;
          *) warn "无效优化目标。"; pause_for_enter; continue ;;
        esac
        auto_tune "$host" "$IPERF_PORT" "$objective" 0 5 1 || warn "自动优化流程未完成。"
        ;;
      4) clear_screen; print_header "状态"; status_full || warn "读取状态失败。"; pause_for_enter ;;
      5)
        if ! prompt_read "请输入本地带宽 Mbps，输入 0 返回："; then pause_for_enter; continue; fi
        local_mbps="$PROMPT_REPLY"
        is_back_choice "$local_mbps" && continue
        if ! prompt_read "请输入对端带宽 Mbps，输入 0 返回："; then pause_for_enter; continue; fi
        peer_mbps="$PROMPT_REPLY"
        is_back_choice "$peer_mbps" && continue
        if ! prompt_read "请输入 RTT 延迟 ms，输入 0 返回："; then pause_for_enter; continue; fi
        rtt_ms="$PROMPT_REPLY"
        is_back_choice "$rtt_ms" && continue
        if ! prompt_read "请输入内存 MiB，直接回车自动识别，输入 0 返回："; then pause_for_enter; continue; fi
        mem_input="$PROMPT_REPLY"
        is_back_choice "$mem_input" && continue
        [ -n "$mem_input" ] || mem_input="$(memory_mb)"
        if ! prompt_read "目标：1 重传优先 / 2 速率优先 / 3 启动速度优先 / 0 返回："; then pause_for_enter; continue; fi
        obj="$PROMPT_REPLY"
        is_back_choice "$obj" && continue
        case "$obj" in
          1) objective="retrans" ;;
          2) objective="throughput" ;;
          3) objective="startup" ;;
          *) warn "无效推荐目标。"; pause_for_enter; continue ;;
        esac
        print_recommendation "$local_mbps" "$peer_mbps" "$rtt_ms" "$mem_input" "$objective" 0.79 0
        if ! prompt_read "是否即时保存这组智能参数？[y/N] "; then save_ans=""; else save_ans="$PROMPT_REPLY"; fi
        case "$save_ans" in
          y|Y) apply_smart "$local_mbps" "$peer_mbps" "$rtt_ms" "$mem_input" "$objective" 0.79 0 || warn "智能参数保存未完成。" ;;
        esac
        pause_for_enter
        ;;
      6)
        clear_screen
        print_header "预制参数写入"
        list_profiles
        echo
        ui_back_item
        if ! prompt_read "请输入中文预设名或英文别名，输入 0 返回："; then pause_for_enter; continue; fi
        profile="$PROMPT_REPLY"
        is_back_choice "$profile" && continue
        apply_profile "$profile" || warn "预制参数写入未完成。"
        pause_for_enter
        ;;
      7) clear_screen; print_header "回滚"; rollback_last || warn "回滚失败或没有可用备份。"; pause_for_enter ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause_for_enter ;;
    esac
  done
}

usage() {
  cat <<EOF
$APP_NAME $APP_VERSION

用法：
  sh tcp-tune.sh
  sh tcp-tune.sh --yes server [--public-url http://IP:39188]
  sh tcp-tune.sh --yes client --peer http://IP:PORT --token TOKEN
  sh tcp-tune.sh doctor
  sh tcp-tune.sh install
  sh tcp-tune.sh status
  sh tcp-tune.sh profiles
  sh tcp-tune.sh listen [--port 39188] [--iperf-port 5201] [--ttl 1800]
  sh tcp-tune.sh join --peer http://IP:PORT --token TOKEN [--direction download|upload] [--objective retrans|throughput|startup]
  sh tcp-tune.sh recommend --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024
  sh tcp-tune.sh apply-smart --local-mbps 1000 --peer-mbps 1000 --rtt-ms 100 --memory-mb 1024
  sh tcp-tune.sh apply-profile 中距均衡
  sh tcp-tune.sh apply-buffers RMEM_MAX WMEM_MAX
  sh tcp-tune.sh auto --host IP --direction download --objective retrans --target-retr 0 --rtt-ms 100
  sh tcp-tune.sh advanced-diagnose --host IP --machine-role relay --protocol-class tcp
  sh tcp-tune.sh local-minimal --ipv6-peer IPV6
  sh tcp-tune.sh vps-adapt --peer-ipv6 IPV6 --profile cubic-safe
  sh tcp-tune.sh rollback
  sh tcp-tune.sh stop-agent

全局选项：
  --yes    允许自动安装缺失依赖
  --dry-run    只展示将执行的动作，不写入系统
  --json    输出稳定 JSON envelope，诊断信息写入 stderr
  --non-interactive    禁止清屏、提示和读取终端输入
  --no-color    禁用 ANSI 颜色（也支持 NO_COLOR）
EOF
}
