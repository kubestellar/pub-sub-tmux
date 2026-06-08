#!/bin/bash
# pluk-json.sh — pure-bash JSON builder (no jq dependency)

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Strip remaining control characters that would break JSON
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '%s' "$s"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

json_int() {
  printf '%d' "$1"
}

_PLUK_HAS_DATE_NS=""
_pluk_detect_date_ns() {
  if [ -z "$_PLUK_HAS_DATE_NS" ]; then
    local probe
    probe=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || echo "")
    if echo "$probe" | grep -q 'N'; then
      _PLUK_HAS_DATE_NS="no"
    else
      _PLUK_HAS_DATE_NS="yes"
    fi
  fi
}

_pluk_timestamp() {
  _pluk_detect_date_ns
  if [ "$_PLUK_HAS_DATE_NS" = "yes" ]; then
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ
  else
    date -u +%Y-%m-%dT%H:%M:%S.000Z
  fi
}

_PST_PUB_PID="$$"

json_event() {
  local session="$1" pane="$2" source="$3" seq="$4" type="$5" data="$6"
  local ts
  ts=$(_pluk_timestamp)
  printf '{"v":1,"ts":"%s","seq":%d,"pid":%d,"session":"%s","pane":"%s","source":"%s","type":"%s","data":%s}\n' \
    "$ts" "$seq" "$_PST_PUB_PID" "$(json_escape "$session")" "$(json_escape "$pane")" \
    "$(json_escape "$source")" "$(json_escape "$type")" "$data"
}
