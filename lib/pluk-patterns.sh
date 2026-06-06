#!/bin/bash
# pluk-patterns.sh — event classification engine
# Loads CLI-specific pattern files and classifies output lines into structured events.

_PLUK_PATTERNS_LOADED=""
_PLUK_CURRENT_STATE="unknown"
_PLUK_STATE_CHANGE_TS=0
STATE_DEBOUNCE_SEC="${PST_STATE_DEBOUNCE_SEC:-2}"

IDLE_PATTERN=""
WORKING_PATTERNS=""
RATE_LIMIT_PATTERN=""
LOGIN_PATTERN=""
BYPASS_PATTERN=""
TRUST_DIALOG_PATTERN=""
TOOL_START_PATTERN=""
TOOL_END_PATTERN=""
ERROR_PATTERN=""
MODEL_PATTERN=""
SESSION_END_PATTERN=""

pluk_load_patterns() {
  local cli="$1"
  local pattern_file="${PLUK_PATTERNS_DIR}/${cli}.patterns"
  if [ -f "$pattern_file" ]; then
    # Reset all pattern variables to prevent leakage from previous loads
    IDLE_PATTERN=""
    WORKING_PATTERNS=""
    RATE_LIMIT_PATTERN=""
    LOGIN_PATTERN=""
    BYPASS_PATTERN=""
    TRUST_DIALOG_PATTERN=""
    TOOL_START_PATTERN=""
    TOOL_END_PATTERN=""
    ERROR_PATTERN=""
    MODEL_PATTERN=""
    SESSION_END_PATTERN=""
    # Strip UTF-8 BOM and Windows CRLF line endings
    local cleaned
    cleaned=$(sed '1s/^\xef\xbb\xbf//; s/\r$//' "$pattern_file" 2>/dev/null || cat "$pattern_file")
    # Validate: only allow lines matching VAR_NAME='value' or comments/blanks
    local line_num=0 bad_lines=""
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      [ -z "$line" ] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if ! echo "$line" | grep -qE "^[A-Z_][A-Z_0-9]*='[^']*'$"; then
        bad_lines="${bad_lines} ${line_num}"
      fi
    done <<< "$cleaned"
    if [ -n "$bad_lines" ]; then
      echo "pst: warning: pattern file $pattern_file has invalid lines:$bad_lines (only VAR='value' allowed)" >&2
    fi
    # Only eval single-quoted assignments (safe from injection)
    local safe_lines
    safe_lines=$(echo "$cleaned" | grep -E "^[A-Z_][A-Z_0-9]*='[^']*'$")
    eval "$safe_lines"
    _PLUK_PATTERNS_LOADED="$cli"
    return 0
  fi
  return 1
}

