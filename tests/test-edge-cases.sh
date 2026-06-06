#!/bin/bash
# test-edge-cases.sh — automated edge case tests
# Tests scenarios discovered during manual testing that should be automated.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
BIN_DIR="${PROJECT_DIR}/bin"
export PLUK_RUN_DIR="/tmp/pluk-edge-$$"
export PLUK_CONFIG_DIR="${PROJECT_DIR}/config"
export PLUK_PATTERNS_DIR="${PROJECT_DIR}/config/patterns.d"

PASS=0
FAIL=0
TESTS=0

cleanup() {
  rm -rf "$PLUK_RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — expected "%s" got "%s"\n' "$desc" "$expected" "$actual"
  fi
}

assert_gt() {
  local desc="$1" threshold="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s (got %s)\n' "$desc" "$actual"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s — expected > %s got "%s"\n' "$desc" "$threshold" "$actual"
  fi
}

mkdir -p "$PLUK_RUN_DIR/logs" "$PLUK_RUN_DIR/commands"

# ─── Publisher edge cases ──────────────────────────────────────────────────────

echo "=== Publisher edge cases ==="

# Empty stdin
mkfifo -m 666 "$PLUK_RUN_DIR/commands/empty.fifo" 2>/dev/null || true
echo -n "" | bash "${BIN_DIR}/pluk-publish" --session empty 2>/dev/null
EVENTS=$(wc -l < "$PLUK_RUN_DIR/logs/empty.jsonl" 2>/dev/null | tr -d ' ')
assert_eq "empty stdin produces 0 events" "0" "${EVENTS:-0}"

# Whitespace-only lines
mkfifo -m 666 "$PLUK_RUN_DIR/commands/ws.fifo" 2>/dev/null || true
printf '   \n\t\n  \t  \nreal line\n' | bash "${BIN_DIR}/pluk-publish" --session ws 2>/dev/null
WS_EVENTS=$(wc -l < "$PLUK_RUN_DIR/logs/ws.jsonl" 2>/dev/null | tr -d ' ')
assert_eq "whitespace-only lines filtered" "1" "${WS_EVENTS:-0}"

# Unicode preservation
mkfifo -m 666 "$PLUK_RUN_DIR/commands/uni.fifo" 2>/dev/null || true
printf '🎉 hello émojis 日本語\n' | bash "${BIN_DIR}/pluk-publish" --session uni 2>/dev/null
UNI_VALID=$(python3 -c "import json; d=json.loads(open('$PLUK_RUN_DIR/logs/uni.jsonl').readline()); print('yes' if '🎉' in d['data']['line'] else 'no')" 2>/dev/null)
assert_eq "unicode preserved in events" "yes" "${UNI_VALID:-no}"

