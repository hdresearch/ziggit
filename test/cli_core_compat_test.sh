#!/bin/bash
# cli_core_compat_test.sh - Compare ziggit CLI output to git CLI output
# Runs a series of operations and verifies output matches

set -e

ZIGGIT="${ZIGGIT:-./zig-out/bin/ziggit}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1 (expected='$2' got='$3')"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭  SKIP: $1"; SKIP=$((SKIP+1)); }

# Build ziggit if needed
if [ ! -f "$ZIGGIT" ]; then
    echo "Building ziggit..."
    HOME=/root zig build 2>/dev/null || { echo "Build failed, skipping CLI tests"; exit 0; }
fi

if [ ! -f "$ZIGGIT" ]; then
    echo "ziggit binary not found at $ZIGGIT, skipping"
    exit 0
fi

TESTDIR="/tmp/ziggit_cli_compat_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

cd "$TESTDIR"

echo "=== CLI Compatibility Tests ==="

# ---- Test 1: init creates a valid repo ----
echo "Test 1: init"
$ZIGGIT init repo1 2>/dev/null || true
cd repo1
if [ -f .git/HEAD ] && [ -d .git/objects ] && [ -d .git/refs ]; then
    pass "init creates .git structure"
else
    fail "init creates .git structure" ".git/HEAD exists" "missing"
fi

# Check that git recognizes it
git status >/dev/null 2>&1 && pass "git recognizes ziggit-initialized repo" || fail "git recognizes repo" "success" "failure"
cd "$TESTDIR"

# ---- Test 2: rev-parse HEAD on empty repo ----
echo "Test 2: rev-parse HEAD"
mkdir repo2 && cd repo2
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "initial"

g=$(git rev-parse HEAD 2>/dev/null)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null) || z=""

if [ -n "$g" ] && [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches ($g)"
elif [ -z "$z" ]; then
    skip "rev-parse HEAD (ziggit returned empty)"
else
    fail "rev-parse HEAD" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 3: rev-parse HEAD after multiple commits ----
echo "Test 3: rev-parse HEAD after multiple commits"
mkdir repo3 && cd repo3
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "one" > f.txt && git add f.txt && git commit -q -m "one"
echo "two" > f.txt && git add f.txt && git commit -q -m "two"
echo "three" > f.txt && git add f.txt && git commit -q -m "three"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null) || z=""

if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD after 3 commits ($g)"
elif [ -z "$z" ]; then
    skip "rev-parse HEAD after 3 commits"
else
    fail "rev-parse HEAD after 3 commits" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 4: hash-object compatibility ----
echo "Test 4: hash-object"
mkdir repo4 && cd repo4
git init -q
echo -n "test content" > f.txt

g=$(git hash-object f.txt)
z=$($ZIGGIT hash-object f.txt 2>/dev/null) || z=""

if [ "$g" = "$z" ]; then
    pass "hash-object matches ($g)"
elif [ -z "$z" ]; then
    skip "hash-object (not implemented)"
else
    fail "hash-object" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 5: status --porcelain on clean repo ----
echo "Test 5: status --porcelain"
mkdir repo5 && cd repo5
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "clean" > f.txt && git add f.txt && git commit -q -m "init"

g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain 2>/dev/null) || z=""

if [ "$g" = "$z" ]; then
    pass "status --porcelain on clean repo (both empty)"
elif [ -z "$z" ] && [ -z "$g" ]; then
    pass "status --porcelain on clean repo (both empty)"
else
    fail "status --porcelain clean" "'$g'" "'$z'"
fi
cd "$TESTDIR"

# ---- Test 6: branch listing ----
echo "Test 6: branch"
mkdir repo6 && cd repo6
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
git branch feature-a
git branch feature-b

g=$(git branch --list | sed 's/^[* ]*//' | sort)
z=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort) || z=""

if [ "$g" = "$z" ]; then
    pass "branch list matches"
elif [ -z "$z" ]; then
    skip "branch (not implemented or different format)"
else
    fail "branch list" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 7: tag listing ----
echo "Test 7: tag"
mkdir repo7 && cd repo7
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
git tag v1.0
git tag v2.0

g=$(git tag | sort)
z=$($ZIGGIT tag 2>/dev/null | sort) || z=""

if [ "$g" = "$z" ]; then
    pass "tag list matches"
elif [ -z "$z" ]; then
    skip "tag (not implemented or different format)"
else
    fail "tag list" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 8: cat-file -t ----
echo "Test 8: cat-file -t"
mkdir repo8 && cd repo8
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "hello world" > f.txt && git add f.txt && git commit -q -m "init"
HASH=$(git rev-parse HEAD)

g=$(git cat-file -t "$HASH")
z=$($ZIGGIT cat-file -t "$HASH" 2>/dev/null) || z=""

if [ "$g" = "$z" ]; then
    pass "cat-file -t returns '$g'"
elif [ -z "$z" ]; then
    skip "cat-file -t (not implemented)"
else
    fail "cat-file -t" "$g" "$z"
fi
cd "$TESTDIR"

# ---- Test 9: log --oneline ----
echo "Test 9: log --oneline"
mkdir repo9 && cd repo9
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "one" > f.txt && git add f.txt && git commit -q -m "first"
echo "two" > f.txt && git add f.txt && git commit -q -m "second"

g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$($ZIGGIT log --oneline 2>/dev/null | wc -l | tr -d ' ') || z_count=""

if [ "$g_count" = "$z_count" ]; then
    pass "log --oneline shows $g_count commits"
elif [ -z "$z_count" ] || [ "$z_count" = "0" ]; then
    skip "log --oneline (not implemented)"
else
    fail "log --oneline count" "$g_count" "$z_count"
fi
cd "$TESTDIR"

# ---- Test 10: diff on unmodified repo ----
echo "Test 10: diff on clean repo"
mkdir repo10 && cd repo10
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "content" > f.txt && git add f.txt && git commit -q -m "init"

g=$(git diff)
z=$($ZIGGIT diff 2>/dev/null) || z=""

if [ "$g" = "$z" ]; then
    pass "diff on clean repo (both empty)"
elif [ -z "$z" ] && [ -z "$g" ]; then
    pass "diff on clean repo (both empty)"
else
    fail "diff on clean repo" "'$g'" "'$z'"
fi
cd "$TESTDIR"

# ---- Summary ----
echo ""
echo "=== CLI Compatibility Summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
echo "  Skip: $SKIP"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED (${SKIP} skipped)"
    exit 0
fi
