# Module: src/cli/main.sh
main() {
  ASSUME_YES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --json) OUTPUT_MODE=json; NON_INTERACTIVE=1; NO_COLOR=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      *) break ;;
    esac
  done
  export ASSUME_YES DRY_RUN OUTPUT_MODE NON_INTERACTIVE NO_COLOR
  setup_colors
  trap 'stop_active_iperf_client; exit 130' INT TERM
  trap 'tune_abort_cleanup; stop_active_iperf_client >/dev/null 2>&1 || true' EXIT

  cmd="${1:-menu}"
  if [ "$#" -gt 0 ]; then shift; fi

  case "$cmd" in
    menu) menu ;;
    help|-h|--help) usage ;;
    doctor) doctor ;;
    install) install_only ;;
    status) status_full ;;
    profiles|list-profiles) list_profiles ;;
    apply-profile)
      [ "$#" -ge 1 ] || die "apply-profile 需要一个预设名。"
      profile_arg="$1"
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --dry-run) DRY_RUN=1; export DRY_RUN; shift ;;
          *) die "未知 apply-profile 参数：$1" ;;
        esac
      done
      apply_profile "$profile_arg"
      ;;
    apply-buffers) [ "$#" -ge 2 ] || die "apply-buffers 需要 RMEM_MAX 和 WMEM_MAX。"; apply_buffers "$@" ;;
    recommend|apply-smart)
      local_mbps=""
      peer_mbps=""
      rtt_ms=""
      memory_mb_value=""
      objective="retrans"
      ramp_rate="0.79"
      aggressive="0"
      allow_same_public="0"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --local-mbps) local_mbps="$2"; shift 2 ;;
          --peer-mbps) peer_mbps="$2"; shift 2 ;;
          --rtt-ms) rtt_ms="$2"; shift 2 ;;
          --memory-mb) memory_mb_value="$2"; shift 2 ;;
          --objective) objective="$2"; shift 2 ;;
          --ramp) ramp_rate="$2"; shift 2 ;;
          --aggressive) aggressive="1"; shift ;;
          *) die "未知 $cmd 参数：$1" ;;
        esac
      done
      [ -n "$local_mbps" ] || die "$cmd 需要 --local-mbps"
      [ -n "$peer_mbps" ] || die "$cmd 需要 --peer-mbps"
      [ -n "$rtt_ms" ] || die "$cmd 需要 --rtt-ms"
      [ -n "$memory_mb_value" ] || memory_mb_value="$(memory_mb)"
      if [ "$cmd" = "recommend" ]; then
        print_recommendation "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive"
      else
        apply_smart "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$objective" "$ramp_rate" "$aggressive"
      fi
      ;;
    rollback) rollback_last ;;
    defaults-status)
      if initial_defaults_available; then
        echo "默认值快照：已记录 ($(cat "$(initial_defaults_path_file)" 2>/dev/null || initial_defaults_dir))"
        exit 0
      fi
      echo "默认值快照：未记录"
      exit 1
      ;;
    restore-defaults)
      restore_initial_defaults
      ;;
    advanced-diagnose|高级诊断)
      advanced_diagnose_mode "$@"
      ;;
    local-minimal)
      ipv6_peer=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --ipv6-peer|--peer) ipv6_peer="$2"; shift 2 ;;
          *) die "未知 local-minimal 参数：$1" ;;
        esac
      done
      [ -n "$ipv6_peer" ] || warn "未提供 --ipv6-peer，将仅应用本机最小修正。"
      apply_openwrt_minimal_values 1 0 "$(max_notsent_lowat)" 1048576
      ;;
    vps-adapt)
      profile="cubic-safe"
      peer_ipv6=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --peer-ipv6|--peer) peer_ipv6="$2"; shift 2 ;;
          --profile) profile="$2"; shift 2 ;;
          *) die "未知 vps-adapt 参数：$1" ;;
        esac
      done
      [ -n "$peer_ipv6" ] || warn "未提供 --peer-ipv6，将仅应用 VPS 适配预设。"
      vps_adapt_profile "$profile"
      ;;
    server|listen)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --port) require_option_value "$1" "${2:-}"; AGENT_PORT="$2"; shift 2 ;;
          --iperf-port) require_option_value "$1" "${2:-}"; IPERF_PORT="$2"; shift 2 ;;
          --ttl) require_option_value "$1" "${2:-}"; SESSION_TTL="$2"; shift 2 ;;
          --public-url) require_option_value "$1" "${2:-}"; LISTEN_PUBLIC_URL="$2"; shift 2 ;;
          *) die "未知 $cmd 参数：$1" ;;
        esac
      done
      validate_port_value "$AGENT_PORT" || die "--port 必须在 1 和 65535 之间。"
      validate_port_value "$IPERF_PORT" || die "--iperf-port 必须在 1 和 65535 之间。"
      validate_positive_int_range "$SESSION_TTL" 1 2592000 || die "--ttl 必须是正整数。"
      if [ "$cmd" = "server" ]; then
        server_mode
      else
        listen_mode
      fi
      ;;
    client) client_mode "$@" ;;
    join) join_mode "$@" ;;
    _iperf-json)
      [ "$#" -eq 4 ] || die "_iperf-json 需要 host port reverse seconds"
      run_iperf_client "$1" "$2" "$3" "$4"
      ;;
    auto)
      host=""
      objective="retrans"
      target_retr="0"
      rounds="5"
      port="$IPERF_PORT"
      local_mbps="0"
      peer_mbps="0"
      rtt_ms="100"
      memory_mb_value=""
      ramp_rate="0.79"
      aggressive="0"
      allow_same_public="0"
      reverse="1"
      machine_role="endpoint"
      critical_direction="download"
      protocol_class="unknown"
      proxy_software=""
      traffic_path=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --host) require_option_value "$1" "${2:-}"; host="$2"; shift 2 ;;
          --port) require_option_value "$1" "${2:-}"; port="$2"; shift 2 ;;
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
          --machine-role) require_option_value "$1" "${2:-}"; machine_role="$2"; shift 2 ;;
          --critical-direction) require_option_value "$1" "${2:-}"; critical_direction="$2"; shift 2 ;;
          --protocol-class) require_option_value "$1" "${2:-}"; protocol_class="$2"; shift 2 ;;
          --proxy-software) require_option_value "$1" "${2:-}"; proxy_software="$2"; shift 2 ;;
          --traffic-path) require_option_value "$1" "${2:-}"; traffic_path="$2"; shift 2 ;;
          *) die "未知 auto 参数：$1" ;;
        esac
      done
      [ -n "$host" ] || die "auto 需要 --host"
      validate_host_value "$host" || die "--host 格式非法或以 '-' 开头。"
      validate_port_value "$port" || die "--port 必须在 1 和 65535 之间。"
      validate_objective "$objective" || die "--objective 只支持 retrans、throughput、startup。"
      validate_positive_int_range "$rounds" 1 10 || die "--rounds 必须在 1 和 10 之间。"
      validate_positive_int_range "$target_retr" 0 100000000 || die "--target-retr 必须是非负整数。"
      auto_tune "$host" "$port" "$objective" "$target_retr" "$rounds" "$reverse" "$local_mbps" "$peer_mbps" "$rtt_ms" "$memory_mb_value" "$ramp_rate" "$aggressive" "$allow_same_public" "$machine_role" "$critical_direction" "$protocol_class" "$proxy_software" "$traffic_path"
      ;;
    stop-agent) stop_agent "$@" ;;
    *) usage; die "未知命令：$cmd" ;;
  esac
}

if [ "${TCP_TUNE_LIBRARY:-0}" != "1" ]; then
  main "$@"
fi
