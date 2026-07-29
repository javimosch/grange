#!/usr/bin/env bash
# An SDK version must not mean two different things.
#
# grange shipped ordering (M33), keyset pagination (M35) and projection (M43),
# adding each to all four SDKs — and none of it reached anybody. npm and PyPI
# still served `grange-db` 0.11.0 built before all three, the newest Go tag was
# `sdk/go/v0.10.0`, and the REPO was also labelled 0.11.0. So the same version
# number named two different bodies of code, and since registries are immutable
# the repo could not simply be republished.
#
# Worse, a release note said "all four SDKs take `fields`" — true of the repo,
# false of anything installable. Nothing compared the two, so it drifted for
# three milestones.
#
# This compares them: if the repo's SDK version equals what is published, the
# sources must not mention features the published artifact lacks. It is a
# smell test rather than a diff — comparing tarballs would be stricter and far
# more fragile — and it fires on exactly the failure that happened.
#
# Offline (no registry reachable) it SKIPS rather than passes: a check that
# silently succeeds when it cannot see the thing it checks is worse than none.
set -u
cd "$(dirname "$0")/.."
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# features that must be present in a published SDK claiming a version with them
MARKERS="order after fields"

REPO_NODE=$(python3 -c "import json;print(json.load(open('sdk/node/package.json'))['version'])")
REPO_PY=$(grep -m1 -oE 'version *= *"[0-9.]+"' sdk/python/pyproject.toml | grep -oE '[0-9.]+')
echo "  repo: node $REPO_NODE, python $REPO_PY"

online=0
PUB_NODE=$(npm view grange-db version 2>/dev/null || true)
[ -n "$PUB_NODE" ] && online=1
PUB_PY=$(python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
print(json.load(urllib.request.urlopen("https://pypi.org/pypi/grange-db/json", timeout=15))["info"]["version"])
PY
)
[ -n "$PUB_PY" ] && online=1

if [ "$online" = "0" ]; then
  echo "  SKIP no registry reachable — not asserting anything it cannot see"
  echo '{"ok":true,"sdk_version":"skipped-offline"}'
  exit 0
fi
echo "  published: node ${PUB_NODE:-?}, pypi ${PUB_PY:-?}"

# 1. if the repo version matches the published one, the published artifact must
#    already contain what the repo source contains
if [ -n "$PUB_NODE" ] && [ "$REPO_NODE" = "$PUB_NODE" ]; then
  TB=$(npm view grange-db dist.tarball 2>/dev/null)
  MISS=""
  for m in $MARKERS; do
    grep -q -- "$m" sdk/node/index.js || continue
    curl -sL "$TB" 2>/dev/null | tar -xzO package/index.js 2>/dev/null | grep -q -- "$m" || MISS="$MISS $m"
  done
  [ -z "$MISS" ] && check "node: repo $REPO_NODE matches what is published" 1 \
    || check "node: repo and published are both $REPO_NODE but published lacks:$MISS — BUMP before shipping" 0
else
  check "node: repo ($REPO_NODE) is ahead of published (${PUB_NODE:-none}) — publish it" 1
fi

# 2. same for PyPI
if [ -n "$PUB_PY" ] && [ "$REPO_PY" = "$PUB_PY" ]; then
  MISS=$(python3 - "$MARKERS" <<'PY'
import io, json, sys, tarfile, urllib.request
markers = sys.argv[1].split()
d = json.load(urllib.request.urlopen("https://pypi.org/pypi/grange-db/json", timeout=15))
urls = [u["url"] for u in d["urls"] if u["url"].endswith(".tar.gz")]
src = ""
if urls:
    raw = urllib.request.urlopen(urls[0], timeout=25).read()
    t = tarfile.open(fileobj=io.BytesIO(raw))
    for m in t.getmembers():
        if m.name.endswith("__init__.py"):
            src = t.extractfile(m).read().decode()
local = open("sdk/python/grange_db/__init__.py").read()
print(" ".join(m for m in markers if m in local and m not in src))
PY
)
  [ -z "$MISS" ] && check "python: repo $REPO_PY matches what is published" 1 \
    || check "python: repo and published are both $REPO_PY but published lacks:$MISS — BUMP before shipping" 0
else
  check "python: repo ($REPO_PY) is ahead of published (${PUB_PY:-none}) — publish it" 1
fi

# 3. the Go SDK is tag-driven: `go get ...@latest` serves the newest tag, so a
#    tag behind the source is the same failure wearing different clothes
GOTAG=$(git tag --sort=-v:refname 2>/dev/null | grep '^sdk/go/' | head -1 | sed 's|sdk/go/v||')
if [ -n "$GOTAG" ]; then
  echo "  go tag: v$GOTAG"
  HAVE=""
  for m in $MARKERS; do grep -q -- "$m" sdk/go/grange.go && HAVE="$HAVE $m"; done
  TAGGED=$(git show "sdk/go/v$GOTAG:sdk/go/grange.go" 2>/dev/null || true)
  MISS=""
  for m in $HAVE; do echo "$TAGGED" | grep -q -- "$m" || MISS="$MISS $m"; done
  [ -z "$MISS" ] && check "go: the newest tag carries what the source has" 1 \
    || check "go: sdk/go/v$GOTAG predates:$MISS — tag a new version" 0
fi

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"sdk_version":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
