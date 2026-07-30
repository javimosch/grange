#!/usr/bin/env bash
# Telemetry — the tests are about what it must NOT do.
#
# grange implements cli-telemetry-spec. Every claim it makes to the user is
# checkable, so it is checked here: that the off switches actually stop it, that
# the disclosure never lands on stdout, that the payload contains nothing outside
# the published allow-list, that a hung collector cannot hang a command, and that
# the collector aggregates rather than keeping a row per sender.
#
# The reason this file is long for a feature that sends seven fields: telemetry is
# the one part of grange that takes something from the user rather than giving
# something. A bug here is not a wrong answer, it is a broken promise — and the
# first version had two. The opt-out silently failed to persist (the tool printed
# "disabled" and would have kept sending, because $HOME/.config does not exist on
# a fresh machine and machin's mkdir is one level), and the collector's counter
# never incremented while reporting success.
set -u
BIN="${BIN:-./grange}"
PORT="${PORT:-4501}"
SCHEMA="${SCHEMA:-$HOME/ai/cli-telemetry-spec/event.schema.json}"
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

WORK=$(mktemp -d /tmp/grange-tel-XXXX)
export HOME="$WORK/home"; mkdir -p "$HOME"
BINA=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")

# ---- 1. the off switches. Each must name itself, so a user can tell WHICH one
#         is in effect — "off, and I will not say why" is not inspectable.
st() { "$BINA" telemetry 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["enabled"], d["reason"], sep="|")'; }

R=$(st); [ "${R%%|*}" = "True" ] && check "default state is enabled, and says so" 1 || check "default state ($R)" 0
R=$(GRANGE_TELEMETRY=0 st); echo "$R" | grep -q "^False|GRANGE_TELEMETRY" \
  && check "GRANGE_TELEMETRY=0 disables it and names itself" 1 || check "GRANGE_TELEMETRY=0 ($R)" 0
R=$(DO_NOT_TRACK=1 st); echo "$R" | grep -q "^False|DO_NOT_TRACK" \
  && check "DO_NOT_TRACK=1 is honoured (the cross-vendor convention)" 1 || check "DO_NOT_TRACK ($R)" 0
R=$(CI=true st); echo "$R" | grep -q "^False|CI detected" \
  && check "CI defaults to off — CI runs are not users" 1 || check "CI detection ($R)" 0
R=$(GITHUB_ACTIONS=true st); echo "$R" | grep -q "^False|CI detected" \
  && check "GitHub Actions is detected as CI" 1 || check "GitHub Actions ($R)" 0
# DO_NOT_TRACK=0 means "do track" — the convention has a value for a reason
R=$(DO_NOT_TRACK=0 st); [ "${R%%|*}" = "True" ] \
  && check "DO_NOT_TRACK=0 means do-track, not off" 1 || check "DO_NOT_TRACK=0 ($R)" 0

# ---- 2. the promise that matters: disabled means NO packet leaves.
#         Asserted by pointing it at a local listener and proving nothing arrives,
#         which is the only version of this claim a user should accept.
python3 - "$WORK" <<'PY' &
import http.server, socketserver, sys, threading
hits = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        hits["n"] += 1
        ln = int(self.headers.get("content-length", 0))
        body = self.rfile.read(ln)
        open(sys.argv[1] + "/hits.log", "ab").write(body + b"\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 4502), H) as s:
    s.timeout = 25
    for _ in range(400):
        s.handle_request()
PY
COLLECTOR=$!
sleep 0.8
U="http://127.0.0.1:4502/t"

: > "$WORK/hits.log"
for sw in "GRANGE_TELEMETRY=0" "DO_NOT_TRACK=1" "CI=true"; do
  env "$sw" GRANGE_TELEMETRY_URL="$U" HOME="$WORK/off-$RANDOM" "$BINA" count --db "$WORK/db" --coll c >/dev/null 2>&1
done
N=$(wc -l < "$WORK/hits.log" 2>/dev/null || echo 0)
[ "$N" = "0" ] && check "no event is sent while any off switch is set (0 requests received)" 1 \
  || check "$N events were sent DESPITE an off switch" 0

# ---- 3. enabled: exactly one event per invocation, and it must validate against
#         the PUBLISHED schema, which has additionalProperties:false
: > "$WORK/hits.log"
H2="$WORK/h2"; mkdir -p "$H2"
HOME="$H2" GRANGE_TELEMETRY_URL="$U" "$BINA" count --db "$WORK/db" --coll c >/dev/null 2>"$WORK/err1"
sleep 0.3
N=$(wc -l < "$WORK/hits.log" 2>/dev/null || echo 0)
[ "$N" = "1" ] && check "exactly one event per invocation" 1 || check "expected 1 event, got $N" 0
head -1 "$WORK/hits.log" | python3 -c '
import json,sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("event") == "install" else 1)' \
  && check "the first run reports install — the event downloads cannot tell you" 1 \
  || check "the first run did not report install" 0

