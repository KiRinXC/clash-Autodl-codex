#!/usr/bin/env python3
import copy
import datetime
import json
import os
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(2)

target_path, live_path, output_path = sys.argv[1:4]

def load(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path, "rb") as source:
        return tomllib.load(source)

def merge(current, target):
    for key, value in target.items():
        if isinstance(value, dict) and isinstance(current.get(key), dict):
            merge(current[key], value)
        else:
            current[key] = copy.deepcopy(value)

def key_text(value):
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_-]+", text) else json.dumps(text, ensure_ascii=False)

def value_text(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, list):
        return "[" + ", ".join(value_text(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(f"{key_text(k)} = {value_text(v)}" for k, v in value.items()) + "}"
    raise TypeError(f"unsupported TOML value: {type(value).__name__}")

def emit_table(table, prefix, lines):
    scalars = [(key, value) for key, value in table.items() if not isinstance(value, dict)]
    tables = [(key, value) for key, value in table.items() if isinstance(value, dict)]
    for key, value in scalars:
        lines.append(f"{key_text(key)} = {value_text(value)}")
    for key, value in tables:
        if lines and lines[-1] != "":
            lines.append("")
        section = ".".join([*prefix, str(key)])
        lines.append(f"[{section}]")
        emit_table(value, [*prefix, str(key)], lines)

target = load(target_path)
live = load(live_path) if live_path else {}
for key in (
    "openai_base_url", "chatgpt_base_url", "forced_login_method",
    "forced_chatgpt_workspace_id", "experimental_realtime_ws_base_url",
    "apps_mcp_product_sku", "oss_provider",
):
    if key not in target:
        live.pop(key, None)
target.pop("sqlite_home", None)
merge(live, target)
if "model_provider" not in live:
    live["model_provider"] = target.get("model_provider", "openai")

lines = []
emit_table(live, [], lines)
with open(output_path, "w", encoding="utf-8", newline="") as output:
    output.write("\n".join(lines).rstrip() + "\n")
