#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_home" "$tmp_state"
}
trap cleanup EXIT

HOME="$tmp_home" \
CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
bash -lc '
  set -euo pipefail
  source "$1/lib/codex_common.sh"
  CLASH_URL="https://example.invalid/sub.yaml"
  CODEX_PROXY_URL="http://127.0.0.1:17900"
  CODEX_MIHOMO_CONTROLLER_URL="http://127.0.0.1:16900"
  CODEX_PROXY_GROUP="CodexProxy"
  PROXY_ENABLED="true"
  save_project_config
  grep -q "^CLASH_URL=" "$2/config.sh"
  ! grep -q "CODEX_DOMESTIC_BASE_URL" "$2/config.sh"
  ! grep -q "CODEX_OVERSEAS_BASE_URL" "$2/config.sh"
  ! grep -q "OPENAI_API_KEY" "$2/config.sh"
  load_project_config "$2/config.sh"
  [ "$CLASH_URL" = "https://example.invalid/sub.yaml" ]
  [ "$CODEX_PROXY_URL" = "http://127.0.0.1:17900" ]
  [ "$PROXY_ENABLED" = "true" ]
' _ "$repo_root" "$tmp_state"