if [ -f "$SCHEMA" ]; then
  head -1 "$WORK/hits.log" | python3 -c '
import json, sys
schema = json.load(open(sys.argv[1]))
ev = json.load(sys.stdin)
allowed = set(schema["properties"])
extra = set(ev) - allowed
missing = [k for k in schema["required"] if k not in ev]
if extra:   print("EXTRA FIELDS:", extra); sys.exit(1)
if missing: print("MISSING:", missing); sys.exit(1)
' "$SCHEMA" && check "the payload validates against the published allow-list schema" 1 \
    || check "the payload does not match cli-telemetry-spec/event.schema.json" 0
else
  echo "  skip  schema validation (cli-telemetry-spec not checked out at $SCHEMA)"
fi

# nothing identifying, checked literally against the sent bytes
BODY=$(head -1 "$WORK/hits.log")
LEAK=""
for bad in "$(hostname)" "$(whoami)" "$HOME" "$WORK" "/tmp" "db" "install_id"; do
  case "$BODY" in *"$bad"*) LEAK="$LEAK $bad" ;; esac
done
[ -z "$LEAK" ] && check "the sent bytes contain no hostname, user, path, or install id" 1 \
  || check "the payload leaks:$LEAK  ($BODY)" 0

# ---- 4. disclosure: stderr only, once
grep -q "telemetry" "$WORK/err1" && check "the first run discloses on stderr" 1 \
  || check "the first run did not disclose" 0
HOME="$H2" GRANGE_TELEMETRY_URL="$U" "$BINA" count --db "$WORK/db" --coll c >"$WORK/out2" 2>"$WORK/err2"
[ ! -s "$WORK/err2" ] && check "the notice does not repeat on the second run" 1 \
  || check "the notice repeated ($(head -c 60 "$WORK/err2"))" 0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/out2" \
  && check "stdout stays pure JSON" 1 || check "stdout was polluted" 0
# the first run is the one that breaks pipelines, so check THAT one too
H3="$WORK/h3"; mkdir -p "$H3"
HOME="$H3" GRANGE_TELEMETRY_URL="$U" "$BINA" count --db "$WORK/db" --coll c 2>/dev/null >"$WORK/out3"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/out3" \
  && check "stdout is pure JSON on a FIRST run, when the notice prints" 1 \
  || check "the disclosure notice landed on stdout and broke the pipeline" 0

# ---- 5. opt-out must PERSIST, or be reported as failed
H4="$WORK/h4"; mkdir -p "$H4"
HOME="$H4" "$BINA" telemetry --telemetry-off >/dev/null 2>&1
R=$(HOME="$H4" st); echo "$R" | grep -q "^False" && check "--telemetry-off survives the process" 1 \
  || check "--telemetry-off did not persist ($R)" 0
: > "$WORK/hits.log"
HOME="$H4" GRANGE_TELEMETRY_URL="$U" "$BINA" count --db "$WORK/db" --coll c >/dev/null 2>&1
sleep 0.2
N=$(wc -l < "$WORK/hits.log" 2>/dev/null || echo 0)
[ "$N" = "0" ] && check "nothing is sent after --telemetry-off" 1 || check "$N events sent after opt-out" 0
# and when it CANNOT persist, it must say so rather than claim success
OUT=$(HOME=/proc/nonexistent "$BINA" telemetry --telemetry-off 2>&1); RC=$?
[ "$RC" != "0" ] && echo "$OUT" | grep -q "opt_out_not_persisted" \
  && check "an opt-out that cannot be saved FAILS instead of lying (exit $RC)" 1 \
  || check "an unsaveable opt-out reported success ($OUT)" 0

# ---- 6. a hung collector must cost a bounded amount and nothing else
# The listener must READ the request and then withhold the response. A listener
# that merely accepts and never reads returns in ~2ms — https_post errors out on
# a different path — so it exercises the error branch, not the timeout, while
# looking like a successful test of the timeout.
python3 -c "
import socket, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 4503)); s.listen(8)
def acc():
    while True:
        try:
            c, _ = s.accept()
            c.recv(65536)                       # read it, then answer never
            threading.Timer(30, c.close).start()
        except Exception: return
threading.Thread(target=acc, daemon=True).start(); time.sleep(25)" &
HANG=$!
# Wait for the listener to actually BIND. Without this the test passed reporting
# "bounded 2ms" — the connection was refused because nothing was listening yet,
# so no send was attempted and the timeout it claims to verify never ran. A check
# that passes when the scenario did not happen is worse than no check.
UP=0
for _ in $(seq 1 60); do
  sleep 0.1
  (exec 3<>/dev/tcp/127.0.0.1/4503) 2>/dev/null && { UP=1; exec 3<&- 2>/dev/null; break; }
