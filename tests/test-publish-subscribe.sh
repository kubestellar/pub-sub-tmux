#!/bin/bash
# test-publish-subscribe.sh — round-trip integration test
# Creates a tmux session, attaches publisher, subscribes, sends text, verifies events.
set -u
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
BIN_DIR="${PROJECT_DIR}/bin"
export PLUK_RUN_DIR="/tmp/pluk-test-$$"
export PLUK_CONFIG_DIR="${PROJECT_DIR}/config"
export PLUK_PATTERNS_DIR="${PROJECT_DIR}/config/patterns.d"

TEST_SESSION="pluk-test-$$"
PASS=0
FAIL=0
TESTS=0

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -rf "$PLUK_RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

assert_true() {
  local description="$1"
  shift
  TESTS=$((TESTS + 1))
  if "$@"; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$description"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$description"
  fi
}

mkdir -p "$PLUK_RUN_DIR/logs" "$PLUK_RUN_DIR/commands"

echo "=== Setup ==="
echo "  test session: $TEST_SESSION"
echo "  run dir: $PLUK_RUN_DIR"

tmux new-session -d -s "$TEST_SESSION" -x 120 -y 40
sleep 0.5
assert_true "tmux session created" tmux has-session -t "$TEST_SESSION"

echo ""
echo "=== Publisher attach ==="

PLUK_STDERR="$PLUK_RUN_DIR/publisher-stderr.txt"
tmux pipe-pane -t "$TEST_SESSION" -o "env PLUK_RUN_DIR=$PLUK_RUN_DIR PLUK_CONFIG_DIR=$PLUK_CONFIG_DIR PLUK_PATTERNS_DIR=$PLUK_PATTERNS_DIR bash ${BIN_DIR}/pluk-publish --session $TEST_SESSION --cli claude 2>$PLUK_STDERR"

# Wait for publisher to initialize — send a probe and wait for it to appear
sleep 2
tmux send-keys -t "$TEST_SESSION" "echo pluk-init-probe" Enter
for _wait in 1 2 3 4 5 6 7 8; do
  grep -q "pluk-init-probe" "$PLUK_RUN_DIR/logs/${TEST_SESSION}.jsonl" 2>/dev/null && break
  sleep 2
done

LOG_FILE="$PLUK_RUN_DIR/logs/${TEST_SESSION}.jsonl"
if [ -f "$PLUK_STDERR" ]; then
  printf '  stderr: %s\n' "$(head -5 "$PLUK_STDERR" 2>/dev/null)"
fi
if [ ! -f "$LOG_FILE" ]; then
  sleep 3
fi
assert_true "log file created" test -f "$LOG_FILE"

echo ""
echo "=== Raw output events ==="

tmux send-keys -t "$TEST_SESSION" "echo pluk-hello-42" Enter
for _hw in 1 2 3 4 5; do
  grep -q 'pluk-hello-42' "$LOG_FILE" 2>/dev/null && break
  sleep 2
done

assert_true "log file has content" test -s "$LOG_FILE"
assert_true "raw_output events present" grep -q '"type":"raw_output"' "$LOG_FILE"
assert_true "hello text captured" grep -q 'pluk-hello-42' "$LOG_FILE"

echo ""
echo "=== Sequence numbers ==="

seq_count=$(grep -o '"seq":[0-9]*' "$LOG_FILE" 2>/dev/null | sed 's/"seq"://' | sort -n | tail -1)
seq_count="${seq_count:-0}"
assert_true "sequence numbers present (last=$seq_count)" test "$seq_count" -gt 0

prev=0
monotonic=true
while IFS= read -r s; do
  [ -z "$s" ] && continue
  if [ "$s" -le "$prev" ]; then
    monotonic=false
    break
  fi
  prev="$s"
done < <(grep -o '"seq":[0-9]*' "$LOG_FILE" 2>/dev/null | sed 's/"seq"://')
assert_true "sequence numbers monotonically increasing" $monotonic
assert_true "sequence numbers monotonically increasing" $monotonic

echo ""
echo "=== JSON validity ==="

