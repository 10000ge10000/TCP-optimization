# Module: src/ai/client.sh
ai_content_from_response() {
  awk '
    BEGIN { key="\"content\""; in_string=0; escaped=0; found=0; out="" }
    {
      text = text $0 "\n"
    }
    END {
      pos = index(text, key)
      if (!pos) exit 1
      text = substr(text, pos + length(key))
      colon = index(text, ":")
      if (!colon) exit 1
      text = substr(text, colon + 1)
      start = index(text, "\"")
      if (!start) exit 1
      text = substr(text, start + 1)
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (escaped) {
          if (ch == "n") out = out "\n"
          else if (ch == "r") out = out "\r"
          else if (ch == "t") out = out "\t"
          else out = out ch
          escaped = 0
        } else if (ch == "\\") {
          escaped = 1
        } else if (ch == "\"") {
          print out
          exit 0
        } else {
          out = out ch
        }
      }
      exit 1
    }
  '
}

ai_curl_post_chat() {
  model="$1"
  prompt="$2"
  max_tokens="${3:-256}"
  base_url="${TCP_TUNE_AI_GATEWAY_URL:-$NVIDIA_BASE_URL}"
  base_url="${base_url%/}"
  validate_model_name "$model" || return 2
  escaped_model="$(printf '%s' "$model" | json_escape_string)"
  escaped_prompt="$(printf '%s' "$prompt" | json_escape_string)"
  body="$(cat <<EOF
{"model":"$escaped_model","messages":[{"role":"user","content":"$escaped_prompt"}],"temperature":0,"max_tokens":$max_tokens}
EOF
)"
  auth_header=""
  if [ -n "${NVIDIA_API_KEY:-}" ]; then
    auth_header="Authorization: Bearer $NVIDIA_API_KEY"
  elif [ -n "${TCP_TUNE_AI_GATEWAY_TOKEN:-}" ]; then
    auth_header="Authorization: Bearer $TCP_TUNE_AI_GATEWAY_TOKEN"
  fi
  curl_ip_arg=""
  case "${TCP_TUNE_AI_CURL_IP_FAMILY:-}" in
    -4|--ipv4) curl_ip_arg="-4" ;;
    -6|--ipv6) curl_ip_arg="-6" ;;
    *) curl_ip_arg="" ;;
  esac
  attempt=1
  max_attempts="$TCP_TUNE_AI_RETRIES"
  is_unsigned_integer "$max_attempts" || max_attempts=4
  [ "$max_attempts" -lt 1 ] && max_attempts=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$auth_header" ]; then
      curl -fs $curl_ip_arg --connect-timeout 10 --retry 1 --retry-delay 1 --max-time "$TCP_TUNE_AI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "User-Agent: TCP-optimization/1.0" \
        -H "$auth_header" \
        -d "$body" \
        "$base_url/chat/completions" && return 0
    else
      curl -fs $curl_ip_arg --connect-timeout 10 --retry 1 --retry-delay 1 --max-time "$TCP_TUNE_AI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "User-Agent: TCP-optimization/1.0" \
        -d "$body" \
        "$base_url/chat/completions" && return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

ai_curl_client() {
  mode="$1"
  shift || true
  have_cmd curl || die "AI 模式需要 curl。"
  case "$mode" in
    benchmark)
      models="$*"
      best_model=""
      best_ms=""
      for model in $models; do
        start="$(date +%s 2>/dev/null || echo 0)"
        if response="$(ai_curl_post_chat "$model" "Return only OK." 16 2>&1)"; then
          end="$(date +%s 2>/dev/null || echo "$start")"
          elapsed=$((end - start))
          printf '%s\tOK\t%ss\n' "$model" "$elapsed"
          if [ -z "$best_ms" ] || [ "$elapsed" -lt "$best_ms" ]; then
            best_ms="$elapsed"
            best_model="$model"
          fi
        else
          printf '%s\tFAIL\t%s\n' "$model" "$(printf '%s' "$response" | head -n 1 | cut -c 1-120)"
        fi
      done
      [ -n "$best_model" ] || return 2
      ;;
    select)
      configured="${NVIDIA_MODEL:-auto}"
      if [ -n "$configured" ] && [ "$configured" != "auto" ]; then
        echo "$configured"
        return 0
      fi
      models="$*"
      for model in $models; do
        if ai_curl_post_chat "$model" "Return only OK." 16 >/dev/null 2>&1; then
          echo "$model"
          return 0
        fi
      done
      return 2
      ;;
    decide)
      model="$1"
      objective="$2"
      role="$3"
      summary="$(cat)"
      upload_bps="$(printf '%s' "$summary" | json_number_field upload_bits_per_second 0)"
      upload_retr="$(printf '%s' "$summary" | json_number_field upload_retransmits 0)"
      upload_first="$(printf '%s' "$summary" | json_number_field upload_first_second_bits_per_second 0)"
      download_bps="$(printf '%s' "$summary" | json_number_field download_bits_per_second 0)"
      download_retr="$(printf '%s' "$summary" | json_number_field download_retransmits 0)"
      download_first="$(printf '%s' "$summary" | json_number_field download_first_second_bits_per_second 0)"
      max_notsent="$(ai_max_notsent)"
      prompt="$(cat <<EOF
