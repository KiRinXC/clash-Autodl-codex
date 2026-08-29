#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
bin="$home/.local/bin"
runtime="$data/runtime"
fake_bin="$tmp_dir/fake-bin"
pid_log="$tmp_dir/mihomo-pids"

cleanup() {
  pid="$(cat "$runtime/clash/mihomo.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$home" "$config" "$runtime/clash/bin" "$runtime/clash/conf" "$fake_bin"

cat > "$runtime/clash/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = eval ] && [ "${2:-}" = -i ]; then
  file="${@: -1}"
  if grep -q 'FAIL_START' "$file"; then
    printf 'mixed-port: %s\ncontroller-broken: true\n' "$CODEX_PROXY_PORT" > "$file"
  else
    printf 'mixed-port: %s\nold-config: true\n' "$CODEX_PROXY_PORT" > "$file"
  fi
elif [ "${1:-}" = eval ] && [ "${2:-}" = '.proxies | length' ]; then
  printf '1\n'
fi
SH

cat > "$runtime/clash/bin/mihomo-linux-amd64" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in -d) config_dir="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$config_dir" ]
printf '%s\n' "$$" >> "${FAKE_MIHOMO_PID_LOG:?}"
if grep -q '^controller-broken: true$' "$config_dir/config.yaml"; then
  printf '%s\n' 'level=error msg="Start Mixed(http+socks) server error: listen tcp 127.0.0.1:17890: bind: address already in use"' >&2
  trap 'exit 0' TERM INT EXIT
  while :; do sleep 1; done
fi
touch "$config_dir/listening"
trap 'rm -f "$config_dir/listening"; exit 0' TERM INT EXIT
while :; do sleep 1; done
SH
chmod +x "$runtime/clash/bin/yq" "$runtime/clash/bin/mihomo-linux-amd64"
dd if=/dev/zero of="$runtime/clash/conf/geoip.metadb" bs=1048576 count=6 >/dev/null 2>&1
printf '%s\n' 'mixed-port: 17890' 'old-config: true' > "$runtime/clash/conf/config.yaml"
chmod 600 "$runtime/clash/conf/config.yaml"

FAKE_MIHOMO_PID_LOG="$pid_log" nohup "$runtime/clash/bin/mihomo-linux-amd64" \
  -d "$runtime/clash/conf" >/dev/null 2>&1 &
old_pid="$!"
printf '%s\n' "$old_pid" > "$runtime/clash/mihomo.pid"
for _ in 1 2 3 4 5; do
  [ -f "$runtime/clash/conf/listening" ] && break
  sleep 1
done
[ -f "$runtime/clash/conf/listening" ]

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
write_status="false"
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_status="true"; shift 2 ;;
    http://* | https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */proxies/CodexProxy)
    if grep -q '^controller-broken: true$' "${FAKE_CLASH_CONF:?}/config.yaml"; then
      printf '%s\n' '{"error":"group unavailable"}' > "$output"
      [ "$write_status" != "true" ] || printf '404'
      exit 0
    fi
    printf '%s\n' '{"name":"CodexProxy","now":"Node A","all":["Node A","DIRECT"]}' > "$output"
    [ "$write_status" != "true" ] || printf '200'
    exit 0
    ;;
esac
printf '%s\n' 'proxies:' '  - name: FAIL_START' > "$output"
SH
cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
if [ -f "${FAKE_CLASH_CONF:?}/listening" ]; then
  printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
  exit 0
fi
exit 1
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_bin/curl" "$fake_bin/ss" "$fake_bin/systemctl"

cat > "$config/config.sh" <<'EOF'
CLASH_URL='https://working-subscription.example.invalid/clash.yaml'
CODEX_PROXY_URL='http://127.0.0.1:17890'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16006'
CODEX_PROXY_GROUP='CodexProxy'
PROXY_ENABLED='true'
EOF
before_config="$(cksum "$runtime/clash/conf/config.yaml")"
before_user_config="$(cksum "$config/config.sh")"

if printf '%s\n' 'https://broken-subscription.example.invalid/clash.yaml' | \
  HOME="$home" PATH="$fake_bin:$PATH" FAKE_CLASH_CONF="$runtime/clash/conf" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" \
  CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  FAKE_MIHOMO_PID_LOG="$pid_log" \
  CODEX_MIHOMO_START_WAIT_SECONDS=2 \
  bash "$repo_root/install-clash.sh" >/dev/null 2>&1; then
  printf '损坏的新配置不应安装成功\n' >&2
  exit 1
fi

[ "$(cksum "$runtime/clash/conf/config.yaml")" = "$before_config" ]
[ "$(cksum "$config/config.sh")" = "$before_user_config" ]
grep -q 'working-subscription.example.invalid' "$config/config.sh"
grep -q '^old-config: true$' "$runtime/clash/conf/config.yaml"
new_pid="$(cat "$runtime/clash/mihomo.pid")"
kill -0 "$new_pid"
mapfile -t started_pids < "$pid_log"
[ "${#started_pids[@]}" -ge 3 ]
if kill -0 "${started_pids[1]}" >/dev/null 2>&1; then
  printf 'failed staged Mihomo process was not cleaned up\n' >&2
  exit 1
fi
[ -f "$runtime/clash/conf/listening" ]
[ "$(stat -c '%a' "$runtime/clash/conf/config.yaml")" = 600 ]
! find "$runtime/clash/conf" -maxdepth 1 \( -name '.config.pending.*' -o -name '.config.backup.*' \) | grep -q .
