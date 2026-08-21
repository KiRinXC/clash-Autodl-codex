#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
tmp_bin="$tmp_home/.local/bin"
runtime="$tmp_data/runtime"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
mkdir -p "$tmp_home" "$tmp_config" "$tmp_data/codex-homes/api" "$tmp_data/codex-homes/chatgpt" \
  "$tmp_data/codex-shared/sessions"
printf 'CLASH_URL=%q\n' 'https://subscription.example.invalid' > "$tmp_config/config.sh"
printf 'api_key = "preserved"\nmodel_provider = "openai"\n' > "$tmp_config/api-profile.toml"
touch "$tmp_data/codex-homes/api/auth.json" "$tmp_data/codex-homes/chatgpt/auth.json"
touch "$tmp_data/codex-shared/sessions/rollout-preserved.jsonl"

# Old releases stored Clash runtime directories directly under runtime/.
mkdir -p "$runtime/bin" "$runtime/conf"
printf 'mixed-port: 7890\n' > "$runtime/conf/config.yaml"
touch "$runtime/bin/mihomo-linux-amd64"
chmod +x "$runtime/bin/mihomo-linux-amd64"
HOME="$tmp_home" CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  bash -c ". '$repo_root/lib/install_runtime.sh'; migrate_legacy_clash_runtime; legacy_clash_is_present"
[ -e "$runtime/clash/conf/config.yaml" ]
[ ! -e "$runtime/conf" ]

HOME="$tmp_home" CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin" \
  bash -c ". '$repo_root/lib/install_runtime.sh'; deploy_runtime '$repo_root'; install_proxy_wrappers; install_codex_wrappers; install_path_block; mark_component_installed clash; mark_component_installed codex"
mkdir -p "$runtime/clash/conf"
touch "$runtime/clash/conf/config.yaml"

HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin" bash "$repo_root/uninstall.sh" clash >/dev/null
[ ! -e "$tmp_bin/proxy-on" ]
[ -x "$tmp_bin/codex-status" ]
[ -s "$tmp_config/config.sh" ]
[ -e "$tmp_data/codex-homes/api/auth.json" ]
[ -d "$runtime" ]

HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin" bash "$repo_root/uninstall.sh" codex >/dev/null
[ ! -e "$tmp_bin/codex-status" ]
[ -e "$tmp_data/codex-homes/api/auth.json" ]
[ -e "$tmp_data/codex-shared/sessions/rollout-preserved.jsonl" ]
[ -s "$tmp_config/api-profile.toml" ]
[ ! -d "$runtime" ]
! grep -q 'clash-codex-autodl-path begin' "$tmp_home/.bashrc"

HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
  bash "$repo_root/uninstall.sh" data --yes >/dev/null
[ ! -d "$tmp_config" ]
[ ! -d "$tmp_data/codex-homes" ]
[ ! -d "$tmp_data/codex-shared" ]