You are a conservative TCP tuning controller. Return only one JSON object. Do not include shell commands.
Allowed congestion values: cubic,bbr,reno.
Allowed integer fields: mtu_probing 0/1, slow_start_after_idle 0/1, rmem_max,wmem_max between 1048576 and 268435456, notsent_lowat between 16384 and $max_notsent, limit_output_bytes between 131072 and 4194304.
OpenWrt may only use minimal=true plus mtu_probing, slow_start_after_idle, notsent_lowat, limit_output_bytes.
Objective: $objective
Role: $role
Measurements: upload_bps=$upload_bps, upload_retransmits=$upload_retr, upload_first_second_bps=$upload_first, download_bps=$download_bps, download_retransmits=$download_retr, download_first_second_bps=$download_first.
Objective rules: retrans must reduce retransmits without collapsing throughput; throughput must improve total throughput and tolerate only bounded retransmits; startup must favor first-second speed and short sender queues over peak throughput.
Prefer VPS-side adaptation. For high VPS->OpenWrt retransmits with good throughput, prefer cubic-safe. For OpenWrt upload bottlenecks that remain low across tests, do not over-increase buffers.
Your entire response must begin with { and end with }.
Return only this decision JSON schema: {"vps":{"congestion":"cubic","mtu_probing":1,"slow_start_after_idle":0,"rmem_max":67108864,"wmem_max":67108864,"notsent_lowat":$max_notsent,"limit_output_bytes":1048576},"openwrt":{"minimal":true,"mtu_probing":1,"slow_start_after_idle":0,"notsent_lowat":$max_notsent,"limit_output_bytes":1048576},"reason":"short Chinese reason"}.
EOF
)"
      response="$(ai_curl_post_chat "$model" "$prompt" 4096)"
      content="$(printf '%s' "$response" | ai_content_from_response)"
      printf '%s' "$content" | extract_json_object_text
      ;;
    normalize)
      role="$1"
      raw="$(cat)"
      max_notsent="$(ai_max_notsent)"
      congestion="$(printf '%s' "$raw" | json_string_field congestion cubic)"
      case "$congestion" in cubic|bbr|reno) ;; *) congestion="cubic" ;; esac
      vps_mtu="$(clamp_int "$(printf '%s' "$raw" | json_number_field mtu_probing 1)" 1 0 1)"
      vps_slow="$(clamp_int "$(printf '%s' "$raw" | json_number_field slow_start_after_idle 0)" 0 0 1)"
      vps_rmem="$(clamp_int "$(printf '%s' "$raw" | json_number_field rmem_max 67108864)" 67108864 1048576 268435456)"
      vps_wmem="$(clamp_int "$(printf '%s' "$raw" | json_number_field wmem_max 67108864)" 67108864 1048576 268435456)"
      vps_notsent="$(clamp_int "$(printf '%s' "$raw" | json_number_field notsent_lowat "$max_notsent")" "$max_notsent" 16384 "$max_notsent")"
      vps_limit="$(clamp_int "$(printf '%s' "$raw" | json_number_field limit_output_bytes 1048576)" 1048576 131072 4194304)"
      reason="$(printf '%s' "$raw" | json_string_field reason 未提供 | tr "'" " " | cut -c 1-160)"
      case "$role" in
        vps)
          printf "vps_congestion='%s'\n" "$congestion"
          printf "vps_mtu_probing='%s'\n" "$vps_mtu"
          printf "vps_slow_start='%s'\n" "$vps_slow"
          printf "vps_rmem_max='%s'\n" "$vps_rmem"
          printf "vps_wmem_max='%s'\n" "$vps_wmem"
          printf "vps_notsent='%s'\n" "$vps_notsent"
          printf "vps_limit='%s'\n" "$vps_limit"
          printf "ai_reason='%s'\n" "$reason"
          ;;
        openwrt)
          printf "op_minimal='1'\n"
          printf "op_mtu_probing='%s'\n" "$vps_mtu"
          printf "op_slow_start='%s'\n" "$vps_slow"
          printf "op_notsent='%s'\n" "$vps_notsent"
          printf "op_limit='%s'\n" "$vps_limit"
          printf "ai_reason='%s'\n" "$reason"
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

