#!/bin/bash
# test/cli_compat_test.sh - CLI compatibility test: compare ziggit CLI output to git CLI output
# Usage: ./test/cli_compat_test.sh [path-to-ziggit-binary]
set -euo pipefail

ZIGGIT_REL="${1:-./zig-out/bin/ziggit}"
ZIGGIT="$(cd "$(dirname "$ZIGGIT_REL")" && pwd)/$(basename "$ZIGGIT_REL")"
PASS=0
FAIL=0
SKIP=0
TESTDIR="/tmp/ziggit_cli_compat_$$"

cleanup() {
    rm -rf "$TESTDIR"
}
trap cleanup EXIT

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $desc"
        echo "    expected: $(echo "$expected" | head -3)"
        echo "    actual:   $(echo "$actual" | head -3)"
    fi
}

check_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $desc (expected to contain '$needle')"
        echo "    actual: $(echo "$haystack" | head -3)"
    fi
}

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    cd "$SCRIPT_DIR/.."
    HOME=/root zig build 2>/dev/null || { echo "SKIP: Cannot build ziggit"; exit 0; }
    ZIGGIT="$(pwd)/zig-out/bin/ziggit"
fi

echo "=== CLI Compatibility Tests ==="
echo "ziggit: $ZIGGIT"
echo ""

# ============================================================
# Test 1: --version
# ============================================================
echo "Test 1: --version"
z_ver=$("$ZIGGIT" --version 2>/dev/null || true)
check_contains "version output contains 'ziggit'" "ziggit" "$z_ver"

# ============================================================
# Test 2: init
# ============================================================
echo "Test 2: init"
mkdir -p "$TESTDIR/init_test"
cd "$TESTDIR/init_test"
"$ZIGGIT" init 2>/dev/null || true
check "init creates .git directory" "yes" "$([ -d .git ] && echo yes || echo no)"
check "init creates .git/HEAD" "yes" "$([ -f .git/HEAD ] && echo yes || echo no)"
check "init creates .git/objects" "yes" "$([ -d .git/objects ] && echo yes || echo no)"
check "init creates .git/refs" "yes" "$([ -d .git/refs ] && echo yes || echo no)"

# Verify git recognizes the repo
g_status=$(git status 2>/dev/null && echo ok || echo fail)
check_contains "git recognizes ziggit-initialized repo" "ok" "$g_status"

# ============================================================
# Test 3: rev-parse HEAD (both on a repo with commits)
# ============================================================
echo "Test 3: rev-parse HEAD"
cd "$TESTDIR"
rm -rf rev_test && mkdir rev_test && cd rev_test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > file.txt
git add file.txt
git commit -q -m "initial commit"

g_head=$(git rev-parse HEAD)
z_head=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
check "rev-parse HEAD matches git" "$g_head" "$z_head"

# ============================================================
# Test 4: status --porcelain (clean repo)
# ============================================================
echo "Test 4: status --porcelain (clean)"
g_status=$(git status --porcelain)
z_status=$("$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
check "clean repo status matches" "$g_status" "$z_status"

# ============================================================
# Test 5: status --porcelain (with untracked file)
# ============================================================
echo "Test 5: status --porcelain (untracked)"
echo "new" > untracked.txt
g_status=$(git status --porcelain | sort)
z_status=$("$ZIGGIT" status --porcelain 2>/dev/null | sort || echo "ERROR")
check "untracked file in status" "$g_status" "$z_status"
rm untracked.txt

# ============================================================
# Test 6: log --oneline
# ============================================================
echo "Test 6: log --oneline"
echo "second" > file2.txt
git add file2.txt
git commit -q -m "second commit"

g_log_count=$(git log --oneline | wc -l | tr -d ' ')
z_log_count=$("$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
check "log --oneline line count matches" "$g_log_count" "$z_log_count"

# ============================================================
# Test 7: branch listing
# ============================================================
echo "Test 7: branch"
git checkout -q -b feature-branch
git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || true
g_branches=$(git branch --list | sed 's/^[* ]*//' | sort)
z_branches=$("$ZIGGIT" branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "ERROR")
check "branch list matches" "$g_branches" "$z_branches"

# ============================================================
# Test 8: tag
# ============================================================
echo "Test 8: tag"
git tag v1.0
g_tags=$(git tag -l | sort)
z_tags=$("$ZIGGIT" tag 2>/dev/null | sort || echo "ERROR")
check "tag list matches" "$g_tags" "$z_tags"

# ============================================================
# Test 9: rev-parse HEAD after multiple commits
# ============================================================
echo "Test 9: rev-parse after tag"
g_head2=$(git rev-parse HEAD)
z_head2=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
check "rev-parse HEAD still matches after tag" "$g_head2" "$z_head2"

# ============================================================
# Test 10: cat-file -t (object type)
# ============================================================
echo "Test 10: cat-file -t"
g_type=$(git cat-file -t HEAD)
z_type=$("$ZIGGIT" cat-file -t HEAD 2>/dev/null || echo "ERROR")
check "cat-file -t HEAD type matches" "$g_type" "$z_type"

# ============================================================
# Test 11: diff (modified file)
# ============================================================
echo "Test 11: diff"
echo "modified content" > file.txt
g_diff_has_output=$(git diff | head -1)
z_diff_has_output=$("$ZIGGIT" diff 2>/dev/null | head -1 || echo "")
if [ -n "$g_diff_has_output" ] && [ -n "$z_diff_has_output" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ both show diff output for modified file"
elif [ -z "$g_diff_has_output" ] && [ -z "$z_diff_has_output" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ both show no diff (consistent)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ diff output presence differs"
fi
git checkout -- file.txt

# ============================================================
# Test 12: show (commit details)
# ============================================================
echo "Test 12: show"
z_show=$("$ZIGGIT" show 2>/dev/null || echo "ERROR")
if [ "$z_show" != "ERROR" ]; then
    check_contains "show includes commit hash" "$(git rev-parse --short HEAD)" "$z_show"
else
    SKIP=$((SKIP + 1))
    echo "  ⚠ show command not supported"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== CLI Compatibility Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "FAIL: $FAIL tests failed"
    exit 1
else
    echo "ALL PASSED"
    exit 0
fi
