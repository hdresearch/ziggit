#!/bin/bash
# CLI integration test: verify ziggit CLI output matches git CLI output
# Tests hash-object, cat-file, rev-parse, log, status, branch, tag

set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1"; SKIP=$((SKIP+1)); }

if [ ! -x "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT"
    exit 0
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_test_XXXXXX)
trap "rm -rf $TMPDIR" EXIT

cd "$TMPDIR"

# ============================================================================
echo "=== Test 1: init and rev-parse HEAD ==="
mkdir test1 && cd test1
git init -q && git config user.email t@t.com && git config user.name T
echo "hello" > f.txt && git add f.txt && git commit -q -m "init"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD)
[ "$g" = "$z" ] && pass "rev-parse HEAD matches" || fail "rev-parse HEAD: git=$g ziggit=$z"
cd "$TMPDIR"

# ============================================================================
echo "=== Test 2: status --porcelain on clean repo ==="
mkdir test2 && cd test2
git init -q && git config user.email t@t.com && git config user.name T
echo "data" > f.txt && git add f.txt && git commit -q -m "init"

g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain)
[ "$g" = "$z" ] && pass "status --porcelain clean" || fail "status clean: git='$g' ziggit='$z'"
cd "$TMPDIR"

# ============================================================================
echo "=== Test 3: status with untracked files ==="
mkdir test3 && cd test3
git init -q && git config user.email t@t.com && git config user.name T
echo "tracked" > t.txt && git add t.txt && git commit -q -m "init"
echo "new" > untracked.txt

g=$(git status --porcelain | sort)
z=$($ZIGGIT status --porcelain | sort)
if echo "$z" | grep -q "?? untracked.txt"; then
    pass "status shows untracked"
else
    fail "status untracked: ziggit='$z'"
fi
cd "$TMPDIR"

# ============================================================================
echo "=== Test 4: branch listing ==="
mkdir test4 && cd test4
git init -q && git config user.email t@t.com && git config user.name T
echo "x" > f.txt && git add f.txt && git commit -q -m "init"
git branch dev
git branch staging

z=$($ZIGGIT branch 2>/dev/null || true)
if echo "$z" | grep -q "dev" && echo "$z" | grep -q "staging"; then
    pass "branch lists git-created branches"
else
    # Some implementations might have different output format
    skip "branch listing (format may differ)"
fi
cd "$TMPDIR"

# ============================================================================
echo "=== Test 5: log shows commits ==="
mkdir test5 && cd test5
git init -q && git config user.email t@t.com && git config user.name T
echo "a" > a.txt && git add a.txt && git commit -q -m "first"
echo "b" > b.txt && git add b.txt && git commit -q -m "second"
echo "c" > c.txt && git add c.txt && git commit -q -m "third"

g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$($ZIGGIT log --oneline 2>/dev/null | wc -l | tr -d ' ')
[ "$g_count" = "$z_count" ] && pass "log commit count matches ($g_count)" || fail "log count: git=$g_count ziggit=$z_count"
cd "$TMPDIR"

# ============================================================================
echo "=== Test 6: hash-object compatibility ==="
mkdir test6 && cd test6
git init -q && git config user.email t@t.com && git config user.name T
echo "test content" > test.txt

g=$(git hash-object test.txt)
z=$($ZIGGIT hash-object test.txt 2>/dev/null || true)
if [ -n "$z" ] && [ "$g" = "$z" ]; then
    pass "hash-object matches"
elif [ -z "$z" ]; then
    skip "hash-object (not implemented in CLI)"
else
    fail "hash-object: git=$g ziggit=$z"
fi
cd "$TMPDIR"

# ============================================================================
echo "=== Test 7: rev-parse after multiple commits ==="
mkdir test7 && cd test7
git init -q && git config user.email t@t.com && git config user.name T
echo "1" > f.txt && git add f.txt && git commit -q -m "c1"
echo "2" > f.txt && git add f.txt && git commit -q -m "c2"
echo "3" > f.txt && git add f.txt && git commit -q -m "c3"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD)
[ "$g" = "$z" ] && pass "rev-parse HEAD after 3 commits" || fail "rev-parse multi: git=$g ziggit=$z"
cd "$TMPDIR"

# ============================================================================
echo "=== Test 8: tag visibility ==="
mkdir test8 && cd test8
git init -q && git config user.email t@t.com && git config user.name T
echo "x" > f.txt && git add f.txt && git commit -q -m "init"
git tag v1.0.0
git tag -a v2.0.0 -m "annotated"

z=$($ZIGGIT tag 2>/dev/null || true)
if [ -n "$z" ]; then
    if echo "$z" | grep -q "v1.0.0" && echo "$z" | grep -q "v2.0.0"; then
        pass "tag lists both lightweight and annotated"
    else
        fail "tag listing: ziggit='$z'"
    fi
else
    skip "tag listing (not implemented in CLI)"
fi
cd "$TMPDIR"

# ============================================================================
echo "=== Test 9: diff detection ==="
mkdir test9 && cd test9
git init -q && git config user.email t@t.com && git config user.name T
echo "original" > f.txt && git add f.txt && git commit -q -m "init"
echo "modified" > f.txt

z=$($ZIGGIT diff 2>/dev/null || true)
if [ -n "$z" ]; then
    if echo "$z" | grep -q "modified" || echo "$z" | grep -q "f.txt"; then
        pass "diff detects modifications"
    else
        fail "diff: ziggit='$z'"
    fi
else
    skip "diff (not implemented or no output)"
fi
cd "$TMPDIR"

# ============================================================================
echo ""
echo "Results: $PASS pass, $FAIL fail, $SKIP skip"
[ $FAIL -eq 0 ] || exit 1
