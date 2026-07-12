# Module: src/platform/macos.sh
macos_write_unsupported() {
  DIE_EXIT_CODE="$EXIT_DEPENDENCY" die "macOS 仅支持测速、状态与诊断，不支持写入 Linux sysctl 参数。"
}
