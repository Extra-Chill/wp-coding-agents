#!/bin/bash
# Behaviour coverage for the shared escaping helpers in lib/common.sh.
#
# These were three copies before: two JSON escapers that handled backslash,
# quote and newline, and one in lib/agent-state-ownership.sh that handled only
# backslash and quote. That third copy's output is machine-read JSON, so a value
# containing a newline emitted a literal newline inside a string literal — which
# is invalid JSON, and would break whatever parsed it.
#
# Nothing exercised the newline case, which is why the drift survived. It does
# now, including through the consumer that had the weaker copy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

source lib/common.sh

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# json_escape
# ---------------------------------------------------------------------------

check "escapes a double quote" '\"' "$(json_escape '"')"
check "escapes a backslash" '\\' "$(json_escape '\')"
check "escapes a newline" '\n' "$(json_escape "$(printf 'a\nb')" | sed 's/^a//; s/b$//')"
check "leaves plain text alone" 'plain text' "$(json_escape 'plain text')"

# Backslash must be escaped before the quote, or \" becomes \\" and the string
# terminates early. Order is the subtle part of every JSON escaper.
check "escapes a backslash-quote pair in the right order" '\\\"' "$(json_escape '\"')"

# The property that matters: output is a valid JSON string literal.
json_roundtrip() {
  python3 -c 'import json,sys; print(json.loads("\"" + sys.stdin.read() + "\""))' 2>/dev/null
}
check "a newline survives a JSON round-trip" "$(printf 'a\nb')" \
  "$(json_escape "$(printf 'a\nb')" | json_roundtrip)"
check "a quoted path survives a JSON round-trip" 'say "hi"' \
  "$(json_escape 'say "hi"' | json_roundtrip)"
check "a windows-style path survives a JSON round-trip" 'C:\dir\file' \
  "$(json_escape 'C:\dir\file' | json_roundtrip)"

# ---------------------------------------------------------------------------
# xml_escape
# ---------------------------------------------------------------------------

check "escapes an ampersand" '&amp;' "$(xml_escape '&')"
check "escapes angle brackets" '&lt;tag&gt;' "$(xml_escape '<tag>')"
check "escapes the ampersand first" '&amp;lt;' "$(xml_escape '&lt;')"
check "leaves a quote alone in a text node" '"quoted"' "$(xml_escape '"quoted"')"
check "escapes a realistic plist value" 'a &amp; b &lt; c' "$(xml_escape 'a & b < c')"

# ---------------------------------------------------------------------------
# The consumer that had the divergent copy now emits parseable JSON
# ---------------------------------------------------------------------------

source lib/agent-state-ownership.sh

LIST="$(agent_state_ownership_json_list "$(printf '/tmp/a\nb')" '/tmp/say "hi"')"
check "agent-state path list parses as JSON" '/tmp/a
b|/tmp/say "hi"' \
  "$(printf '[%s]' "$LIST" | python3 -c 'import json,sys; print("|".join(json.load(sys.stdin)))' 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'PASS: tests/escaping-helpers.sh\n'
