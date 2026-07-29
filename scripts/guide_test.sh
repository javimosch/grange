#!/usr/bin/env bash
# The guide must describe the binary it ships in.
#
# grange is agent-first: `grange guide` IS the interface documentation, so a
# stale guide MISLEADS rather than merely omits. It had drifted badly and
# silently — for ten milestones it reported version 0.1.0 and stated
#
#     "no fsync builtin yet — OS-crash durability is best-effort"
#
# AFTER fsync shipped and was asserted at the syscall level, and it listed 12 of
# 19 verbs while omitting cold storage, range indexes, ordering, pagination,
# cost accounting, scan budgets, replicas, verify, watch, bulk and export.
#
# Nothing could have caught that, because nothing compared the guide against the
# source. This does: every verb the CLI dispatches, every HTTP route the server
# answers, and every GRANGE_* variable the code reads must appear in the guide.
# It is deliberately mechanical — it cannot check that the prose is TRUE, only
# that nothing is missing, which is the failure mode that actually occurred.
set -u
BIN="${1:-./grange}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
fails=0
missing=""

G=$("$BIN" guide 2>/dev/null)
H=$("$BIN" help-json 2>/dev/null)

echo "$G" | python3 -m json.tool >/dev/null 2>&1 || { echo "  FAIL guide is not valid JSON"; exit 1; }
echo "$H" | python3 -m json.tool >/dev/null 2>&1 || { echo "  FAIL help-json is not valid JSON"; exit 1; }

note() { echo "  MISSING from the guide: $1"; missing="$missing $1"; fails=$((fails + 1)); }

# 1. every verb the CLI dispatches
for v in $(grep -ohE 'verb == "[a-z-]+"' "$SRC/cli.src" | grep -oE '"[a-z-]+"' | tr -d '"' | sort -u); do
  echo "$G" | grep -q "\"$v\"" || note "verb $v"
done

# 2. every HTTP route the server answers
for r in $(grep -ohE 'req\.path, "/[a-z_]+"|req\.path == "/[a-z_]+"' "$SRC/serve.src" "$SRC/serveread.src" \
           | grep -oE '/[a-z_]+' | sort -u); do
  echo "$G" | grep -q -- "$r" || note "route $r"
done

# 3. every GRANGE_* variable the code reads
for e in $(grep -rohE 'GRANGE_[A-Z_]+' "$SRC" | sort -u); do
  echo "$G" | grep -q "$e" || note "env $e"
done

[ "$fails" = "0" ] && echo "  ok   every verb, route and GRANGE_* variable appears in the guide" \
                   || echo "  FAIL $fails item(s) exist in src/ but not in the guide:$missing"

# 4. the two documents must agree on the version, and on the verb list — they
#    drifted apart before (help-json listed 12 verbs, the CLI dispatched 19)
GV=$(echo "$G" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
HV=$(echo "$H" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
if [ "$GV" = "$HV" ]; then echo "  ok   guide and help-json report the same version ($GV)"
else echo "  FAIL version mismatch: guide $GV, help-json $HV"; fails=$((fails + 1)); fi

CLI_VERBS=$(grep -ohE 'verb == "[a-z-]+"' "$SRC/cli.src" | grep -oE '"[a-z-]+"' | tr -d '"' | sort -u | tr '\n' ' ')
for v in $CLI_VERBS; do
  echo "$H" | grep -q "\"$v\"" || { echo "  FAIL help-json omits verb: $v"; fails=$((fails + 1)); }
done
echo "$H" | grep -q '"put"' && echo "  ok   help-json lists the dispatched verbs"

# 5. claims that were WRONG rather than missing, pinned so they cannot come back
echo "$G" | grep -qi "no fsync builtin yet" && { echo "  FAIL the guide still claims fsync is missing"; fails=$((fails + 1)); } \
  || echo "  ok   the stale durability claim is gone"
echo "$G" | grep -q '"version":"0.1.0"' && { echo "  FAIL the guide still reports version 0.1.0"; fails=$((fails + 1)); } \
  || echo "  ok   the version is not the M0 placeholder"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"guide":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
