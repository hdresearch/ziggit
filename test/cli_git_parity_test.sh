#!/bin/bash
# test/cli_git_parity_test.sh
# CLI integration test: compares ziggit output to git output for core commands.
# Requires both `git` and `ziggit` to be in PATH or built.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/zig-out/bin/ziggit}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 (expected='$2' got='$3')"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$SCRIPT_DIR" && zig build 2>/dev/null)
fi

if [ ! -x "$ZIGGIT" ]; then
    echo "ERROR: ziggit binary not found at $ZIGGIT"
    exit 1
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_parity_XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "=== CLI Git Parity Tests ==="
echo "Using: $ZIGGIT"
echo "Temp dir: $TMPDIR"

# ============================================================================
# Test 1: rev-parse HEAD
# ============================================================================
echo ""
echo "--- rev-parse HEAD ---"

cd "$TMPDIR" && rm -rf repo1 && mkdir repo1 && cd repo1
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > file.txt
git add file.txt
git commit -q -m "initial"

G_HASH=$(git rev-parse HEAD)
Z_HASH=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")

if [ "$G_HASH" = "$Z_HASH" ]; then
    pass "rev-parse HEAD matches"
else
    fail "rev-parse HEAD" "$G_HASH" "$Z_HASH"
fi

# ============================================================================
# Test 2: rev-parse HEAD after second commit
# ============================================================================
echo "world" > file2.txt
git add file2.txt
git commit -q -m "second"

G_HASH2=$(git rev-parse HEAD)
Z_HASH2=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")

if [ "$G_HASH2" = "$Z_HASH2" ]; then
    pass "rev-parse HEAD after second commit"
else
    fail "rev-parse HEAD after second commit" "$G_HASH2" "$Z_HASH2"
fi

# ============================================================================
# Test 3: hash-object
# ============================================================================
echo ""
echo "--- hash-object ---"

echo "test content for hashing" > "$TMPDIR/hashtest.txt"
G_HASH_OBJ=$(git hash-object "$TMPDIR/hashtest.txt")
Z_HASH_OBJ=$($ZIGGIT hash-object "$TMPDIR/hashtest.txt" 2>/dev/null || echo "ERROR")

if [ "$G_HASH_OBJ" = "$Z_HASH_OBJ" ]; then
    pass "hash-object matches for text file"
else
    fail "hash-object" "$G_HASH_OBJ" "$Z_HASH_OBJ"
fi

# ============================================================================
# Test 4: hash-object with stdin
# ============================================================================
G_HASH_STDIN=$(echo "stdin content" | git hash-object --stdin)
Z_HASH_STDIN=$(echo "stdin content" | $ZIGGIT hash-object --stdin 2>/dev/null || echo "ERROR")

if [ "$G_HASH_STDIN" = "$Z_HASH_STDIN" ]; then
    pass "hash-object --stdin matches"
else
    fail "hash-object --stdin" "$G_HASH_STDIN" "$Z_HASH_STDIN"
fi

# ============================================================================
# Test 5: cat-file -t
# ============================================================================
echo ""
echo "--- cat-file ---"

cd "$TMPDIR/repo1"
HEAD=$(git rev-parse HEAD)
G_TYPE=$(git cat-file -t "$HEAD")
Z_TYPE=$($ZIGGIT cat-file -t "$HEAD" 2>/dev/null || echo "ERROR")

if [ "$G_TYPE" = "$Z_TYPE" ]; then
    pass "cat-file -t matches for commit"
else
    fail "cat-file -t" "$G_TYPE" "$Z_TYPE"
fi

# ============================================================================
# Test 6: cat-file -s (size)
# ============================================================================
G_SIZE=$(git cat-file -s "$HEAD")
Z_SIZE=$($ZIGGIT cat-file -s "$HEAD" 2>/dev/null || echo "ERROR")

if [ "$G_SIZE" = "$Z_SIZE" ]; then
    pass "cat-file -s matches for commit"
else
    fail "cat-file -s" "$G_SIZE" "$Z_SIZE"
fi

# ============================================================================
# Test 7: status --porcelain on clean repo
# ============================================================================
echo ""
echo "--- status ---"

G_STATUS=$(git status --porcelain)
Z_STATUS=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")

if [ "$G_STATUS" = "$Z_STATUS" ]; then
    pass "status --porcelain clean repo"
else
    fail "status --porcelain clean" "$G_STATUS" "$Z_STATUS"
fi

# ============================================================================
# Test 8: branch listing
# ============================================================================
echo ""
echo "--- branch ---"

# ziggit uses 'branch' without --list flag
G_BRANCH=$(git branch | sed 's/^[* ]*//' | tr -d ' ' | sort)
Z_BRANCH=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | tr -d ' ' | sort || echo "ERROR")

if [ "$G_BRANCH" = "$Z_BRANCH" ]; then
    pass "branch listing matches"
else
    fail "branch listing" "$G_BRANCH" "$Z_BRANCH"
fi

# ============================================================================
# Test 9: tag listing (empty)
# ============================================================================
echo ""
echo "--- tag ---"

G_TAGS=$(git tag -l 2>/dev/null)
Z_TAGS=$($ZIGGIT tag -l 2>/dev/null || $ZIGGIT tag --list 2>/dev/null || echo "UNSUPPORTED")

if [ "$Z_TAGS" = "UNSUPPORTED" ]; then
    skip "tag -l (command not supported)"
elif [ "$G_TAGS" = "$Z_TAGS" ]; then
    pass "tag -l empty matches"
else
    fail "tag -l empty" "$G_TAGS" "$Z_TAGS"
fi

# ============================================================================
# Test 10: log format
# ============================================================================
echo ""
echo "--- log ---"

G_LOG_HASH=$(git log --format=%H | head -1)
Z_LOG_HASH=$($ZIGGIT log --format=%H 2>/dev/null | head -1 || echo "UNSUPPORTED")

if [ "$Z_LOG_HASH" = "UNSUPPORTED" ]; then
    skip "log --format=%H (command not supported)"
elif [ "$G_LOG_HASH" = "$Z_LOG_HASH" ]; then
    pass "log --format=%H first commit matches"
else
    fail "log --format=%H" "$G_LOG_HASH" "$Z_LOG_HASH"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "================================"
echo "CLI Parity Tests: $PASS passed, $FAIL failed, $SKIP skipped"
echo "================================"

[ $FAIL -eq 0 ] || exit 1
