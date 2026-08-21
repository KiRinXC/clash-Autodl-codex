#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bash install-codex.sh

安装 Codex CLI 并保存 API 配置，不进行模型调用验证。
USAGE
}

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage; exit 1 ;;
esac

# shellcheck source=lib/install_runtime.sh
. "$SCRIPT_DIR/lib/install_runtime.sh"

deploy_runtime "$SCRIPT_DIR"
migrate_legacy_clash_runtime
RUNTIME_DIR="$(install_runtime_dir)"
export CLASH_CODEX_AUTODL_REPO_ROOT="$RUNTIME_DIR"
export CODEX_AUTODL_REPO_ROOT="$RUNTIME_DIR"

# shellcheck source=lib/codex_common.sh
. "$RUNTIME_DIR/lib/codex_common.sh"
# shellcheck source=lib/codex_profiles.sh
. "$RUNTIME_DIR/lib/codex_profiles.sh"
# shellcheck source=lib/codex_sessions.sh
. "$RUNTIME_DIR/lib/codex_sessions.sh"

ensure_codex_cli
codex_migrate_api_source

if [ -f "$(codex_api_source_file)" ]; then
  if codex_profile_is_configured api; then
    log_ok "检测到已有 API 用户数据，继续使用现有配置"
  else
    apply_codex_api_source
  fi
elif codex_profile_is_configured api; then
  log_warn "检测到已有 API 档案，但无法生成单文件数据源；已保留并继续使用"
else
  configure_codex_api_initial
fi

save_codex_active_auth api
provider="$(codex_config_model_provider "$(codex_profile_home api)/config.toml")"
codex_initialize_session_sync false "$provider"
install_codex_wrappers
install_codex_shell_hook
install_path_block
mark_component_installed codex

if legacy_clash_is_present; then
  install_proxy_wrappers
  install_proxy_shell_hook
  mark_component_installed clash
  log_ok "已将旧 Clash 安装迁移到新的 proxy-* 命令"
fi

log_ok "Codex CLI 和 API 配置安装完成（尚未验证）"
log_info "重新打开终端后运行 codex-verify 进行真实调用验证"
print_daily_commands