invalid=0
total=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  total=$((total + 1))
  if ! echo "$line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    invalid=$((invalid + 1))
    printf '  \033[33mINVALID:\033[0m %s\n' "${line:0:100}"
  fi
done < "$LOG_FILE"
TESTS=$((TESTS + 1))
if [ "$invalid" -eq 0 ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m all %d events valid JSON\n' "$total"
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %d/%d invalid JSON lines\n' "$invalid" "$total"
fi

echo ""
echo "=== Subscriber ==="

SUB_OUT="/tmp/pluk-sub-test-$$.txt"
"${BIN_DIR}/pluk-subscribe" "$TEST_SESSION" --last 5 --no-follow > "$SUB_OUT" 2>/dev/null
assert_true "subscriber returned events" test -s "$SUB_OUT"

sub_count=$(wc -l < "$SUB_OUT" | tr -d ' ')
assert_true "subscriber got events (count=$sub_count)" test "$sub_count" -gt 0
rm -f "$SUB_OUT"

echo ""
echo "=== Subscriber --filter ==="

FILTER_OUT="/tmp/pluk-filter-test-$$.txt"
"${BIN_DIR}/pluk-subscribe" "$TEST_SESSION" --filter "raw_output" --no-follow > "$FILTER_OUT" 2>/dev/null
filter_count=$(wc -l < "$FILTER_OUT" | tr -d ' ')
assert_true "filtered subscriber only raw_output (count=$filter_count)" test "$filter_count" -gt 0

non_raw_lines=$(grep -v '"type":"raw_output"' "$FILTER_OUT" 2>/dev/null || true)
non_raw_count=0
[ -n "$non_raw_lines" ] && non_raw_count=$(echo "$non_raw_lines" | wc -l | tr -d ' ')
assert_true "no non-raw events in filtered output (got=$non_raw_count)" test "$non_raw_count" -eq 0
rm -f "$FILTER_OUT"

echo ""
echo "=== Multiple output events ==="

for n in pluk-multi-a pluk-multi-b pluk-multi-c; do
  tmux send-keys -t "$TEST_SESSION" "echo $n" Enter
  sleep 3
done
# Wait for last event to appear
for _mw in 1 2 3 4 5 6 7 8; do
  grep -q "pluk-multi-c" "$LOG_FILE" 2>/dev/null && break
  sleep 2
done

for n in pluk-multi-a pluk-multi-b pluk-multi-c; do
  assert_true "captured $n" grep -q "$n" "$LOG_FILE"
done

echo ""
echo "=== Event envelope completeness ==="

first_event=$(head -1 "$LOG_FILE")
for field in v ts seq pid session pane source type data; do
  TESTS=$((TESTS + 1))
  if echo "$first_event" | grep -q "\"${field}\""; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m field "%s" present\n' "$field"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m field "%s" missing\n' "$field"
  fi
done

echo ""
echo "=== Bidirectional (pluk-send) ==="

CMD_FIFO="$PLUK_RUN_DIR/commands/${TEST_SESSION}.fifo"
assert_true "command FIFO exists" test -p "$CMD_FIFO"

before_count=$(wc -l < "$LOG_FILE" | tr -d ' ')
"${BIN_DIR}/pluk-send" --session "$TEST_SESSION" --text "echo sent-via-pluk" --enter 2>/dev/null &
SEND_PID=$!

# Wait for the sent text to appear in the log
for _sw in 1 2 3 4 5 6; do
  grep -q "sent-via-pluk" "$LOG_FILE" 2>/dev/null && break
  sleep 2
done

TESTS=$((TESTS + 1))
if tmux capture-pane -t "$TEST_SESSION" -p 2>/dev/null | grep -q "sent-via-pluk"; then
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m pluk-send text appeared in pane\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m pluk-send text not found in pane\n'
fi

after_count=$(wc -l < "$LOG_FILE" | tr -d ' ')
assert_true "new events after pluk-send (before=$before_count after=$after_count)" test "$after_count" -gt "$before_count"

wait "$SEND_PID" 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf 'Results: %d tests, \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$TESTS" "$PASS" "$FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit "$FAIL"
