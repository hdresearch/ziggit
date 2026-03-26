#!/bin/bash
# test/cli_core_test.sh - Core CLI compatibility tests: ziggit vs git
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/../zig-out/bin/ziggit}"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }

if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$SCRIPT_DIR/.." && zig build 2>/dev/null) || { echo "Build failed"; exit 1; }
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== CLI Core Compatibility Tests ==="

# ---- Test 1: init ----
echo "Test 1: init"
mkdir -p "$TMPDIR/t1"
(cd "$TMPDIR/t1" && $ZIGGIT init -q . 2>/dev/null || $ZIGGIT init . 2>/dev/null || true)
if [ -f "$TMPDIR/t1/.git/HEAD" ] && [ -d "$TMPDIR/t1/.git/objects" ] && [ -d "$TMPDIR/t1/.git/refs" ]; then
    pass "init creates .git structure"
else
    fail "init creates .git structure"
fi

# ---- Test 2: rev-parse HEAD on git-created repo ----
echo "Test 2: rev-parse HEAD"
mkdir -p "$TMPDIR/t2"
(cd "$TMPDIR/t2" && git init -q && git config user.email "t@t.com" && git config user.name "T" && echo "hello" > f.txt && git add f.txt && git commit -q -m "initial")

g=$(cd "$TMPDIR/t2" && git rev-parse HEAD)
z=$(cd "$TMPDIR/t2" && $ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches git"
else
    fail "rev-parse HEAD: git=$g ziggit=$z"
fi

# ---- Test 3: status --porcelain on clean repo ----
echo "Test 3: status --porcelain (clean)"
g=$(cd "$TMPDIR/t2" && git status --porcelain)
z=$(cd "$TMPDIR/t2" && $ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ] || { [ -z "$g" ] && [ -z "$z" ]; }; then
    pass "status --porcelain matches (clean repo)"
else
    fail "status --porcelain: git='$g' ziggit='$z'"
fi

# ---- Test 4: log --oneline ----
echo "Test 4: log --oneline"
g=$(cd "$TMPDIR/t2" && git log --oneline | head -1)
z=$(cd "$TMPDIR/t2" && $ZIGGIT log --oneline 2>/dev/null | head -1 || echo "ERROR")
g_prefix=$(echo "$g" | cut -c1-7)
z_prefix=$(echo "$z" | cut -c1-7)
if [ "$g_prefix" = "$z_prefix" ]; then
    pass "log --oneline hash prefix matches ($g_prefix)"
else
    fail "log --oneline: git='$g' ziggit='$z'"
fi

# ---- Test 5: branch listing ----
echo "Test 5: branch listing"
g=$(cd "$TMPDIR/t2" && git branch --list 2>/dev/null | sed 's/^[* ]*//' | sort)
z=$(cd "$TMPDIR/t2" && $ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "branch list matches"
elif echo "$g" | grep -q master && echo "$z" | grep -q master; then
    pass "branch list both contain master"
else
    fail "branch list: git='$g' ziggit='$z'"
fi

# ---- Test 6: multiple commits, rev-parse still matches ----
echo "Test 6: multiple commits"
mkdir -p "$TMPDIR/t6"
(cd "$TMPDIR/t6" && git init -q && git config user.email "t@t.com" && git config user.name "T" && echo "one" > a.txt && git add a.txt && git commit -q -m "first" && echo "two" > b.txt && git add b.txt && git commit -q -m "second" && echo "three" > c.txt && git add c.txt && git commit -q -m "third")

g=$(cd "$TMPDIR/t6" && git rev-parse HEAD)
z=$(cd "$TMPDIR/t6" && $ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD after 3 commits"
else
    fail "rev-parse HEAD after 3 commits: git=$g ziggit=$z"
fi

# ---- Test 7: tags ----
echo "Test 7: tags"
(cd "$TMPDIR/t6" && git tag v1.0 && git tag v2.0)
g=$(cd "$TMPDIR/t6" && git tag -l | sort)
z=$(cd "$TMPDIR/t6" && $ZIGGIT tag 2>/dev/null | sort || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "tag list matches"
else
    fail "tag list: git='$g' ziggit='$z'"
fi

# ---- Test 8: hash-object ----
echo "Test 8: hash-object"
echo -n "test content for hash" > "$TMPDIR/hashfile"
g=$(git hash-object "$TMPDIR/hashfile")
z=$($ZIGGIT hash-object "$TMPDIR/hashfile" 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "hash-object matches ($g)"
else
    fail "hash-object: git=$g ziggit=$z"
fi

# ---- Test 9: cat-file -t ----
echo "Test 9: cat-file"
hash=$(cd "$TMPDIR/t6" && git rev-parse HEAD)
g=$(cd "$TMPDIR/t6" && git cat-file -t "$hash")
z=$(cd "$TMPDIR/t6" && $ZIGGIT cat-file -t "$hash" 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "cat-file -t matches ($g)"
else
    fail "cat-file -t: git=$g ziggit=$z"
fi

# ---- Test 10: ls-files ----
echo "Test 10: ls-files"
g=$(cd "$TMPDIR/t6" && git ls-files | sort)
z=$(cd "$TMPDIR/t6" && $ZIGGIT ls-files 2>/dev/null | sort || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "ls-files matches"
else
    fail "ls-files: git='$g' ziggit='$z'"
fi

# ---- Summary ----
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] || exit 1
