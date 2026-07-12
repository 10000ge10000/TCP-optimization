# Module: src/core/validation.sh
validate_machine_role() {
  case "${1:-endpoint}" in
    relay|landing|mixed|endpoint) return 0 ;;
    *) return 1 ;;
  esac
}

validate_critical_direction() {
  case "${1:-download}" in
    download|upload|both) return 0 ;;
    *) return 1 ;;
  esac
}

validate_protocol_class() {
  case "${1:-unknown}" in
    tcp|udp-quic|mixed|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_link_context() {
  machine_role="${1:-endpoint}"
  critical_direction="${2:-download}"
  protocol_class="${3:-unknown}"
  proxy_software="$(safe_report_text "${4:-}")"
  traffic_path="$(safe_report_text "${5:-}")"
  validate_machine_role "$machine_role" || die "--machine-role 只支持 relay、landing、mixed、endpoint。"
  validate_critical_direction "$critical_direction" || die "--critical-direction 只支持 download、upload、both。"
  validate_protocol_class "$protocol_class" || die "--protocol-class 只支持 tcp、udp-quic、mixed、unknown。"
  printf "%s\t%s\t%s\t%s\t%s\n" "$machine_role" "$critical_direction" "$protocol_class" "$proxy_software" "$traffic_path"
}

validate_bool_number() {
  case "$1" in
    0|1) return 0 ;;
    *) return 1 ;;
  esac
}

validate_positive_int_range() {
  value="$1"
  min="$2"
  max="$3"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN { exit !(value + 0 >= min + 0 && value + 0 <= max + 0) }'
}

require_option_value() {
  opt="$1"
  value="${2:-}"
  case "$value" in
    ''|--*) die "$opt 需要参数值" ;;
  esac
}

validate_port_value() {
  validate_positive_int_range "$1" 1 65535
}

validate_host_value() {
  host="${1:-}"
  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  case "$host" in
    -*|*[!A-Za-z0-9._:%-]*|*..*) return 1 ;;
  esac
  return 0
}

validate_peer_url() {
  value="${1:-}"
  case "$value" in http://*|https://*) ;; *) return 1 ;; esac
  case "$value" in *[[:space:]]*|*@*|*\?*|*\#*) return 1 ;; esac
  return 0
}

validate_objective() {
  case "${1:-}" in retrans|throughput|startup) return 0 ;; *) return 1 ;; esac
}

validate_model_name() {
  value="${1:-}"
  [ -n "$value" ] && [ "${#value}" -le 128 ] || return 1
  case "$value" in -*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  return 0
}

ai_max_notsent() {
  value="$TCP_TUNE_AI_MAX_NOTSENT"
  validate_positive_int_range "$value" 16384 2147483647 || value=1048576
  echo "$value"
}
