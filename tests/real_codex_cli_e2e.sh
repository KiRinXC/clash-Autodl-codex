#!/usr/bin/env bash
set -euo pipefail

# This test downloads the current official CLI, so it is opt-in for local/CI runs.
[ "${RUN_REAL_CODEX_E2E:-false}" = true ] || exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
bin="$home/.local/bin"

cleanup() {
  case "$tmp_dir" in
    /tmp/tmp.*) rm -rf "$tmp_dir" ;;
    *) printf '拒绝清理非临时目录: %s\n' "$tmp_dir" >&2 ;;
  esac
}
trap cleanup EXIT
mkdir -p "$home"

printf '%s\n%s\n' 'http://127.0.0.1:1/v1' 'sk-local-install-test-not-a-secret' | \
  env HOME="$home" PATH="/usr/bin:/bin" \
    CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
    CLASH_CODEX_AUTODL_DATA_DIR="$data" \
    CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
    GITHUB_DIRECT_MAX_TIME=90 \
    bash "$repo_root/install-codex.sh" >/dev/null

[ -x "$bin/codex" ]
"$bin/codex" --version | grep -Eq '^codex-cli '
grep -q '^model = "gpt-5.6-sol"$' "$data/codex-homes/api/config.toml"
grep -q '^base_url = "http://127.0.0.1:1/v1"$' "$data/codex-homes/api/config.toml"
grep -q 'sk-local-install-test-not-a-secret' "$data/codex-homes/api/auth.json"
set +e
strict_output="$(CODEX_HOME="$data/codex-homes/api" timeout 8 "$bin/codex" --strict-config \
  exec --skip-git-repo-check --ephemeral 'config parse test' 2>&1)"
strict_status="$?"
set -e
[ "$strict_status" -eq 0 ] || [ "$strict_status" -eq 1 ] || [ "$strict_status" -eq 124 ]
! grep -q 'unknown configuration field' <<< "$strict_output"
grep -q '^provider: OpenAI$' <<< "$strict_output"
status="$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" "$bin/codex-status")"
grep -q 'API URL: http://127.0.0.1:1/v1' <<< "$status"

HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash "$repo_root/uninstall.sh" codex >/dev/null
[ ! -e "$bin/codex" ]
[ -s "$config/api-profile.toml" ]
[ -s "$data/codex-homes/api/auth.json" ]
