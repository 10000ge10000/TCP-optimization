#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export TCP_TUNE_LIBRARY=1
export NO_COLOR=1
# shellcheck source=/dev/null
. "$ROOT_DIR/tcp-tune.sh"

passed=0
failed=0

check_equal() {
  name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual" >&2
    failed=$((failed + 1))
  fi
}

check_true() {
  name="$1"; shift
  if "$@"; then
    printf 'ok - %s\n' "$name"; passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$name" >&2; failed=$((failed + 1))
  fi
}

check_true "valid port" validate_port_value 39188
if validate_port_value 70000; then failed=$((failed + 1)); printf 'not ok - invalid port\n' >&2; else passed=$((passed + 1)); printf 'ok - invalid port rejected\n'; fi
check_true "valid IPv6 host" validate_host_value '2001:db8::1'
if validate_host_value '-evil'; then failed=$((failed + 1)); printf 'not ok - leading dash host\n' >&2; else passed=$((passed + 1)); printf 'ok - leading dash host rejected\n'; fi
check_true "valid peer URL" validate_peer_url 'http://127.0.0.1:39188'
if validate_peer_url 'http://user@example.com'; then failed=$((failed + 1)); printf 'not ok - userinfo URL\n' >&2; else passed=$((passed + 1)); printf 'ok - userinfo URL rejected\n'; fi

escaped="$(printf 'a\tb\\c"d\ne' | json_escape_string)"
check_equal "JSON escaping" 'a\tb\\c\"d\ne' "$escaped"

values="$(recommend_values 1000 500 100 1024 throughput 0.79 0)"
case "$values" in ERR*) failed=$((failed + 1)); printf 'not ok - BDP recommendation\n' >&2 ;; *) passed=$((passed + 1)); printf 'ok - BDP recommendation\n' ;; esac

detect_os() { OS_FAMILY=openwrt; OS_ID=openwrt; OS_NAME=OpenWrt; PKG_MANAGER=opkg; }
check_equal "OpenWrt 128MiB guard" 4194304 "$(memory_cap_bytes 128 0)"
check_equal "OpenWrt 512MiB guard" 16777216 "$(memory_cap_bytes 512 0)"

OBJECTIVE_GUARD_OK=1
check_true "retrans objective accepts 15 percent improvement" objective_step_improved retrans 100000000 97000000 100 85 50000000 48000000 0
if objective_step_improved throughput 100000000 102000000 10 10 50000000 50000000 0; then failed=$((failed + 1)); printf 'not ok - throughput tolerance\n' >&2; else passed=$((passed + 1)); printf 'ok - throughput requires 5 percent\n'; fi
OBJECTIVE_GUARD_OK=0
if objective_step_improved throughput 100000000 110000000 10 10 50000000 50000000 0; then failed=$((failed + 1)); printf 'not ok - qdisc RTT guard\n' >&2; else passed=$((passed + 1)); printf 'ok - qdisc RTT guard rejects\n'; fi

fixture='{"start":{"test_start":{"protocol":"TCP"}},"intervals":[{"sum":{"bits_per_second":25000000}}],"end":{"sum_sent":{"bits_per_second":99000000,"retransmits":7},"sum_received":{"bits_per_second":98000000}}}'
check_equal "iperf bps" 98000000 "$(printf '%s' "$fixture" | extract_bps)"
check_equal "iperf retransmits" 7 "$(printf '%s' "$fixture" | extract_retransmits)"
check_equal "iperf first interval" 25000000 "$(printf '%s' "$fixture" | extract_first_interval_bps)"

temp_dir="$(mktemp -d)"
DRY_RUN=1
SYSCTL_FILE="$temp_dir/sysctl.conf"
apply_buffers 4194304 4194304 2 65536 8192 4096 8192 81920 131072 >/dev/null
if [ -e "$SYSCTL_FILE" ]; then failed=$((failed + 1)); printf 'not ok - dry-run wrote sysctl file\n' >&2; else passed=$((passed + 1)); printf 'ok - dry-run does not write sysctl file\n'; fi
rmdir "$temp_dir"

temp_dir="$(mktemp -d)"
sleep 30 & owned_pid=$!
write_process_manifest "$temp_dir/process.manifest" "$owned_pid" test-session definitely-not-the-command 0
if stop_verified_process "$temp_dir/process.manifest" test-session 2>/dev/null; then
  failed=$((failed + 1)); printf 'not ok - PID identity mismatch\n' >&2
