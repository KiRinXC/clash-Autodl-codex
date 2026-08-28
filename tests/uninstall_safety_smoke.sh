#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
bin="$home/.local/bin"
runtime="$data/runtime"
sleep_pid=""

cleanup() {
  [ -z "$sleep_pid" ] || kill "$sleep_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$bin" "$config"

write_codex_binary() {
  local marker="$1"
  cat > "$bin/codex" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf 'codex-cli $marker\\n' ;; esac
SH
  chmod +x "$bin/codex"
}

record_install() {
  HOME="$home" PATH="$bin:$PATH" CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    bash -c ". '$repo_root/lib/codex_common.sh'; record_project_codex_install '$bin/codex' github-release"
}

# A project-installed, unchanged binary is removed.
write_codex_binary owned
record_install
HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" codex >/dev/null
[ ! -e "$bin/codex" ]

# Replacing a binary at the same path transfers ownership back to the user.
write_codex_binary original
record_install
write_codex_binary user-replacement
HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" codex >/dev/null
[ -x "$bin/codex" ]
grep -q 'user-replacement' "$bin/codex"

# A stale Mihomo PID must never terminate an unrelated process.
mkdir -p "$runtime/clash" "$runtime"
: > "$runtime/.clash-installed"
sleep 120 &
sleep_pid="$!"
printf '%s\n' "$sleep_pid" > "$runtime/clash/mihomo.pid"
HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" clash >/dev/null
kill -0 "$sleep_pid"

# Deleting user data while components remain keeps wrappers and shell hooks usable.
HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash -c "
    . '$repo_root/lib/install_runtime.sh'
    deploy_runtime '$repo_root'
    export CLASH_CODEX_AUTODL_REPO_ROOT='$runtime'
    export CODEX_AUTODL_REPO_ROOT='$runtime'
    . '$runtime/lib/codex_common.sh'
    . '$runtime/lib/codex_profiles.sh'
    . '$runtime/lib/codex_sessions.sh'
    install_proxy_wrappers
    install_codex_wrappers
    install_proxy_shell_hook
    install_codex_shell_hook
    install_path_block
    mark_component_installed clash
    mark_component_installed codex
  " >/dev/null

mkdir -p "$data/codex-homes/api" "$data/codex-shared/sessions" \
  "$runtime/clash/conf/providers" "$runtime/clash/logs"
printf '%s\n' "CLASH_URL='https://secret-subscription.example.invalid'" > "$config/config.sh"
printf '%s\n' 'api_key = "secret-key"' 'model_provider = "OpenAI"' > "$config/api-profile.toml"
printf '%s\n' '{"OPENAI_API_KEY":"secret-key"}' > "$data/codex-homes/api/auth.json"
printf '%s\n' 'secret-node' > "$runtime/clash/conf/config.yaml"
printf '%s\n' 'secret-provider' > "$runtime/clash/conf/providers/cache.yaml"
printf '%s\n' 'secret-log' > "$runtime/clash/logs/mihomo.log"

HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" data --yes >/dev/null

[ -x "$bin/proxy-status" ]
[ -x "$bin/codex-status" ]
[ -s "$config/proxy-shell-init.sh" ]
[ -s "$config/codex-shell-init.sh" ]
grep -q "PROXY_ENABLED='false'" "$config/config.sh"
! grep -R -q 'secret-' "$config" "$data" 2>/dev/null
[ ! -e "$data/codex-homes" ]
[ ! -e "$data/codex-shared" ]
[ ! -e "$runtime/clash/logs" ]
[ -e "$runtime/.clash-installed" ]
[ -e "$runtime/.codex-installed" ]

terminal_status="$(env -i HOME="$home" PATH="/usr/bin:/bin" TERM=dumb \
  /bin/bash --noprofile --rcfile "$home/.bashrc" -i -c exit 2>&1)"
grep -q '^\[proxy\] 已关闭$' <<< "$terminal_status"
grep -q '^\[codex\] 未配置$' <<< "$terminal_status"
grep -q '^\[sync\] 待初始化 | 0 个会话$' <<< "$terminal_status"
