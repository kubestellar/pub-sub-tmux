#!/bin/bash
# pst-common.sh — shared constants, directories, logging

PST_VERSION="0.1.0"
PST_RUN_DIR="${PST_RUN_DIR:-/var/run/pub-sub-tmux}"
PST_LOG_DIR="${PST_RUN_DIR}/logs"
PST_CMD_DIR="${PST_RUN_DIR}/commands"
PST_CONFIG_DIR="${PST_CONFIG_DIR:-/etc/pub-sub-tmux}"
PST_PATTERNS_DIR="${PST_CONFIG_DIR}/patterns.d"

PST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$PST_PATTERNS_DIR" ] && [ -d "${PST_SCRIPT_DIR}/../config/patterns.d" ]; then
  PST_PATTERNS_DIR="${PST_SCRIPT_DIR}/../config/patterns.d"
fi

pst_log() {
  printf '[%s] pst: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

pst_ensure_dirs() {
  for d in "$PST_LOG_DIR" "$PST_CMD_DIR"; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d" 2>/dev/null || sudo mkdir -p "$d"
      chmod 1777 "$d" 2>/dev/null || true
    fi
  done
}

pst_log_file() {
  local session="$1"
  printf '%s/%s.jsonl' "$PST_LOG_DIR" "$session"
}

pst_cmd_fifo() {
  local session="$1"
  printf '%s/%s.fifo' "$PST_CMD_DIR" "$session"
}

pst_json_field() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

pst_json_int_field() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p" | head -1
}

pst_json_bool_field() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p" | head -1
}

pst_ensure_fifo() {
  local fifo="$1"
  if [ ! -p "$fifo" ]; then
    rm -f "$fifo" 2>/dev/null
    mkfifo "$fifo" 2>/dev/null || { sudo mkfifo "$fifo" && sudo chmod 666 "$fifo"; }
  fi
}
