#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLASH_CODEX_AUTODL_REPO_ROOT="$runtime_dir"
export CODEX_AUTODL_REPO_ROOT="$runtime_dir"

# shellcheck source=lib/codex_common.sh
. "$runtime_dir/lib/codex_common.sh"
# shellcheck source=lib/codex_profiles.sh
. "$runtime_dir/lib/codex_profiles.sh"
# shellcheck source=lib/codex_sessions.sh
. "$runtime_dir/lib/codex_sessions.sh"

usage() {
  cat <<'USAGE'
内部命令。请使用 proxy-*、codex-* 或 codex。
USAGE
}

proxy_command() {
  [ "$#" -eq 1 ] || { log_error "无效的代理命令"; return 1; }
  case "$1" in
    enable) proxy_enable_persistent ;;
    disable) proxy_disable_persistent ;;
    env) proxy_print_env ;;
    env-off) proxy_print_unset_env ;;
    shell-start) proxy_shell_start ;;
    switch) proxy-switch ;;
    status) proxy-status ;;
    *) log_error "无效的代理命令: $1"; return 1 ;;
  esac
}

codex_command() {
  [ "$#" -eq 1 ] || { log_error "无效的 Codex 命令"; return 1; }
  case "$1" in
    verify) verify_active_codex_profile ;;
    status) codex_profiles_status ;;
    switch) codex_switch_profile ;;
    sync) codex_manual_sync ;;
    config) configure_active_codex_profile ;;
    shell-status) codex_shell_status ;;
    *) log_error "无效的 Codex 命令: $1"; return 1 ;;
  esac
}

case "${1:-}" in
  proxy) shift; proxy_command "$@" ;;
  codex) shift; codex_command "$@" ;;
  run) shift; run_codex_with_active_profile "$@" ;;
  --help | -h | help | "") usage ;;
  *) log_error "未知内部命令: $1"; exit 1 ;;
esac
