#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_config="$tmp_dir/config"
runtime="$tmp_dir/runtime"
fake_bin="$tmp_dir/fake-bin"

cleanup() {
  pid="$(cat "$runtime/clash/mihomo.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$tmp_home" "$tmp_config" "$runtime/lib" "$runtime/clash/bin" "$runtime/clash/conf" "$fake_bin"
cp "$repo_root/command.sh" "$runtime/command.sh"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib/codex_common.sh"
cp "$repo_root/lib/codex_profiles.sh" "$runtime/lib/codex_profiles.sh"
cp "$repo_root/lib/codex_sessions.sh" "$runtime/lib/codex_sessions.sh"
chmod +x "$runtime/command.sh"
printf 'mixed-port: 17890\n' > "$runtime/clash/conf/config.yaml"

cat > "$runtime/clash/bin/mihomo-linux-amd64" <<'SH'
#!/usr/bin/env bash
exec -a mihomo sleep 1000
SH
chmod +x "$runtime/clash/bin/mihomo-linux-amd64"
cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
method="GET"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$method" = PUT ]; then
  : > "$output"
  printf '204'
else
  printf '%s\n' '{"name":"CodexProxy","now":"Node A","all":["Node A","DIRECT"]}' > "$output"
  printf '200'
fi
SH
chmod +x "$fake_bin/ss" "$fake_bin/systemctl" "$fake_bin/curl"

cat > "$tmp_config/config.sh" <<'EOF'
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_PROXY_URL='http://127.0.0.1:17890'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:6006'
CODEX_PROXY_GROUP='CodexProxy'
PROXY_ENABLED='false'
EOF

env_args=(HOME="$tmp_home" PATH="$fake_bin:$PATH" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config")
env "${env_args[@]}" "$runtime/command.sh" proxy enable >/dev/null
grep -q "PROXY_ENABLED='true'" "$tmp_config/config.sh"
pid="$(cat "$runtime/clash/mihomo.pid")"
kill -0 "$pid"
env_output="$(env "${env_args[@]}" "$runtime/command.sh" proxy env)"
grep -q 'export http_proxy=' <<< "$env_output"
shell_output="$(env "${env_args[@]}" CODEX_MIHOMO_START_WAIT_SECONDS=1 "$runtime/command.sh" proxy shell-start 2>&1)"
grep -q '\[proxy\] 已开启 | 节点: Node A' <<< "$shell_output"
if grep -q 'unknown' <<< "$shell_output"; then exit 1; fi

env "${env_args[@]}" "$runtime/command.sh" proxy disable >/dev/null
grep -q "PROXY_ENABLED='false'" "$tmp_config/config.sh"
if kill -0 "$pid" >/dev/null 2>&1; then exit 1; fi
status_output="$(env "${env_args[@]}" "$runtime/command.sh" proxy status 2>&1)"
grep -q 'Controller 状态: Controller 不可访问' <<< "$status_output"
if grep -q 'unknown' <<< "$status_output"; then exit 1; fi
disabled_output="$(env "${env_args[@]}" "$runtime/command.sh" proxy shell-start 2>&1)"
grep -q '\[proxy\] 已关闭' <<< "$disabled_output"

HOME="$tmp_home" CLASH_CODEX_AUTODL_CONFIG_DIR="$tmp_config" \
  CLASH_CODEX_AUTODL_REPO_ROOT="$runtime" bash -c ". '$runtime/lib/codex_common.sh'; install_proxy_shell_hook" >/dev/null
grep -q 'proxy-switch()' "$tmp_config/proxy-shell-init.sh"
grep -q 'case \$- in' "$tmp_config/proxy-shell-init.sh"
