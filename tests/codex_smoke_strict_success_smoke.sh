#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_with_fake_codex() {
  local script_body="$1"
  local tmp_dir fake_bin output status

  tmp_dir="$(mktemp -d)"
  fake_bin="$tmp_dir/bin"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail

$script_body
EOF
  chmod +x "$fake_bin/codex"

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
    CODEX_SMOKE_TIMEOUT=1 \
    bash -c "source '$repo_root/lib/codex_common.sh'; codex_smoke_test" 2>&1
  )"
  status="$?"
  set -e

  rm -rf "$tmp_dir"
  printf '%s\n' "$output"
  return "$status"
}

set +e
log_only_output="$(
  run_with_fake_codex '
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf "%s\n" "log mentions CODEX_READY, but this is not the final answer" >&2
printf "%s\n" "NOT_READY" > "$out_file"
sleep 5
'
)"
log_only_status="$?"
set -e

if [ "$log_only_status" -eq 0 ]; then
  printf '%s\n' "$log_only_output"
  echo "expected log-only READY timeout case to fail"
  exit 1
fi

grep -q '\[FAIL\].*验证失败.*1' <<<"$log_only_output"
grep -q '\[INFO\].*/tmp/codex-bootstrap-smoke.log' <<<"$log_only_output"
! grep -q '\[OK\].*Codex' <<<"$log_only_output"
! grep -q 'log mentions CODEX_READY' <<<"$log_only_output"

set +e
nonzero_output="$(
  run_with_fake_codex '
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf "%s\n" "CODEX_READY" > "$out_file"
exit 42
'
)"
nonzero_status="$?"
set -e

if [ "$nonzero_status" -eq 0 ]; then
  printf '%s\n' "$nonzero_output"
  echo "expected non-zero codex exit case to fail"
  exit 1
fi

grep -q '\[FAIL\].*验证失败.*42' <<<"$nonzero_output"
! grep -q '\[OK\].*Codex' <<<"$nonzero_output"

set +e
error_summary_output="$(
  run_with_fake_codex '
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf "%s\n" "Reading additional input from stdin..." >&2
printf "%s\n" "ERROR: stream disconnected before completion" >&2
printf "%s\n" "NOT_READY" > "$out_file"
exit 1
'
)"
error_summary_status="$?"
set -e

if [ "$error_summary_status" -eq 0 ]; then
  printf '%s\n' "$error_summary_output"
  echo "expected stream-disconnected case to fail"
  exit 1
fi

grep -q '\[FAIL\].*验证失败.*1' <<<"$error_summary_output"
grep -q '\[FAIL\].*原因: stream disconnected before completion' <<<"$error_summary_output"
! grep -q 'Reading additional input from stdin' <<<"$error_summary_output"
