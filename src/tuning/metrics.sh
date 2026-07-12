# Module: src/tuning/metrics.sh
objective_numbers_regressed() {
  objective="$1"
  first_bps="${2:-0}"
  final_bps="${3:-0}"
  first_retr="${4:-0}"
  final_retr="${5:-0}"
  first_startup_bps="${6:-0}"
  final_startup_bps="${7:-0}"
  target_retr="${8:-0}"
  awk -v objective="$objective" -v fb="$first_bps" -v lb="$final_bps" \
      -v fr="$first_retr" -v lr="$final_retr" -v fs="$first_startup_bps" \
      -v ls="$final_startup_bps" -v target="$target_retr" '
    BEGIN {
      bad = 0
      retr_limit = fr * 1.20
      if (retr_limit < fr + 10) retr_limit = fr + 10
      if (objective == "retrans") {
        if (fb > 0 && lb < fb * 0.95) bad = 1
        if (fs > 0 && ls < fs * 0.90) bad = 1
        if (lr > target && fr > 0 && lr > fr) bad = 1
      } else if (objective == "throughput") {
        if (fb > 0 && lb < fb * 0.95) bad = 1
        if (lr > retr_limit) bad = 1
        if (fs > 0 && ls < fs * 0.90) bad = 1
      } else {
        if (fs > 0 && ls < fs * 0.90) bad = 1
        if (fb > 0 && lb < fb * 0.90) bad = 1
        if (lr > retr_limit) bad = 1
      }
      exit !bad
    }
  '
}

objective_step_improved() {
  objective="$1"
  before_bps="${2:-0}"
  after_bps="${3:-0}"
  before_retr="${4:-0}"
  after_retr="${5:-0}"
  before_startup_bps="${6:-0}"
  after_startup_bps="${7:-0}"
  target_retr="${8:-0}"
  awk -v objective="$objective" -v bb="$before_bps" -v ab="$after_bps" \
      -v br="$before_retr" -v ar="$after_retr" -v bs="$before_startup_bps" \
      -v as="$after_startup_bps" -v target="$target_retr" -v guard="${OBJECTIVE_GUARD_OK:-1}" '
    BEGIN {
      ok = 0
      retr_limit = br * 1.20
      if (retr_limit < br + 10) retr_limit = br + 10
      if (objective == "retrans") {
        if ((ar <= target || (br > 0 && ar <= br * 0.85)) && (bb <= 0 || ab >= bb * 0.95) && (bs <= 0 || as >= bs * 0.90)) ok = 1
      } else if (objective == "throughput") {
        if (bb > 0 && ab >= bb * 1.05 && ar <= retr_limit && (bs <= 0 || as >= bs * 0.90)) ok = 1
      } else {
        if (bs > 0 && as >= bs * 1.075 && (bb <= 0 || ab >= bb * 0.90) && ar <= retr_limit) ok = 1
      }
      if (guard != 1) ok = 0
      exit !ok
    }
  '
}

objective_run_succeeded() {
  objective="$1"
  first_bps="${2:-0}"
  final_bps="${3:-0}"
  first_retr="${4:-0}"
  final_retr="${5:-0}"
  first_startup_bps="${6:-0}"
  final_startup_bps="${7:-0}"
  target_retr="${8:-0}"
  awk -v objective="$objective" -v fb="$first_bps" -v lb="$final_bps" \
      -v fr="$first_retr" -v lr="$final_retr" -v fs="$first_startup_bps" \
      -v ls="$final_startup_bps" -v target="$target_retr" -v guard="${OBJECTIVE_GUARD_OK:-1}" '
    BEGIN {
      ok = 0
      retr_limit = fr * 1.20
      if (retr_limit < fr + 10) retr_limit = fr + 10
      if (objective == "retrans") {
        if ((lr <= target || (fr > 0 && lr <= fr * 0.85)) && (fb <= 0 || lb >= fb * 0.95) && (fs <= 0 || ls >= fs * 0.90)) ok = 1
      } else if (objective == "throughput") {
        if (fb > 0 && lb >= fb * 1.05 && lr <= retr_limit && (fs <= 0 || ls >= fs * 0.90)) ok = 1
      } else {
        if (fs > 0 && ls >= fs * 1.075 && (fb <= 0 || lb >= fb * 0.90) && lr <= retr_limit) ok = 1
      }
      if (guard != 1) ok = 0
      exit !ok
    }
  '
}
