#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
work_dir="$tmp_dir/work"
calls="$tmp_dir/calls"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.local/bin" "$work_dir"
cp "$repo_root/start.sh" "$work_dir/start.sh"

cat > "$work_dir/install.sh" <<SH
#!/usr/bin/env bash
mkdir -p '$tmp_home/.local/bin'
cat > '$tmp_home/.local/bin/clash-codex' <<'INNER'
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
INNER
chmod +x '$tmp_home/.local/bin/clash-codex'
SH
chmod +x "$work_dir/install.sh"

HOME="$tmp_home" bash "$work_dir/start.sh" >/dev/null
grep -qx 'setup' "$calls"

: > "$calls"
HOME="$tmp_home" bash "$work_dir/start.sh" --reconfigure-clash >/dev/null
grep -qx 'setup clash' "$calls"

: > "$calls"
HOME="$tmp_home" bash "$work_dir/start.sh" --reconfigure-codex >/dev/null
grep -qx 'setup codex' "$calls"
grep -qx 'auth api' "$calls"

help_output="$(HOME="$tmp_home" bash "$work_dir/start.sh" --help)"
grep -q -- '--reconfigure-clash' <<<"$help_output"
grep -q -- '--reconfigure-codex' <<<"$help_output"
