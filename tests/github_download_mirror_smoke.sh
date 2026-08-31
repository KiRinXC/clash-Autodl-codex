#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
fake_bin="$tmp_dir/bin"
output_file="$tmp_dir/download"

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
mkdir -p "$fake_bin"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output_file=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    http://* | https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  https://github.com/*)
    printf 'partial-from-github' > "$output_file"
    exit 28
    ;;
  https://ghfast.top/*)
    # The fallback must receive an empty, origin-specific file. The previous
    # implementation reused GitHub's partial response here.
    [ "$(wc -c < "$output_file" | tr -d '[:space:]')" = 0 ] || exit 18
    printf 'complete-from-mirror' > "$output_file"
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_bin/curl"

function_source="$tmp_dir/function.sh"
awk '/^download_github_file\(\)/ { capture = 1 } capture { print } capture && /^}$/ { exit }' \
  "$repo_root/setup_mihomo.sh" > "$function_source"

PATH="$fake_bin:$PATH" bash -c '
  set -euo pipefail
  . "$1/lib/codex_common.sh"
  GITHUB_MIRRORS=("github.com" "ghfast.top/https://github.com")
  . "$2"
  download_github_file "/owner/repo/releases/download/v1/file.gz" "$3" test-artifact
' _ "$repo_root" "$function_source" "$output_file" >/dev/null

grep -qx 'complete-from-mirror' "$output_file"