else
  if kill -0 "$owned_pid" 2>/dev/null; then passed=$((passed + 1)); printf 'ok - PID identity mismatch does not kill process\n'; else failed=$((failed + 1)); printf 'not ok - PID identity mismatch killed process\n' >&2; fi
fi
kill "$owned_pid" 2>/dev/null || true
wait "$owned_pid" 2>/dev/null || true
rm -f "$temp_dir/process.manifest"; rmdir "$temp_dir"

temp_dir="$(mktemp -d)"
mkdir -p "$temp_dir/bin" "$temp_dir/backup"
cat > "$temp_dir/bin/sysctl" <<'MOCK'
#!/bin/sh
state=${FAKE_SYSCTL_STATE:?}
case "$1" in
  -n)
    awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/,""); print; found=1} END {exit !found}' "$state"
    ;;
  -w)
    pair=$2; key=${pair%%=*}; value=${pair#*=}
    [ "${FAKE_FAIL_KEY:-}" != "$key" ] || exit 1
    if [ "${FAKE_MISMATCH_KEY:-}" = "$key" ] && [ ! -e "${FAKE_MISMATCH_MARKER:-/nonexistent}" ]; then
      value=$((value + 1))
      : > "$FAKE_MISMATCH_MARKER"
    fi
    awk -F= -v key="$key" -v value="$value" 'BEGIN{found=0} $1==key{print key "=" value; found=1; next} {print} END{if(!found) print key "=" value}' "$state" > "$state.tmp"
    mv "$state.tmp" "$state"
    printf '%s = %s\n' "$key" "$value"
    ;;
  *) exit 1 ;;
esac
MOCK
chmod 700 "$temp_dir/bin/sysctl"
printf '%s\n' 'net.ipv4.tcp_notsent_lowat=65536' 'net.ipv4.tcp_limit_output_bytes=131072' > "$temp_dir/state"
printf '%s\n' '# original' > "$temp_dir/managed.conf"
printf '%s\n' 'net.ipv4.tcp_notsent_lowat = 32768' 'net.ipv4.tcp_limit_output_bytes = 262144' > "$temp_dir/candidate.conf"
old_path=$PATH; PATH="$temp_dir/bin:$PATH"; export PATH
FAKE_SYSCTL_STATE="$temp_dir/state"; export FAKE_SYSCTL_STATE
unset FAKE_FAIL_KEY 2>/dev/null || true
detect_os() { OS_FAMILY=linux; OS_ID=linux; OS_NAME=Linux; PKG_MANAGER=none; }
if apply_sysctl_transaction "$temp_dir/managed.conf" "$temp_dir/candidate.conf" "$temp_dir/backup" test-target; then
  check_equal "transaction applied live value" 32768 "$(awk -F= '$1=="net.ipv4.tcp_notsent_lowat"{print $2}' "$temp_dir/state")"
else
  failed=$((failed + 1)); printf 'not ok - transaction apply\n' >&2
fi
FAKE_FAIL_KEY=net.ipv4.tcp_notsent_lowat; export FAKE_FAIL_KEY
printf '%s\n' 'net.ipv4.tcp_notsent_lowat = 65536' > "$temp_dir/rollback-values.conf"
if restore_runtime_values "$temp_dir/rollback-values.conf"; then
  failed=$((failed + 1)); printf 'not ok - rollback failure reported success\n' >&2
else
  passed=$((passed + 1)); printf 'ok - rollback failure is reported\n'
fi
unset FAKE_FAIL_KEY

mkdir -p "$temp_dir/mismatch"
printf '%s\n' 'net.ipv4.tcp_notsent_lowat=65536' 'net.ipv4.tcp_limit_output_bytes=131072' > "$temp_dir/state"
FAKE_MISMATCH_KEY=net.ipv4.tcp_notsent_lowat; export FAKE_MISMATCH_KEY
FAKE_MISMATCH_MARKER="$temp_dir/mismatch.once"; export FAKE_MISMATCH_MARKER
if apply_sysctl_transaction "$temp_dir/managed.conf" "$temp_dir/candidate.conf" "$temp_dir/mismatch" mismatch-target; then
  failed=$((failed + 1)); printf 'not ok - verification mismatch accepted\n' >&2
else
  check_equal "verification mismatch restored live value" 65536 "$(awk -F= '$1=="net.ipv4.tcp_notsent_lowat"{print $2}' "$temp_dir/state")"
fi
unset FAKE_MISMATCH_KEY FAKE_MISMATCH_MARKER

