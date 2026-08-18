#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

run_cli() {
  HOME="$tmp_dir/home" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_dir/config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_dir/data" \
  bash "$repo_root/clash-codex" "$@"
}

assert_fails() {
  if run_cli "$@" >/dev/null 2>&1; then
    printf 'command unexpectedly succeeded: clash-codex %s\n' "$*" >&2
    exit 1
  fi
}

assert_fails setup codex extra
assert_fails proxy status extra
assert_fails status extra
assert_fails verify extra
assert_fails auth status --edit
assert_fails sessions status extra
assert_fails uninstall
assert_fails uninstall all extra

[ ! -d "$tmp_dir/data/codex-homes" ]
