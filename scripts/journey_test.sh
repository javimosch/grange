#!/usr/bin/env bash
# The agent journey: everything from "I found a URL" to "I know what I owe".
#
# Every other harness tests a capability. This one tests the PRODUCT — the path a
# stranger's agent actually walks, using only what the published contract tells
# it, in the order the contract tells it. That path crosses the parts of the
# system nothing else covers: the unauthenticated contract, tenant signup, the
# per-tenant data root, metering, and the client SDK.
#
# It matters because this project's recurring failure is not broken code, it is
# claims that stopped being true: "nightly backups" with no backup job, "all four
# SDKs take fields" against packages that had none, a guide advertising no-fsync
# ten milestones after fsync shipped. A journey test is the cheapest way to catch
# the next one, because a step that no longer works fails here loudly.
#
# Runs against a LOCAL server by default. Pass --live to walk the hosted
# instance instead (that mints a real peage wallet; it stays inside the free
# allowance and the probe tenant is left for you to inspect).
set -u
BIN="${BIN:-./grange}"
PORT="${PORT:-4460}"
LIVE=0
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; BASE="https://grange.intrane.fr"; shift ;;
    --bin) BIN="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

WORK=$(mktemp -d /tmp/grange-journey-XXXX)
if [ "$LIVE" = "0" ]; then
  BASE="http://localhost:$PORT"
  fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
  # a local stand-in for the payment rail: signup only needs a pw_-shaped header
  GRANGE_TOKEN=journeyadmin "$BIN" serve --db "$WORK/db" --port "$PORT" --token journeyadmin >"$WORK/log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 80); do sleep 0.1; curl -sf "$BASE/health" >/dev/null 2>&1 && break; done
fi

# ---- 1. the contract is reachable WITHOUT a token, and says how to start
LLMS=$(curl -s -m 20 "$BASE/llms.txt")
echo "$LLMS" | grep -q "mint a wallet" && check "the contract is readable unauthenticated and names step 1" 1 \
  || check "the contract is readable unauthenticated and names step 1" 0
echo "$LLMS" | grep -q "/tenants" && check "the contract names the signup route" 1 \
  || check "the contract names the signup route" 0
# Every route the contract advertises must EXIST in the binary. Grepping llms.txt
# for route names was the first attempt and it was theatre: "/count" appears in
# several unrelated lines, so removing the documented COUNT entry still passed.
# This extracts the $G/<route> forms the contract actually shows and probes each
# one, which catches a contract advertising something that was removed.