done
[ "$UP" = "1" ] && check "the hang-test listener is up (otherwise the timeout is untested)" 1   || check "the hang-test listener never bound — the timeout check below is void" 0
H5="$WORK/h5"; mkdir -p "$H5"
T0=$(date +%s%N)
HOME="$H5" GRANGE_TELEMETRY_URL="http://127.0.0.1:4503/t" "$BINA" count --db "$WORK/db" --coll c >"$WORK/out5" 2>/dev/null
RC=$?
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
[ "$RC" = "0" ] && check "a hung collector does not change the exit code" 1 || check "exit code became $RC" 0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/out5" \
  && check "a hung collector does not corrupt the answer" 1 || check "the answer was lost" 0
# Bounded BELOW as well as above: under ~1s means the send never reached the
# timeout path, so the bound was not exercised. The window is the proof.
if [ "$MS" -lt 3000 ] && [ "$MS" -ge 1000 ]; then
  check "a hung collector costs a bounded ${MS}ms (the 2s race fired), not forever" 1
elif [ "$MS" -lt 1000 ]; then
  check "only ${MS}ms elapsed — the send never hit the timeout, so this is untested" 0
else
  check "a hung collector cost ${MS}ms" 0
fi
kill "$HANG" 2>/dev/null

# ---- 7. the collector side: aggregates, closed vocabulary, no key injection
fuser -k "$PORT/tcp" 2>/dev/null >/dev/null; sleep 0.3
"$BINA" serve --db "$WORK/cdb" --port "$PORT" --token teltok >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 60); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
E='{"tool":"grange","version":"0.13.1","event":"install","verb":"count","os":"linux"}'
for _ in 1 2 3 4 5; do curl -s -m 5 -X POST "http://localhost:$PORT/t" -d "$E" >/dev/null; done
R=$(curl -s -m 5 "http://localhost:$PORT/find?coll=_telemetry&limit=20" -H "authorization: Bearer teltok")
echo "$R" | python3 -c '
import json,sys
items = json.load(sys.stdin)["data"]["items"]
# five identical events must be ONE document with n=5 — a row per event would be
# a log of who did what and when, which is what the spec forbids
sys.exit(0 if len(items) == 1 and items[0]["doc"]["n"] == 5 else 1)' \
  && check "five identical events aggregate into one counter (n=5), not five rows" 1 \
  || check "the collector did not aggregate ($(echo "$R" | head -c 120))" 0

BAD=$(curl -s -m 5 -X POST "http://localhost:$PORT/t" -d '{"tool":"grange","event":"exfiltrate"}')
echo "$BAD" | grep -q "unknown event" && check "the event vocabulary is closed (three, per spec)" 1 \
  || check "an invented event was accepted ($BAD)" 0
curl -s -m 5 -X POST "http://localhost:$PORT/t" -d '{"tool":"grange","version":"1.0","event":"run","verb":"find.a.b","os":"linux"}' >/dev/null
curl -s -m 5 "http://localhost:$PORT/find?coll=_telemetry&limit=20" -H "authorization: Bearer teltok" \
 | python3 -c '
import json,sys
ids = [i["id"] for i in json.load(sys.stdin)["data"]["items"]]
# the separator alphabet and the value alphabet must not overlap, or a crafted
# verb writes extra segments into the key space
bad = [i for i in ids if i.count(".") != 5]
sys.exit(1 if bad else 0)' \
  && check "a crafted verb cannot inject key segments" 1 || check "key injection is possible" 0
# two versions that differ only in dot placement must not share a counter
curl -s -m 5 -X POST "http://localhost:$PORT/t" -d '{"tool":"grange","version":"0.1.31","event":"install","verb":"count","os":"linux"}' >/dev/null
curl -s -m 5 "http://localhost:$PORT/find?coll=_telemetry&limit=20" -H "authorization: Bearer teltok" \
 | python3 -c '
import json,sys
vs = {i["doc"]["version"] for i in json.load(sys.stdin)["data"]["items"]}
sys.exit(0 if len({v for v in vs if v.startswith("0-1")}) == 2 else 1)' \
  && check "0.13.1 and 0.1.31 are distinct counters" 1 || check "distinct versions collapsed into one counter" 0

curl -s -m 5 -X POST "http://localhost:$PORT/shutdown" -H "authorization: Bearer teltok" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
kill "$COLLECTOR" 2>/dev/null
rm -rf "$WORK"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"telemetry":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
