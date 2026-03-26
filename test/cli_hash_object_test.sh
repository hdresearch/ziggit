#!/bin/bash
# CLI integration test: compare ziggit hash-object and object creation with git
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZIGGIT="${ZIGGIT:-$PROJECT_DIR/zig-out/bin/ziggit}"
PASS=0
FAIL=0
TOTAL=0

# Ensure binary is built
if [ ! -f "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$PROJECT_DIR" && HOME=/root zig build 2>/dev/null)
fi

if [ ! -f "$ZIGGIT" ]; then
    echo "ERROR: Could not build ziggit binary at $ZIGGIT"
    exit 1
fi

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ✗ FAIL: $1"; }

echo "=== CLI Hash/Object Compatibility Tests ==="

# Setup
TESTDIR="/tmp/ziggit_cli_hash_test_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
cd "$TESTDIR"

# Test 1: init creates valid repo
echo "Test 1: init creates git-compatible repo"
$ZIGGIT init repo1 >/dev/null 2>&1 || true
if [ -f repo1/.git/HEAD ]; then
    pass "ziggit init creates .git/HEAD"
else
    fail "ziggit init missing .git/HEAD"
fi

if git -C repo1 status >/dev/null 2>&1; then
    pass "git recognizes ziggit-init'd repo"
else
    fail "git doesn't recognize ziggit-init'd repo"
fi

# Test 2: rev-parse HEAD matches after commit
echo "Test 2: rev-parse HEAD after git commit"
cd "$TESTDIR"
git init -q repo2
cd repo2
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "init"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches ($g)"
else
    fail "rev-parse HEAD: git=$g ziggit=$z"
fi

# Test 3: status --porcelain on clean repo
echo "Test 3: status --porcelain on clean repo"
g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$g" = "$z" ]; then
    pass "clean status matches"
else
    fail "clean status differs: git='$g' ziggit='$z'"
fi

# Test 4: status --porcelain with untracked file
echo "Test 4: status with untracked file"
echo "new" > untracked.txt
g=$(git status --porcelain | sort)
z=$($ZIGGIT status --porcelain 2>/dev/null | sort || echo "ZIGGIT_ERROR")
if [ "$g" = "$z" ]; then
    pass "untracked detection matches"
else
    fail "untracked: git='$g' ziggit='$z'"
fi
rm -f untracked.txt

# Test 5: log --oneline
echo "Test 5: log --oneline"
echo "second" > g.txt
git add g.txt
git commit -q -m "second commit"

g_lines=$(git log --oneline | wc -l)
z_lines=$($ZIGGIT log --oneline 2>/dev/null | wc -l || echo "0")
if [ "$g_lines" = "$z_lines" ]; then
    pass "log --oneline line count matches ($g_lines)"
else
    fail "log --oneline: git=$g_lines lines, ziggit=$z_lines lines"
fi

# Test 6: branch listing
echo "Test 6: branch listing"
git checkout -q -b feature-branch
git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || true

g_branches=$(git branch --list | sed 's/^[* ] //' | sort)
z_branches=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ] //' | sort || echo "ZIGGIT_ERROR")
# Just check that feature-branch appears in both
if echo "$z_branches" | grep -q "feature-branch"; then
    pass "ziggit lists feature-branch"
else
    fail "ziggit missing feature-branch (got: $z_branches)"
fi

# Test 7: tag operations
echo "Test 7: tag operations"
git tag v1.0
git tag v2.0

g_tags=$(git tag -l | sort)
z_tags=$($ZIGGIT tag 2>/dev/null | sort || echo "ZIGGIT_ERROR")
if echo "$z_tags" | grep -q "v1.0" && echo "$z_tags" | grep -q "v2.0"; then
    pass "ziggit lists both tags"
else
    fail "ziggit tags: got '$z_tags'"
fi

# Test 8: rev-parse HEAD unchanged after tag
echo "Test 8: rev-parse unchanged after tag"
g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ZIGGIT_ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse still matches after tagging"
else
    fail "rev-parse after tag: git=$g ziggit=$z"
fi

# Cleanup
cd /
rm -rf "$TESTDIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed out of $TOTAL tests ==="
[ "$FAIL" -eq 0 ] || exit 1