pluk_classify_line() {
  local line="$1"
  local session="$2"
  local pane="$3"
  local source="$4"
  local seq_ref="$5"

  [ -z "$line" ] && return

  local now
  now=$(date +%s)

  if [ -n "$RATE_LIMIT_PATTERN" ] && echo "$line" | grep -qE "$RATE_LIMIT_PATTERN"; then
    local resets_at=""
    # Try AM/PM format, then 24h format, then relative ("in N hours/minutes")
    resets_at=$(echo "$line" | grep -oE '[0-9]{1,2}(:[0-9]{2})?\s*[aApP][mM]' | head -1)
    if [ -z "$resets_at" ]; then
      resets_at=$(echo "$line" | grep -oE '(at |@ ?)[0-9]{1,2}:[0-9]{2}' | sed 's/^at //; s/^@ ?//' | head -1)
    fi
    if [ -z "$resets_at" ]; then
      resets_at=$(echo "$line" | grep -oE 'in [0-9]+ (hour|minute|second)s?' | head -1)
    fi
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "rate_limit" \
      "{\"cli\":$(json_string "$_PLUK_PATTERNS_LOADED"),\"message\":$(json_string "$line"),\"resets_at\":$(json_string "$resets_at")}"
    return
  fi

  if [ -n "$LOGIN_PATTERN" ] && echo "$line" | grep -qE "$LOGIN_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "login_required" \
      "{\"cli\":$(json_string "$_PLUK_PATTERNS_LOADED"),\"prompt\":$(json_string "$line")}"
    return
  fi

  if [ -n "$TRUST_DIALOG_PATTERN" ] && echo "$line" | grep -qE "$TRUST_DIALOG_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "trust_dialog" \
      "{\"prompt\":$(json_string "$line"),\"auto_approved\":false}"
    return
  fi

  if [ -n "$BYPASS_PATTERN" ] && echo "$line" | grep -qE "$BYPASS_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "bypass_permissions" \
      "{\"prompt\":$(json_string "$line"),\"auto_approved\":false}"
    return
  fi

  if [ -n "$TOOL_START_PATTERN" ] && echo "$line" | grep -qE "$TOOL_START_PATTERN"; then
    local tool
    # Try parenthesized type first: "● description (shell)" → "shell"
    tool=$(echo "$line" | sed -n 's/.*(\([a-z]*\))$/\1/p' | head -1)
    # Fall back to first word after ●: "● Read main.ts" → "Read"
    [ -z "$tool" ] && tool=$(echo "$line" | sed -n 's/^.*[●] \([A-Za-z]*\).*/\1/p' | head -1)
    [ -z "$tool" ] && tool="unknown"
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "tool_call_started" \
      "{\"tool\":$(json_string "$tool"),\"input_preview\":$(json_string "${line:0:120}")}"
    return
  fi

  if [ -n "$TOOL_END_PATTERN" ] && echo "$line" | grep -qE "$TOOL_END_PATTERN"; then
    local tool duration_str
    # Try parenthesized type first: "✓ description (shell)" → "shell"
    tool=$(echo "$line" | sed -n 's/.*(\([a-z]*\))$/\1/p' | head -1)
    # Fall back to first word after ✓: "✓ Read main.ts (0.1s)" → "Read"
    [ -z "$tool" ] && tool=$(echo "$line" | sed -n 's/^.*[✓] \([A-Za-z]*\).*/\1/p' | head -1)
    [ -z "$tool" ] && tool="unknown"
    duration_str=$(echo "$line" | sed -n 's/.*(\([0-9.]*\)s).*/\1/p')
    local duration_ms="null"
    if [ -n "$duration_str" ]; then
      duration_ms=$(echo "$duration_str" | awk '{printf "%d", $1 * 1000}')
    fi
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "tool_call_completed" \
      "{\"tool\":$(json_string "$tool"),\"duration_ms\":$duration_ms}"
    return
  fi

  if [ -n "$ERROR_PATTERN" ] && echo "$line" | grep -qE "$ERROR_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "error" \
      "{\"message\":$(json_string "$line"),\"severity\":\"error\"}"
    return
  fi

  if [ -n "$MODEL_PATTERN" ] && echo "$line" | grep -qE "$MODEL_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "model_changed" \
      "{\"from\":null,\"to\":$(json_string "$line")}"
    return
  fi

  if [ -n "$SESSION_END_PATTERN" ] && echo "$line" | grep -qE "$SESSION_END_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "session_ended" \
      "{\"cli\":$(json_string "$_PLUK_PATTERNS_LOADED"),\"exit_code\":null,\"duration_sec\":null}"
    return
  fi

  local new_state=""
  if [ -n "$IDLE_PATTERN" ] && echo "$line" | grep -qE "$IDLE_PATTERN"; then
    new_state="idle"
  elif [ -n "$WORKING_PATTERNS" ] && echo "$line" | grep -qE "$WORKING_PATTERNS"; then
    new_state="working"
  fi

  if [ -n "$new_state" ] && [ "$new_state" != "$_PLUK_CURRENT_STATE" ]; then
    local elapsed=$((now - _PLUK_STATE_CHANGE_TS))
    if [ "$elapsed" -ge "$STATE_DEBOUNCE_SEC" ]; then
      local old_state="$_PLUK_CURRENT_STATE"
      _PLUK_CURRENT_STATE="$new_state"
      _PLUK_STATE_CHANGE_TS="$now"
      eval "$seq_ref=\$((\$$seq_ref + 1))"
      json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "state_change" \
        "{\"from\":$(json_string "$old_state"),\"to\":$(json_string "$new_state")}"
    fi
  fi
}
