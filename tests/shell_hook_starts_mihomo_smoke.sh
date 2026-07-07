#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"
work_dir="$(mktemp -d)"
fake_bin="$(mktemp -d)"
listening_marker="$work_dir/mihomo-listening"

cleanup() {
  if [ -f "$work_dir/mihomo.pid" ]; then
    pid="$(cat "$work_dir/mihomo.pid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp_home" "$tmp_state" "$work_dir" "$fake_bin"
}
trap cleanup EXIT

mkdir -p "$tmp_state" "$work_dir/lib" "$work_dir/bin" "$work_dir/conf" "$fake_bin"
cp "$repo_root/lib/codex_common.sh" "$work_dir/lib/codex_common.sh"

cat > "$tmp_state/config.sh" <<'EOF'
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_DOMESTIC_BASE_URL='https://domestic.example.invalid/api'
CODEX_OVERSEAS_BASE_URL='https://overseas.example.invalid/api'
CODEX_ACTIVE_RELAY='domestic'
CODEX_PROXY_URL='http://127.0.0.1:17900'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16900'
CODEX_PROXY_GROUP='CodexProxy'
CODEX_MODEL='gpt-5.4'
CODEX_REVIEW_MODEL='gpt-5.4'
AUTO_PROXY_ON_SHELL_START='true'
EOF

cat > "$work_dir/conf/config.yaml" <<'EOF'
mixed-port: 17900
external-controller: 127.0.0.1:16900
proxies:
  - name: Node A
    type: http
    server: example.invalid
    port: 443
proxy-groups:
  - name: CodexProxy
    type: select
    proxies:
      - Node A
EOF

cat > "$work_dir/bin/mihomo-linux-amd64" <<SH
#!/usr/bin/env bash
touch '$listening_marker'
trap 'rm -f "$listening_marker"; exit 0' TERM INT
while :; do
  sleep 1
done
SH
chmod +x "$work_dir/bin/mihomo-linux-amd64"

cat > "$fake_bin/ss" <<SH
#!/usr/bin/env bash
if [ -f '$listening_marker' ]; then
  printf 'LISTEN 0 128 127.0.0.1:17900 0.0.0.0:*\n'
  exit 0
fi
exit 1
SH
chmod +x "$fake_bin/ss"

HOME="$tmp_home" \
PATH="$fake_bin:$PATH" \
CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
CLASH_CODEX_AUTODL_REPO_ROOT="$work_dir" \
bash -lc "
  set -euo pipefail
  source '$work_dir/lib/codex_common.sh'
  install_shell_hook >/dev/null
"

output="$(
  HOME="$tmp_home" \
  PATH="$fake_bin:$PATH" \
  CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
  bash -lc '
    set -euo pipefail
    source "$HOME/.codex/clash-codex-autodl.sh"
    printf "http_proxy=%s\n" "${http_proxy:-}"
  ' 2>&1
)"

[ -f "$listening_marker" ]
grep -q '\[INFO\].*正在启动 Mihomo' <<<"$output"
grep -q '\[OK\].*Mihomo 正在监听 http://127.0.0.1:17900' <<<"$output"
grep -q 'http_proxy=http://127.0.0.1:17900' <<<"$output"
