#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_data="$tmp_dir/data"
tmp_bin="$tmp_home/.local/bin"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home"
HOME="$tmp_home" \
CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" \
CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin" \
bash "$repo_root/install.sh" >/dev/null

[ -x "$tmp_bin/clash-codex" ]
[ -x "$tmp_bin/codex-autodl" ]
[ -x "$tmp_data/runtime/clash-codex" ]
[ -f "$tmp_data/runtime/lib/codex_sessions.sh" ]
grep -q 'clash-codex-autodl-path begin' "$tmp_home/.bashrc"

output="$(cd "$tmp_dir" && HOME="$tmp_home" "$tmp_bin/clash-codex" --help)"
grep -q 'clash-codex setup' <<<"$output"
grep -q 'clash-codex auth' <<<"$output"