ai_require_env() {
  if ! have_cmd python3 && ! have_cmd curl; then
    die "AI 模式需要 curl；有 python3 时会使用更完整的解析路径。"
  fi
  if [ -z "${NVIDIA_API_KEY:-}" ] && [ -z "${TCP_TUNE_AI_GATEWAY_URL:-}" ]; then
    die "缺少 NVIDIA_API_KEY 或 TCP_TUNE_AI_GATEWAY_URL。请通过环境变量提供，不要把真实 Key 写入脚本或仓库。"
  fi
}

ai_python_client() {
  mode="$1"
  shift || true
  export NVIDIA_BASE_URL NVIDIA_MODEL TCP_TUNE_AI_TIMEOUT TCP_TUNE_AI_GATEWAY_URL TCP_TUNE_AI_GATEWAY_TOKEN TCP_TUNE_AI_MAX_NOTSENT
  if ! have_cmd python3; then
    ai_curl_client "$mode" "$@"
    return "$?"
  fi
  ai_tmp_dir="$(secure_temp_dir tcp-tune-ai)" || {
    DIE_EXIT_CODE="$EXIT_DEPENDENCY" die "无法创建安全 AI 临时目录。"
  }
  tmp_py="$ai_tmp_dir/client.py"
  cat > "$tmp_py" <<'PY'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

mode = sys.argv[1]
gateway_url = os.environ.get("TCP_TUNE_AI_GATEWAY_URL", "").strip()
base_url = (gateway_url or os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")).rstrip("/")
api_key = os.environ.get("NVIDIA_API_KEY", "") or os.environ.get("TCP_TUNE_AI_GATEWAY_TOKEN", "")
timeout = float(os.environ.get("TCP_TUNE_AI_TIMEOUT", "20"))

def post_chat(model, messages, max_tokens=256):
    if not api_key and not gateway_url:
        raise RuntimeError("missing NVIDIA_API_KEY")
    body = {
        "model": model,
        "messages": messages,
        "temperature": 0,
        "max_tokens": max_tokens,
    }
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "TCP-optimization/1.0",
    }
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    req = urllib.request.Request(
        base_url + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("missing response choices")
    choice = choices[0]
    message = choice.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                parts.append(str(item.get("text") or item.get("content") or ""))
            else:
                parts.append(str(item))
        content = "".join(parts)
    if content is None:
        content = choice.get("text") or data.get("output_text") or message.get("reasoning_content")
    if content is None:
        keys = ",".join(sorted(message.keys() or choice.keys()))
        raise RuntimeError("missing response content: " + keys)
    return str(content)

def extract_json(text):
    text = text.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    if fenced:
        text = fenced.group(1)
    else:
        start = text.find("{")
        if start >= 0:
            depth = 0
            in_string = False
            escaped = False
            end = -1
            for idx, ch in enumerate(text[start:], start):
                if in_string:
                    if escaped:
                        escaped = False
                    elif ch == "\\":
                        escaped = True
                    elif ch == '"':
                        in_string = False
                else:
                    if ch == '"':
                        in_string = True
                    elif ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                        if depth == 0:
                            end = idx
                            break
            if end >= start:
                text = text[start:end + 1]
    return json.loads(text, strict=False)

if mode == "benchmark":
    models = sys.argv[2:]
    results = []
    for model in models:
        start = time.time()
        try:
            content = post_chat(model, [{"role": "user", "content": "Return only OK."}], 16)
            elapsed = time.time() - start
            ok = bool(content.strip())
            results.append((elapsed, model, ok, ""))
            print(f"{model}\tOK\t{elapsed:.3f}s")
        except Exception as exc:
            results.append((999999.0, model, False, str(exc).splitlines()[0][:120]))
            print(f"{model}\tFAIL\t{str(exc).splitlines()[0][:120]}")
    usable = [item for item in results if item[2]]
    if not usable:
        sys.exit(2)
    usable.sort()
    print("BEST\t" + usable[0][1])
elif mode == "select":
    configured = os.environ.get("NVIDIA_MODEL", "auto")
    if configured and configured != "auto":
        print(configured)
        sys.exit(0)
    models = sys.argv[2:]
    best = None
    for model in models:
        start = time.time()
        try:
            post_chat(model, [{"role": "user", "content": "Return only OK."}], 16)
            elapsed = time.time() - start
            if best is None or elapsed < best[0]:
                best = (elapsed, model)
        except Exception:
            continue
    if best is None:
        sys.exit(2)
    print(best[1])
elif mode == "decide":
    model = sys.argv[2]
    objective = sys.argv[3]
    role = sys.argv[4]
    summary = sys.stdin.read()
    try:
        metrics = json.loads(summary)
    except Exception:
        metrics = {}
    upload_bps = metrics.get("upload_bits_per_second", 0)
    upload_retr = metrics.get("upload_retransmits", 0)
    download_bps = metrics.get("download_bits_per_second", 0)
    download_retr = metrics.get("download_retransmits", 0)
    max_notsent = int(os.environ.get("TCP_TUNE_AI_MAX_NOTSENT", "1048576"))
    max_notsent = max(16384, min(2147483647, max_notsent))
    system = (
        "You are a conservative TCP tuning controller. "
        "Return only one JSON object. Do not include shell commands. "
        "Allowed congestion values: cubic,bbr,reno. "
        "Allowed integer fields: mtu_probing 0/1, slow_start_after_idle 0/1, "
        "rmem_max,wmem_max between 1048576 and 268435456, "
        f"notsent_lowat between 16384 and {max_notsent}, "
        "limit_output_bytes between 131072 and 4194304. "
        "OpenWrt may only use minimal=true plus mtu_probing, slow_start_after_idle, notsent_lowat, limit_output_bytes."
    )
    user = (
        "Objective: " + objective + "\nRole: " + role + "\n"
        f"Measurements: upload_bps={upload_bps}, upload_retransmits={upload_retr}, "
        f"download_bps={download_bps}, download_retransmits={download_retr}.\n"
        "Prefer VPS-side adaptation. For high VPS->OpenWrt retransmits with good throughput, prefer cubic-safe. "
        "For OpenWrt upload bottlenecks that remain low across tests, do not over-increase buffers.\n"
        "Your entire response must begin with { and end with }. "
        "Return only this decision JSON schema: {\"vps\":{\"congestion\":\"cubic\",\"mtu_probing\":1,\"slow_start_after_idle\":0,"
        f"\"rmem_max\":67108864,\"wmem_max\":67108864,\"notsent_lowat\":{max_notsent},"
        "\"limit_output_bytes\":1048576},\"openwrt\":{\"minimal\":true,\"mtu_probing\":1,"
        f"\"slow_start_after_idle\":0,\"notsent_lowat\":{max_notsent},\"limit_output_bytes\":1048576}},"
        "\"reason\":\"short Chinese reason\"}."
    )
    content = post_chat(model, [{"role": "system", "content": system}, {"role": "user", "content": user}], 4096)
    print(json.dumps(extract_json(content), ensure_ascii=False, separators=(",", ":")))
elif mode == "normalize":
    role = sys.argv[2]
    raw = sys.stdin.read()
    data = extract_json(raw)
    max_notsent = int(os.environ.get("TCP_TUNE_AI_MAX_NOTSENT", "1048576"))
    max_notsent = max(16384, min(2147483647, max_notsent))
    vps = data.get("vps") if isinstance(data.get("vps"), dict) else {}
    op = data.get("openwrt") if isinstance(data.get("openwrt"), dict) else {}
    reason = str(data.get("reason", ""))[:160].replace("'", "")

    def choice(value, allowed, default):
        value = str(value or default)
        return value if value in allowed else default

    def integer(value, default, low, high):
        try:
            value = int(value)
        except Exception:
            value = default
        return max(low, min(high, value))

    out = {
        "vps_congestion": choice(vps.get("congestion"), {"cubic", "bbr", "reno"}, "cubic"),
        "vps_mtu_probing": integer(vps.get("mtu_probing"), 1, 0, 1),
        "vps_slow_start": integer(vps.get("slow_start_after_idle"), 0, 0, 1),
        "vps_rmem_max": integer(vps.get("rmem_max"), 67108864, 1048576, 268435456),
        "vps_wmem_max": integer(vps.get("wmem_max"), 67108864, 1048576, 268435456),
        "vps_notsent": integer(vps.get("notsent_lowat"), max_notsent, 16384, max_notsent),
        "vps_limit": integer(vps.get("limit_output_bytes"), 1048576, 131072, 4194304),
        "op_minimal": 1 if op.get("minimal", True) else 0,
        "op_mtu_probing": integer(op.get("mtu_probing"), 1, 0, 1),
        "op_slow_start": integer(op.get("slow_start_after_idle"), 0, 0, 1),
        "op_notsent": integer(op.get("notsent_lowat"), max_notsent, 16384, max_notsent),
        "op_limit": integer(op.get("limit_output_bytes"), 1048576, 131072, 4194304),
        "ai_reason": reason,
    }
    if role == "vps":
        keys = ["vps_congestion", "vps_mtu_probing", "vps_slow_start", "vps_rmem_max", "vps_wmem_max", "vps_notsent", "vps_limit", "ai_reason"]
    elif role == "openwrt":
        keys = ["op_minimal", "op_mtu_probing", "op_slow_start", "op_notsent", "op_limit", "ai_reason"]
    else:
        keys = list(out.keys())
    for key in keys:
        print(f"{key}='{out[key]}'")
else:
    raise SystemExit("unknown mode")
PY
  rc=0
  python3 "$tmp_py" "$mode" "$@" || rc="$?"
  rm -f "$tmp_py"
  rmdir "$ai_tmp_dir" 2>/dev/null || true
  return "$rc"
}

ai_select_model() {
  # shellcheck disable=SC2086
  ai_python_client select $AI_MODEL_CANDIDATES
}

ai_benchmark_models() {
  ai_require_env
  print_header "AI 模型测速"
  ui_subtitle "只发送短测试请求，不输出 API Key。"
  rc=0
  old_ifs="$IFS"; IFS=' '
  # shellcheck disable=SC2086
  set -- $AI_MODEL_CANDIDATES
  IFS="$old_ifs"
  output="$(ai_python_client benchmark "$@")" || rc="$?"
  printf '%s\n' "$output"
  printf 'BEST\t%s\n' "${NVIDIA_MODEL:-gpt-5.5}"
  return "$rc"
}

ai_measure_pair() {
  host="$1"
  port="$2"
  seconds="${3:-12}"
  bind_ip="$(local_lan_ipv4 || true)"
  case "$host" in *:*) bind_ip="" ;; esac

  ui_note "测速" "上传：本机 → 对端（$TCP_TUNE_SAMPLE_COUNT 次中位数）" >&2
  upload_metrics="$(measure_iperf_samples "$host" "$port" 0 "$seconds" "$bind_ip" 1 "$TCP_TUNE_SAMPLE_COUNT")" || {
    DIE_EXIT_CODE="$EXIT_BENCHMARK" die "上传多样本测速失败或波动过大。"
  }
  tab="$(printf '\t')"; old_ifs="$IFS"; IFS="$tab"
  read -r upload_bps upload_retr upload_first upload_spread <<EOF
$upload_metrics
EOF
  IFS="$old_ifs"

  ui_note "测速" "下载：对端 → 本机（$TCP_TUNE_SAMPLE_COUNT 次中位数）" >&2
  download_metrics="$(measure_iperf_samples "$host" "$port" 1 "$seconds" "$bind_ip" 1 "$TCP_TUNE_SAMPLE_COUNT")" || {
    DIE_EXIT_CODE="$EXIT_BENCHMARK" die "下载多样本测速失败或波动过大。"
  }
  old_ifs="$IFS"; IFS="$tab"
  read -r download_bps download_retr download_first download_spread <<EOF
$download_metrics
EOF
  IFS="$old_ifs"

  cat <<EOF
{"upload_bits_per_second":$upload_bps,"upload_retransmits":$upload_retr,"upload_first_second_bits_per_second":$upload_first,"upload_spread_percent":$upload_spread,"download_bits_per_second":$download_bps,"download_retransmits":$download_retr,"download_first_second_bits_per_second":$download_first,"download_spread_percent":$download_spread}
EOF
}
