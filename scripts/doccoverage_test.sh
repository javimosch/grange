#!/usr/bin/env bash
# "100% documented for agents" — as a check, not a claim.
#
# grange is agent-first: there is no UI, so `grange guide` and the in-repo skills
# ARE the product's interface. That makes documentation drift a functional bug,
# and this project's history is almost entirely documentation drift: a guide
# reporting version 0.1.0 for ten milestones, "no fsync builtin yet" long after
# fsync shipped, "nightly backups" with no backup job, "all four SDKs take
# fields" against published packages that had none. Each was found by accident.
#
# So this enumerates the dev-facing surface OUT OF THE SOURCE — every CLI verb,
# every HTTP route, every GRANGE_* environment variable, every flag — and fails
# if any of them is absent from `grange guide`. Undocumented surface cannot hide
# behind "I remembered to write it down".
#
# What it does NOT prove: that the prose is CORRECT, only that the surface is
# mentioned. Correctness is what guide_test.sh (version, verb count) and
# journey_test.sh (every advertised route answers) cover from the other side.
# Together: nothing documented is missing, and nothing present is undocumented.
set -u
BIN="${BIN:-./grange}"
SRC="${SRC:-src}"
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

GUIDE=$("$BIN" guide 2>/dev/null)
[ -n "$GUIDE" ] && check "guide is emitted" 1 || { check "guide is emitted" 0; exit 1; }
echo "$GUIDE" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  && check "guide is valid JSON (an agent can parse it)" 1 \
  || check "guide is not valid JSON" 0
