#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
called="$tmp_dir/called"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.local/bin"
cat > "$tmp_home/.local/bin/clash-codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$called'
SH
chmod +x "$tmp_home/.local/bin/clash-codex"

HOME="$tmp_home" bash "$repo_root/verify_codex.sh"
grep -qx 'verify' "$called"

if HOME="$tmp_home" bash "$repo_root/verify_codex.sh" current >/dev/null 2>&1; then
  printf 'verify_codex.sh should reject legacy relay arguments\n' >&2
  exit 1
fi