# ---- 2. signup with a wallet credential
if [ "$LIVE" = "1" ]; then
  PW=$(curl -s -m 25 -X POST https://peage.intrane.fr/v1/wallets -d '{}' \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("data",{}).get("token",""))')
else
  PW="pw_journeyprobe"
fi
[ -n "$PW" ] && check "a payment-rail wallet can be minted" 1 || check "a payment-rail wallet can be minted" 0

SIGNUP=$(curl -s -m 25 -X POST "$BASE/tenants" -H "X-Peage-Wallet: $PW" -d '{"name":"journey probe"}')
GT=$(echo "$SIGNUP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])' 2>/dev/null || echo "")
[ -n "$GT" ] && check "signup returns a tenant token" 1 || check "signup returns a tenant token ($(echo "$SIGNUP" | head -c 90))" 0
echo "$SIGNUP" | grep -q "free_bytes" && check "signup states the pricing up front" 1 \
  || check "signup states the pricing up front" 0
[ -n "$GT" ] || { echo '{"ok":false,"journey":"signup failed — nothing further is testable"}'; exit 1; }
A="authorization: Bearer $GT"

# Every route the contract advertises must EXIST in the binary, probed with the
# METHOD the contract shows. Two earlier versions of this check were theatre:
# grepping llms.txt for route names passed even after the documented COUNT entry
# was removed ("/count" appears in unrelated lines), and probing everything with
# GET reported six healthy POST routes as missing. A third attempt missed that
# the contract writes -X POST "$G/bulk?..." with a QUOTE between the method and
# the URL, so those two were classified as GET as well.
GHOSTS=""
NCHECK=0
while IFS='|' read -r method route; do
  [ -n "$route" ] || continue
  case "$route" in tenants) continue ;; esac   # signup is exercised on its own
  NCHECK=$((NCHECK + 1))
  if [ "$method" = "POST" ]; then
    BODY=$(curl -s -m 15 -X POST "$BASE/$route?coll=journeyprobe" -H "$A" -d '{}' 2>/dev/null)
  else
    BODY=$(curl -s -m 15 "$BASE/$route?coll=journeyprobe" -H "$A" 2>/dev/null)
  fi
  echo "$BODY" | grep -q "no such route" && GHOSTS="$GHOSTS $method:$route"
done <<EOF
$(echo "$LLMS" | grep -oE '(-X POST )?"?\$G/[a-z_]+' \
   | sed -e 's|-X POST "\?\$G/|POST\||' -e 's|^"\?\$G/|GET\||' | sort -u)
EOF
[ -z "$GHOSTS" ] && check "every route the contract advertises exists ($NCHECK probed, with the documented method)" 1 \
  || check "the contract advertises routes that do not exist:$GHOSTS" 0

# ---- 3. the wallet must be REQUIRED, or the pricing is theatre
NOW=$(curl -s -m 20 -X POST "$BASE/tenants" -d '{"name":"no wallet"}')
echo "$NOW" | grep -q "X-Peage-Wallet" && check "signup without a wallet is refused, and says why" 1 \
  || check "signup without a wallet is refused ($(echo "$NOW" | head -c 70))" 0

# ---- 4. use the product exactly as documented
curl -s -m 20 -X POST "$BASE/put" -H "$A" -d '{"coll":"leads","id":"l1","doc":{"co":"acme","score":9,"ts":1785400000}}' >/dev/null
curl -s -m 20 -X POST "$BASE/put" -H "$A" -d '{"coll":"leads","id":"l2","doc":{"co":"beta","score":4,"ts":1785400100}}' >/dev/null
IDX=$(curl -s -m 40 -X POST "$BASE/index" -H "$A" -d '{"coll":"leads","field":"ts","kind":"range"}')
echo "$IDX" | grep -q '"docs_indexed":2' && check "a range index can be declared" 1 || check "a range index can be declared ($IDX)" 0
CNT=$(curl -s -m 20 "$BASE/count?coll=leads" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo 0)
[ "$CNT" = "2" ] && check "documents are stored and counted" 1 || check "documents are stored and counted (got $CNT)" 0

ORD=$(curl -s -m 20 "$BASE/find?coll=leads&limit=2&order=-ts&fields=co" -H "$A")
echo "$ORD" | grep -q '"mode":"range-ordered"' && check "ordering uses the index it was told to build" 1 \
  || check "ordering uses the index (mode: $(echo "$ORD" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["mode"])' 2>/dev/null))" 0
echo "$ORD" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
ok = d["items"][0]["doc"] == {"co":"beta"} and list(d["items"][0]["doc"]) == ["co"]
sys.exit(0 if ok else 1)' \
  && check "projection returns only the requested field, newest first" 1 \
  || check "projection returns only the requested field, newest first" 0
echo "$ORD" | grep -q '"next"' && check "a cursor is offered for the next page" 1 || check "a cursor is offered" 0

# ---- 5. the bill is inspectable before any money moves
USAGE=$(curl -s -m 20 "$BASE/usage" -H "$A")
echo "$USAGE" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
missing=[k for k in ("bytes","free_bytes","accrued_cents","price_cents_gb_month") if k not in d]
sys.exit(1 if missing else 0)' \
  && check "usage reports bytes, free allowance, accrual and price" 1 \
  || check "usage is missing fields ($(echo "$USAGE" | head -c 90))" 0
FREE=$(echo "$USAGE" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(1 if d["accrued_cents"]==0 and d["bytes"]<d["free_bytes"] else 0)' 2>/dev/null || echo 0)
[ "$FREE" = "1" ] && check "a small tenant owes nothing (free allowance honoured)" 1 \
  || check "a small tenant owes nothing" 0

# ---- 6. the tenant cannot reach anyone else's data
OTHER=$(curl -s -m 20 "$BASE/count?db=default&coll=_sys" -H "$A" | head -c 80)
echo "$OTHER" | grep -qE '"count":0|error' && check "a tenant cannot read internal collections" 1 \
  || check "a tenant cannot read internal collections ($OTHER)" 0

# ---- 7. the SDK the contract advertises works against this server
if [ -d /tmp/gdb ]; then
  PYTHONPATH=/tmp/gdb /usr/bin/python3 -c "
import grange_db, sys
g = grange_db.Grange('$BASE', '$GT').coll('leads')
r = g.find('', limit=2, order='ts', desc=True, fields='co')
sys.exit(0 if g.count('') == 2 and r['mode'] == 'range-ordered' else 1)" \
    && check "the published python SDK works against this server" 1 \
    || check "the published python SDK works against this server" 0
else
  echo "  skip  published SDK check (install with: /usr/bin/python3 -m pip install --target /tmp/gdb grange-db)"
fi

if [ "$LIVE" = "0" ]; then
  curl -s -m 10 -X POST "$BASE/shutdown" -H "authorization: Bearer journeyadmin" >/dev/null 2>&1
  sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
fi
rm -rf "$WORK"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"journey":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
