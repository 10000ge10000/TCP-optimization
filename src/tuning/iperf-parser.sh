# Module: src/tuning/iperf-parser.sh
iperf_python_field() {
  field="$1"
  python3 -c '
import json, sys
d=json.load(sys.stdin)
field=sys.argv[1]
end=d.get("end") or {}
intervals=d.get("intervals") or []
value=None
if field == "bps":
    value=(end.get("sum_received") or {}).get("bits_per_second")
    if value is None:
        vals=[(item.get("receiver") or {}).get("bits_per_second") for item in end.get("streams") or []]
        vals=[v for v in vals if v is not None]
        if vals: value=sum(vals)
    if value is None: value=(end.get("sum") or {}).get("bits_per_second")
elif field == "retrans":
    value=(end.get("sum_sent") or {}).get("retransmits")
    if value is None:
        vals=[(item.get("sender") or {}).get("retransmits") for item in end.get("streams") or []]
        vals=[v for v in vals if v is not None]
        if vals: value=sum(vals)
elif field == "first":
    if intervals:
        first=intervals[0] or {}
        value=(first.get("sum") or first.get("sum_received") or first.get("sum_sent") or {}).get("bits_per_second")
        if value is None:
            vals=[item.get("bits_per_second") for item in first.get("streams") or []]
            vals=[v for v in vals if v is not None]
            if vals: value=sum(vals)
if value is None: sys.exit(2)
try: value=float(value)
except (TypeError, ValueError): sys.exit(2)
if value < 0: sys.exit(2)
print(int(value))
' "$field"
}

jsonfilter_number() {
  expression="$1"
  jsonfilter -e "$expression" 2>/dev/null | awk '
    { for (i=1; i<=NF; i++) { if ($i !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) exit 2; value=$i; count++ } }
    END { if (count != 1) exit 2; printf "%.0f\n", value }
  '
}

jsonfilter_sum() {
  expression="$1"
  jsonfilter -e "$expression" 2>/dev/null | awk '
    { for (i=1; i<=NF; i++) { if ($i !~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) exit 2; total+=$i; count++ } }
    END { if (count < 1) exit 2; printf "%.0f\n", total }
  '
}

iperf_jsonfilter_field() {
  field="$1"
  case "$field" in
    bps)
      jsonfilter_number '@.end.sum_received.bits_per_second' && return 0
      jsonfilter_sum '@.end.streams[*].receiver.bits_per_second' && return 0
      jsonfilter_number '@.end.sum.bits_per_second' && return 0
      ;;
    retrans)
      jsonfilter_number '@.end.sum_sent.retransmits' && return 0
      jsonfilter_sum '@.end.streams[*].sender.retransmits' && return 0
      ;;
    first)
      jsonfilter_number '@.intervals[0].sum.bits_per_second' && return 0
      jsonfilter_sum '@.intervals[0].streams[*].bits_per_second' && return 0
      ;;
  esac
  return 2
}

# 最后降级只接受多行 pretty JSON，并只读取明确的聚合对象。
# 紧凑 JSON 或缺少聚合对象时显式失败，避免从 P4 streams 猜最后一个字段。
iperf_awk_field() {
  field="$1"
  awk -v wanted="$field" '
    NR == 1 && $0 ~ /[{].*[}]/ { compact=1 }
    # 状态切换只认对象/数组开括号：stream 里的数值字段 "end": 1.000315 不得改变解析状态。
    /"intervals"[[:space:]]*:[[:space:]]*\[/ { in_intervals=1; in_end=0 }
    in_intervals && /"sum"[[:space:]]*:[[:space:]]*[{]/ && first_bps=="" { interval_sum=1; next }
    interval_sum && /"bits_per_second"[[:space:]]*:/ {
      line=$0; sub(/^.*"bits_per_second"[[:space:]]*:[[:space:]]*/, "", line); sub(/[^0-9.eE+-].*$/, "", line)
      if (line ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) first_bps=line
      interval_sum=0
    }
    /"end"[[:space:]]*:[[:space:]]*[{]/ { in_end=1; in_intervals=0 }
    in_end && /"sum_received"[[:space:]]*:/ { block="received"; next }
    in_end && /"sum_sent"[[:space:]]*:/ { block="sent"; next }
    in_end && /"sum"[[:space:]]*:/ { block="sum"; next }
    in_end && /"bits_per_second"[[:space:]]*:/ {
      line=$0; sub(/^.*"bits_per_second"[[:space:]]*:[[:space:]]*/, "", line); sub(/[^0-9.eE+-].*$/, "", line)
      if (line ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) {
        if (block=="received" && received_bps=="") received_bps=line
        else if (block=="sum" && sum_bps=="") sum_bps=line
      }
    }
    in_end && block=="sent" && /"retransmits"[[:space:]]*:/ {
      line=$0; sub(/^.*"retransmits"[[:space:]]*:[[:space:]]*/, "", line); sub(/[^0-9].*$/, "", line)
      if (line ~ /^[0-9]+$/ && retrans=="") retrans=line
    }
    /^[[:space:]]*}[,]?[[:space:]]*$/ { block=""; interval_sum=0 }
    END {
      if (compact) exit 2
      if (wanted=="bps") value=(received_bps!="" ? received_bps : sum_bps)
      else if (wanted=="retrans") value=retrans
      else if (wanted=="first") value=first_bps
      if (value=="") exit 2
      printf "%.0f\n", value
    }
  '
}

extract_iperf_field() {
  field="$1"
  if have_cmd python3; then iperf_python_field "$field"; return; fi
  if have_cmd jsonfilter; then iperf_jsonfilter_field "$field"; return; fi
  iperf_awk_field "$field"
}

extract_retransmits() { extract_iperf_field retrans; }
extract_bps() { extract_iperf_field bps; }
extract_first_interval_bps() { extract_iperf_field first; }

iperf_metric_or_unknown() {
  field="$1"
  value="$(extract_iperf_field "$field" 2>/dev/null)" || value=""
  if is_unsigned_integer "$value"; then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