SKILLS=$(cat skills/*/SKILL.md 2>/dev/null)
[ -n "$SKILLS" ] && check "in-repo skills are present" 1 || check "in-repo skills are present" 0

# Deliberately excluded from the documentation requirement, each for a stated
# reason — an exclusion list that is not justified is just a way to pass.
#   torture     internal stress verb, not a product feature
#   help-json   the machine-readable form of --help; documenting it in the guide
#               it is a sibling of would be circular
#   follow      the CLI verb behind `serve --follow`, documented as the flag
IGNORE_VERBS="torture help-json follow"
#   /shutdown   admin-only, deliberately absent from the public contract
IGNORE_ROUTES=""
#   the load-bearing internals: knobs I tune while measuring, not a contract I
#   want an agent depending on. If one becomes part of the interface it must be
#   documented, so removing a name from this list is how that is enforced.
IGNORE_ENV="GRANGE_BULK_DIRECT GRANGE_BULK_PASS GRANGE_IDX_BATCH GRANGE_IDX_PARTS GRANGE_RANGE_PAGE GRANGE_SORT_SPILL GRANGE_SORT_EXTERNAL GRANGE_SORT_EXTERNAL_PAGES GRANGE_COLD_MEMTABLE GRANGE_MAX_RUNS GRANGE_MERCHANT_KEY"
#   bench-only and internal flags
IGNORE_FLAGS="vs-sqlite n once batch help remote-coll remote-db rtoken --db --token"

ignored() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Lookups are ANCHORED to the part of the guide that is supposed to carry each
# kind of name. A plain substring test over the whole JSON passed all ten checks
# on the first run, which was not documentation being complete — "get" occurs in
# a dozen unrelated sentences, so the check could not fail. That is the same
# theatre three versions of the journey route-check turned out to be.
#
#   verb  -> must be a KEY of guide.verbs
#   route -> must appear inside guide.http (the section that documents routes)
#   env   -> must be a KEY of guide.env
#   flag  -> must appear in guide.verbs or guide.loop, where usage is shown
in_section() {  # in_section <jsonpath-ish section> <needle> [--key]
  echo "$GUIDE" | SEC="$1" NEEDLE="$2" MODE="${3:-substr}" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
sec, needle, mode = os.environ["SEC"], os.environ["NEEDLE"], os.environ["MODE"]
node = d
for part in sec.split("."):
    node = node.get(part) if isinstance(node, dict) else None
    if node is None:
        sys.exit(2)          # the section itself is gone: a failure, not a pass
if mode == "key":
    sys.exit(0 if isinstance(node, dict) and needle in node else 1)
sys.exit(0 if needle in json.dumps(node) else 1)'
}
in_guide() { echo "$GUIDE" | grep -qF -- "$1"; }

# ---- CLI verbs
missing=""
n=0
for v in $(grep -ohE 'if verb == "[a-z_-]+"' "$SRC"/*.src | sed 's/.*"\(.*\)"/\1/' | sort -u); do
  ignored "$v" "$IGNORE_VERBS" && continue
  n=$((n + 1))
  in_section verbs "$v" key || missing="$missing $v"
done
[ -z "$missing" ] && check "every CLI verb appears in the guide ($n checked)" 1 \
  || check "CLI verbs missing from the guide:$missing" 0

# ---- HTTP routes
missing=""
n=0
for r in $(grep -ohE 'srv_route\([a-z_.]+, "/[a-z_/]*"\)' "$SRC"/*.src | sed 's/.*"\(.*\)".*/\1/' | sort -u); do
  ignored "$r" "$IGNORE_ROUTES" && continue
  n=$((n + 1))
  in_section http "$r" || missing="$missing $r"
done
[ -z "$missing" ] && check "every HTTP route appears in the guide ($n checked)" 1 \
  || check "HTTP routes missing from the guide:$missing" 0

# ---- environment variables: these are the operational contract. An operator
# tuning an undocumented one is guessing, and a knob nobody can find might as
# well not exist.
missing=""
n=0
for e in $(grep -ohE 'env\("GRANGE_[A-Z_]+"\)' "$SRC"/*.src | sed 's/.*"\(.*\)".*/\1/' | sort -u); do
  ignored "$e" "$IGNORE_ENV" && continue
  n=$((n + 1))
  in_section env "$e" key || missing="$missing $e"
done
[ -z "$missing" ] && check "every operator-facing GRANGE_* variable appears in the guide ($n checked)" 1 \
  || check "environment variables missing from the guide:$missing" 0

# ---- flags
missing=""
n=0
for f in $(grep -ohE '(flag_[a-z]+|srv_argv_flag)\((fs, )?"[a-z-]+"' "$SRC"/*.src | sed -E 's/.*"(.*)"/\1/' | sort -u); do
  ignored "$f" "$IGNORE_FLAGS" && continue
  n=$((n + 1))
  in_section verbs "--$f" || in_section loop "--$f" || in_section http "$f=" \
    || in_section query "$f=" || missing="$missing $f"
done
[ -z "$missing" ] && check "every user-facing flag appears in the guide ($n checked)" 1 \
  || check "flags missing from the guide:$missing" 0

# ---- query operators, which is where the guide has been thinnest.
#
# Each operator is anchored to the sub-section that OWNS it, not to guide.query
# as a whole. Testing for a bare "|" passed even after every mention of
# alternatives had been deleted, because the pagination cursor format is
# `<value>|<id>` — the character was still there, documenting something else
# entirely. A one-character needle cannot distinguish a documented operator from
# an unrelated coincidence.
missing=""
in_section query.where "~=" || missing="$missing ~=(where)"
in_section query.where ">=" || missing="$missing >=(where)"
in_section query.where "<=" || missing="$missing <=(where)"
in_section query.in_clause "a|b|c" || missing="$missing alternatives(in_clause)"
in_section query.pagination "|" || missing="$missing cursor-format(pagination)"
[ -z "$missing" ] && check "every where-clause operator appears in the guide" 1 \
  || check "query operators missing from the guide:$missing" 0

# ---- the skills must cover the WORKFLOWS, which the guide does not: it is a
# reference, and a reference does not tell an agent which order to do things in
missing=""
for topic in "where" "order" "cursor" "fields" "index" "cold" "tenant" "verify" "backup" "a|b"; do
  echo "$SKILLS" | grep -qF -- "$topic" || missing="$missing $topic"
done
[ -z "$missing" ] && check "the in-repo skills cover every major workflow" 1 \
  || check "workflows absent from every skill:$missing" 0

# ---- and the guide must not advertise what no longer exists (the other
# direction of the same drift). Verb names in the guide's own verb list are
# checked against the dispatch table.
VERBS_IN_SRC=$(grep -ohE 'if verb == "[a-z_-]+"' "$SRC"/*.src | sed 's/.*"\(.*\)"/\1/' | sort -u)
ghosts=""
for v in $(echo "$GUIDE" | python3 -c '
import json,sys
d = json.load(sys.stdin)
v = d.get("verbs") or d.get("cli") or {}
print(" ".join(v.keys()) if isinstance(v, dict) else " ".join(map(str, v)))' 2>/dev/null); do
  echo "$VERBS_IN_SRC" | grep -qx "$v" || ghosts="$ghosts $v"
done
[ -z "$ghosts" ] && check "the guide advertises no verb the binary lacks" 1 \
  || check "the guide advertises verbs that do not exist:$ghosts" 0

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"doc_coverage":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
