#!/bin/bash
# test/cli_core_operations_test.sh
# CLI integration tests comparing ziggit output with git output.
# Tests: init, add, commit, rev-parse, status, tag, log, cat-file

set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ✗ FAIL: $1"; echo "    expected: '$2'"; echo "    got:      '$3'"; }

echo "=== CLI Core Operations Tests ==="

# Setup
TESTDIR="/tmp/ziggit_cli_core_test_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "ERROR: ziggit binary not found at $ZIGGIT"
    echo "Run 'zig build' first"
    exit 1
fi

# --- Test: init creates valid repo ---
echo "Test: init creates valid repo"
cd "$TESTDIR"
REPO="$TESTDIR/repo1"
$ZIGGIT init "$REPO" >/dev/null 2>&1 || true
if [ -f "$REPO/.git/HEAD" ]; then
    pass "init creates .git/HEAD"
else
    fail "init creates .git/HEAD" "exists" "missing"
fi
if [ -d "$REPO/.git/objects" ]; then
    pass "init creates .git/objects"
else
    fail "init creates .git/objects" "exists" "missing"
fi
if [ -d "$REPO/.git/refs" ]; then
    pass "init creates .git/refs"
else
    fail "init creates .git/refs" "exists" "missing"
fi

# --- Test: rev-parse HEAD matches git ---
echo "Test: rev-parse HEAD matches git"
REPO2="$TESTDIR/repo2"
git init -q "$REPO2"
cd "$REPO2"
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "initial"

G=$(git rev-parse HEAD)
Z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "rev-parse HEAD: $Z"
else
    fail "rev-parse HEAD" "$G" "$Z"
fi

# --- Test: status --porcelain on clean repo ---
echo "Test: status on clean repo"
G=$(git status --porcelain)
Z=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "status --porcelain clean"
else
    fail "status --porcelain clean" "$G" "$Z"
fi

# --- Test: tag listing ---
echo "Test: tag operations"
git tag v1.0.0
G=$(git tag -l | sort)
Z=$($ZIGGIT tag -l 2>/dev/null | sort || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "tag -l matches"
else
    fail "tag -l" "$G" "$Z"
fi

# --- Test: rev-parse after multiple commits ---
echo "Test: rev-parse after multiple commits"
echo "world" > g.txt
git add g.txt
git commit -q -m "second"

G=$(git rev-parse HEAD)
Z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "rev-parse HEAD after second commit: $Z"
else
    fail "rev-parse HEAD after second commit" "$G" "$Z"
fi

# --- Test: hash-object ---
echo "Test: hash-object"
echo -n "test content" > "$TESTDIR/hashtest.txt"
G=$(git hash-object "$TESTDIR/hashtest.txt")
Z=$($ZIGGIT hash-object "$TESTDIR/hashtest.txt" 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "hash-object: $Z"
else
    fail "hash-object" "$G" "$Z"
fi

# --- Test: cat-file ---
echo "Test: cat-file"
BLOB_HASH=$(git hash-object -w f.txt)
G=$(git cat-file -t "$BLOB_HASH")
Z=$($ZIGGIT cat-file -t "$BLOB_HASH" 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "cat-file -t: $Z"
else
    fail "cat-file -t" "$G" "$Z"
fi

G=$(git cat-file -p "$BLOB_HASH")
Z=$($ZIGGIT cat-file -p "$BLOB_HASH" 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "cat-file -p matches"
else
    fail "cat-file -p" "$G" "$Z"
fi

# --- Test: log --oneline ---
echo "Test: log"
G=$(git log --oneline | wc -l | tr -d ' ')
Z=$($ZIGGIT log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "log --oneline count: $Z"
else
    fail "log --oneline count" "$G" "$Z"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed out of $TOTAL ==="
[ "$FAIL" -eq 0 ] || exit 1
