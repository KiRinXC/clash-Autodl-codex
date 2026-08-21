#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bash install-clash.sh

安装或重新配置 Clash/Mihomo，并默认永久开启代理。
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

load_project_config
CLASH_URL="$(prompt_required "请输入 Clash/Mihomo 订阅 URL" "${CLASH_URL:-}")"
validate_http_url CLASH_URL "$CLASH_URL"
export PROXY_ENABLED="true"
save_project_config

if user_systemd_available && [ -f "$HOME/.config/systemd/user/$(proxy_service_name)" ]; then
  systemctl --user stop "$(proxy_service_name)" >/dev/null 2>&1 || true
fi
bash "$RUNTIME_DIR/setup_mihomo.sh" "$(project_config_file)"
install_proxy_systemd_service
if user_systemd_available; then
  stop_existing_mihomo
fi
install_proxy_wrappers
install_proxy_shell_hook
install_path_block
mark_component_installed clash
proxy_enable_persistent

if saved_codex_is_present && codex_binary_path >/dev/null 2>&1; then
  codex_migrate_api_source
  install_codex_wrappers
  install_codex_shell_hook
  mark_component_installed codex
  log_ok "已将旧 Codex 安装迁移到新的 codex-* 命令"
fi

log_ok "Clash/Mihomo 安装完成"
log_info "重新打开终端后会自动启用代理并显示当前节点"
print_daily_commands
