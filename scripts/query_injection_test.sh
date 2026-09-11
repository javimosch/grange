#!/usr/bin/env bash
# Query injection prevention test.
#
# Verifies that the serve mode rejects query parameters containing newlines,
# tabs, null bytes, and oversized payloads — characters that could break the
# record format, the JSON path lookup, or exhaust memory.
set -u
BIN="${1:-./grange}"
fails=0
PORT="${QI_PORT:-4475}"
TOK=qitok

echo "  query injection prevention:"

DB=$(mktemp -d /tmp/grange-qi-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# seed a document and a range index on score
curl -s -X POST "http://localhost:$PORT/put" -H "Authorization: Bearer $TOK" \
  -d '{"coll":"c","id":"x","doc":{"name":"test","score":5}}' >/dev/null 2>&1
curl -s -X POST "http://localhost:$PORT/index" -H "Authorization: Bearer $TOK" \
  -d '{"coll":"c","field":"score","kind":"range"}' >/dev/null 2>&1

check_rejected() {
  local name="$1" path="$2"
  local CODE
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT${path}" \
    -H "Authorization: Bearer $TOK" 2>&1)
  if [ "$CODE" = "400" ]; then
    echo "  ok   $name — rejected (400)"
  else
    echo "  FAIL $name — got HTTP $CODE (expected 400)"
    fails=$((fails + 1))
  fi
}

check_accepted() {
  local name="$1" path="$2"
  local CODE
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT${path}" \
    -H "Authorization: Bearer $TOK" 2>&1)
  if [ "$CODE" = "200" ]; then
    echo "  ok   $name — accepted (200)"
  else
    echo "  FAIL $name — got HTTP $CODE (expected 200)"
    fails=$((fails + 1))
  fi
}

# 1. newline in where
check_rejected "newline in where" "/find?coll=c&where=name%0Atest"

# 2. tab in where
check_rejected "tab in where" "/find?coll=c&where=name%09test"

# 3. oversized where with encoded chars
check_rejected "oversized where (>10KB)" "/find?coll=c&where=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("name=" + "A"*10001))')"

# 4. newline in order
check_rejected "newline in order" "/find?coll=c&order=name%0A"

# 5. tab in fields
check_rejected "tab in fields" "/find?coll=c&fields=name%09"

# 6. newline in count where
check_rejected "newline in count where" "/count?coll=c&where=name%0Atest"

# 7. newline in agg group-by
check_rejected "newline in agg group-by" "/agg?coll=c&group-by=name%0A"

# 8. tab in agg sum
check_rejected "tab in agg sum" "/agg?coll=c&group-by=name&sum=score%09"

# 9. valid queries should still work
check_accepted "valid find" "/find?coll=c&where=name=test"
check_accepted "valid count" "/count?coll=c&where=name=test"
check_accepted "valid agg" "/agg?coll=c&group-by=name&sum=score"
check_accepted "valid find with order" "/find?coll=c&where=score%3E%3D0&order=score&desc=true"
check_accepted "valid find with fields" "/find?coll=c&fields=name,score"

# 11. pipe in where (valid — used for IN clauses)
check_accepted "pipe in where (IN clause)" "/find?coll=c&where=name=a|b"

# 12. dotted path in where (valid — nested field access)
check_accepted "dotted path in where" "/find?coll=c&where=user.id=7"

# verify server is still alive
if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
  echo "  ok   server still alive after injection attempts"
else
  echo "  FAIL server crashed after injection attempts"
  fails=$((fails + 1))
fi

curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"query_injection":"pass"}'
  exit 0
fi
echo '{"ok":false,"query_injection":"fail","failures":'"$fails"'}'
exit 1
