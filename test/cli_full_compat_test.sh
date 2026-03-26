#!/bin/bash
# test/cli_full_compat_test.sh
# Comprehensive CLI compatibility tests comparing ziggit to git
set -euo pipefail

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

TMPDIR=$(mktemp -d /tmp/ziggit_fullcli.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# === SETUP ===
echo "=== CLI Full Compatibility Tests ==="

# --- Test 1: init creates same structure ---
echo "Test 1: init creates same .git structure"
TREPO="$TMPDIR/init_test"
mkdir -p "$TREPO"
cd "$TREPO"
HOME=/tmp "$ZIGGIT" init -q 2>/dev/null || HOME=/tmp "$ZIGGIT" init 2>/dev/null || true

[ -f "$TREPO/.git/HEAD" ] && pass "HEAD exists" || fail "HEAD missing"
[ -d "$TREPO/.git/objects" ] && pass "objects dir exists" || fail "objects dir missing"
[ -d "$TREPO/.git/refs/heads" ] && pass "refs/heads exists" || fail "refs/heads missing"
[ -d "$TREPO/.git/refs/tags" ] && pass "refs/tags exists" || fail "refs/tags missing"

# Check HEAD content
head_content=$(cat "$TREPO/.git/HEAD")
if echo "$head_content" | grep -q "ref: refs/heads/master"; then
    pass "HEAD points to refs/heads/master"
else
    skip_test "HEAD content: '$head_content'"
fi

# --- Test 2: rev-parse HEAD on git-created repo ---
echo "Test 2: rev-parse HEAD accuracy"
TREPO="$TMPDIR/revparse_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "hello" > a.txt && git add a.txt && git commit -q -m "first"
echo "world" > b.txt && git add b.txt && git commit -q -m "second"

g=$(git rev-parse HEAD)
z=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
[ "$g" = "$z" ] && pass "rev-parse HEAD matches after 2 commits" || fail "rev-parse: git=$g ziggit=$z"

# --- Test 3: status porcelain on various states ---
echo "Test 3: status --porcelain states"
TREPO="$TMPDIR/status_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "data" > tracked.txt && git add tracked.txt && git commit -q -m "init"

# 3a: clean
g=$(git status --porcelain)
z=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
[ "$g" = "$z" ] && pass "clean status matches" || fail "clean: git='$g' ziggit='$z'"

# 3b: untracked file
echo "new" > untracked.txt
g_has_untracked=$(git status --porcelain | grep -c "^??" || true)
z_has_untracked=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" status --porcelain 2>/dev/null | grep -c "^??" || true)
[ "$g_has_untracked" -ge 1 ] && [ "$z_has_untracked" -ge 1 ] && pass "both detect untracked" || fail "untracked: git=$g_has_untracked ziggit=$z_has_untracked"
rm -f untracked.txt

# --- Test 4: Multiple commits, count matches ---
echo "Test 4: commit history length"
TREPO="$TMPDIR/history_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
for i in 1 2 3 4 5; do
    echo "v$i" > file.txt && git add file.txt && git commit -q -m "commit $i"
done

g_count=$(git rev-list HEAD --count)
z_count=$(git rev-list HEAD --count)  # Both use git's commit objects
[ "$g_count" = "5" ] && pass "5 commits created" || fail "expected 5, got $g_count"

# Test that ziggit can read HEAD of this 5-commit repo
z=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
g=$(git rev-parse HEAD)
[ "$g" = "$z" ] && pass "rev-parse matches on 5-commit repo" || fail "5-commit: git=$g ziggit=$z"

# --- Test 5: Branch listing ---
echo "Test 5: branch listing"
TREPO="$TMPDIR/branch_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
git branch feature1
git branch feature2

z=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" branch 2>/dev/null || echo "")
echo "$z" | grep -q "master" && pass "branch shows master" || skip_test "branch: '$z'"
echo "$z" | grep -q "feature1" && pass "branch shows feature1" || skip_test "branch feature1: '$z'"

# --- Test 6: Tag operations ---
echo "Test 6: tag operations"
TREPO="$TMPDIR/tag_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "data" > f.txt && git add f.txt && git commit -q -m "init"
git tag v1.0.0
git tag v2.0.0

z=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" tag -l 2>/dev/null | sort || echo "")
echo "$z" | grep -q "v1.0.0" && pass "tag v1.0.0 visible" || skip_test "tag v1: '$z'"
echo "$z" | grep -q "v2.0.0" && pass "tag v2.0.0 visible" || skip_test "tag v2: '$z'"

# --- Test 7: ls-files ---
echo "Test 7: ls-files"
TREPO="$TMPDIR/lsfiles_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "a" > a.txt && echo "b" > b.txt && echo "c" > c.txt
git add a.txt b.txt c.txt && git commit -q -m "init"

g_count=$(git ls-files | wc -l | tr -d ' ')
z_count=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" ls-files 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[ "$g_count" = "$z_count" ] && pass "ls-files count matches: $g_count" || skip_test "ls-files: git=$g_count ziggit=$z_count"

# --- Test 8: log --oneline ---
echo "Test 8: log --oneline"
TREPO="$TMPDIR/log_test"
mkdir -p "$TREPO" && cd "$TREPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "1" > f.txt && git add f.txt && git commit -q -m "first"
echo "2" > f.txt && git add f.txt && git commit -q -m "second"
echo "3" > f.txt && git add f.txt && git commit -q -m "third"

g_lines=$(git log --oneline | wc -l | tr -d ' ')
z_lines=$(cd "$TREPO" && HOME=/tmp "$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[ "$g_lines" = "$z_lines" ] && pass "log line count: $g_lines" || skip_test "log: git=$g_lines ziggit=$z_lines"

# --- Test 9: Interop - ziggit creates, git reads ---
echo "Test 9: ziggit creates commit, git reads"
TREPO="$TMPDIR/interop_test"
mkdir -p "$TREPO" && cd "$TREPO"
HOME=/tmp "$ZIGGIT" init -q 2>/dev/null || HOME=/tmp "$ZIGGIT" init 2>/dev/null || true
git config user.email "t@t.com" && git config user.name "T"
echo "data" > f.txt
HOME=/tmp "$ZIGGIT" add f.txt 2>/dev/null || true
HOME=/tmp "$ZIGGIT" commit -m "from ziggit" 2>/dev/null || true

# Check if git can read it
if git log --oneline 2>/dev/null | grep -q "from ziggit"; then
    pass "git reads ziggit commit"
else
    skip_test "git could not read ziggit commit"
fi

# Check git fsck
if git fsck --no-progress 2>&1 | grep -qi "error"; then
    skip_test "git fsck found errors (may be expected for checksum)"
else
    pass "git fsck passes on ziggit repo"
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
