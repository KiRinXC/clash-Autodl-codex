#!/usr/bin/env bash

# Codex keeps all conversation state in its native CODEX_HOME. This project
# must not create a second session tree, move rollouts, or install symlinks
# below ~/.codex. Authentication snapshots live outside CODEX_HOME; only the
# session_meta provider field is rewritten when authentication changes.

codex_process_is_running() {
  ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" '
    $1 != self && ($2 ~ /^(codex|codex-cli)$/ || $0 ~ /(^|[[:space:]])codex(-cli)?([[:space:]]|$)/ || $0 ~ /\/@openai\/codex\/[^[:space:]]*/) { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

codex_rewrite_native_session_providers() {
  local target_provider="$1" native_home work python_bin result changed skipped
  local source_file output_file first_line escaped_provider index applied_index
  local -a fallback_sources fallback_originals fallback_outputs
  [ -n "$target_provider" ] || { log_error "目标 model_provider 不能为空"; return 1; }
  native_home="$(codex_native_home)"
  mkdir -p "$(project_data_dir)"
  work="$(mktemp -d "$(project_data_dir)/.session-provider-sync.XXXXXX")"

  if python_bin="$(python_command 2>/dev/null)"; then
    if ! result="$("$python_bin" - "$native_home/sessions" "$native_home/archived_sessions" \
      "$target_provider" "$work" <<'PY'
import json
import os
import shutil
import stat
import sys

roots = sys.argv[1:3]
target_provider = sys.argv[3]
work = sys.argv[4]
skipped = 0
errors = []
updates = []

for root in roots:
    if not os.path.isdir(root):
        continue
    for directory, _, files in os.walk(root):
        for name in files:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(directory, name)
            try:
                with open(path, "rb") as source:
                    original = source.read()
                newline_at = original.find(b"\n")
                if newline_at >= 0:
                    first = original[:newline_at]
                    rest = original[newline_at + 1:]
                    line_ending = b"\n"
                    if first.endswith(b"\r"):
                        first = first[:-1]
                        line_ending = b"\r\n"
                else:
                    first = original
                    rest = b""
                    line_ending = b""
                record = json.loads(first.decode("utf-8"))
                payload = record.get("payload")
                if record.get("type") != "session_meta" or not isinstance(payload, dict):
                    skipped += 1
                    continue
                if payload.get("model_provider") == target_provider:
                    continue
                payload["model_provider"] = target_provider
                replacement = json.dumps(
                    record, ensure_ascii=False, separators=(",", ":")
                ).encode("utf-8") + line_ending + rest
                updates.append((path, original, replacement, os.stat(path)))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError, TypeError, RuntimeError) as exc:
                errors.append(f"{path}: {exc}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)

applied = []
try:
    for index, (path, original, replacement, file_stat) in enumerate(updates):
        staged = os.path.join(work, f"rewrite-{index}.tmp")
        with open(staged, "wb") as target:
            target.write(replacement)
            target.flush()
            os.fsync(target.fileno())
        shutil.copyfile(staged, path)
        os.chmod(path, stat.S_IMODE(file_stat.st_mode))
        applied.append((path, original, file_stat))
        with open(path, "rb") as verify:
            verify_first = verify.readline().rstrip(b"\r\n")
        verified = json.loads(verify_first.decode("utf-8"))
        if verified.get("payload", {}).get("model_provider") != target_provider:
            raise RuntimeError(f"{path}: provider verification failed")
except (OSError, UnicodeDecodeError, json.JSONDecodeError, TypeError, RuntimeError) as exc:
    print(str(exc), file=sys.stderr)
    for path, original, file_stat in applied:
        try:
            with open(path, "wb") as restore:
                restore.write(original)
                restore.flush()
                os.fsync(restore.fileno())
            os.chmod(path, stat.S_IMODE(file_stat.st_mode))
        except OSError as restore_error:
            print(f"{path}: rollback failed: {restore_error}", file=sys.stderr)
    raise SystemExit(1)

print(f"{len(updates)} {skipped}")
PY
)"; then
      rm -rf "$work"
      log_error "会话 provider 元数据同步失败；未成功修改的文件保持原样"
      return 1
    fi
    read -r changed skipped <<< "$result"
  else
    changed=0
    skipped=0
    case "$target_provider" in
      '' | *[!A-Za-z0-9._-]*)
        rm -rf "$work"
        log_error "缺少 Python，且目标 provider 含无法安全写入 JSON 的字符"
        return 1
        ;;
    esac
    escaped_provider="$(printf '%s' "$target_provider" | sed 's/[&|]/\\&/g')"
    fallback_sources=()
    fallback_originals=()
    fallback_outputs=()
    index=0
    while IFS= read -r -d '' source_file; do
      first_line="$(head -n 1 "$source_file" 2>/dev/null || true)"
      if ! printf '%s\n' "$first_line" | grep -Eq '"type"[[:space:]]*:[[:space:]]*"session_meta"'; then
        skipped=$((skipped + 1))
        continue
      fi
      output_file="$work/rewrite-$index.tmp"
      if printf '%s\n' "$first_line" | grep -Eq '"model_provider"[[:space:]]*:'; then
        if ! sed -E "1 s|\"model_provider\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"model_provider\":\"$escaped_provider\"|" \
          "$source_file" > "$output_file"; then
          rm -rf "$work"
          log_error "无法读取会话文件: $source_file"
          return 1
        fi
      else
        if ! sed -E "1 s|\"payload\"[[:space:]]*:[[:space:]]*\{|\"payload\":{\"model_provider\":\"$escaped_provider\",|" \
          "$source_file" > "$output_file"; then
          rm -rf "$work"
          log_error "无法读取会话文件: $source_file"
          return 1
        fi
      fi
      if cmp -s "$source_file" "$output_file"; then
        continue
      fi
      fallback_sources+=("$source_file")
      fallback_originals+=("$work/original-$index.tmp")
      fallback_outputs+=("$output_file")
      if ! cp "$source_file" "$work/original-$index.tmp"; then
        rm -rf "$work"
        log_error "无法暂存会话回退副本: $source_file"
        return 1
      fi
      index=$((index + 1))
    done < <(find "$native_home/sessions" "$native_home/archived_sessions" \
      -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
    for index in "${!fallback_sources[@]}"; do
      if ! cp "${fallback_outputs[$index]}" "${fallback_sources[$index]}"; then
        for ((applied_index = 0; applied_index < index; applied_index++)); do
          cp "${fallback_originals[$applied_index]}" "${fallback_sources[$applied_index]}" || true
        done
        rm -rf "$work"
        log_error "无法更新会话 provider: ${fallback_sources[$index]}"
        return 1
      fi
      changed=$((changed + 1))
    done
  fi

  rm -rf "$work"
  if [ "${changed:-0}" -gt 0 ]; then
    log_ok "已将 $changed 个原生会话的 model_provider 对齐为 $target_provider"
  else
    log_info "原生会话 provider 已是 $target_provider"
  fi
  if [ "${skipped:-0}" -gt 0 ]; then
    log_warn "跳过 $skipped 个没有有效 session_meta 的 rollout 文件"
  fi
}

codex_sync_native_sessions_to_profile() {
  local profile="$1" profile_config provider
  codex_profile_is_configured "$profile" || { log_error "$profile 配置尚未完成"; return 1; }
  profile_config="$(codex_profile_home "$profile")/config.toml"
  provider="$(codex_config_model_provider "$profile_config")"
  codex_rewrite_native_session_providers "$provider"
}

codex_native_session_rollout_count() {
  local native_home
  native_home="$(codex_native_home)"
  {
    find "$native_home/sessions" "$native_home/archived_sessions" \
      -type f -name 'rollout-*.jsonl' 2>/dev/null || true
  } | wc -l | tr -d '[:space:]'
}

codex_session_rollout_count() {
  codex_native_session_rollout_count
}

codex_session_sync_is_initialized() {
  # A single native CODEX_HOME needs no project-managed session initialization.
  return 0
}

codex_initialize_session_sync() {
  # Compatibility no-op for older callers. Deliberately performs no writes.
  return 0
}

codex_sessions_status() {
  log_ok "会话: 使用 Codex 原生目录（切换时仅同步 session_meta.model_provider）"
  log_info "原生 CODEX_HOME: $(codex_native_home)"
  log_info "Rollout 数量: $(codex_native_session_rollout_count)"
}
