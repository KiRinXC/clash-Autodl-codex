#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
runtime="$tmp_dir/runtime"
config="$tmp_dir/config"
fake_bin="$tmp_dir/fake-bin"
curl_log="$tmp_dir/curl.log"
mihomo_pid=""

cleanup() {
  [ -z "$mihomo_pid" ] || kill "$mihomo_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$runtime/lib" "$runtime/clash" "$config" "$fake_bin"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib/codex_common.sh"

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
case "${SS_MODE:-anonymous}" in
  other)
    printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:* users:(("other",pid=999,fd=3))\n'
    ;;
  matching)
    printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:* users:(("mihomo",pid=%s,fd=3))\n' "${MIHOMO_PID:?}"
    ;;
  *)
    printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
    ;;
esac
SH
cat > "$fake_bin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CURL_LOG:?}"
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
  printf '%s\n' '{"name":"代理 Group / 100%","now":"Node A","all":["Node A","DIRECT"]}' > "$output"
  printf '200'
fi
SH
chmod +x "$fake_bin/ss" "$fake_bin/lsof" "$fake_bin/systemctl" "$fake_bin/curl"

bash -c 'exec -a mihomo sleep 120' &
mihomo_pid="$!"
printf '%s\n' "$mihomo_pid" > "$runtime/clash/mihomo.pid"

cat > "$config/config.sh" <<'EOF'
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_PROXY_URL='http://127.0.0.1:17890'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:16006'
CODEX_PROXY_GROUP='代理 Group / 100%'
PROXY_ENABLED='true'
EOF

common_env=(
  HOME="$tmp_dir/home"
  PATH="$fake_bin:$PATH"
  CURL_LOG="$curl_log"
  MIHOMO_PID="$mihomo_pid"
  CLASH_CODEX_AUTODL_REPO_ROOT="$runtime"
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config"
)

# A listener owned by a visible different PID is not accepted as Mihomo ready.
env "${common_env[@]}" SS_MODE=other bash -c "
  . '$runtime/lib/codex_common.sh'
  load_project_config
  local_proxy_is_listening
  if local_proxy_is_ready; then exit 1; fi
  [ \"\$(mihomo_readiness_error_text)\" = '代理端口由其他进程占用: http://127.0.0.1:17890' ]
"

# Missing ownership metadata remains compatible; matching metadata is accepted.
env "${common_env[@]}" SS_MODE=anonymous bash -c "
  . '$runtime/lib/codex_common.sh'
  load_project_config
  local_proxy_is_ready
"
env "${common_env[@]}" SS_MODE=matching bash -c "
  . '$runtime/lib/codex_common.sh'
  load_project_config
  local_proxy_is_ready
  mihomo_is_ready
"

encoded_group='%E4%BB%A3%E7%90%86%20Group%20%2F%20100%25'
node="$(env "${common_env[@]}" SS_MODE=matching bash -c "
  . '$runtime/lib/codex_common.sh'
  load_project_config
  current_proxy_node
")"
[ "$node" = 'Node A' ]
status_output="$(env "${common_env[@]}" SS_MODE=matching bash -c "
  . '$runtime/lib/codex_common.sh'
  proxy-status
")"
grep -q '代理组: 代理 Group / 100%' <<< "$status_output"
grep -q '当前节点: Node A' <<< "$status_output"
switch_output="$(printf '1\n' | env "${common_env[@]}" SS_MODE=matching bash -c "
  . '$runtime/lib/codex_common.sh'
  proxy-switch
")"
grep -q '已选择: Node A' <<< "$switch_output"
grep -q "http://127.0.0.1:16006/proxies/$encoded_group" "$curl_log"
grep -q -- "-X PUT .*http://127.0.0.1:16006/proxies/$encoded_group" "$curl_log"
if grep -q '/proxies/代理 Group / 100%' "$curl_log"; then exit 1; fi

# Invalid timeout values fall back cleanly instead of reaching curl/seq arithmetic.
: > "$curl_log"
for invalid_timeout in 0 -2 not-a-number; do
  timeout_warning="$tmp_dir/timeout-warning-${invalid_timeout//[^a-zA-Z0-9]/_}"
  env "${common_env[@]}" CODEX_MIHOMO_CONTROLLER_TIMEOUT="$invalid_timeout" bash -c "
    . '$runtime/lib/codex_common.sh'
    load_project_config
    mihomo_controller_request GET '/version'
  " 2> "$timeout_warning"
  grep -q -- '--max-time 3' "$curl_log"
  grep -q 'CODEX_MIHOMO_CONTROLLER_TIMEOUT' "$timeout_warning"
done

env "${common_env[@]}" CODEX_MIHOMO_CONTROLLER_TIMEOUT=007 bash -c "
  . '$runtime/lib/codex_common.sh'
  load_project_config
  mihomo_controller_request GET '/version'
"
grep -q -- '--max-time 7' "$curl_log"

for invalid_wait in 0 -2 not-a-number; do
  env "${common_env[@]}" CODEX_MIHOMO_START_WAIT_SECONDS="$invalid_wait" bash -c "
    . '$runtime/lib/codex_common.sh'
    attempts=0
    mihomo_is_ready() { attempts=\$((attempts + 1)); return 1; }
    sleep() { :; }
    if wait_for_mihomo_ready 2>/dev/null; then exit 1; fi
    [ \"\$attempts\" -eq 20 ]
  "
done
