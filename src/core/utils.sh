# Module: src/core/utils.sh
die() {
  printf "%s错误：%s%s\n" "$COLOR_RED" "$*" "$COLOR_RESET" >&2
  exit "${DIE_EXIT_CODE:-$EXIT_USAGE}"
}

info() {
  printf "%s[INFO]%s %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
  printf "%s[WARN]%s %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_integer() {
  value="${1:-}"
  [ -n "$value" ] || return 1
  case "$value" in
    -*) value="${value#-}" ;;
  esac
  [ -n "$value" ] || return 1
  case "$value" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

is_unsigned_integer() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}

is_positive_number() {
  awk -v value="$1" 'BEGIN {
    exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 > 0)
  }'
}

need_root() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    die "此操作需要 root 权限。请使用 root 用户或 sudo 运行。"
  fi
}

ensure_state_dir() {
  need_root
  umask 077
  mkdir -p "$STATE_DIR/backups" "$STATE_DIR/sessions" "$STATE_DIR/rolled-back"
  chmod 700 "$STATE_DIR" "$STATE_DIR/backups" "$STATE_DIR/sessions" "$STATE_DIR/rolled-back" 2>/dev/null || true
}

secure_temp_dir() {
  prefix="${1:-tcp-tune}"
  if have_cmd mktemp; then
    umask 077
    mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
    return
  fi
  return 1
}

atomic_copy_file() {
  source_file="$1"
  target_file="$2"
  target_dir=${target_file%/*}
  [ "$target_dir" = "$target_file" ] && target_dir=.
  mkdir -p "$target_dir"
  tmp_file="$target_dir/.tcp-tune.$$.tmp"
  umask 077
  cp "$source_file" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$target_file"
}

atomic_write_line() {
  target_file="$1"
  value="$2"
  target_dir=${target_file%/*}
  [ "$target_dir" = "$target_file" ] && target_dir=.
  mkdir -p "$target_dir"
  tmp_file="$target_dir/.tcp-tune.$$.tmp"
  umask 077
  printf '%s\n' "$value" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$target_file"
}

process_start_identity() {
  pid="$1"
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
    return
  fi
  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//'
}

process_matches_manifest() {
  pid="$1"
  expected_start="$2"
  expected_marker="$3"
  is_unsigned_integer "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual_start="$(process_start_identity "$pid" 2>/dev/null || true)"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -F -- "$expected_marker" >/dev/null 2>&1
  else
    ps -p "$pid" -o command= 2>/dev/null | grep -F -- "$expected_marker" >/dev/null 2>&1
  fi
}

manifest_value() {
  manifest_file="$1"
  manifest_key="$2"
  awk -F= -v key="$manifest_key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest_file" 2>/dev/null
}

write_process_manifest() {
  manifest_file="$1"
  pid="$2"
  session_id="$3"
  marker="$4"
  port="$5"
  start_id="$(process_start_identity "$pid" 2>/dev/null || true)"
  [ -n "$start_id" ] || return 1
  tmp_file="${manifest_file}.tmp.$$"
  umask 077
  {
    printf 'pid=%s\n' "$pid"
    printf 'session=%s\n' "$session_id"
    printf 'start=%s\n' "$start_id"
    printf 'marker=%s\n' "$marker"
    printf 'port=%s\n' "$port"
  } > "$tmp_file"
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$manifest_file"
}

stop_verified_process() {
  manifest_file="$1"
  expected_session="${2:-}"
  [ -f "$manifest_file" ] || return 1
  pid="$(manifest_value "$manifest_file" pid)"
  session="$(manifest_value "$manifest_file" session)"
  start_id="$(manifest_value "$manifest_file" start)"
  marker="$(manifest_value "$manifest_file" marker)"
  [ -z "$expected_session" ] || [ "$session" = "$expected_session" ] || return 2
  if ! process_matches_manifest "$pid" "$start_id" "$marker"; then
    warn "进程身份校验失败，拒绝终止 PID $pid。"
    return 3
  fi
  kill "$pid" 2>/dev/null || return 1
  wait_count=0
  while kill -0 "$pid" 2>/dev/null && [ "$wait_count" -lt 5 ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done
  if kill -0 "$pid" 2>/dev/null && process_matches_manifest "$pid" "$start_id" "$marker"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  return 0
}

initial_defaults_dir() {
  printf '%s\n' "$STATE_DIR/initial-defaults"
}

initial_defaults_path_file() {
  printf '%s\n' "$STATE_DIR/initial-defaults.path"
}

profiles_dir() {
  printf '%s\n' "$STATE_DIR/profiles"
}

latest_profile_path() {
  printf '%s\n' "$STATE_DIR/profiles/latest.md"
}

safe_report_text() {
  printf '%s' "${1:-}" | tr '\r\n\t,:"'"'"'' '        ' | cut -c 1-160
}

mask_report_peer() {
  value="${1:-}"
  [ -n "$value" ] || { echo ""; return 0; }
  case "$value" in
    http://\[*\]*|https://\[*\]*)
      inner="$(printf '%s' "$value" | sed 's#^[^[]*\[\([^]]*\)\].*#\1#')"
      first="${inner%%:*}"
      last="${inner##*:}"
      printf '%s\n' "$(safe_report_text "$first:...:$last")"
      return 0
      ;;
    *:*)
      first="${value%%:*}"
      last="${value##*:}"
      if [ -n "$first" ] && [ -n "$last" ] && [ "$first" != "$value" ]; then
        printf '%s\n' "$(safe_report_text "$first:...:$last")"
        return 0
      fi
      ;;
    *.*.*.*)
      masked="$(printf '%s\n' "$value" | awk -F. 'NF == 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {print $1 "." $2 ".x.x"; found=1} END {if (!found) print ""}')"
      if [ -n "$masked" ]; then
        printf '%s\n' "$(safe_report_text "$masked")"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$(safe_report_text "$value")"
}

unique_path() {
  base_path="$1"
  candidate_path="$base_path"
  suffix=1
  while [ -e "$candidate_path" ]; do
    candidate_path="${base_path}-$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate_path"
}
