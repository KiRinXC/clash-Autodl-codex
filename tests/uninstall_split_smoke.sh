#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
work_dir="$tmp_dir/work"
tmp_home="$tmp_dir/home"
tmp_state="$tmp_home/.config/clash-codex-autodl"
data_dir="$tmp_home/.local/share/clash-codex-autodl"

cleanup() {
  if [ -n "${proxy_pid:-}" ] && kill -0 "$proxy_pid" >/dev/null 2>&1; then
    kill "$proxy_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/bin" "$work_dir/conf" "$work_dir/logs" \
  "$tmp_home/.codex" "$tmp_home/.local/bin" "$tmp_state" \
  "$data_dir/codex-homes/api" "$data_dir/codex-homes/chatgpt"
mkdir -p "$data_dir/codex-shared/sessions"
touch "$data_dir/codex-shared/sessions/rollout-preserved.jsonl"
cp "$repo_root/uninstall_codex_bootstrap.sh" "$work_dir/uninstall_codex_bootstrap.sh"

touch "$work_dir/bin/mihomo-linux-amd64" "$work_dir/conf/config.yaml" "$work_dir/logs/mihomo.log"
touch "$tmp_home/.codex/config.toml" "$tmp_home/.codex/auth.json"
touch "$data_dir/codex-homes/api/auth.json" "$data_dir/codex-homes/chatgpt/auth.json"
printf 'api\n' > "$tmp_state/active-auth"
touch "$tmp_state/proxy-shell-init.sh" "$tmp_state/codex-shell-init.sh"
touch "$tmp_home/.local/bin/codex" "$tmp_home/.local/bin/clash-codex" "$tmp_home/.local/bin/codex-autodl"
cat > "$data_dir/install-manifest" <<EOF
INSTALLED_BY_PROJECT='true'
CODEX_BINARY_PATH='$tmp_home/.local/bin/codex'
EOF

sleep 1000 &
proxy_pid="$!"
printf '%s\n' "$proxy_pid" > "$work_dir/mihomo.pid"

cat > "$tmp_home/.bashrc" <<'EOF'
# clash-codex-autodl-path begin
export PATH="$HOME/.local/bin:$PATH"
# clash-codex-autodl-path end
# clash-codex-autodl-proxy begin
proxy hook
# clash-codex-autodl-proxy end
# clash-codex-autodl-codex begin
codex hook
# clash-codex-autodl-codex end
# clash-autodl-codex begin
legacy hook
# clash-autodl-codex end
EOF

HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
CLASH_CODEX_AUTODL_DATA_DIR="$data_dir" \
bash "$work_dir/uninstall_codex_bootstrap.sh" --proxy

! kill -0 "$proxy_pid" >/dev/null 2>&1
proxy_pid=""
[ ! -d "$work_dir/bin" ]
[ ! -d "$work_dir/conf" ]
[ ! -d "$work_dir/logs" ]
[ ! -e "$tmp_state/proxy-shell-init.sh" ]
[ -e "$tmp_state/codex-shell-init.sh" ]
[ -e "$data_dir/codex-homes/api/auth.json" ]
[ -e "$tmp_home/.codex/auth.json" ]

mkdir -p "$work_dir/conf"
HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
CLASH_CODEX_AUTODL_DATA_DIR="$data_dir" \
bash "$work_dir/uninstall_codex_bootstrap.sh" --codex

[ ! -d "$data_dir/codex-homes" ]
[ -f "$data_dir/codex-shared/sessions/rollout-preserved.jsonl" ]
[ ! -e "$tmp_state/active-auth" ]
[ ! -e "$tmp_state/codex-shell-init.sh" ]
[ ! -e "$tmp_home/.local/bin/codex" ]
[ -d "$work_dir/conf" ]
[ -e "$tmp_home/.codex/config.toml" ]
[ -e "$tmp_home/.codex/auth.json" ]
[ -f "$data_dir/codex-shared/sessions/rollout-preserved.jsonl" ]

mkdir -p "$tmp_home/.config/clash-autodl-codex"
touch "$tmp_home/.codex/clash-autodl-codex.sh"
HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
CLASH_CODEX_AUTODL_DATA_DIR="$data_dir" \
bash "$work_dir/uninstall_codex_bootstrap.sh" --all

[ ! -d "$tmp_state" ]
[ ! -e "$tmp_home/.local/bin/clash-codex" ]
[ ! -e "$tmp_home/.local/bin/codex-autodl" ]
[ ! -d "$tmp_home/.config/clash-autodl-codex" ]
[ ! -e "$tmp_home/.codex/clash-autodl-codex.sh" ]
[ -e "$tmp_home/.codex/auth.json" ]
! grep -q 'clash-codex-autodl' "$tmp_home/.bashrc"
! grep -q 'clash-autodl-codex' "$tmp_home/.bashrc"
