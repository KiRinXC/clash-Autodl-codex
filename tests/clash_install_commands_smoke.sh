#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
tmp_data="$tmp_dir/data"
tmp_bin="$tmp_home/.local/bin"
runtime="$tmp_data/runtime"
fake_bin="$tmp_dir/fake-bin"

cleanup() {
  pid="$(cat "$runtime/clash/mihomo.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$tmp_home" "$runtime/clash/bin" "$runtime/clash/conf" "$fake_bin"

cat > "$runtime/clash/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = eval ] && [ "${2:-}" = -i ]; then
  file="${@: -1}"
  printf 'mixed-port: %s\nexternal-controller: %s\nproxy-group: %s\n' \
    "$CODEX_PROXY_PORT" "$CODEX_MIHOMO_CONTROLLER_BIND" "$CODEX_PROXY_GROUP_NAME" > "$file"
elif [ "${1:-}" = eval ] && [[ "${2:-}" == *length* ]]; then
  printf '1\n'
fi
SH
cat > "$runtime/clash/bin/mihomo-linux-amd64" <<'SH'
#!/usr/bin/env bash
exec -a mihomo sleep 1000
SH
chmod +x "$runtime/clash/bin/yq" "$runtime/clash/bin/mihomo-linux-amd64"
dd if=/dev/zero of="$runtime/clash/conf/geoip.metadb" bs=1048576 count=6 >/dev/null 2>&1

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for proxy_name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
  [ "${!proxy_name:-}" != 'http://127.0.0.1:7890' ] || exit 66
done
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
    printf '%s\n' '{"name":"CodexProxy","now":"Node A","all":["Node A","DIRECT"]}' > "$output"
    [ "$write_status" != "true" ] || printf '200'
    exit 0
    ;;
esac
cat > "$output" <<'YAML'
proxies:
  - name: Node A
    type: http
    server: example.invalid
    port: 443
YAML
SH
cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
if [ -f "${FAKE_CLASH_CONFIG:?}" ]; then
  port="$(sed -n 's/^mixed-port: //p' "$FAKE_CLASH_CONFIG" | head -n 1)"
  [ -z "$port" ] || printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$port"
else
  printf '%s\n' \
    'LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*' \
    'LISTEN 0 128 127.0.0.1:6006 0.0.0.0:*'
fi
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_bin/curl" "$fake_bin/ss" "$fake_bin/systemctl"

install_output="$(printf '%s\n' 'https://subscription.example.invalid/clash.yaml' | \
  HOME="$tmp_home" PATH="$fake_bin:$PATH" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$tmp_data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$tmp_bin" \
  http_proxy='http://127.0.0.1:7890' https_proxy='http://127.0.0.1:7890' \
  HTTP_PROXY='http://127.0.0.1:7890' HTTPS_PROXY='http://127.0.0.1:7890' \
  FAKE_CLASH_CONFIG="$runtime/clash/conf/config.yaml" \
  bash "$repo_root/install-clash.sh")"

for name in proxy-on proxy-off proxy-switch proxy-status; do
  [ -x "$tmp_bin/$name" ]
done
[ ! -e "$tmp_bin/proxy-pick" ]
[ ! -e "$tmp_bin/clash-codex" ]
grep -q "CLASH_URL='https://subscription.example.invalid/clash.yaml'" "$tmp_config/config.sh"
grep -q "CODEX_PROXY_URL='http://127.0.0.1:17890'" "$tmp_config/config.sh"
grep -q "CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16006'" "$tmp_config/config.sh"
grep -q "PROXY_ENABLED='true'" "$tmp_config/config.sh"
grep -q '默认代理端口已被其他进程占用' <<< "$install_output"
grep -q '默认 Controller 端口已被其他进程占用' <<< "$install_output"
grep -qx 'mixed-port: 17890' "$runtime/clash/conf/config.yaml"
grep -qx 'external-controller: 127.0.0.1:16006' "$runtime/clash/conf/config.yaml"
grep -q 'proxy-switch()' "$tmp_config/proxy-shell-init.sh"
grep -q 'clash-codex-autodl-proxy begin' "$tmp_home/.bashrc"
pid="$(cat "$runtime/clash/mihomo.pid")"
kill -0 "$pid"
