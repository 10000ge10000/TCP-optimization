#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export TCP_TUNE_LIBRARY=1
export NO_COLOR=1
# shellcheck source=/dev/null
. "$ROOT_DIR/tcp-tune.sh"

# 测试以非 root 运行:状态目录指向临时目录,并以同权限语义替代 root 检查。
TEST_STATE_DIR="$(mktemp -d)"
STATE_DIR="$TEST_STATE_DIR"
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
ensure_state_dir() {
  umask 077
  mkdir -p "$STATE_DIR/backups" "$STATE_DIR/sessions" "$STATE_DIR/rolled-back"
}

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

check_equal "bare IPv4 peer is masked" "192.0.x.x" "$(mask_report_peer '192.0.2.10')"
# safe_report_text 会把冒号替换为空格；关键断言是 IPv4 段被打码且端口保留。
check_equal "IPv4:port peer keeps port but masks address" "192.0.x.x 5201" "$(mask_report_peer '192.0.2.10:5201')"

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
    if [ "${FAKE_TAB_KEY:-}" = "$2" ]; then
      # 模拟内核对多值项的读回格式：字段间使用制表符分隔。
      awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/,""); gsub(/ /,"\t"); print; found=1} END {exit !found}' "$state"
    else
      awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/,""); print; found=1} END {exit !found}' "$state"
    fi
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
unset FAKE_FAIL_KEY 2>/dev/null || true

# 多值键（tcp_rmem 等）内核读回使用制表符分隔，写后校验必须归一化空白后再比较。
mkdir -p "$temp_dir/tabbed"
printf '%s\n' 'net.ipv4.tcp_rmem=4096 131072 6291456' > "$temp_dir/state"
printf '%s\n' 'net.ipv4.tcp_rmem = 4096 87380 8388608' > "$temp_dir/tabbed-candidate.conf"
FAKE_TAB_KEY=net.ipv4.tcp_rmem; export FAKE_TAB_KEY
if apply_sysctl_transaction "$temp_dir/managed.conf" "$temp_dir/tabbed-candidate.conf" "$temp_dir/tabbed" tabbed-target; then
  check_equal "multi-value key survives tab-separated readback" '4096 87380 8388608' "$(awk -F= '$1=="net.ipv4.tcp_rmem"{print $2}' "$temp_dir/state")"
else
  failed=$((failed + 1)); printf 'not ok - multi-value key rejected by tab-separated readback\n' >&2
fi
unset FAKE_TAB_KEY

# 备份元数据损坏时必须拒绝恢复，而不是把目标文件当作“原本不存在”删除。
mkdir -p "$temp_dir/corrupt"
printf '%s\n' 'live content' > "$temp_dir/live.conf"
printf '%s\n' "$temp_dir/live.conf" > "$temp_dir/corrupt/broken.path"
: > "$temp_dir/corrupt/broken.existed"
if restore_managed_file "$temp_dir/corrupt" broken 2>/dev/null; then
  failed=$((failed + 1)); printf 'not ok - corrupt backup metadata was accepted\n' >&2
else
  if [ -f "$temp_dir/live.conf" ]; then
    passed=$((passed + 1)); printf 'ok - corrupt backup metadata refuses restore and keeps target\n'
  else
    failed=$((failed + 1)); printf 'not ok - corrupt backup metadata deleted target file\n' >&2
  fi