# --no-raw skips raw_output
mkfifo -m 666 "$PLUK_RUN_DIR/commands/noraw.fifo" 2>/dev/null || true
printf 'normal\n● Read main.ts\nout of extra usage\n' | bash "${BIN_DIR}/pluk-publish" --session noraw --cli claude --no-raw 2>/dev/null
NORAW_HAS=$(python3 -c "
import json
types = set()
for l in open('$PLUK_RUN_DIR/logs/noraw.jsonl'):
    if l.strip(): types.add(json.loads(l)['type'])
print('no' if 'raw_output' in types else 'yes')
" 2>/dev/null)
assert_eq "--no-raw suppresses raw_output" "yes" "${NORAW_HAS:-no}"

# Session name validation
RESULT=$(bash "${BIN_DIR}/pluk-publish" --session "$(python3 -c "print('x'*201)")" 2>&1 | grep -c "too long")
assert_gt "long session name rejected" "0" "${RESULT:-0}"

# ─── Subscriber edge cases ─────────────────────────────────────────────────────

echo ""
echo "=== Subscriber edge cases ==="

# Filter with spaces around types
echo '{"v":1,"ts":"2026-06-04T10:00:00Z","seq":1,"pid":1,"session":"sp","pane":"0","source":"p","type":"error","data":{"message":"e","severity":"error"}}' > "$PLUK_RUN_DIR/logs/sp.jsonl"
echo '{"v":1,"ts":"2026-06-04T10:00:01Z","seq":2,"pid":1,"session":"sp","pane":"0","source":"p","type":"raw_output","data":{"line":"x"}}' >> "$PLUK_RUN_DIR/logs/sp.jsonl"
SP_RESULT=$(bash "${BIN_DIR}/pluk-subscribe" sp --filter " error , raw_output " --no-follow 2>/dev/null | wc -l | tr -d ' ')
assert_eq "filter with spaces: both types match" "2" "${SP_RESULT:-0}"

# Filter with regex metacharacters
echo '{"v":1,"ts":"2026-06-04T10:00:00Z","seq":1,"pid":1,"session":"rx","pane":"0","source":"p","type":"raw.output","data":{"line":"x"}}' > "$PLUK_RUN_DIR/logs/rx.jsonl"
echo '{"v":1,"ts":"2026-06-04T10:00:01Z","seq":2,"pid":1,"session":"rx","pane":"0","source":"p","type":"raw_output","data":{"line":"y"}}' >> "$PLUK_RUN_DIR/logs/rx.jsonl"
RX_RESULT=$(bash "${BIN_DIR}/pluk-subscribe" rx --filter "raw.output" --no-follow 2>/dev/null | wc -l | tr -d ' ')
assert_eq "filter dot is literal not regex" "1" "${RX_RESULT:-0}"

# --since validation
SINCE_RESULT=$(bash "${BIN_DIR}/pluk-subscribe" sp --since "m" --no-follow 2>&1 | grep -c "positive integer")
assert_gt "--since bare unit rejected" "0" "${SINCE_RESULT:-0}"

SINCE_NEG=$(bash "${BIN_DIR}/pluk-subscribe" sp --since "-5m" --no-follow 2>&1 | grep -c "positive integer")
assert_gt "--since negative rejected" "0" "${SINCE_NEG:-0}"

# --last validation
LAST_NEG=$(bash "${BIN_DIR}/pluk-subscribe" sp --last "-1" --no-follow 2>&1 | grep -c "non-negative")
assert_gt "--last negative rejected" "0" "${LAST_NEG:-0}"

# Empty log file
touch "$PLUK_RUN_DIR/logs/emptylog.jsonl"
EMPTY_RESULT=$(bash "${BIN_DIR}/pluk-subscribe" emptylog --no-follow 2>/dev/null | wc -l | tr -d ' ')
assert_eq "empty log returns 0 events" "0" "${EMPTY_RESULT:-0}"

# ─── pluk-send edge cases ──────────────────────────────────────────────────────

echo ""
echo "=== pluk-send edge cases ==="

# Missing session
SEND_MISS=$(bash "${BIN_DIR}/pluk-send" --text "test" 2>&1 | grep -c "required")
assert_gt "pluk-send missing session" "0" "${SEND_MISS:-0}"

# Missing text and key
SEND_NOTEXT=$(bash "${BIN_DIR}/pluk-send" --session test 2>&1 | grep -c "required")
assert_gt "pluk-send missing text/key" "0" "${SEND_NOTEXT:-0}"

# --enter alone (no text)
mkfifo -m 666 "$PLUK_RUN_DIR/commands/enteronly.fifo" 2>/dev/null || true
# Just verify it doesn't error
bash "${BIN_DIR}/pluk-send" --session enteronly --enter 2>/dev/null &
SEND_PID=$!
sleep 2
# Read from FIFO to unblock
cat "$PLUK_RUN_DIR/commands/enteronly.fifo" > /dev/null 2>&1 &
CAT_PID=$!
wait $SEND_PID 2>/dev/null
SEND_EXIT=$?
kill $CAT_PID 2>/dev/null; wait $CAT_PID 2>/dev/null
assert_eq "pluk-send --enter only exits 0" "0" "$SEND_EXIT"

# ─── Pattern edge cases ──────────────────────────────────────────────────────

echo ""
echo "=== Pattern edge cases ==="

source "${PROJECT_DIR}/lib/pluk-json.sh"
export PLUK_STATE_DEBOUNCE_SEC=0
source "${PROJECT_DIR}/lib/pluk-patterns.sh"

# Pattern variable reset between loads
pluk_load_patterns "claude" 2>/dev/null
OLD_BYPASS="$BYPASS_PATTERN"
# Load a minimal pattern that doesn't define BYPASS
mkdir -p "$PLUK_RUN_DIR/patterns"
echo "RATE_LIMIT_PATTERN='custom'" > "$PLUK_RUN_DIR/patterns/minimal.patterns"
PLUK_PATTERNS_DIR="$PLUK_RUN_DIR/patterns" pluk_load_patterns "minimal" 2>/dev/null
assert_eq "pattern vars reset on new load" "" "$BYPASS_PATTERN"

# False positive resistance
pluk_load_patterns "claude" 2>/dev/null
_PLUK_CURRENT_STATE="unknown"; _PLUK_STATE_CHANGE_TS=0; seq=0
FP=$(: > "$PLUK_RUN_DIR/fp.jsonl" && pluk_classify_line 'const err = new Error("test")' "s" "0" "t" seq >> "$PLUK_RUN_DIR/fp.jsonl" && cat "$PLUK_RUN_DIR/fp.jsonl")
FP_COUNT="0"
[ -n "$FP" ] && FP_COUNT=$(echo "$FP" | grep -c "error" 2>/dev/null || true)
FP_COUNT="${FP_COUNT:-0}"
assert_eq "code with Error: no false positive" "0" "$FP_COUNT"

# ─── JSON validity ─────────────────────────────────────────────────────────────

echo ""
echo "=== JSON validity ==="

mkfifo -m 666 "$PLUK_RUN_DIR/commands/json.fifo" 2>/dev/null || true
printf 'normal\n● Read test.ts\n✓ Read test.ts (0.1s)\nout of extra usage\n❯\n' | bash "${BIN_DIR}/pluk-publish" --session json --cli claude 2>/dev/null
JSON_INVALID=$(python3 -c "
import json
inv = 0
for l in open('$PLUK_RUN_DIR/logs/json.jsonl'):
    if not l.strip(): continue
    try: json.loads(l)
    except: inv += 1
print(inv)
" 2>/dev/null)
assert_eq "all publisher events are valid JSON" "0" "${JSON_INVALID:-1}"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf 'Results: %d tests, \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$TESTS" "$PASS" "$FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit "$FAIL"
