#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_state="$(mktemp -d)"
fake_bin="$(mktemp -d)"
codex_called="$tmp_home/codex-called"
listening_marker="$fake_bin/mihomo-listening"

cleanup() {
  if [ -n "${mihomo_pid:-}" ] && kill -0 "$mihomo_pid" >/dev/null 2>&1; then
    kill "$mihomo_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_home" "$tmp_state" "$fake_bin"
}
trap cleanup EXIT

mkdir -p "$tmp_state" "$fake_bin"

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
AUTO_CODEX_CHECK_ON_SHELL_START='true'
EOF

cat > "$fake_bin/codex" <<SH
#!/usr/bin/env bash
out_file=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output-last-message)
      out_file="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
touch '$codex_called'
if [ -n "\$out_file" ]; then
  printf '%s\n' "CODEX_RELAY_READY" > "\$out_file"
fi
exit 0
SH
chmod +x "$fake_bin/codex"

cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '香港W01'
SH
chmod +x "$fake_bin/python3"

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

HOME="$tmp_home" \
PATH="$fake_bin:$PATH" \
LISTENING_MARKER="$listening_marker" \
CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
bash -lc "
  set -euo pipefail
  source '$repo_root/lib/codex_common.sh'
  install_shell_hook >/dev/null
"

output="$(
  HOME="$tmp_home" \
  PATH="$fake_bin:$PATH" \
  LISTENING_MARKER="$listening_marker" \
  CODEX_AUTODL_CONFIG_DIR="$tmp_state" \
  bash -lc '
    set -euo pipefail
    source "$HOME/.codex/clash-codex-autodl.sh"
    printf "http_proxy=%s\n" "${http_proxy:-}"
  ' 2>&1
)"

grep -q '\[OK\].*代理已开启: http://127.0.0.1:17900' <<<"$output"
grep -q '\[OK\].*当前节点: 香港W01' <<<"$output"
grep -q '\[OK\].*Codex 中转站: domestic https://domestic.example.invalid/api' <<<"$output"
grep -q 'http_proxy=http://127.0.0.1:17900' <<<"$output"

[ ! -f "$codex_called" ]
! grep -q 'CODEX_RELAY_READY' <<<"$output"
! grep -q 'Codex 可用' <<<"$output"

! grep -q 'clash-codex-autodl 命令已加载' <<<"$output"
! grep -q '代理地址' <<<"$output"
! grep -q 'Mihomo' <<<"$output"
