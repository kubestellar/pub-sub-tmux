#!/bin/bash
# test-patterns.sh — verify pattern matching accuracy against fixture files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
LIB_DIR="${PROJECT_DIR}/lib"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
export PLUK_PATTERNS_DIR="${PROJECT_DIR}/config/patterns.d"

source "${LIB_DIR}/pluk-json.sh"
export PLUK_STATE_DEBOUNCE_SEC=0
source "${LIB_DIR}/pluk-patterns.sh"

PASS=0
FAIL=0
TESTS=0

assert_has_event() {
  local description="$1" output="$2" event_type="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -q "\"type\":\"${event_type}\""; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$description"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — expected event type "%s"\n' "$description" "$event_type"
    printf '       output: %s\n' "$(echo "$output" | head -3)"
  fi
}

assert_no_event() {
  local description="$1" output="$2" event_type="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -q "\"type\":\"${event_type}\""; then
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — unexpected event type "%s" found\n' "$description" "$event_type"
  else
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$description"
  fi
}

assert_event_field() {
  local description="$1" output="$2" event_type="$3" field="$4" expected="$5"
  TESTS=$((TESTS + 1))
  local event_line
  event_line=$(echo "$output" | grep "\"type\":\"${event_type}\"" | head -1)
  if [ -z "$event_line" ]; then
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — no event of type "%s"\n' "$description" "$event_type"
    return
  fi
  if echo "$event_line" | grep -q "\"${field}\":\"${expected}\""; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$description"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — field "%s" != "%s"\n' "$description" "$field" "$expected"
    printf '       event: %s\n' "$event_line"
  fi
}

_FIXTURE_OUT="/tmp/pluk-fixture-$$.jsonl"

run_fixture() {
  local cli="$1" fixture="$2"
  _PLUK_CURRENT_STATE="unknown"
  _PLUK_STATE_CHANGE_TS=0
  pluk_load_patterns "$cli"
  local seq=0
  : > "$_FIXTURE_OUT"
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/\r//g')
    [ -z "$line" ] && continue
    pluk_classify_line "$line" "test-session" "0" "pipe-pane" seq >> "$_FIXTURE_OUT"
  done < "$fixture"
  cat "$_FIXTURE_OUT"
}

# ─── Claude patterns ──────────────────────────────────────────────────────────

echo "=== Claude Code patterns ==="

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-rate-limit.txt")
assert_has_event "rate limit detected" "$output" "rate_limit"
assert_has_event "tool start detected" "$output" "tool_call_started"
assert_has_event "tool end detected" "$output" "tool_call_completed"

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-trust-dialog.txt")
assert_has_event "trust dialog detected" "$output" "trust_dialog"

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-idle.txt")
assert_has_event "idle state detected" "$output" "state_change"
last_idle_state=$(echo "$output" | grep '"type":"state_change"' | tail -1)
TESTS=$((TESTS + 1))
if echo "$last_idle_state" | grep -q '"to":"idle"'; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m idle state ends in idle\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m idle fixture should end in idle, got: %s\n' "$last_idle_state"
fi

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-working.txt")
assert_has_event "working state detected" "$output" "state_change"
assert_event_field "working state value" "$output" "state_change" "to" "working"

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-tool-calls.txt")
tool_starts=$(echo "$output" | grep -c '"type":"tool_call_started"' || true)
tool_ends=$(echo "$output" | grep -c '"type":"tool_call_completed"' || true)
TESTS=$((TESTS + 1))
if [ "$tool_starts" -eq 3 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m 3 tool starts detected (%d found)\n' "$tool_starts"
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m expected 3 tool starts, got %d\n' "$tool_starts"
fi
TESTS=$((TESTS + 1))
if [ "$tool_ends" -eq 3 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m 3 tool ends detected (%d found)\n' "$tool_ends"
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m expected 3 tool ends, got %d\n' "$tool_ends"
fi

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-bypass.txt")
assert_has_event "bypass permissions detected" "$output" "bypass_permissions"

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-error.txt")
error_count=$(echo "$output" | grep -c '"type":"error"' || true)
TESTS=$((TESTS + 1))
if [ "$error_count" -eq 2 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m 2 errors detected (%d found)\n' "$error_count"
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m expected 2 errors, got %d\n' "$error_count"
fi

# ─── Copilot patterns ─────────────────────────────────────────────────────────

echo ""
echo "=== Copilot CLI patterns ==="

output=$(run_fixture "copilot" "${FIXTURES_DIR}/copilot-idle.txt")
assert_has_event "copilot state change detected" "$output" "state_change"
last_state=$(echo "$output" | grep '"type":"state_change"' | tail -1)
TESTS=$((TESTS + 1))
if echo "$last_state" | grep -q '"to":"idle"'; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m copilot ends in idle state\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m copilot should end in idle, got: %s\n' "$last_state"
fi

output=$(run_fixture "copilot" "${FIXTURES_DIR}/copilot-tools.txt")
cop_starts=$(echo "$output" | grep -c '"type":"tool_call_started"' || true)
cop_ends=$(echo "$output" | grep -c '"type":"tool_call_completed"' || true)
TESTS=$((TESTS + 1))
if [ "$cop_starts" -eq 3 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m copilot 3 tool starts detected\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m copilot tool starts: expected 3, got %d\n' "$cop_starts"
fi
TESTS=$((TESTS + 1))
if [ "$cop_ends" -eq 3 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m copilot 3 tool completions detected\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m copilot tool completions: expected 3, got %d\n' "$cop_ends"
fi
assert_event_field "copilot tool type is shell" "$output" "tool_call_started" "tool" "shell"

# ─── False positives ──────────────────────────────────────────────────────────

echo ""
echo "=== False positive resistance ==="

output=$(run_fixture "claude" "${FIXTURES_DIR}/false-positives.txt")
assert_no_event "no false error from code" "$output" "error"
assert_no_event "no false rate_limit from code" "$output" "rate_limit"
assert_no_event "no false tool_call_started" "$output" "tool_call_started"
assert_no_event "no false tool_call_completed" "$output" "tool_call_completed"

# ─── JSON validity ─────────────────────────────────────────────────────────────

echo ""
echo "=== JSON validity ==="

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-rate-limit.txt")
TESTS=$((TESTS + 1))
invalid=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! echo "$line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    invalid=$((invalid + 1))
    printf '  \033[31mINVALID JSON:\033[0m %s\n' "$line"
  fi
done <<< "$output"
if [ "$invalid" -eq 0 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m all events are valid JSON\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %d invalid JSON lines\n' "$invalid"
fi

# ─── Event envelope ────────────────────────────────────────────────────────────

echo ""
echo "=== Event envelope ==="

output=$(run_fixture "claude" "${FIXTURES_DIR}/claude-rate-limit.txt")
first_event=$(echo "$output" | grep -v '^$' | head -1)
TESTS=$((TESTS + 1))
required_fields=("v" "ts" "seq" "pid" "session" "pane" "source" "type" "data")
missing=""
for field in "${required_fields[@]}"; do
  if ! echo "$first_event" | grep -q "\"${field}\""; then
    missing="${missing} ${field}"
  fi
done
if [ -z "$missing" ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m all envelope fields present\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m missing fields:%s\n' "$missing"
fi

TESTS=$((TESTS + 1))
if echo "$first_event" | grep -q '"session":"test-session"'; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m session name correct\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m session name not set correctly\n'
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf 'Results: %d tests, \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$TESTS" "$PASS" "$FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f "$_FIXTURE_OUT" 2>/dev/null
exit "$FAIL"
