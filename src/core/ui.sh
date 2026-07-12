# Module: src/core/ui.sh
setup_colors() {
  COLOR_RESET=""; COLOR_BOLD=""; COLOR_DIM=""; COLOR_RED=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    COLOR_RESET="$(printf '\033[0m')"
    COLOR_BOLD="$(printf '\033[1m')"
    COLOR_DIM="$(printf '\033[2m')"
    COLOR_RED="$(printf '\033[31m')"
    COLOR_GREEN="$(printf '\033[32m')"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_BLUE="$(printf '\033[34m')"
    COLOR_CYAN="$(printf '\033[36m')"
  fi
}

setup_colors

clear_screen() {
  if [ -t 1 ]; then
    printf '\033[2J\033[H'
  fi
}

has_interactive_input() {
  [ "${NON_INTERACTIVE:-0}" != "1" ] || return 1
  [ -t 0 ] || { [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; }
}

prompt_read() {
  prompt="$1"
  printf "%s" "$prompt"
  if [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    IFS= read -r PROMPT_REPLY < /dev/tty || return 1
  else
    IFS= read -r PROMPT_REPLY || return 1
  fi
  return 0
}

is_back_choice() {
  case "$1" in
    0|q|Q|b|B) return 0 ;;
    *) return 1 ;;
  esac
}

return_to_menu() {
  MENU_RETURNED="1"
  return 0
}

ui_back_item() {
  ui_menu_item "0" "返回主菜单" "不执行本页操作" "$COLOR_DIM"
}

pause_for_enter() {
  has_interactive_input || return 0
  printf "\n%s按回车返回主菜单...%s" "$COLOR_DIM" "$COLOR_RESET"
  if [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    IFS= read -r PROMPT_REPLY < /dev/tty || true
  else
    IFS= read -r PROMPT_REPLY || true
  fi
}

# 显示宽度计算：中文等 CJK 字符占 2 列，ASCII 占 1 列
# 用 awk 按 UTF-8 字节范围统计 CJK 字符数，补齐到指定显示宽度
ui_pad() {
  text="$1"
  width="$2"
  # awk 仅返回显示宽度（CJK 字符算 2），补空格交给 shell printf，兼容 busybox awk
  disp=$(printf '%s' "$text" | awk '{
    s = $0
    disp = 0
    n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c < "\200") disp += 1
      else if (c >= "\300") disp += 2
    }
    print disp + 0
  }')
  [ -z "$disp" ] && disp=0
  pad=$((width - disp))
  if [ "$pad" -gt 0 ]; then
    printf '%s%*s' "$text" "$pad" ""
  else
    printf '%s' "$text"
  fi
}

print_rule() {
  printf "%s%s%s\n" "$COLOR_CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$COLOR_RESET"
}

print_header() {
  title="$1"
  printf "\n  %s%s%s\n" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
  print_rule
}

print_kv() {
  label="$1"
  value="$2"
  printf "  %s%s%s  %s\n" "$COLOR_BLUE" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$value"
}

ui_rule() {
  printf "%s%s%s\n" "$COLOR_DIM" "────────────────────────────────────────────────────────────" "$COLOR_RESET"
}

ui_row() {
  label="$1"
  value="$2"
  if is_narrow_terminal && [ "${#value}" -gt 52 ]; then
    value="$(printf '%s' "$value" | cut -c 1-49)..."
  fi
  printf "  %s%s%s  %s\n" "$COLOR_BOLD" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$value"
}

ui_section() {
  title="$1"
  printf "  %s▎%s %s%s%s\n" "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
}

ui_note() {
  label="$1"
  text="$2"
  if is_narrow_terminal && [ "${#text}" -gt 52 ]; then
    text="$(printf '%s' "$text" | cut -c 1-49)..."
  fi
  printf "  %s%s%s  %s%s%s\n" "$COLOR_DIM" "$(ui_pad "$label" 12)" "$COLOR_RESET" "$COLOR_DIM" "$text" "$COLOR_RESET"
}

ui_subtitle() {
  text="$1"
  printf "  %s%s%s\n" "$COLOR_DIM" "$text" "$COLOR_RESET"
}

terminal_cols() {
  cols="$(tput cols 2>/dev/null || echo 120)"
  is_unsigned_integer "$cols" || cols=120
  echo "$cols"
}

is_narrow_terminal() {
  [ "$(terminal_cols)" -lt 90 ]
}

ui_mode_card() {
  number="$1"
  title="$2"
  desc="$3"
  target="$4"
  printf "  %s[%s]%s %s%s%s  %s\n" "$COLOR_CYAN" "$number" "$COLOR_RESET" "$COLOR_BOLD" "$(ui_pad "$title" 10)" "$COLOR_RESET" "$desc"
  printf "           %s目标：%s%s\n" "$COLOR_DIM" "$target" "$COLOR_RESET"
}

metric_line() {
  label="$1"
  value="$2"
  state="${3:-}"
  case "$state" in
    good) color="$COLOR_GREEN" ;;
    warn) color="$COLOR_YELLOW" ;;
    bad) color="$COLOR_RED" ;;
    *) color="$COLOR_CYAN" ;;
  esac
  printf "  %s  %s%s%s\n" "$(ui_pad "$label" 10)" "$color" "$value" "$COLOR_RESET"
}

ui_menu_group() {
  text="$1"
  printf "  %s%s%s\n" "$COLOR_CYAN" "$text" "$COLOR_RESET"
}

ui_menu_item() {
  number="$1"
  title="$2"
  desc="$3"
  color="${4:-$COLOR_CYAN}"
  printf "  %s[%s]%s %s%s%s  %s%s%s\n" \
    "$color" "$number" "$COLOR_RESET" \
    "$COLOR_BOLD" "$(ui_pad "$title" 16)" "$COLOR_RESET" \
    "$COLOR_DIM" "$desc" "$COLOR_RESET"
}

trend_label() {
  current="$1"
  previous="$2"
  if [ -z "$previous" ]; then
    echo "建立基线"
  elif [ "$current" -lt "$previous" ]; then
    echo "重传下降"
  elif [ "$current" -gt "$previous" ]; then
    echo "重传上升"
  else
    echo "保持稳定"
  fi
}

next_action_label() {
  objective="$1"
  retr="$2"
  target_retr="$3"
  case "$objective" in
    throughput)
      if [ "$retr" -le "$target_retr" ]; then
        echo "重传可接受，继续尝试提高吞吐。"
      else
        echo "重传偏高，先收缩缓冲再测试。"
      fi
      ;;
    startup)
      echo "降低初始排队，优先改善短连接起速。"
      ;;
    *)
      if [ "$retr" -le "$target_retr" ]; then
        echo "已达到目标，保持当前参数。"
      else
        echo "降低排队和发送缓冲，继续压低重传。"
      fi
      ;;
  esac
}
