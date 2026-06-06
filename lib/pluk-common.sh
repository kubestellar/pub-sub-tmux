#!/bin/bash
# pluk-common.sh — shared constants, directories, logging

PLUK_VERSION="0.1.0"
PLUK_RUN_DIR="${PLUK_RUN_DIR:-/var/run/pluk}"
PLUK_LOG_DIR="${PLUK_RUN_DIR}/logs"
PLUK_CMD_DIR="${PLUK_RUN_DIR}/commands"
PLUK_CONFIG_DIR="${PLUK_CONFIG_DIR:-/etc/pluk}"
_PLUK_PATTERNS_EXPLICIT="${PLUK_PATTERNS_DIR:-}"
PLUK_PATTERNS_DIR="${PLUK_PATTERNS_DIR:-${PLUK_CONFIG_DIR}/patterns.d}"

PLUK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$PLUK_PATTERNS_DIR" ] && [ -z "$_PLUK_PATTERNS_EXPLICIT" ]; then
  # Only try fallbacks when PLUK_PATTERNS_DIR was not explicitly set
  if [ -d "${PLUK_SCRIPT_DIR}/../config/patterns.d" ]; then
    PLUK_PATTERNS_DIR="${PLUK_SCRIPT_DIR}/../config/patterns.d"
  elif [ -d "${PLUK_SCRIPT_DIR}/../../etc/pluk/patterns.d" ]; then
    PLUK_PATTERNS_DIR="${PLUK_SCRIPT_DIR}/../../etc/pluk/patterns.d"
  fi
fi

pst_log() {
  printf '[%s] pst: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

pluk_ensure_dirs() {
  for d in "$PLUK_LOG_DIR" "$PLUK_CMD_DIR"; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d" 2>/dev/null || sudo mkdir -p "$d" 2>/dev/null || {
        echo "pst: error: cannot create directory: $d" >&2
        return 1
      }
      chmod 1777 "$d" 2>/dev/null || true
    fi
  done
}

pluk_log_file() {
  local session="$1"
  printf '%s/%s.jsonl' "$PLUK_LOG_DIR" "$session"
}

pluk_cmd_fifo() {
  local session="$1"
  printf '%s/%s.fifo' "$PLUK_CMD_DIR" "$session"
}

pluk_json_field() {
  local field="$1" input
  input=$(cat)
  if command -v python3 &>/dev/null; then
    echo "$input" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$field',''))" 2>/dev/null
  else
    echo "$input" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

pluk_json_int_field() {
  local field="$1" input
  input=$(cat)
  if command -v python3 &>/dev/null; then
    echo "$input" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); v=d.get('$field',0); print(int(v) if v is not None else 0)" 2>/dev/null
  else
    echo "$input" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p" | head -1
  fi
}

pluk_json_bool_field() {
  local field="$1" input
  input=$(cat)
  if command -v python3 &>/dev/null; then
    echo "$input" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); v=d.get('$field'); print('true' if v is True else 'false')" 2>/dev/null
  else
    echo "$input" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p" | head -1
  fi
}

pluk_ensure_fifo() {
  local fifo="$1"
  if [ ! -p "$fifo" ]; then
    rm -f "$fifo" 2>/dev/null
    mkfifo -m 666 "$fifo" 2>/dev/null || mkfifo "$fifo" 2>/dev/null || { sudo mkfifo "$fifo" && sudo chmod 666 "$fifo"; }
    chmod 666 "$fifo" 2>/dev/null || true
  fi
}
