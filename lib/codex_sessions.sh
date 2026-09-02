#!/usr/bin/env bash

codex_process_is_running() {
  ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" '
    $1 != self && ($2 ~ /^(codex|codex-cli)$/ || $0 ~ /(^|[[:space:]])codex(-cli)?([[:space:]]|$)/ || $0 ~ /\/@openai\/codex\/[^[:space:]]*/) { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

codex_config_sqlite_home() {
  local config_file="$1"
  [ -f "$config_file" ] || return 0
  sed -n 's/^[[:space:]]*sqlite_home[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config_file" | head -n 1
}

codex_native_state_database_path() {
  local config_file="$1" native configured candidate
  native="$(codex_native_home)"
  configured="$(codex_config_sqlite_home "$config_file")"
  if [ -n "$configured" ]; then
    configured="$(printf '%s' "$configured" | sed "s#^~#$HOME#")"
    case "$configured" in
      /*) candidate="$configured/state_5.sqlite" ;;
      *) candidate="$native/$configured/state_5.sqlite" ;;
    esac
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  fi
  for candidate in "$native/sqlite/state_5.sqlite" "$native/state_5.sqlite"; do
    [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

codex_native_state_database_candidates() {
  local config_file="$1" native configured candidate
  native="$(codex_native_home)"
  configured="$(codex_config_sqlite_home "$config_file")"
  if [ -n "$configured" ]; then
    configured="$(printf '%s' "$configured" | sed "s#^~#$HOME#")"
    case "$configured" in
      /*) candidate="$configured/state_5.sqlite" ;;
      *) candidate="$native/$configured/state_5.sqlite" ;;
    esac
    [ -f "$candidate" ] && printf '%s\n' "$candidate"
  fi
  for candidate in "$native/sqlite/state_5.sqlite" "$native/state_5.sqlite"; do
    [ -f "$candidate" ] && printf '%s\n' "$candidate"
  done | awk '!seen[$0]++'
}

codex_sync_native_session_state() {
  local target_provider="$1" config_file="$2"
  local native_home work python_bin result changed sqlite_changed skipped database="" database_candidates=""
  local source_file output_file first_line escaped_provider index applied_index
  local -a fallback_sources fallback_originals fallback_outputs
  [ -n "$config_file" ] || config_file="$(codex_native_config_file)"
  [ -n "$target_provider" ] || { log_error "目标 model_provider 不能为空"; return 1; }
  native_home="$(codex_native_home)"
  database_candidates="$(codex_native_state_database_candidates "$config_file")"
  mkdir -p "$(project_data_dir)"
  work="$(mktemp -d "$(project_data_dir)/.session-state-sync.XXXXXX")"

  if python_bin="$(python_command 2>/dev/null)"; then
    if ! result="$("$python_bin" - "$native_home/sessions" "$native_home/archived_sessions" \
      "$target_provider" "$database_candidates" "$work" <<'PY'
import json
import os
import shutil
import sqlite3
import stat
import sys

roots = sys.argv[1:3]
target_provider = sys.argv[3]
candidate_text = sys.argv[4]
work = sys.argv[5]
updates = []
skipped = 0
errors = []
total_rollouts = 0

for root in roots:
    if not os.path.isdir(root):
        continue
    for directory, _, files in os.walk(root):
        for name in files:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            total_rollouts += 1
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
                replacement = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + line_ending + rest
                updates.append((path, original, replacement, os.stat(path)))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
                errors.append(f"{path}: {exc}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)

rollout_count = total_rollouts
database = None
database_options = [path for path in candidate_text.splitlines() if path]
database_scores = []
for priority, path in enumerate(database_options):
    try:
        connection = sqlite3.connect(path, timeout=2)
        columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
        if "model_provider" not in columns:
            connection.close()
            continue
        rows = connection.execute("SELECT COUNT(*) FROM threads").fetchone()[0]
        connection.close()
        database_scores.append((abs(rows - rollout_count), -rows, -os.path.getmtime(path), priority, path))
    except sqlite3.Error:
        continue
if database_scores:
    database = sorted(database_scores)[0][-1]

db_connection = None
sqlite_changed = 0
applied = []
try:
    if database:
        db_connection = sqlite3.connect(database, timeout=5)
        db_connection.execute("PRAGMA busy_timeout=5000")
        columns = {row[1] for row in db_connection.execute("PRAGMA table_info(threads)")}
        if "model_provider" not in columns:
            db_connection.close()
            db_connection = None
        else:
            db_connection.execute("BEGIN IMMEDIATE")
            cursor = db_connection.execute(
                "UPDATE threads SET model_provider = ? WHERE COALESCE(model_provider, '') COLLATE BINARY <> (? COLLATE BINARY)",
                (target_provider, target_provider),
            )
            sqlite_changed = cursor.rowcount

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

    if db_connection is not None:
        remaining = db_connection.execute(
            "SELECT COUNT(*) FROM threads WHERE COALESCE(model_provider, '') COLLATE BINARY <> (? COLLATE BINARY)",
            (target_provider,),
        ).fetchone()[0]
        if remaining:
            raise RuntimeError(f"state database still contains {remaining} mismatched rows")
        db_connection.commit()
        db_connection.close()
        db_connection = None
except (OSError, UnicodeDecodeError, json.JSONDecodeError, sqlite3.Error, TypeError, RuntimeError) as exc:
    print(str(exc), file=sys.stderr)
    if db_connection is not None:
        db_connection.rollback()
        db_connection.close()
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

print(f"{len(updates)} {sqlite_changed} {skipped}")
PY
)"; then
      rm -rf "$work"
      log_error "Codex 会话或 state_5.sqlite 同步失败；未成功修改的文件保持原样"
      return 1
    fi
    read -r changed sqlite_changed skipped <<< "$result"
  else
    if [ -n "$database_candidates" ]; then
      rm -rf "$work"
      log_error "同步 state_5.sqlite 需要 Python 3；请安装 Python 后重试"
      return 1
    fi
    changed=0
    sqlite_changed=0
    skipped=0
    case "$target_provider" in
      '' | *[!A-Za-z0-9._-]*)
        rm -rf "$work"
        log_error "缺少 Python，且目标 provider 含无法安全写入 JSON 的字符"
        return 1
        ;;
    esac
    escaped_provider="$(printf '%s' "$target_provider" | sed 's/[&|]/\\&/g')"
    output_file="$work/rewrite.tmp"
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
      if printf '%s\n' "$first_line" | grep -Eq '"model_provider"[[:space:]]*:'; then
        sed -E "1 s|\"model_provider\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"model_provider\":\"$escaped_provider\"|" "$source_file" > "$output_file"
      else
        sed -E "1 s|\"payload\"[[:space:]]*:[[:space:]]*\{|\"payload\":{\"model_provider\":\"$escaped_provider\",|" "$source_file" > "$output_file"
      fi
      if cmp -s "$source_file" "$output_file"; then
        continue
      fi
      fallback_sources+=("$source_file")
      fallback_originals+=("$work/original-$index.tmp")
      fallback_outputs+=("$work/output-$index.tmp")
      if ! cp "$source_file" "${fallback_originals[$index]}" ||
        ! cp "$output_file" "${fallback_outputs[$index]}"; then
        rm -rf "$work"
        log_error "无法暂存会话 provider 回退副本: $source_file"
        return 1
      fi
      index=$((index + 1))
    done < <(find "$native_home/sessions" "$native_home/archived_sessions" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
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
  if [ "$changed" -gt 0 ] || [ "$sqlite_changed" -gt 0 ]; then
    log_ok "已同步会话 provider: $changed 个 rollout，$sqlite_changed 条 SQLite 索引 -> $target_provider"
  else
    log_info "会话 provider 和 SQLite 索引已是 $target_provider"
  fi
  if [ -n "$database" ] && [ "$database" != - ]; then
    log_info "使用的 Codex state database: $database"
  fi
  if [ "$skipped" -gt 0 ]; then
    log_warn "跳过 $skipped 个没有有效 session_meta 的 rollout 文件"
  fi
}

codex_rewrite_native_session_providers() {
  codex_sync_native_session_state "$1" "$(codex_native_config_file)"
}

codex_sync_native_sessions_to_profile() {
  local profile="$1" profile_config provider
  codex_profile_is_configured "$profile" || { log_error "$profile 配置尚未完成"; return 1; }
  profile_config="$(codex_profile_home "$profile")/config.toml"
  provider="$(codex_config_model_provider "$profile_config")"
  codex_sync_native_session_state "$provider" "$(codex_native_config_file)"
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
  return 0
}

codex_initialize_session_sync() {
  return 0
}

codex_sessions_status() {
  local database
  log_ok "会话: 使用 Codex 原生目录（切换时同步 rollout 与 SQLite provider）"
  log_info "原生 CODEX_HOME: $(codex_native_home)"
  log_info "Rollout 数量: $(codex_native_session_rollout_count)"
  database="$(codex_native_state_database_path "$(codex_native_config_file)" 2>/dev/null || true)"
  [ -z "$database" ] || log_info "State database: $database"
}
