#!/usr/bin/env bash
# The stranger test: does the PUBLISHED artifact work for someone who has none
# of my context?
#
# Every other harness builds grange from source, in the repository, on a machine
# with machin installed. None of that describes a stranger. They have a URL, a
# README, and a shell — and until M51 nothing had ever verified that path.
#
# It had been broken since the first release, in two ways nobody could have
# reported, because the failure happens before the tool runs:
#
#   1. the README's install command pointed at an asset name that has never been
#      published (grange-linux-x86_64 vs grange), so it returned 404 — 9 bytes of
#      "Not Found", which chmod +x accepts and the shell then refuses to execute
#   2. the binary it pointed at was DYNAMICALLY linked against libssl, libcrypto,
#      libsqlite3 and glibc 2.34+, under a README paragraph promising "statically
#      linked, no runtime dependencies, no glibc floor"
#
# Release download count across every version at the time: zero. A funnel with no
# users is also a funnel with no bug reports, so the only way to find this was to
# walk it.
#
# What this does: fetches the published release into an empty directory with no
# repository, no machin, no PATH entry for either, and a throwaway HOME, then
# runs the documented first-run sequence. Any step that a stranger could not
# recover from on their own is a failure.
#
#   ./scripts/stranger_test.sh [--tag v0.13.1] [--keep]
set -u
TAG="${TAG:-latest}"
KEEP=0
REPO="javimosch/grange"
ASSET="grange-linux-x86_64"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --asset) ASSET="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
  esac
done
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

