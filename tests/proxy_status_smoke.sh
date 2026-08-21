#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
fake_bin="$tmp_dir/fake-bin"
controller_port=18081
controller_base="http://127.0.0.1:${controller_port}"
server_log="$tmp_dir/server.log"
python_cmd=""

cleanup() {
  if [ -n "${mihomo_pid:-}" ] && kill -0 "$mihomo_pid" >/dev/null 2>&1; then
    kill "$mihomo_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$tmp_dir/runtime/clash"

for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    candidate_path="$(command -v "$candidate")"
    if "$candidate_path" - <<'PY' >/dev/null 2>&1
import sys
PY
    then
      python_cmd="$candidate_path"
      break
    fi
  fi
done

if [ -z "$python_cmd" ]; then
  echo "missing working python"
  exit 1
fi

cat > "$fake_bin/python3" <<SH
#!/usr/bin/env bash
exec "$python_cmd" "\$@"
SH
chmod +x "$fake_bin/python3"

cat > "$fake_bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:7890 0.0.0.0:*\n'
SH
chmod +x "$fake_bin/ss"

cat > "$fake_bin/ps" <<'SH'
#!/usr/bin/env bash
printf 'mihomo mihomo -d /tmp/test-conf\n'
SH
chmod +x "$fake_bin/ps"

"$python_cmd" - "$controller_port" >"$server_log" 2>&1 <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/proxies/CodexProxy":
            body = json.dumps({
                "name": "CodexProxy",
                "type": "Selector",
                "now": "Node A",
                "all": ["DIRECT", "Node A"],
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
server_pid=$!
bash -c 'exec -a mihomo sleep 1000' &
mihomo_pid=$!
printf '%s\n' "$mihomo_pid" > "$tmp_dir/runtime/clash/mihomo.pid"
sleep 1

output="$(
  CODEX_AUTODL_CONFIG_DIR="$tmp_dir" \
  CLASH_CODEX_AUTODL_REPO_ROOT="$tmp_dir/runtime" \
  PATH="$fake_bin:$PATH" \
  bash -c "
    set -euo pipefail
    source '$repo_root/lib/codex_common.sh'
    CODEX_PROXY_URL='http://127.0.0.1:7890'
    CODEX_MIHOMO_CONTROLLER_URL='$controller_base'
    CODEX_PROXY_GROUP='CodexProxy'
    save_project_config
    export http_proxy='http://127.0.0.1:7890'
    proxy-status
  " 2>&1
)"

grep -q "\[OK\].*永久代理: 已开启" <<<"$output"
grep -q "\[OK\].*当前终端环境: 已开启" <<<"$output"
grep -q "\[INFO\].*地址: http://127.0.0.1:7890" <<<"$output"
grep -q "\[OK\].*当前节点: Node A" <<<"$output"
