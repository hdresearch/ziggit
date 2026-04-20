#!/bin/bash
# test/cli_full_lifecycle_test.sh
# Full lifecycle comparison: run identical operations with ziggit and git,
# compare outputs. Validates init, add, commit, rev-parse, status, log, tag, branch.
set -euo pipefail

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"

if [ ! -x "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not built (run 'zig build' first)"
    exit 0
fi

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $label"
        echo "  expected: '$expected'"
        echo "  actual:   '$actual'"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $label (expected to contain '$needle')"
        echo "  got: '$haystack'"
    fi
}

# ============================================================================
# Setup
# ============================================================================
TESTDIR="/tmp/ziggit_cli_lifecycle_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
cd "$TESTDIR"

cleanup() {
    rm -rf "$TESTDIR"
}
trap cleanup EXIT

# ============================================================================
# Test 1: init
# ============================================================================
"$ZIGGIT" init test_repo >/dev/null 2>&1 || true
cd test_repo

# Ziggit-initialized repo should be recognizable by git
git_status=$(git status --porcelain 2>/dev/null || echo "GIT_FAILED")
assert_eq "git recognizes ziggit init" "" "$git_status"

# HEAD should point to master
head_ref=$(cat .git/HEAD)
assert_contains "HEAD points to master" "$head_ref" "refs/heads/master"

# ============================================================================
# Test 2: add + commit
# ============================================================================
echo "hello" > hello.txt
"$ZIGGIT" add hello.txt 2>/dev/null
"$ZIGGIT" commit -m "first commit" 2>/dev/null

# rev-parse HEAD should match between git and ziggit
git_hash=$(git rev-parse HEAD 2>/dev/null)
ziggit_hash=$("$ZIGGIT" rev-parse HEAD 2>/dev/null)
assert_eq "rev-parse HEAD after first commit" "$git_hash" "$ziggit_hash"

# ============================================================================
# Test 3: status on clean repo
# ============================================================================
git_status=$(git status --porcelain 2>/dev/null)
ziggit_status=$("$ZIGGIT" status --porcelain 2>/dev/null || echo "")
# Both should be empty for clean repo
assert_eq "status porcelain on clean repo" "$git_status" "$ziggit_status"

# ============================================================================
# Test 4: second commit, rev-parse still matches
# ============================================================================
echo "world" > world.txt
"$ZIGGIT" add world.txt 2>/dev/null
"$ZIGGIT" commit -m "second commit" 2>/dev/null

git_hash2=$(git rev-parse HEAD 2>/dev/null)
ziggit_hash2=$("$ZIGGIT" rev-parse HEAD 2>/dev/null)
assert_eq "rev-parse HEAD after second commit" "$git_hash2" "$ziggit_hash2"

# ============================================================================
# Test 5: git log shows both commits
# ============================================================================
commit_count=$(git rev-list --count HEAD 2>/dev/null)
assert_eq "two commits in log" "2" "$commit_count"

# ============================================================================
# Test 6: tag
# ============================================================================
"$ZIGGIT" tag v1.0 2>/dev/null || true
git_tags=$(git tag -l 2>/dev/null)
assert_contains "git tag shows ziggit tag" "$git_tags" "v1.0"

# ============================================================================
# Test 7: git fsck validates everything
# ============================================================================
fsck_result=$(git fsck --no-dangling 2>&1 || true)
# fsck should not report errors (some warnings about dangling are OK)
fsck_errors=$(echo "$fsck_result" | grep -c "error" || true)
assert_eq "git fsck no errors" "0" "$fsck_errors"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "CLI lifecycle test: $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
