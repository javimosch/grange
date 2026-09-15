#!/bin/bash
# quickstart.sh — get a stranger from zero to a running grange in <2 minutes.
#
# Usage:
#   ./scripts/quickstart.sh [PORT] [--db DIR]
#
# What it does:
#   1. Builds grange (or uses ./grange if present)
#   2. Creates a data directory
#   3. Starts the server on PORT (default 4444)
#   4. Verifies /health responds
#   5. Prints the admin token and next steps
#
# Opt-in, retrocompatible: doesn't touch existing deployments. Idempotent —
# safe to re-run.

set -e
cd "$(dirname "$0")/.."
BIN=./grange
PORT=${1:-4444}
DB=${2:-/tmp/grange-quickstart.db}

echo "=== grange quickstart ==="
echo

# 1. Build
if [ ! -f "$BIN" ]; then
    echo "[1/4] building grange..."
    make build 2>&1 | tail -2
else
    echo "[1/4] using existing binary"
fi

# 2. Data dir
echo "[2/4] data dir: $DB"
mkdir -p "$DB"

# 3. Start
echo "[3/4] starting on port $PORT..."
$BIN serve --db "$DB" --port $PORT --host 127.0.0.1 > /tmp/grange-quickstart.log 2>&1 &
BGPID=$!
sleep 2

# Wait for listen
for i in $(seq 1 10); do
    if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"up"'; then
        break
    fi
    sleep 0.5
done

# 4. Verify
echo "[4/4] verifying..."
HEALTH=$(curl -s "http://127.0.0.1:$PORT/health")
if echo "$HEALTH" | grep -q '"status":"up"'; then
    echo "  ok: server is up"
else
    echo "  FAIL: server did not start. Log:"
    cat /tmp/grange-quickstart.log
    exit 1
fi

# Extract token from log
TOKEN=$(grep -o '"token":"[^"]*"' /tmp/grange-quickstart.log | head -1 | sed 's/"token":"\([^"]*\)"/\1/')
if [ -z "$TOKEN" ]; then
    TOKEN=$(grep 'token' /tmp/grange-quickstart.log | head -1 | sed 's/.*token":"\([^"]*\)".*/\1/')
fi

echo
echo "=== grange is running ==="
echo "  URL:    http://127.0.0.1:$PORT"
echo "  Token:  $TOKEN"
echo "  Data:   $DB"
echo "  PID:    $BGPID"
echo
echo "=== next steps ==="
echo "  # put a doc"
echo "  curl -X POST http://127.0.0.1:$PORT/put -H \"Authorization: Bearer $TOKEN\" -d '{\"doc\":{\"hello\":\"world\"}}'"
echo
echo "  # count"
echo "  curl http://127.0.0.1:$PORT/count -H \"Authorization: Bearer $TOKEN\""
echo
echo "  # guide"
echo "  ./grange guide"
echo
echo "  # stop"
echo "  kill $BGPID"
echo
echo "=== production notes ==="
echo "  - Set GRANGE_TOKEN to keep the token stable across restarts"
echo "  - Set GRANGE_MAX_RSS_MB=300 to bound memory"
echo "  - Set GRANGE_CONCURRENT_READS=1 to auto-spawn a read replica"
echo "  - Add --follow on a second port for a read replica"
echo "  - POST /promote to flip a follower to primary on failover"
