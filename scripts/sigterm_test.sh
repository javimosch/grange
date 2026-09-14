#!/bin/bash
# sigterm_test.sh — verify graceful SIGTERM/SIGINT handling in serve mode.
# A blocked signal should be caught via signalfd, log a graceful_shutdown
# event, and exit 0 (not 143).
set -e
cd "$(dirname "$0")/.."
BIN=./grange
DB=$(mktemp -d)
PORT=4599
TOKEN=testtok
PASS=0
FAIL=0

check() {
    if [ "$1" = "$2" ]; then
        echo "  ok: $3"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $3 (got '$1' expected '$2')"
        FAIL=$((FAIL + 1))
    fi
}

# Part 1: SIGTERM produces graceful shutdown (exit 0, log line)
$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/sigterm_out.log 2>&1 &
BGPID=$!
sleep 1
GPID=$(pgrep -x grange | head -1)
kill -TERM $GPID
wait $BGPID 2>/dev/null
EXITCODE=$?
check "$EXITCODE" "0" "SIGTERM exits gracefully (exit 0, not 143)"
grep -q 'graceful_shutdown' /tmp/sigterm_out.log
check "$?" "0" "SIGTERM logs graceful_shutdown event"

# Part 2: SIGINT also produces graceful shutdown
PORT=$((PORT + 1))
$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/sigint_out.log 2>&1 &
BGPID=$!
sleep 1
GPID=$(pgrep -x grange | head -1)
kill -INT $GPID
wait $BGPID 2>/dev/null
EXITCODE=$?
check "$EXITCODE" "0" "SIGINT exits gracefully (exit 0, not 130)"
grep -q 'graceful_shutdown' /tmp/sigint_out.log
check "$?" "0" "SIGINT logs graceful_shutdown event"

# Part 3: in-flight request completes before shutdown
PORT=$((PORT + 1))
$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/sig_inflight.log 2>&1 &
BGPID=$!
sleep 1
GPID=$(pgrep -x grange | head -1)
# Start a request, then immediately send SIGTERM
curl -s -o /dev/null "http://127.0.0.1:$PORT/health?token=$TOKEN" &
CURLPID=$!
kill -TERM $GPID
wait $BGPID 2>/dev/null
EXITCODE=$?
check "$EXITCODE" "0" "shutdown with in-flight request exits 0"

rm -rf "$DB" /tmp/sigterm_out.log /tmp/sigint_out.log /tmp/sig_inflight.log
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
