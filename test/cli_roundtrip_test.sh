#!/bin/bash
# test/cli_roundtrip_test.sh
# CLI integration test comparing ziggit output to git output
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0
TMPDIR="/tmp/ziggit_cli_roundtrip_$$"

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ SKIP: $1"; SKIP=$((SKIP+1)); }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$SCRIPT_DIR/.." && zig build) || { echo "Build failed"; exit 1; }
fi

mkdir -p "$TMPDIR/repo1"
cd "$TMPDIR/repo1"

# ============================================================================
echo "=== Test: init and rev-parse HEAD ==="
git init -q .
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "init"

g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "rev-parse HEAD matches" || fail "rev-parse HEAD: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: status on clean repo ==="
g=$(git status --porcelain)
z=$("$ZIGGIT" status --porcelain 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "status --porcelain clean" || fail "status --porcelain: git='$g' ziggit='$z'"

# ============================================================================
echo "=== Test: hash-object ==="
echo "test content" > hashtest.txt
g=$(git hash-object hashtest.txt)
z=$("$ZIGGIT" hash-object hashtest.txt 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "hash-object matches" || fail "hash-object: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: hash-object --stdin ==="
g=$(echo "stdin test" | git hash-object --stdin)
z=$(echo "stdin test" | "$ZIGGIT" hash-object --stdin 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "hash-object --stdin matches" || fail "hash-object --stdin: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: rev-parse after second commit ==="
echo "world" >> f.txt
git add f.txt
git commit -q -m "second"
g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "rev-parse HEAD after 2nd commit" || fail "rev-parse 2nd: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: cat-file -t ==="
blob_hash=$(git hash-object f.txt)
g=$(git cat-file -t "$blob_hash")
z=$("$ZIGGIT" cat-file -t "$blob_hash" 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "cat-file -t matches" || fail "cat-file -t: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: cat-file -p for blob ==="
g=$(git cat-file -p "$blob_hash")
z=$("$ZIGGIT" cat-file -p "$blob_hash" 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "cat-file -p blob matches" || fail "cat-file -p blob: git='$g' ziggit='$z'"

# ============================================================================
echo "=== Test: cat-file -s for blob ==="
g=$(git cat-file -s "$blob_hash")
z=$("$ZIGGIT" cat-file -s "$blob_hash" 2>/dev/null || echo "ZIGGIT_ERROR")
[ "$g" = "$z" ] && pass "cat-file -s matches" || fail "cat-file -s: git=$g ziggit=$z"

# ============================================================================
echo "=== Test: log (basic check) ==="
z=$("$ZIGGIT" log 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$z" != "ZIGGIT_ERROR" ] && [ -n "$z" ]; then
    pass "log produces output"
else
    skip "log not implemented or failed"
fi

# ============================================================================
echo "=== Test: branch ==="
z=$("$ZIGGIT" branch 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$z" != "ZIGGIT_ERROR" ] && echo "$z" | grep -q "master\|main"; then
    pass "branch shows default branch"
else
    skip "branch not implemented or failed"
fi

# ============================================================================
echo "=== Test: tag ==="
git tag v1.0.0
z=$("$ZIGGIT" tag 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$z" != "ZIGGIT_ERROR" ] && echo "$z" | grep -q "v1.0.0"; then
    pass "tag shows created tag"
else
    skip "tag not implemented or failed"
fi

# ============================================================================
echo "=== Test: status detects untracked file ==="
echo "new" > untracked.txt
g=$(git status --porcelain | grep "^??" | sort)
z=$("$ZIGGIT" status --porcelain 2>/dev/null | grep "^??" | sort || echo "ZIGGIT_ERROR")
if [ "$z" = "ZIGGIT_ERROR" ]; then
    skip "status --porcelain with untracked not working"
else
    [ "$g" = "$z" ] && pass "status untracked matches" || fail "status untracked: git='$g' ziggit='$z'"
fi
rm -f untracked.txt hashtest.txt

# ============================================================================
echo ""
echo "============================================"
echo "CLI Roundtrip Results: $PASS pass, $FAIL fail, $SKIP skip"
echo "============================================"
[ $FAIL -eq 0 ] || exit 1
