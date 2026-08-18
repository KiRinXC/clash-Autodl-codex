#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
tmp_home="$tmp_dir/home"
tmp_state="$tmp_home/.config/clash-codex-autodl"
called="$tmp_dir/proxy-on-called"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_home/.local/bin" "$tmp_state"
cat > "$tmp_state/config.sh" <<'EOF'
AUTO_PROXY_ON_SHELL_START='true'
EOF

cat > "$tmp_home/.local/bin/clash-codex" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = proxy ] && [ "\${2:-}" = on ]; then
  touch '$called'
  printf '%s\n' 'export http_proxy=http://127.0.0.1:17900'
  printf '%s\n' 'export https_proxy=http://127.0.0.1:17900'
  exit 0
fi
exit 1
SH
chmod +x "$tmp_home/.local/bin/clash-codex"

HOME="$tmp_home" CODEX_AUTODL_CONFIG_DIR="$tmp_state" bash -lc "
  set -euo pipefail
  source '$repo_root/lib/codex_common.sh'
  install_proxy_shell_hook >/dev/null
"

output="$(HOME="$tmp_home" bash -lc '
  set -euo pipefail
  source "$HOME/.config/clash-codex-autodl/proxy-shell-init.sh"
  printf "http_proxy=%s\n" "${http_proxy:-}"
')"

[ -f "$called" ]
grep -q 'http_proxy=http://127.0.0.1:17900' <<<"$output"
