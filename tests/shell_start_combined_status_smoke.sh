#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
home="$tmp_dir/home"
config="$tmp_dir/config"
data="$tmp_dir/data"
runtime="$data/runtime"
bin="$tmp_dir/user-bin"
state_file="$tmp_dir/node"
port_file="$tmp_dir/controller-port"
controller_port=""
server_pid=""
mihomo_pid=""

cleanup() {
  [ -z "$mihomo_pid" ] || kill "$mihomo_pid" >/dev/null 2>&1 || true
  [ -z "$server_pid" ] || kill "$server_pid" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
mkdir -p "$home" "$config" "$bin" "$runtime/clash" \
  "$data/codex-homes/api" "$data/codex-shared/sessions" "$data/codex-shared/sqlite"

python_cmd="$(command -v python3 || command -v python)"
"$python_cmd" - "$state_file" "$port_file" >/dev/null 2>&1 <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

state_file = sys.argv[1]
port_file = sys.argv[2]
open(state_file, "w", encoding="utf-8").write("Node A")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/proxies/CodexProxy":
            self.send_error(404)
            return
        now = open(state_file, encoding="utf-8").read().strip()
        body = json.dumps({"now": now, "all": ["DIRECT", "Node A", "Node B"]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        if self.path != "/proxies/CodexProxy":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        name = json.loads(self.rfile.read(length)).get("name")
        if name not in {"DIRECT", "Node A", "Node B"}:
            self.send_error(400)
            return
        open(state_file, "w", encoding="utf-8").write(name)
        self.send_response(204)
        self.end_headers()

server = HTTPServer(("127.0.0.1", 0), Handler)
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

cat > "$bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:17890 0.0.0.0:*\n'
SH
chmod +x "$bin/ss"
bash -c 'exec -a mihomo sleep 120' &
mihomo_pid="$!"
printf '%s\n' "$mihomo_pid" > "$runtime/clash/mihomo.pid"

cat > "$config/config.sh" <<EOF
CLASH_URL='https://subscription.example.invalid/clash.yaml'
CODEX_PROXY_URL='http://127.0.0.1:17890'
CODEX_MIHOMO_CONTROLLER_URL='http://127.0.0.1:$controller_port'
CODEX_PROXY_GROUP='CodexProxy'
PROXY_ENABLED='true'
EOF
cat > "$data/codex-homes/api/config.toml" <<'EOF'
model_provider = "OpenAI"
model = "gpt-5.6-sol"
sqlite_home = "/managed/sqlite"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.example.invalid/v1"
wire_api = "responses"
requires_openai_auth = true
EOF
printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$data/codex-homes/api/auth.json"
printf '%s\n' api > "$config/active-auth"
printf '%s\n' 1 > "$data/codex-shared/.layout-version"
ln -s "$data/codex-shared/sessions" "$data/codex-homes/api/sessions"

HOME="$home" CLASH_CODEX_AUTODL_CONFIG_DIR="$config" \
  CLASH_CODEX_AUTODL_DATA_DIR="$data" CLASH_CODEX_AUTODL_USER_BIN_DIR="$bin" \
  bash -c "
    . '$repo_root/lib/install_runtime.sh'
    deploy_runtime '$repo_root'
    export CLASH_CODEX_AUTODL_REPO_ROOT='$runtime'
    export CODEX_AUTODL_REPO_ROOT='$runtime'
    . '$runtime/lib/codex_common.sh'
    . '$runtime/lib/codex_profiles.sh'
    . '$runtime/lib/codex_sessions.sh'
    install_proxy_wrappers
    install_codex_wrappers
    install_proxy_shell_hook
    install_codex_shell_hook
    install_path_block
  " >/dev/null

sleep 1
terminal_status="$(env -i HOME="$home" PATH="/usr/bin:/bin" TERM=dumb \
  /bin/bash --noprofile --rcfile "$home/.bashrc" -i -c exit 2>&1)"
grep -q '^\[proxy\] 已开启 | 节点: Node A$' <<< "$terminal_status"
grep -q '^\[codex\] API | https://api.example.invalid/v1$' <<< "$terminal_status"
grep -q '^\[sync\] 已同步 | 0 个会话$' <<< "$terminal_status"

switch_output="$(printf '3\n' | env -i HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" CLASH_CODEX_AUTODL_DATA_DIR="$data" \
  HTTPS_PROXY='http://127.0.0.1:1' "$bin/proxy-switch")"
grep -q '已选择: Node B' <<< "$switch_output"
[ "$(cat "$state_file")" = 'Node B' ]
status_output="$(env -i HOME="$home" PATH="$bin:/usr/bin:/bin" \
  CLASH_CODEX_AUTODL_CONFIG_DIR="$config" CLASH_CODEX_AUTODL_DATA_DIR="$data" \
  "$bin/proxy-status" 2>&1)"
grep -q '当前节点: Node B' <<< "$status_output"
