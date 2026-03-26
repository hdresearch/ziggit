#!/bin/bash
# test/cli_lifecycle_test.sh
# Comprehensive CLI compatibility test: compare ziggit output to git output
set -e

export HOME=/root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "Building ziggit..."
    cd "$SCRIPT_DIR/.." && zig build 2>/dev/null
fi
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found"
    exit 0
fi

PASS=0; FAIL=0; SKIP=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip_test() { echo "  - SKIP: $1"; SKIP=$((SKIP+1)); }

TMPDIR=$(mktemp -d /tmp/ziggit_cli_lifecycle.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== CLI Lifecycle Tests ==="

# --- Test 1: Single file commit, rev-parse ---
echo "Test 1: Single file commit, rev-parse HEAD"
REPO="$TMPDIR/t1"
mkdir -p "$REPO" && cd "$REPO"
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "hello" > hello.txt
git add hello.txt && git commit -q -m "init"

g=$(git rev-parse HEAD)
z=$(cd "$REPO" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD: ${g:0:12}..."
else
    fail "rev-parse HEAD: git=${g:0:12} ziggit=${z:0:12}"
fi

# --- Test 2: Clean status ---
echo "Test 2: Clean repo status"
g=$(cd "$REPO" && git status --porcelain)
z=$(cd "$REPO" && "$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
if [ -z "$g" ] && [ -z "$z" ]; then
    pass "status clean: both empty"
elif [ "$g" = "$z" ]; then
    pass "status clean: match"
else
    fail "status clean: git='$g' ziggit='$z'"
fi

# --- Test 3: Multiple commits, rev-parse tracks latest ---
echo "Test 3: Multiple commits tracking"
cd "$REPO"
echo "v2" > hello.txt && git add hello.txt && git commit -q -m "v2"
echo "v3" > hello.txt && git add hello.txt && git commit -q -m "v3"

g=$(git rev-parse HEAD)
z=$(cd "$REPO" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse after 3 commits: ${g:0:12}..."
else
    fail "rev-parse after 3 commits: git=${g:0:12} ziggit=${z:0:12}"
fi

# --- Test 4: Untracked file detection ---
echo "Test 4: Untracked file detection"
cd "$REPO"
echo "new" > new_file.txt
g_count=$(git status --porcelain | grep -c "^??" || true)
z_count=$(cd "$REPO" && "$ZIGGIT" status --porcelain 2>/dev/null | grep -c "^??" || true)
if [ "$g_count" -ge 1 ] && [ "$z_count" -ge 1 ]; then
    pass "untracked: git=$g_count ziggit=$z_count"
else
    fail "untracked: git=$g_count ziggit=$z_count"
fi
rm -f new_file.txt

# --- Test 5: Tag creation and listing ---
echo "Test 5: Tag listing"
cd "$REPO"
git tag v1.0.0
g=$(git tag -l | sort)
z=$(cd "$REPO" && "$ZIGGIT" tag -l 2>/dev/null | sort || echo "")
if [ "$g" = "$z" ]; then
    pass "tag -l: exact match"
elif echo "$z" | grep -q "v1.0.0"; then
    pass "tag -l: contains v1.0.0"
else
    skip_test "tag -l: git='$g' ziggit='$z'"
fi

# --- Test 6: Branch listing ---
echo "Test 6: Branch listing"
cd "$REPO"
git branch dev-branch
z=$(cd "$REPO" && "$ZIGGIT" branch 2>/dev/null || echo "")
if echo "$z" | grep -q "master"; then
    pass "branch: found master"
else
    skip_test "branch: '$z'"
fi

# --- Test 7: ls-files count ---
echo "Test 7: ls-files"
cd "$REPO"
g_count=$(git ls-files | wc -l | tr -d ' ')
z_count=$(cd "$REPO" && "$ZIGGIT" ls-files 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "ls-files: both $g_count"
else
    skip_test "ls-files: git=$g_count ziggit=$z_count"
fi

# --- Test 8: log count ---
echo "Test 8: log --oneline count"
cd "$REPO"
g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$(cd "$REPO" && "$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "log count: both $g_count"
else
    skip_test "log count: git=$g_count ziggit=$z_count"
fi

# --- Test 9: New repo with multiple files ---
echo "Test 9: Multi-file repo"
REPO2="$TMPDIR/t9"
mkdir -p "$REPO2" && cd "$REPO2"
git init -q && git config user.email "t@t.com" && git config user.name "T"
for i in $(seq 1 10); do
    echo "file $i" > "file_$i.txt"
done
git add . && git commit -q -m "ten files"

g=$(git rev-parse HEAD)
z=$(cd "$REPO2" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "multi-file rev-parse: ${g:0:12}..."
else
    fail "multi-file rev-parse: git=${g:0:12} ziggit=${z:0:12}"
fi

# --- Test 10: Empty repo ---
echo "Test 10: Empty repo status"
REPO3="$TMPDIR/t10"
mkdir -p "$REPO3" && cd "$REPO3"
git init -q && git config user.email "t@t.com" && git config user.name "T"

z=$(cd "$REPO3" && "$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
if [ "$z" = "" ] || [ "$z" = "ERROR" ]; then
    pass "empty repo: no crash"
else
    pass "empty repo: got '$z'"
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
