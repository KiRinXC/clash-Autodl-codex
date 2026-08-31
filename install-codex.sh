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

codex_migrate_legacy_profiles
codex_migrate_api_source

api_source="$(codex_api_source_file)"
selected_profile=""
active_profile="$(codex_active_auth)"
if codex_detect_native_profile; then
  log_ok "检测到原生 Codex 登录: $CODEX_NATIVE_AUTH_METHOD"
  log_info "原生 CODEX_HOME: $CODEX_NATIVE_HOME"
  case "$CODEX_NATIVE_AUTH_METHOD" in
    api | chatgpt)
      selected_profile="$CODEX_NATIVE_AUTH_METHOD"
      if [ "$CODEX_NATIVE_AUTH_STORAGE" = file ]; then
        codex_acquire_sync_lock
        if ! codex_capture_native_profile "$selected_profile" ||
          ! codex_apply_saved_profile "$selected_profile" "$selected_profile"; then
          codex_release_sync_lock
          log_error "无法保存并接管现有原生 Codex 认证"
          exit 1
        fi
        codex_release_sync_lock
        [ "$selected_profile" != api ] || codex_migrate_api_source
      else
        log_warn "当前凭据位于系统 keyring，无法作为可完整覆盖的 auth.json 保存"
        log_info "将使用 Codex 原生登录重新生成文件型凭据；不会创建项目自定义的 ~/.codex 文件或目录"
        case "$selected_profile" in
          api) configure_codex_api_profile ;;
          chatgpt) configure_codex_chatgpt_profile ;;
        esac
      fi
      ;;
    *)
      selected_profile="api"
      save_codex_active_auth "$selected_profile"
      log_warn "本项目只切换 API Key 与 ChatGPT，不能保存 $CODEX_NATIVE_AUTH_METHOD"
      log_warn "原生登录保持不变；运行 codex-config 配置项目的 API 认证"
      ;;
  esac
elif codex_profile_is_configured "$active_profile"; then
  selected_profile="$active_profile"
  if [ -d "$(codex_native_home)" ]; then
    codex_acquire_sync_lock
    if ! codex_apply_saved_profile "$selected_profile" "$selected_profile"; then
      codex_release_sync_lock
      exit 1
    fi
    codex_release_sync_lock
  elif [ "$selected_profile" = api ] && codex_api_source_is_usable "$api_source"; then
    apply_codex_api_source
  else
    configure_codex_chatgpt_profile
  fi
  log_ok "已将项目保存的 $selected_profile 认证恢复到原生 CODEX_HOME"
elif codex_profile_is_configured api; then
  selected_profile="api"
  if [ -d "$(codex_native_home)" ]; then
    codex_acquire_sync_lock
    if ! codex_apply_saved_profile api "$active_profile"; then
      codex_release_sync_lock
      exit 1
    fi
    codex_release_sync_lock
  else
    apply_codex_api_source
  fi
  log_ok "已将项目保存的 API 认证恢复到原生 CODEX_HOME"
elif codex_profile_is_configured chatgpt; then
  selected_profile="chatgpt"
  if [ -d "$(codex_native_home)" ]; then
    codex_acquire_sync_lock
    if ! codex_apply_saved_profile chatgpt "$active_profile"; then
      codex_release_sync_lock
      exit 1
    fi
    codex_release_sync_lock
  else
    configure_codex_chatgpt_profile
  fi
  log_ok "已将项目保存的 ChatGPT 认证恢复到原生 CODEX_HOME"
elif codex_api_source_is_usable "$api_source"; then
  apply_codex_api_source
  selected_profile="api"
else
  configure_codex_api_profile
  selected_profile="api"
fi

save_codex_active_auth "$selected_profile"
if legacy_clash_is_present; then
  install_proxy_wrappers
  install_proxy_shell_hook
  mark_component_installed clash
  log_ok "已将旧 Clash 安装迁移到新的 proxy-* 命令"
fi

if codex_profile_is_configured "$selected_profile"; then
  if [ "$selected_profile" = api ]; then profile_label="API"; else profile_label="ChatGPT"; fi
  log_ok "Codex CLI 和 $profile_label 配置安装完成（尚未进行模型调用验证）"
else
  log_ok "Codex CLI 和管理命令安装完成；项目认证仍待配置"
fi
if [ -f "$(codex_api_source_file)" ]; then
  log_info "API 文本配置: $(codex_api_source_file)"
fi
log_info "Codex 原生目录: $(codex_native_home)（项目只替换 auth.json，并定向修改 config.toml）"
log_info "重新打开终端后运行 codex-verify 进行真实调用验证"
print_daily_commands
