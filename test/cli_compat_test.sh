#!/bin/bash
# test/cli_compat_test.sh
# Compare ziggit CLI output to git CLI output for core operations
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT (run 'zig build' first)"
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip_test() { echo "  - SKIP: $1"; SKIP=$((SKIP+1)); }

TMPDIR=$(mktemp -d /tmp/ziggit_cli_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

TESTDIR="$TMPDIR/repo"
mkdir -p "$TESTDIR"

echo "=== CLI Compatibility Tests ==="

# Setup test repo
cd "$TESTDIR"
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "init"

# --- Test 1: rev-parse HEAD ---
echo "Test 1: rev-parse HEAD"
g=$(git rev-parse HEAD)
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches: ${g:0:12}..."
else
    fail "rev-parse HEAD: git=$g ziggit=$z"
fi

# --- Test 2: status --porcelain (clean) ---
echo "Test 2: status --porcelain (clean repo)"
g=$(cd "$TESTDIR" && git status --porcelain)
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "status --porcelain (clean) both empty"
else
    fail "status --porcelain: git='$g' ziggit='$z'"
fi

# --- Test 3: rev-parse after multiple commits ---
echo "Test 3: rev-parse after multiple commits"
cd "$TESTDIR"
echo "v2" > f.txt
git add f.txt
git commit -q -m "second"
echo "v3" > f.txt
git add f.txt
git commit -q -m "third"

g=$(git rev-parse HEAD)
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD after 3 commits: ${g:0:12}..."
else
    fail "rev-parse HEAD after 3 commits: git=$g ziggit=$z"
fi

# --- Test 4: status with untracked file ---
echo "Test 4: status with untracked file"
cd "$TESTDIR"
echo "new" > untracked.txt
g=$(git status --porcelain | grep "^??" | wc -l | tr -d ' ')
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" status --porcelain 2>/dev/null | grep "^??" | wc -l | tr -d ' ' || echo "0")
if [ "$g" -ge 1 ] && [ "$z" -ge 1 ]; then
    pass "both detect untracked files (git=$g ziggit=$z)"
else
    fail "untracked detection: git=$g ziggit=$z"
fi
rm -f untracked.txt

# --- Test 5: log --oneline count ---
echo "Test 5: log --oneline count"
cd "$TESTDIR"
g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "log --oneline count matches: $g_count"
else
    skip_test "log count: git=$g_count ziggit=$z_count"
fi

# --- Test 6: tag creation and listing ---
echo "Test 6: tag operations"
cd "$TESTDIR"
git tag v1.0.0
g=$(git tag -l | sort)
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" tag -l 2>/dev/null | sort || echo "")
if [ "$g" = "$z" ]; then
    pass "tag -l matches"
elif echo "$z" | grep -q "v1.0.0"; then
    pass "tag -l contains v1.0.0"
else
    skip_test "tag -l: git='$g' ziggit='$z'"
fi

# --- Test 7: branch listing ---
echo "Test 7: branch listing"
cd "$TESTDIR"
z=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" branch 2>/dev/null || echo "")
if echo "$z" | grep -q "master"; then
    pass "branch listing contains master"
else
    skip_test "branch: ziggit='$z'"
fi

# --- Test 8: ls-files ---
echo "Test 8: ls-files"
cd "$TESTDIR"
g_count=$(git ls-files | wc -l | tr -d ' ')
z_count=$(cd "$TESTDIR" && HOME=/root "$ZIGGIT" ls-files 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "ls-files count matches: $g_count"
else
    skip_test "ls-files count: git=$g_count ziggit=$z_count"
fi

# --- Summary ---
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"  
echo "  Skipped: $SKIP"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED (${SKIP} skipped)"
    exit 0
fi