if [ "$TAG" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
  URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
fi

WORK=$(mktemp -d /tmp/grange-stranger-XXXX)
export HOME="$WORK/home"; mkdir -p "$HOME"
cd "$WORK" || exit 1

# ---- 1. the install command, exactly as the README prints it
HTTP=$(curl -sSL -o grange -w '%{http_code}' "$URL" 2>/dev/null)
[ "$HTTP" = "200" ] && check "the documented download URL resolves (http $HTTP)" 1 \
  || check "the documented download URL returns http $HTTP — a stranger gets nothing ($URL)" 0
SIZE=$(wc -c < grange 2>/dev/null || echo 0)
[ "$SIZE" -gt 100000 ] 2>/dev/null && check "the downloaded file is a plausible binary ($SIZE bytes)" 1 \
  || check "the download is $SIZE bytes — an error page, not a binary" 0
chmod +x grange 2>/dev/null

# ---- 2. it must RUN here, and "here" is the point: no machin, no repo, no libs
#         that only a developer machine has
RUNS=0
if [ -x ./grange ] && ./grange guide >/dev/null 2>&1; then
  RUNS=1
  check "the binary executes (this is where a dynamic build fails on a slim host)" 1
else
  check "the binary does not execute: $(./grange guide 2>&1 | head -c 90)" 0
fi

# The promise in the README is checkable, so check it rather than trust it. A
# dynamically linked release is not a bug on THIS machine — it is a bug on the
# machines I cannot test, which is all of them.
# These two are gated on RUNS, because they LIE on a non-binary: `ldd` reports
# "not a dynamic executable" for a text file and `objdump` finds no GLIBC
# symbols in one, so a 404 error page scored "static, as the README promises" —
# the check passing for a reason that has nothing to do with what it claims.
if [ "$RUNS" = "0" ]; then
  check "linkage cannot be assessed: the download is not a runnable binary" 0
elif command -v ldd >/dev/null 2>&1; then
  if ldd ./grange 2>&1 | grep -q "not a dynamic executable"; then
    check "the binary is static, as the README promises" 1
  else
    check "the README promises static but the release links: $(ldd ./grange 2>&1 | grep -oE 'lib[a-z0-9]+\.so[^ ]*' | tr '\n' ' ')" 0
  fi
fi
if [ "$RUNS" = "1" ] && command -v objdump >/dev/null 2>&1; then
  FLOOR=$(objdump -T ./grange 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
  [ -z "$FLOOR" ] && check "no glibc floor, as the README promises" 1 \
    || check "the README promises no glibc floor but the release requires $FLOOR" 0
fi

# ---- 3. the first command the README tells them to run must teach them the tool
G=$(./grange guide 2>/dev/null)
echo "$G" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "guide is machine-readable, so an agent can drive the tool" 1 \
  || check "guide is not valid JSON" 0
echo "$G" | python3 -c '
import json,sys
d = json.load(sys.stdin)
# a stranger needs to know WHAT it is and WHAT TO DO first, from the guide alone
sys.exit(0 if d.get("model") and d.get("loop") and d.get("verbs") else 1)' 2>/dev/null \
  && check "guide states the model, the loop and the verbs" 1 \
  || check "guide is missing the model/loop/verbs a newcomer needs" 0

# ---- 4. the loop the guide prints must actually work, with no other knowledge
./grange put --db db --coll notes --id n1 --doc '{"title":"first","n":1}' >/dev/null 2>&1
GOT=$(./grange get --db db --coll notes --id n1 2>/dev/null)
echo "$GOT" | grep -q '"title":"first"' && check "put then get round-trips on a fresh database" 1 \
  || check "put/get failed on a fresh database ($(echo "$GOT" | head -c 80))" 0
CNT=$(./grange count --db db --coll notes 2>/dev/null | grep -o '"count":[0-9]*' | head -1)
[ "$CNT" = '"count":1' ] && check "count agrees" 1 || check "count disagrees ($CNT)" 0
./grange verify --db db --coll notes 2>/dev/null | grep -q '"intact":true' \
  && check "verify reports the fresh database intact" 1 || check "verify does not report intact" 0

# ---- 5. the server, which is the actual product
PORT=4498
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
./grange serve --db db --port "$PORT" --token strangertok >serve.log 2>&1 &
SRV=$!
UP=0
for _ in $(seq 1 60); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && { UP=1; break; }; done
[ "$UP" = "1" ] && check "serve starts and answers /health" 1 \
  || check "serve did not come up ($(head -c 100 serve.log))" 0

# the contract an agent is told to read first must be reachable WITHOUT a token
LLMS=$(curl -s -m 10 "http://localhost:$PORT/llms.txt" 2>/dev/null)
[ -n "$LLMS" ] && check "/llms.txt is served unauthenticated (the agent's front door)" 1 \
  || check "/llms.txt is empty or refused" 0

A="authorization: Bearer strangertok"
curl -s -m 10 -X POST "http://localhost:$PORT/put" -H "$A" \
  -d '{"coll":"notes","id":"n2","doc":{"title":"second","n":2}}' >/dev/null 2>&1
HTTPCNT=$(curl -s -m 10 "http://localhost:$PORT/count?coll=notes" -H "$A" 2>/dev/null | grep -o '"count":[0-9]*' | head -1)
[ "$HTTPCNT" = '"count":2' ] && check "the HTTP API writes and counts (2 docs)" 1 \
  || check "the HTTP API disagrees ($HTTPCNT)" 0

# a stranger WILL get the token wrong; the error has to say so
UNAUTH=$(curl -s -m 10 "http://localhost:$PORT/count?coll=notes" -H "authorization: Bearer wrong" 2>/dev/null)
echo "$UNAUTH" | grep -qi "auth" && check "a wrong token produces an error that names the problem" 1 \
  || check "a wrong token produces an unhelpful response ($(echo "$UNAUTH" | head -c 70))" 0

curl -s -m 5 -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

# ---- 6. stdout discipline (cli-output-spec): a stranger piping to jq must not
#         get log lines mixed into their data
OUT=$(./grange count --db db --coll notes 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "stdout is pure JSON, safe to pipe" 1 || check "stdout carries non-JSON noise" 0

cd /
[ "$KEEP" = "1" ] && echo "  kept: $WORK" || rm -rf "$WORK"

if [ "$fails" -eq 0 ]; then echo "{\"ok\":true,\"stranger\":\"pass\",\"tag\":\"$TAG\",\"asset\":\"$ASSET\"}"; exit 0; fi
echo "{\"ok\":false,\"failures\":$fails,\"tag\":\"$TAG\",\"asset\":\"$ASSET\"}"
exit 1
