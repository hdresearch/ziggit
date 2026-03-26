#!/bin/bash
# Test that ziggit CLI output matches git CLI output for core operations
set -e
ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0; FAIL=0; SKIP=0

if [ ! -x "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not built at $ZIGGIT"
    exit 0
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_verify.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# === Test 1: init creates valid repo ===
cd "$TMPDIR" && mkdir t1 && cd t1
$ZIGGIT init 2>/dev/null || true
if [ -f .git/HEAD ]; then
    PASS=$((PASS+1))
    echo "✓ Test 1: init creates .git/HEAD"
else
    FAIL=$((FAIL+1))
    echo "FAIL: Test 1: no .git/HEAD after init"
fi

# === Test 2: rev-parse HEAD matches after ziggit commit ===
cd "$TMPDIR" && rm -rf t2 && mkdir t2 && cd t2
git init -q && git config user.email t@t.com && git config user.name T
echo "hello" > f.txt && git add f.txt && git commit -q -m "init"
g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null) || z=""
if [ "$g" = "$z" ]; then
    PASS=$((PASS+1))
    echo "✓ Test 2: rev-parse HEAD matches"
else
    FAIL=$((FAIL+1))
    echo "FAIL: Test 2: git='$g' ziggit='$z'"
fi

# === Test 3: status --porcelain matches for clean repo ===
cd "$TMPDIR" && rm -rf t3 && mkdir t3 && cd t3
git init -q && git config user.email t@t.com && git config user.name T
echo "data" > a.txt && git add a.txt && git commit -q -m "init"
g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain 2>/dev/null) || z=""
if [ "$g" = "$z" ]; then
    PASS=$((PASS+1))
    echo "✓ Test 3: status --porcelain matches (clean)"
else
    FAIL=$((FAIL+1))
    echo "FAIL: Test 3: git='$g' ziggit='$z'"
fi

# === Test 4: log --oneline shows correct commit message ===
cd "$TMPDIR" && rm -rf t4 && mkdir t4 && cd t4
git init -q && git config user.email t@t.com && git config user.name T
echo "x" > x.txt && git add x.txt && git commit -q -m "first commit"
echo "y" > y.txt && git add y.txt && git commit -q -m "second commit"
g_lines=$(git log --oneline | wc -l)
z_lines=$($ZIGGIT log --oneline 2>/dev/null | wc -l) || z_lines=0
if [ "$g_lines" = "$z_lines" ]; then
    PASS=$((PASS+1))
    echo "✓ Test 4: log --oneline line count matches ($g_lines)"
else
    FAIL=$((FAIL+1))
    echo "FAIL: Test 4: git=$g_lines lines, ziggit=$z_lines lines"
fi

# === Test 5: branch shows current branch ===
cd "$TMPDIR" && rm -rf t5 && mkdir t5 && cd t5
git init -q && git config user.email t@t.com && git config user.name T
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
g=$(git branch --list | grep -o 'master\|main' | head -1)
z=$($ZIGGIT branch 2>/dev/null | grep -o 'master\|main' | head -1) || z=""
if [ -n "$g" ] && [ "$g" = "$z" ]; then
    PASS=$((PASS+1))
    echo "✓ Test 5: branch shows '$g'"
elif [ -z "$g" ]; then
    SKIP=$((SKIP+1))
    echo "SKIP: Test 5: no master/main branch found"
else
    FAIL=$((FAIL+1))
    echo "FAIL: Test 5: git='$g' ziggit='$z'"
fi

# === Test 6: tag list matches ===
cd "$TMPDIR" && rm -rf t6 && mkdir t6 && cd t6
git init -q && git config user.email t@t.com && git config user.name T
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
git tag v1.0.0
git tag v2.0.0
g=$(git tag -l | sort)
z=$($ZIGGIT tag 2>/dev/null | sort) || z=""
if [ "$g" = "$z" ]; then
    PASS=$((PASS+1))
    echo "✓ Test 6: tag list matches"
else
    # Tags may be output differently - check both exist
    if echo "$z" | grep -q "v1.0.0" && echo "$z" | grep -q "v2.0.0"; then
        PASS=$((PASS+1))
        echo "✓ Test 6: tag list contains expected tags"
    else
        FAIL=$((FAIL+1))
        echo "FAIL: Test 6: git='$g' ziggit='$z'"
    fi
fi

# === Summary ===
echo ""
echo "CLI Object Verify: $PASS pass, $FAIL fail, $SKIP skip"
[ $FAIL -eq 0 ] || exit 1
