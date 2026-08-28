#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
fake_bin="$tmp_dir/fake-bin"
port_file="$tmp_dir/port"
python_cmd=""

cleanup() {
  if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

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
exit 1
SH
chmod +x "$fake_bin/ss"

cat > "$fake_bin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_bin/lsof"

"$python_cmd" - "$port_file" <<'PY' &
import socket
import sys

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(8)

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(sock.getsockname()[1]))

while True:
    conn, _ = sock.accept()
    conn.close()
PY
server_pid="$!"

for _ in $(seq 1 50); do
  if [ -s "$port_file" ]; then
    break
  fi
  sleep 0.1
done

port="$(cat "$port_file")"
PATH="$fake_bin:$PATH" bash -c "
  set -euo pipefail
  source '$repo_root/lib/codex_common.sh'
  local_proxy_is_listening 'http://127.0.0.1:$port'
"

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
curl_log="$tmp_dir/curl.log"
cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$fake_bin/python3" "$fake_bin/python"
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 0
SH
chmod +x "$fake_bin/python3" "$fake_bin/python" "$fake_bin/curl"

if PATH="$fake_bin:$PATH" CURL_LOG="$curl_log" bash -c "
  source '$repo_root/lib/codex_common.sh'
  local_proxy_is_listening 'http://127.0.0.1:$port'
"; then
  printf 'closed local port should not be reported as listening\n' >&2
  exit 1
fi
[ ! -e "$curl_log" ]