mkdir -p "$temp_dir/failure"
printf '%s\n' 'net.ipv4.tcp_notsent_lowat=65536' 'net.ipv4.tcp_limit_output_bytes=131072' > "$temp_dir/state"
FAKE_FAIL_KEY=net.ipv4.tcp_limit_output_bytes; export FAKE_FAIL_KEY
if apply_sysctl_transaction "$temp_dir/managed.conf" "$temp_dir/candidate.conf" "$temp_dir/failure" fail-target; then
  failed=$((failed + 1)); printf 'not ok - transaction partial failure accepted\n' >&2
else
  check_equal "transaction partial failure restored live value" 65536 "$(awk -F= '$1=="net.ipv4.tcp_notsent_lowat"{print $2}' "$temp_dir/state")"
fi
PATH=$old_path; export PATH
rm -f "$temp_dir/bin/sysctl" "$temp_dir/state" "$temp_dir/managed.conf" "$temp_dir/candidate.conf" "$temp_dir/rollback-values.conf"
rm -f "$temp_dir/backup"/* "$temp_dir/failure"/* "$temp_dir/mismatch"/* "$temp_dir/mismatch.once"
rmdir "$temp_dir/bin" "$temp_dir/backup" "$temp_dir/failure" "$temp_dir/mismatch" "$temp_dir"

# 平台诊断状态必须区分“不支持”“执行失败”和“未检测到”。这些覆盖函数放在
# 测试末尾，避免影响前面的事务测试。
have_cmd() {
  case "$1" in
    tc|ip|tracepath|ping) return 1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
check_equal "missing tc is unsupported" "unsupported unsupported" "$(qdisc_stats eth0)"
check_equal "unsupported qdisc delta is preserved" "unsupported unsupported" "$(qdisc_delta 'unsupported unsupported' 'unsupported unsupported')"
check_equal "missing ip route command is unsupported" "unsupported" "$(route_iface_for_host '2001:db8::1')"
check_equal "IPv6 PMTU without probe support is unsupported" "unsupported" "$(probe_pmtu '2001:db8::1')"

have_cmd() { [ "$1" = "ip" ]; }
ip() { return 1; }
check_equal "route command failure is failed" "failed" "$(route_iface_for_host '2001:db8::1')"

have_cmd() { [ "$1" = "tracepath" ]; }
tracepath() { return 1; }
check_equal "PMTU command failure is failed" "failed" "$(probe_pmtu '2001:db8::1')"

compact_p4='{"intervals":[{"streams":[{"bits_per_second":10000000},{"bits_per_second":20000000}]}],"end":{"streams":[{"sender":{"retransmits":2},"receiver":{"bits_per_second":40000000}},{"sender":{"retransmits":3},"receiver":{"bits_per_second":50000000}}]}}'
have_cmd() { [ "$1" = "python3" ]; }
check_equal "Python stream receiver throughput sum" 90000000 "$(printf '%s\n' "$compact_p4" | extract_bps)"
check_equal "Python stream sender retransmit sum" 5 "$(printf '%s\n' "$compact_p4" | extract_retransmits)"
check_equal "Python first interval stream sum" 30000000 "$(printf '%s\n' "$compact_p4" | extract_first_interval_bps)"

# 模拟 OpenWrt jsonfilter：汇总字段缺失时必须聚合 receiver/sender/interval streams。
have_cmd() { [ "$1" = "jsonfilter" ]; }
jsonfilter() {
  [ "$1" = "-e" ] || return 1
  case "$2" in
    '@.end.streams[*].receiver.bits_per_second') printf '40000000\n50000000\n' ;;
    '@.end.streams[*].sender.retransmits') printf '2\n3\n' ;;
    '@.intervals[0].streams[*].bits_per_second') printf '10000000\n20000000\n' ;;
    *) return 1 ;;
  esac
}
check_equal "jsonfilter receiver throughput fallback" 90000000 "$(printf '%s\n' "$compact_p4" | extract_bps)"
check_equal "jsonfilter sender retransmit fallback" 5 "$(printf '%s\n' "$compact_p4" | extract_retransmits)"
check_equal "jsonfilter first interval fallback" 30000000 "$(printf '%s\n' "$compact_p4" | extract_first_interval_bps)"

pretty_fixture='{
  "intervals": [
    {
      "sum": {
        "bits_per_second": 25000000
      }
    }
  ],
  "end": {
    "sum_sent": {
      "bits_per_second": 99000000,
      "retransmits": 7
    },
    "sum_received": {
      "bits_per_second": 98000000
    }
  }
}'
have_cmd() { return 1; }
check_equal "awk aggregate receiver throughput" 98000000 "$(printf '%s\n' "$pretty_fixture" | extract_bps)"
check_equal "awk aggregate sender retransmits" 7 "$(printf '%s\n' "$pretty_fixture" | extract_retransmits)"
check_equal "awk aggregate first interval" 25000000 "$(printf '%s\n' "$pretty_fixture" | extract_first_interval_bps)"
if printf '%s\n' "$compact_p4" | extract_bps >/dev/null 2>&1; then
  failed=$((failed + 1)); printf 'not ok - awk guessed compact P4 JSON\n' >&2
else
  passed=$((passed + 1)); printf 'ok - awk rejects compact P4 JSON\n'
fi
check_equal "missing parser metric remains unknown" unknown "$(printf '%s\n' '{"end":{}}' | iperf_metric_or_unknown bps)"
check_equal "unknown rate remains unknown" unknown "$(format_rate unknown)"

ensure_dependency() { return 0; }
iperf3() { printf '%s\n' "$*"; }
ipv6_args="$(run_iperf_client '2001:db8::1' 5201 0 5 '2001:db8::2' 1)"
case "$ipv6_args" in
  *'-B 2001:db8::2'*) passed=$((passed + 1)); printf 'ok - legal IPv6 bind is preserved\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - legal IPv6 bind was removed\n' >&2 ;;
esac
mismatch_args="$(run_iperf_client '2001:db8::1' 5201 0 5 '192.0.2.2' 1)"
case "$mismatch_args" in
  *'-B 192.0.2.2'*) failed=$((failed + 1)); printf 'not ok - mismatched IPv4 bind was preserved\n' >&2 ;;
  *) passed=$((passed + 1)); printf 'ok - mismatched IPv4 bind is removed\n' ;;
esac

run_iperf_client() { printf '%s\n' '{"end":{}}'; }
check_equal "diagnostics preserve missing metrics" "unknown unknown unknown unknown unknown unknown" "$(measure_iperf_pair '2001:db8::1' 5201 3 1 '')"
pair_rows="$(print_iperf_pair_rows P1 '1000000 1 500000 2000000 2 1000000')"
case "$pair_rows" in
  *'P1 上传'*'P1 下载'*) passed=$((passed + 1)); printf 'ok - diagnostic pair labels remain independent\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - diagnostic pair labels were overwritten\n' >&2 ;;
esac
if (profile_probe_metrics '2001:db8::1' 5201 '' >/dev/null 2>&1); then
  failed=$((failed + 1)); printf 'not ok - profile probe accepted missing metrics as zero\n' >&2
else
  passed=$((passed + 1)); printf 'ok - profile probe rejects missing metrics\n'
fi

# 结果页必须使用实际完成轮数，不能回退后仍显示配置的最大轮数。
if grep -F 'warn "已完成 $completed_rounds 轮，重传尚未降至目标值。"' "$ROOT_DIR/src/tuning/optimizer.sh" >/dev/null 2>&1; then
  passed=$((passed + 1)); printf 'ok - result uses actual completed rounds\n'
else
  failed=$((failed + 1)); printf 'not ok - result uses configured maximum rounds\n' >&2
fi

# 脱敏真实 fixtures：覆盖 3.17.1 P1/P4、3.16 成功/失败和截断输出。
have_cmd() { command -v "$1" >/dev/null 2>&1; }
real_fixture="$ROOT_DIR/tests/fixtures/iperf3/iperf-3.17.1-ipv6-download-p1.json"
real_bps="$(extract_bps < "$real_fixture")"
real_retrans="$(extract_retransmits < "$real_fixture")"
check_true "real reverse fixture receiver throughput" test "$real_bps" -gt 0
check_true "real reverse fixture sender retransmits" test "$real_retrans" -gt 0
p4_fixture="$ROOT_DIR/tests/fixtures/iperf3/iperf-3.17.1-ipv6-download-p4.json"
p4_bps="$(extract_bps < "$p4_fixture")"
check_true "real P4 fixture parses aggregate throughput" test "$p4_bps" -gt 0
if extract_bps < "$ROOT_DIR/tests/fixtures/iperf3/iperf-3.16-ipv6-upload-p1.json" >/dev/null 2>&1; then
  failed=$((failed + 1)); printf 'not ok - real failed fixture produced throughput\n' >&2
else
  passed=$((passed + 1)); printf 'ok - real failed fixture remains unknown\n'
fi
if extract_bps < "$ROOT_DIR/tests/fixtures/iperf3/truncated-output.json.part" >/dev/null 2>&1; then
  failed=$((failed + 1)); printf 'not ok - truncated fixture produced throughput\n' >&2
else
  passed=$((passed + 1)); printf 'ok - truncated fixture is rejected\n'
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
