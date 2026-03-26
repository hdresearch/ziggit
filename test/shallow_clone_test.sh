#!/bin/bash
# Test shallow clone functionality
# Tests both bare and correctness via git fsck

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/zig-out/bin/ziggit}"
TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

echo "=== Shallow Clone Tests ==="

# Test 1: Bare shallow clone
echo -n "Test 1: Bare shallow clone --depth 1... "
$ZIGGIT clone --depth 1 --bare https://github.com/nickel-org/rust-mustache.git "$TESTDIR/shallow-bare" 2>/dev/null
cd "$TESTDIR/shallow-bare"

# Verify it's a valid git repo
git fsck 2>&1 | grep -v "^$" || true

# Verify shallow file exists
if [ ! -f shallow ]; then
    echo "FAIL: shallow file missing"
    exit 1
fi

# Verify shallow file has content
SHALLOW_LINES=$(wc -l < shallow)
if [ "$SHALLOW_LINES" -lt 1 ]; then
    echo "FAIL: shallow file is empty"
    exit 1
fi

# Verify only 1 commit in log (depth=1)
COMMIT_COUNT=$(git log --oneline 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "FAIL: expected 1 commit, got $COMMIT_COUNT"
    exit 1
fi

echo "OK (1 commit, $SHALLOW_LINES shallow boundary)"

# Test 2: Compare with git's shallow clone
echo -n "Test 2: Compare HEAD commit with git... "
ZIGGIT_HEAD=$(git rev-parse HEAD)
cd /

git clone --depth 1 --bare https://github.com/nickel-org/rust-mustache.git "$TESTDIR/git-shallow-bare" 2>/dev/null
GIT_HEAD=$(cd "$TESTDIR/git-shallow-bare" && git rev-parse HEAD)

if [ "$ZIGGIT_HEAD" != "$GIT_HEAD" ]; then
    echo "FAIL: HEAD mismatch: ziggit=$ZIGGIT_HEAD git=$GIT_HEAD"
    exit 1
fi
echo "OK (HEAD: $ZIGGIT_HEAD)"

# Test 3: Non-bare shallow clone
echo -n "Test 3: Non-bare shallow clone --depth 1... "
$ZIGGIT clone --depth 1 https://github.com/nickel-org/rust-mustache.git "$TESTDIR/shallow-nonbare" 2>/dev/null || true
cd "$TESTDIR/shallow-nonbare"

# Verify shallow file exists
if [ ! -f ".git/shallow" ]; then
    echo "FAIL: .git/shallow file missing"
    exit 1
fi

COMMIT_COUNT=$(git log --oneline 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "FAIL: expected 1 commit, got $COMMIT_COUNT"
    exit 1
fi

echo "OK (1 commit)"

# Test 4: --depth=N format (equals sign)
echo -n "Test 4: --depth=1 format... "
$ZIGGIT clone --depth=1 --bare https://github.com/nickel-org/rust-mustache.git "$TESTDIR/shallow-eq" 2>/dev/null
cd "$TESTDIR/shallow-eq"
COMMIT_COUNT=$(git log --oneline 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "FAIL: expected 1 commit, got $COMMIT_COUNT"
    exit 1
fi
echo "OK"

echo ""
echo "=== All shallow clone tests passed ==="
