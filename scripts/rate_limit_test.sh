#!/usr/bin/env bash
# HTTP serve mode rate limiting test.
#
# Verifies that both admin and tenant tokens are rate-limited, and that the
# limits are configurable via env vars.  Uses a low limit to avoid sending
# hundreds of requests.
set -u
BIN="${1:-./grange}"
fails=0
PORT="${RL_PORT:-4474}"
TOK=rltok

echo "  HTTP serve mode rate limiting:"

# --- Part 1: admin token rate limiting ---
DB=$(mktemp -d /tmp/grange-rl-admin-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3

# set a low admin rate limit (5/min) for testing
GRANGE_ADMIN_RATE_PER_MIN=5 "$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# send 5 requests (should succeed), then 6th (should be rate-limited)
ok_count=0
rl_count=0
for i in $(seq 1 8); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/stats?coll=default" -H "Authorization: Bearer $TOK" 2>&1)
  if [ "$CODE" = "200" ]; then
    ok_count=$((ok_count + 1))
  elif [ "$CODE" = "429" ]; then
    rl_count=$((rl_count + 1))
  fi
done

if [ "$ok_count" -eq 5 ] && [ "$rl_count" -ge 1 ]; then
  echo "  ok   admin token rate-limited at 5/min ($ok_count ok, $rl_count throttled)"
else
  echo "  FAIL admin rate limit: $ok_count ok, $rl_count throttled (expected 5 ok, >=1 throttled)"
  fails=$((fails + 1))
fi

# shutdown
curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

# --- Part 2: tenant token rate limiting ---
DB=$(mktemp -d /tmp/grange-rl-tenant-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3

# set a low tenant rate limit (3/min)
GRANGE_RATE_PER_MIN=3 "$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# create a tenant
TT=$(curl -s -X POST "http://localhost:$PORT/tenants" -H "X-Peage-Wallet: pw_test" -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])' 2>/dev/null || echo "")

if [ -z "$TT" ]; then
  echo "  FAIL could not create tenant for rate limit test"
  fails=$((fails + 1))
else
  # send requests as tenant (should be limited at 3/min)
  ok_count=0
  rl_count=0
  for i in $(seq 1 6); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/stats?coll=default" -H "Authorization: Bearer $TT" 2>&1)
    if [ "$CODE" = "200" ]; then
      ok_count=$((ok_count + 1))
    elif [ "$CODE" = "429" ]; then
      rl_count=$((rl_count + 1))
    fi
  done

  if [ "$ok_count" -eq 3 ] && [ "$rl_count" -ge 1 ]; then
    echo "  ok   tenant token rate-limited at 3/min ($ok_count ok, $rl_count throttled)"
  else
    echo "  FAIL tenant rate limit: $ok_count ok, $rl_count throttled (expected 3 ok, >=1 throttled)"
    fails=$((fails + 1))
  fi
fi

# shutdown
curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

# --- Part 3: admin not limited when env is unset (disabled by default) ---
DB=$(mktemp -d /tmp/grange-rl-default-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# send 20 requests — should all succeed (admin rate limiting is off by default)
ok_count=0
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/stats?coll=default" -H "Authorization: Bearer $TOK" 2>&1)
  if [ "$CODE" = "200" ]; then ok_count=$((ok_count + 1)); fi
done

if [ "$ok_count" -eq 20 ]; then
  echo "  ok   admin token not limited by default (20/20 ok, disabled unless GRANGE_ADMIN_RATE_PER_MIN is set)"
else
  echo "  FAIL admin rate limit active at default: $ok_count/20 ok"
  fails=$((fails + 1))
fi

curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"rate_limit":"pass"}'
  exit 0
fi
echo '{"ok":false,"rate_limit":"fail","failures":'"$fails"'}'
exit 1