fi
PATH=$old_path; export PATH
rm -f "$temp_dir/bin/sysctl" "$temp_dir/state" "$temp_dir/managed.conf" "$temp_dir/candidate.conf" "$temp_dir/rollback-values.conf"
rm -f "$temp_dir/tabbed-candidate.conf" "$temp_dir/live.conf"
rm -f "$temp_dir/backup"/* "$temp_dir/failure"/* "$temp_dir/mismatch"/* "$temp_dir/tabbed"/* "$temp_dir/corrupt"/* "$temp_dir/mismatch.once"
rmdir "$temp_dir/bin" "$temp_dir/backup" "$temp_dir/failure" "$temp_dir/mismatch" "$temp_dir/tabbed" "$temp_dir/corrupt" "$temp_dir"

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
have_cmd() { return 1; }
check_equal "missing tc overrides route failure" "unsupported unsupported" "$(qdisc_stats failed)"

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
# 真实 fixture 含 stream 级数值 "end"/"start" 字段，曾使 awk 状态机提前切换、first 永远缺失。
# 期望值按 awk 后端的 %.0f 取整（与 python 后端的 int() 截断可能相差 1 bps）。
real_p1_fixture="$ROOT_DIR/tests/fixtures/iperf3/iperf-3.17.1-ipv6-upload-p1.json"
check_equal "awk real fixture receiver throughput" 64288432 "$(extract_bps < "$real_p1_fixture")"
check_equal "awk real fixture first interval" 248227048 "$(extract_first_interval_bps < "$real_p1_fixture")"
real_dl_fixture="$ROOT_DIR/tests/fixtures/iperf3/iperf-3.17.1-ipv4-download-p1.json"
check_equal "awk real download fixture first interval" 569197499 "$(extract_first_interval_bps < "$real_dl_fixture")"
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

# auto_tune 端到端行为测试：外部依赖全部用桩替换，验证结果页语义而非源码文案。
need_root() { return 0; }
install_runtime_deps() { return 0; }
detect_os() { OS_FAMILY=linux; OS_ID=linux; OS_NAME=Linux; PKG_MANAGER=none; }
ensure_tcp_baseline() { return 0; }
manual_backup_begin() { printf '%s\n' "$TEST_STATE_DIR"; }
memory_mb() { echo 1024; }
public_ip() { echo ""; }
local_lan_ipv4() { echo 192.0.2.10; }
route_iface_for_host() { echo unsupported; }
iface_mtu() { echo unknown; }
probe_pmtu() { echo unsupported; }
qdisc_stats() { echo "unsupported unsupported"; }
detect_rtt_ms() { echo 50; }
post_client_stage() { return 0; }
post_json() { return 0; }
write_tuning_profile() { printf '%s\n' "$TEST_STATE_DIR/fake-report.md"; }
apply_buffers() { printf 'APPLY_BUFFERS_CALLED\n'; }
rollback_last() { printf 'ROLLBACK_CALLED\n'; }
restore_manual_backup() { return 0; }
FAKE_SAMPLE_RETR=0
measure_iperf_samples() { printf '100000000\t%s\t50000000\t2\n' "$FAKE_SAMPLE_RETR"; }

auto_baseline_output="$(auto_tune '2001:db8::1' 5201 retrans 0 3 1 0 0 100 1024 0.79 0 1 2>&1)" || auto_baseline_output="AUTO_TUNE_FAILED
$auto_baseline_output"
case "$auto_baseline_output" in
  AUTO_TUNE_FAILED*) failed=$((failed + 1)); printf 'not ok - baseline-met auto_tune exits cleanly\n' >&2 ;;
  *) passed=$((passed + 1)); printf 'ok - baseline-met auto_tune exits cleanly\n' ;;
esac
case "$auto_baseline_output" in
  *APPLY_BUFFERS_CALLED*) failed=$((failed + 1)); printf 'not ok - baseline-met run must not write parameters\n' >&2 ;;
  *) passed=$((passed + 1)); printf 'ok - baseline-met run does not write parameters\n' ;;
esac
case "$auto_baseline_output" in
  *'共测试 1 轮'*) passed=$((passed + 1)); printf 'ok - result page shows actual completed rounds\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - result page shows actual completed rounds\n' >&2 ;;
esac
case "$auto_baseline_output" in
  *'本次只完成基线测试'*) passed=$((passed + 1)); printf 'ok - baseline-only result does not claim retained parameters\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - baseline-only result claims retained parameters\n' >&2 ;;
esac

FAKE_SAMPLE_RETR=500
auto_unmet_output="$(auto_tune '2001:db8::1' 5201 retrans 0 1 1 0 0 100 1024 0.79 0 1 2>&1)" || auto_unmet_output="AUTO_TUNE_FAILED
$auto_unmet_output"
case "$auto_unmet_output" in
  *'已完成基线测试，本轮没有写入参数。'*) passed=$((passed + 1)); printf 'ok - exhausted rounds without target keeps baseline-only wording\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - exhausted rounds without target keeps baseline-only wording\n' >&2 ;;
esac
case "$auto_unmet_output" in
  *'已完成 1 轮，重传尚未降至目标值。'*) passed=$((passed + 1)); printf 'ok - unmet target reports actual completed rounds\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - unmet target reports actual completed rounds\n' >&2 ;;
esac

# recommend_values 边界：非法输入必须显式返回 ERR，不得静默给出参数。
case "$(recommend_values 0 500 100 1024 throughput 0.79 0)" in
  ERR*) passed=$((passed + 1)); printf 'ok - recommend rejects zero bandwidth\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - recommend accepted zero bandwidth\n' >&2 ;;
esac
case "$(recommend_values 1000 500 0 1024 throughput 0.79 0)" in
  ERR*) passed=$((passed + 1)); printf 'ok - recommend rejects zero rtt\n' ;;
  *) failed=$((failed + 1)); printf 'not ok - recommend accepted zero rtt\n' >&2 ;;
esac

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
