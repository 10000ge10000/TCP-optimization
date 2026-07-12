# Module: src/tuning/rollback.sh
restore_backup_dir() {
  backup_dir="$1"
  [ -n "$backup_dir" ] || return 1
  rollback_failed=0
  restore_runtime_values "$backup_dir/restore-current.conf" || rollback_failed=1
  if [ -f "$backup_dir/sysctl-file.path" ]; then
    restore_managed_file "$backup_dir" sysctl-file || rollback_failed=1
  fi
  if [ -f "$backup_dir/baseline-file.path" ]; then
    restore_managed_file "$backup_dir" baseline-file || rollback_failed=1
  fi
  # v0.1.x compatibility: old backups stored the managed files by basename.
  # They did not record whether a file originally existed, so only restore a
  # file that is actually present in the backup; never infer deletion.
  if [ ! -f "$backup_dir/sysctl-file.path" ] && [ -f "$backup_dir/99-tcp-tune.conf" ]; then
    atomic_copy_file "$backup_dir/99-tcp-tune.conf" "$SYSCTL_FILE" || rollback_failed=1
  fi
  legacy_baseline="$backup_dir/$(basename "$BASELINE_FILE")"
  if [ ! -f "$backup_dir/baseline-file.path" ] && [ -f "$legacy_baseline" ]; then
    atomic_copy_file "$legacy_baseline" "$BASELINE_FILE" || rollback_failed=1
  fi
  [ "$rollback_failed" = "0" ]
}

rollback_last() {
  need_root
  latest="$(latest_rollback_backup)"
  [ -n "$latest" ] || die "未找到可回滚备份。"
  case "$(basename "$latest")" in
    manual-*) restore_manual_backup "$latest" || return 1 ;;
    *) restore_backup_dir "$latest" || return 1 ;;
  esac
  mkdir -p "$STATE_DIR/rolled-back"
  rollback_target="$(unique_path "$STATE_DIR/rolled-back/$(basename "$latest")")"
  mv "$latest" "$rollback_target"
  info "已回滚到最近备份：$latest"
}

latest_rollback_backup() {
  {
    find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'manual-*' 2>/dev/null || true
  } | while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    key="$(basename "$dir" | sed -n 's/.*\([0-9]\{8\}-[0-9]\{6\}\).*/\1/p' | tail -n 1)"
    [ -n "$key" ] || key="$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)"
    printf '%s\t%s\n' "$key" "$dir"
  done | sort | tail -n 1 | cut -f2-
}

restore_manual_backup() {
  backup_dir="$1"
  [ -n "$backup_dir" ] || return 1
  [ -d "$backup_dir" ] || return 1
  rollback_failed=0
  for label in vps-adapt openwrt-minimal sysctl-file baseline-file; do
    [ -f "$backup_dir/$label.path" ] || continue
    restore_managed_file "$backup_dir" "$label" || rollback_failed=1
  done
  # v0.1.x manual backups used "<basename>.before". Keep this narrow
  # compatibility layer for project-managed files only; intentionally do not
  # restore the legacy sysctl.conf.before snapshot.
  for legacy_pair in \
    "$VPS_ADAPT_FILE:vps" \
    "$OPENWRT_MINIMAL_FILE:openwrt" \
    "$SYSCTL_FILE:sysctl" \
    "$BASELINE_FILE:baseline"
  do
    legacy_path=${legacy_pair%:*}
    legacy_file="$backup_dir/$(basename "$legacy_path").before"
    [ -f "$legacy_file" ] || continue
    atomic_copy_file "$legacy_file" "$legacy_path" || rollback_failed=1
  done
  restore_runtime_values "$backup_dir/restore-current.conf" || rollback_failed=1
  [ "$rollback_failed" = "0" ] || {
    warn "回滚校验失败，备份保留在：$backup_dir"
    return 1
  }
  info "已按手动备份回滚：$backup_dir"
}

initial_defaults_available() {
  path_file="$(initial_defaults_path_file)"
  dir="$(cat "$path_file" 2>/dev/null || true)"
  [ -n "$dir" ] || dir="$(initial_defaults_dir)"
  [ -d "$dir" ] && [ -f "$dir/restore-current.conf" ]
}
