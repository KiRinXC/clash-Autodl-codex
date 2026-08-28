#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
runtime="$tmp_dir/runtime"
config="$tmp_dir/config"
fake_bin="$tmp_dir/fake-bin"
mode_file="$tmp_dir/controller-mode"
ready_file="$tmp_dir/controller-ready-at"
node_file="$tmp_dir/current-node"
port_file="$tmp_dir/controller-port"
server_pid=""
mihomo_pid=""

cleanup() {
  [ -z "$mihomo_pid" ] || kill "$mihomo_pid" >/dev/null 2>&1 || true
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$runtime/lib" "$runtime/clash" "$config" "$fake_bin"
cp "$repo_root/lib/codex_common.sh" "$runtime/lib/codex_common.sh"

python_cmd="$(command -v python3 || command -v python)"
printf '%s\n' normal > "$mode_file"
printf '%s\n' 0 > "$ready_file"
printf '%s\n' 'Node A' > "$node_file"

"$python_cmd" - "$mode_file" "$ready_file" "$node_file" "$port_file" <<'PY' &
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode_file, ready_file, node_file, port_file = sys.argv[1:]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def mode(self):
        return open(mode_file, encoding="utf-8").read().strip()

    def do_GET(self):
        if self.path != "/proxies/CodexProxy":
            self.respond(404, b'{}')
            return
        if time.time() < float(open(ready_file, encoding="utf-8").read().strip()):
            self.respond(503, b'{"error":"initializing"}')
            return
        mode = self.mode()
        if mode == "404":
            self.respond(404, b'{"error":"group missing"}')
            return
        if mode == "401":
            self.respond(401, b'{"error":"unauthorized"}')
            return
        if mode == "invalid":
            self.respond(200, b'{invalid')
            return
        if mode == "timeout":
            time.sleep(2)
        now = open(node_file, encoding="utf-8").read().strip()
        body = json.dumps({
            "name": "CodexProxy",
            "now": now,
            "all": ["Node A", "Node B", "DIRECT"],
        }).encode()
        self.respond(200, body)

    def do_PUT(self):
        if self.path != "/proxies/CodexProxy":
            self.respond(404, b'{}')
            return
        length = int(self.headers.get("Content-Length", "0"))
        target = json.loads(self.rfile.read(length)).get("name")
        if target not in {"Node A", "Node B", "DIRECT"}:
            self.respond(400, b'{}')
            return
        open(node_file, "w", encoding="utf-8").write(target)
        self.respond(204)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w", encoding="utf-8").write(str(server.server_port))
server.serve_forever()
PY
server_pid="$!"
for _ in 1 2 3 4 5; do
  [ -s "$port_file" ] && break
  sleep 1
done
[ -s "$port_file" ]
controller_port="$(cat "$port_file")"

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
SH
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_bin/ss" "$fake_bin/systemctl"

bash -c 'exec -a mihomo sleep 120' &
mihomo_pid="$!"
printf '%s\n' "$mihomo_pid" > "$runtime/clash/mihomo.pid"

write_config() {
  local controller_url="$1"
  cat > "$config/config.sh" <<EOF
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_PROXY_URL='http://127.0.0.1:17890'
CODEX_MIHOMO_CONTROLLER_URL='$controller_url'
CODEX_PROXY_GROUP='CodexProxy'
PROXY_ENABLED='true'
EOF
}
write_config "http://127.0.0.1:$controller_port"

common_env=(
  PATH="$fake_bin:$PATH"
  CLASH_CODEX_AUTODL_REPO_ROOT="$runtime"
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config"
  CODEX_MIHOMO_CONTROLLER_TIMEOUT=1
  CODEX_MIHOMO_START_WAIT_SECONDS=5
)

# 7890 is already ready while the Controller initializes for two seconds.
printf '%s\n' "$(( $(date +%s) + 2 ))" > "$ready_file"
shell_output="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; proxy_shell_start" 2>&1)"
grep -q '^\[proxy\] 已开启 | 节点: Node A$' <<< "$shell_output"
if grep -q 'unknown' <<< "$shell_output"; then exit 1; fi

# proxy-switch must also wait for a Controller that is still initializing.
printf '%s\n' "$(( $(date +%s) + 2 ))" > "$ready_file"
switch_output="$(printf '2\n' | env "${common_env[@]}" \
  bash -c ". '$runtime/lib/codex_common.sh'; proxy-switch")"
grep -q '已选择: Node B' <<< "$switch_output"
[ "$(cat "$node_file")" = 'Node B' ]

# A Mihomo restart must not make the selected node silently fall back to DIRECT.
kill "$mihomo_pid"
wait "$mihomo_pid" 2>/dev/null || true
bash -c 'exec -a mihomo sleep 120' &
mihomo_pid="$!"
printf '%s\n' "$mihomo_pid" > "$runtime/clash/mihomo.pid"
persisted_node="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; load_project_config; current_proxy_node")"
[ "$persisted_node" = 'Node B' ]

# DIRECT remains an explicit manual option and reports back as the current node.
direct_output="$(printf '3\n' | env "${common_env[@]}" \
  bash -c ". '$runtime/lib/codex_common.sh'; proxy-switch")"
grep -q '已选择: DIRECT' <<< "$direct_output"
direct_node="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; load_project_config; current_proxy_node")"
[ "$direct_node" = 'DIRECT' ]

printf '%s\n' 0 > "$ready_file"
printf '%s\n' 404 > "$mode_file"
status_404="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; proxy-status" 2>&1)"
grep -q 'Controller 状态: 找不到代理组: CodexProxy' <<< "$status_404"
if grep -q 'unknown' <<< "$status_404"; then exit 1; fi

printf '%s\n' 401 > "$mode_file"
status_401="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; proxy-status" 2>&1)"
grep -q 'Controller 状态: Controller 认证失败' <<< "$status_401"
if grep -q 'unknown' <<< "$status_401"; then exit 1; fi

printf '%s\n' invalid > "$mode_file"
status_invalid="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; proxy-status" 2>&1)"
grep -q 'Controller 状态: Controller 响应无效' <<< "$status_invalid"
if grep -q 'unknown' <<< "$status_invalid"; then exit 1; fi

write_config 'http://127.0.0.1:1'
unreachable_output="$(env "${common_env[@]}" CODEX_MIHOMO_START_WAIT_SECONDS=1 \
  bash -c ". '$runtime/lib/codex_common.sh'; proxy_shell_start" 2>&1 || true)"
grep -q '^\[proxy\] 已开启 | Controller 不可访问$' <<< "$unreachable_output"
if grep -q 'unknown' <<< "$unreachable_output"; then exit 1; fi

write_config "http://127.0.0.1:$controller_port"
printf '%s\n' timeout > "$mode_file"
timeout_status="$(env "${common_env[@]}" bash -c ". '$runtime/lib/codex_common.sh'; proxy-status" 2>&1)"
grep -q 'Controller 状态: Controller 响应超时' <<< "$timeout_status"
if grep -q 'unknown' <<< "$timeout_status"; then exit 1; fi
