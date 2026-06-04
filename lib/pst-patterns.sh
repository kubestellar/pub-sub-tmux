#!/bin/bash
# pst-patterns.sh — event classification engine
# Loads CLI-specific pattern files and classifies output lines into structured events.

_PST_PATTERNS_LOADED=""
_PST_CURRENT_STATE="unknown"
_PST_STATE_CHANGE_TS=0
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

pst_load_patterns() {
  local cli="$1"
  local pattern_file="${PST_PATTERNS_DIR}/${cli}.patterns"
  if [ -f "$pattern_file" ]; then
    # Strip UTF-8 BOM if present, then source
    local cleaned
    cleaned=$(sed '1s/^\xef\xbb\xbf//' "$pattern_file" 2>/dev/null || cat "$pattern_file")
    eval "$cleaned"
    _PST_PATTERNS_LOADED="$cli"
    return 0
  fi
  return 1
}

pst_classify_line() {
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
    resets_at=$(echo "$line" | grep -oE '[0-9]{1,2}(:[0-9]{2})?\s*[aApP][mM]' | head -1)
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "rate_limit" \
      "{\"cli\":$(json_string "$_PST_PATTERNS_LOADED"),\"message\":$(json_string "$line"),\"resets_at\":$(json_string "$resets_at")}"
    return
  fi

  if [ -n "$LOGIN_PATTERN" ] && echo "$line" | grep -qE "$LOGIN_PATTERN"; then
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "login_required" \
      "{\"cli\":$(json_string "$_PST_PATTERNS_LOADED"),\"prompt\":$(json_string "$line")}"
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
    tool=$(echo "$line" | sed -n 's/^.*● \([A-Za-z]*\).*/\1/p' | head -1)
    [ -z "$tool" ] && tool="unknown"
    eval "$seq_ref=\$((\$$seq_ref + 1))"
    json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "tool_call_started" \
      "{\"tool\":$(json_string "$tool"),\"input_preview\":$(json_string "${line:0:120}")}"
    return
  fi

  if [ -n "$TOOL_END_PATTERN" ] && echo "$line" | grep -qE "$TOOL_END_PATTERN"; then
    local tool duration_str
    tool=$(echo "$line" | sed -n 's/^.*✓ \([A-Za-z]*\).*/\1/p' | head -1)
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
      "{\"cli\":$(json_string "$_PST_PATTERNS_LOADED"),\"exit_code\":null,\"duration_sec\":null}"
    return
  fi

  local new_state=""
  if [ -n "$IDLE_PATTERN" ] && echo "$line" | grep -qE "$IDLE_PATTERN"; then
    new_state="idle"
  elif [ -n "$WORKING_PATTERNS" ] && echo "$line" | grep -qE "$WORKING_PATTERNS"; then
    new_state="working"
  fi

  if [ -n "$new_state" ] && [ "$new_state" != "$_PST_CURRENT_STATE" ]; then
    local elapsed=$((now - _PST_STATE_CHANGE_TS))
    if [ "$elapsed" -ge "$STATE_DEBOUNCE_SEC" ]; then
      local old_state="$_PST_CURRENT_STATE"
      _PST_CURRENT_STATE="$new_state"
      _PST_STATE_CHANGE_TS="$now"
      eval "$seq_ref=\$((\$$seq_ref + 1))"
      json_event "$session" "$pane" "$source" "$(eval echo "\$$seq_ref")" "state_change" \
        "{\"from\":$(json_string "$old_state"),\"to\":$(json_string "$new_state")}"
    fi
  fi
}
