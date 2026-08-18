#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_home"
}
trap cleanup EXIT

output="$(
  HOME="$tmp_home" \
  bash -lc "
    set -euo pipefail
    source '$repo_root/lib/codex_common.sh'
    project_config_dir
    install_shell_hook >/dev/null
  "
)"

grep -qx "$tmp_home/.config/clash-codex-autodl" <<<"$output"
[ -f "$tmp_home/.config/clash-codex-autodl/proxy-shell-init.sh" ]
[ -f "$tmp_home/.config/clash-codex-autodl/codex-shell-init.sh" ]
[ ! -f "$tmp_home/.codex/clash-autodl-codex.sh" ]
grep -q 'clash-codex-autodl-proxy begin' "$tmp_home/.bashrc"
grep -q 'clash-codex-autodl-codex begin' "$tmp_home/.bashrc"
! grep -q 'clash-autodl-codex begin' "$tmp_home/.bashrc"
grep -q 'proxy-shell-init.sh' "$tmp_home/.bashrc"
grep -q 'codex-shell-init.sh' "$tmp_home/.bashrc"

grep -q '# clash-codex-autodl' "$repo_root/README.md"
! grep -q 'clash-Autodl-codex' "$repo_root/README.md"
! grep -q 'clash-autodl-codex' "$repo_root/README.md"
