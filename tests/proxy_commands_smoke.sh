#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common="$repo_root/lib/codex_common.sh"

grep -q 'function proxy-on' "$common"
grep -q 'function proxy-off' "$common"
grep -q 'function proxy-pick' "$common"
grep -q 'function proxy-status' "$common"
grep -q 'function codex-verify' "$common"
grep -q 'install_proxy_shell_hook()' "$common"
grep -q 'install_codex_shell_hook()' "$common"

! grep -q 'function codex-use-in' "$common"
! grep -q 'function codex-use-out' "$common"
! grep -q 'function codex-ex-in' "$common"
! grep -q 'function codex-ex-out' "$common"

! grep -q 'proxy_on()' "$common"
! grep -q 'proxy_off()' "$common"
! grep -q 'proxy_pick()' "$common"
! grep -q 'proxy_status()' "$common"
! grep -q 'codex_use_domestic()' "$common"
! grep -q 'codex_use_overseas()' "$common"
! grep -q 'codex_relay_status()' "$common"
! grep -q 'codex_verify()' "$common"

grep -q 'clash-codex setup' "$repo_root/README.md"
