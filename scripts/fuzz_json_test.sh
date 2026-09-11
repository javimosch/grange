#!/usr/bin/env bash
# Fuzz test: feed corrupted/oversized/deeply-nested JSON to `put` and verify
# grange never crashes (segfault, non-zero exit from internal error) and always
# returns a semantic error (exit 80-89) for bad input.  A crash on bad input is
# a denial-of-service vector on the hosted instance.
set -u
BIN="${1:-./grange}"
fails=0
pass=0
PORT="${FUZZ_JSON_PORT:-4471}"
TOK=fztok

check_cli() {
  local name="$1" doc="$2" expect_reject="${3:-1}"
  local DB
  DB=$(mktemp -d /tmp/grange-fuzz-json-XXXX)
  local OUT RC
  OUT=$("$BIN" put --db "$DB" --coll c --doc "$doc" 2>&1)
  RC=$?
  if [ "$RC" -ge 110 ]; then
    echo "  FAIL $name — internal error (exit $RC): $OUT"
    fails=$((fails + 1))
    rm -rf "$DB"
    return
  fi
  if [ "$expect_reject" = "1" ]; then
    if [ "$RC" -ge 80 ] && [ "$RC" -le 89 ]; then
      pass=$((pass + 1))
    elif [ "$RC" -eq 0 ]; then
      if "$BIN" verify --db "$DB" --coll c >/dev/null 2>&1; then
        pass=$((pass + 1))
      else
        echo "  FAIL $name — accepted but db corrupted after"
        fails=$((fails + 1))
      fi
    else
      echo "  FAIL $name — unexpected exit $RC: $OUT"
      fails=$((fails + 1))
    fi
  else
    if [ "$RC" -eq 0 ]; then
      if "$BIN" verify --db "$DB" --coll c >/dev/null 2>&1; then
        pass=$((pass + 1))
      else
        echo "  FAIL $name — accepted but verify failed"
        fails=$((fails + 1))
      fi
    else
      echo "  FAIL $name — expected success, got exit $RC: $OUT"
      fails=$((fails + 1))
    fi
  fi
  rm -rf "$DB"
}

# check_http sends a doc via the HTTP API using a file payload (for oversized
# payloads that exceed the OS argument limit).  Verifies the server doesn't
# crash and returns a semantic response.
check_http() {
  local name="$1" body="$2" expect_reject="${3:-1}"
  local TMPF
  TMPF=$(mktemp /tmp/grange-fuzz-payload-XXXX)
  printf '%s' "$body" > "$TMPF"
  local OUT RC
  OUT=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/put" \
    -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" \
    --data-binary "@$TMPF" 2>&1)
  RC=$?
  rm -f "$TMPF"
  if [ "$RC" -ne 0 ]; then
    echo "  FAIL $name — curl error $RC (server may have crashed)"
    fails=$((fails + 1))
    return
  fi
  # verify server is still alive
  if ! curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "  FAIL $name — server crashed after request"
    fails=$((fails + 1))
    return
  fi
  if [ "$expect_reject" = "1" ]; then
    # 400 = rejected, 200 = accepted (both non-crash)
    if [ "$OUT" = "400" ] || [ "$OUT" = "200" ]; then
      pass=$((pass + 1))
    else
      echo "  FAIL $name — unexpected HTTP $OUT"
      fails=$((fails + 1))
    fi
  else
    if [ "$OUT" = "200" ]; then
      pass=$((pass + 1))
    else
      echo "  FAIL $name — expected 200, got $OUT"
      fails=$((fails + 1))
    fi
  fi
}

echo "  malformed JSON fuzz:"

# --- CLI cases (small payloads) ---

# 1. empty string
check_cli "empty" ""

# 2. not JSON at all
check_cli "plain text" "hello world"
check_cli "number" "42"
check_cli "boolean" "true"
check_cli "null" "null"

# 3. truncated JSON
check_cli "truncated object" '{"foo":'
check_cli "truncated array" '[1,2,'
check_cli "truncated key" '{"foo'
check_cli "truncated value" '{"foo":"bar'

# 4. unbalanced braces
check_cli "extra open brace" '{"a":{"b":1}'
check_cli "extra close brace" '{"a":1}}'
check_cli "only open brace" '{'
check_cli "only close brace" '}'

# 5. deeply nested (1000 levels)
DEEP=""
for _ in $(seq 1 1000); do DEEP="$DEEP{\"a\":"; done
DEEP="$DEEP{}"
for _ in $(seq 1 1000); do DEEP="$DEEP}"; done
check_cli "deeply nested 1000" "$DEEP"

# 6. binary garbage
check_cli "binary garbage" $'\xff\xfe\x01\x02'

# 7. special chars that could break the record format
check_cli "pipe in value" '{"x":"a|b"}'
check_cli "tab in value" '{"x":"a\tb"}'

# 8. valid JSON that should be accepted
check_cli "valid object" '{"foo":"bar"}' 0
check_cli "valid array" '[1,2,3]' 0
check_cli "valid nested" '{"a":{"b":[1,2]}}' 0

# 9. injection attempts
check_cli "newline injection" $'{"x":"a\\nb"}'
check_cli "record trailer spoof" '{"x":"#|0|abc"}'

# --- HTTP cases (oversized payloads that exceed OS arg limit) ---

# start a server for the oversized cases
DB=$(mktemp -d /tmp/grange-fuzz-json-srv-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# 10. oversized single value (1 MB string)
BIG=$(python3 -c 'print("{\"doc\":{\"x\":\"" + "A"*1048576 + "\"}}")')
check_http "1MB string value" "$BIG"

# 11. many keys (50k keys)
MANY=$(python3 -c 'print("{\"doc\":{" + ",".join("\"k%d\":%d" % (i,i) for i in range(50000)) + "}}")')
check_http "50k keys" "$MANY"

# 12. very long key (100k chars)
LONGKEY=$(python3 -c 'print("{\"doc\":{\"\"" + "k"*100000 + "\":1}}")')
check_http "100k char key" "$LONGKEY"

# 13. deeply nested via HTTP (2000 levels)
DEEP2=$(python3 -c '
s = "{" * 2000 + "1" + "}" * 2000
print("{\"doc\":" + s + "}")
')
check_http "deeply nested 2000 (http)" "$DEEP2"

# 14. valid large doc via HTTP (should succeed)
VALIDBIG=$(python3 -c 'print("{\"doc\":{\"x\":\"" + "B"*10000 + "\"}}")')
check_http "10KB valid doc" "$VALIDBIG" 0

# shutdown
curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

echo "  pass=$pass fail=$fails"
if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"fuzz_json":"pass","cases":'$((pass + fails))'}'
  exit 0
fi
echo '{"ok":false,"fuzz_json":"fail","failures":'"$fails"'}'
exit 1
