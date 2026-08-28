#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bash install-codex.sh

复用已有 Codex CLI（不存在时才安装），部署 codex-* 管理命令并保存 API 配置。
安装过程不进行模型调用验证。
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

# 先安装管理入口。即使后续配置输入中断，已有 Codex 仍可复用，用户也能重新运行
# install-codex.sh 或使用 codex-config 修复已经存在的 API 文本配置。
install_codex_wrappers
install_codex_shell_hook
install_path_block
mark_component_installed codex

codex_migrate_api_source

api_source="$(codex_api_source_file)"
if codex_api_source_is_usable "$api_source"; then
  if codex_profile_is_configured api; then
    log_ok "检测到已有 API 用户数据，继续使用现有配置"
  else
    apply_codex_api_source
  fi
else
  current_url=""
  if [ -f "$api_source" ]; then
    current_url="$(codex_config_api_url "$api_source")"
    backup="$(codex_backup_invalid_api_source "$api_source")"
    log_warn "检测到空白或无效的 API 文本配置，已备份到: $backup"
    log_info "现在将重新询问 API 地址和 API Key；原运行配置在新配置保存成功前不会修改"
  fi
  configure_codex_api_initial "$current_url"
fi

save_codex_active_auth api
provider="$(codex_config_model_provider "$(codex_profile_home api)/config.toml")"
codex_initialize_session_sync false "$provider"
if legacy_clash_is_present; then
  install_proxy_wrappers
  install_proxy_shell_hook
  mark_component_installed clash
  log_ok "已将旧 Clash 安装迁移到新的 proxy-* 命令"
fi

log_ok "Codex CLI 和 API 配置安装完成（尚未验证）"
log_info "API 文本配置: $(codex_api_source_file)"
log_info "重新打开终端后运行 codex-verify 进行真实调用验证"
print_daily_commands
