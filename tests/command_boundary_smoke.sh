#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"
fake_bin="$(mktemp -d)"
listening_marker="$fake_bin/mihomo-listening"

cleanup() {
  if [ -n "${mihomo_pid:-}" ] && kill -0 "$mihomo_pid" >/dev/null 2>&1; then
    kill "$mihomo_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_home" "$tmp_state" "$fake_bin"
}
trap cleanup EXIT

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
if [ -f "$LISTENING_MARKER" ]; then
  printf 'LISTEN 0 128 127.0.0.1:17900 0.0.0.0:*\n'
  exit 0
fi
exit 1
SH
chmod +x "$fake_bin/ss"

cat > "$fake_bin/mihomo-linux-amd64" <<SH
#!/usr/bin/env bash
touch '$listening_marker'
trap 'rm -f "$listening_marker"; exit 0' TERM INT
while :; do
  sleep 1
done
SH
chmod +x "$fake_bin/mihomo-linux-amd64"
"$fake_bin/mihomo-linux-amd64" &
mihomo_pid="$!"
for _ in $(seq 1 50); do
  if [ -f "$listening_marker" ]; then
    break
  fi
  sleep 0.1
done

cat > "$tmp_state/config.sh" <<'EOF'
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_DOMESTIC_BASE_URL='https://domestic.example.invalid/api'
CODEX_OVERSEAS_BASE_URL='https://overseas.example.invalid/api'
CODEX_PROXY_URL='http://127.0.0.1:17900'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16900'
CODEX_PROXY_GROUP='CodexProxy'
CODEX_MODEL='gpt-5.4'
CODEX_REVIEW_MODEL='gpt-5.4'
CODEX_ACTIVE_RELAY='domestic'
AUTO_CODEX_CHECK_ON_SHELL_START='false'
EOF

HOME="$tmp_home" \
CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
PATH="$fake_bin:$PATH" \
LISTENING_MARKER="$listening_marker" \
bash -lc '
  set -euo pipefail
  source "$1/lib/codex_common.sh"
  load_project_config "$2/config.sh"
  proxy-on
  [ "${http_proxy:-}" = "http://127.0.0.1:17900" ]
  [ ! -f "$HOME/.codex/config.toml" ]
  codex-use-out
  [ "${http_proxy:-}" = "http://127.0.0.1:17900" ]
  [ "$CODEX_ACTIVE_RELAY" = "overseas" ]
' _ "$repo_root" "$tmp_state"
