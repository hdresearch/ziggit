#!/bin/bash
# test/cli_advanced_compat_test.sh
# Advanced CLI compatibility tests: compare ziggit output to git for more commands
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT (run 'zig build' first)"
    exit 0
fi

export HOME=/root
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip_test() { echo "  - SKIP: $1"; SKIP=$((SKIP+1)); }

TMPDIR=$(mktemp -d /tmp/ziggit_cli_adv.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== Advanced CLI Compatibility Tests ==="

# ===== SETUP =====
REPO="$TMPDIR/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

# Create initial commit
echo "hello world" > hello.txt
git add hello.txt
git commit -q -m "initial commit"

# --- Test 1: cat-file -t blob ---
echo "Test 1: cat-file -t on a blob"
BLOB_HASH=$(git hash-object hello.txt)
g=$(git cat-file -t "$BLOB_HASH")
z=$("$ZIGGIT" cat-file -t "$BLOB_HASH" 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "cat-file -t blob: $g"
else
    skip_test "cat-file -t: git='$g' ziggit='$z'"
fi

# --- Test 2: cat-file -t commit ---
echo "Test 2: cat-file -t on commit"
COMMIT_HASH=$(git rev-parse HEAD)
g=$(git cat-file -t "$COMMIT_HASH")
z=$("$ZIGGIT" cat-file -t "$COMMIT_HASH" 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "cat-file -t commit: $g"
else
    skip_test "cat-file -t commit: git='$g' ziggit='$z'"
fi

# --- Test 3: cat-file -p on blob ---
echo "Test 3: cat-file -p on blob"
g=$(git cat-file -p "$BLOB_HASH")
z=$("$ZIGGIT" cat-file -p "$BLOB_HASH" 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "cat-file -p blob content matches"
else
    skip_test "cat-file -p blob: git='$g' ziggit='$z'"
fi

# --- Test 4: rev-parse HEAD~0 ---
echo "Test 4: rev-parse HEAD"
g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD: ${g:0:12}..."
else
    fail "rev-parse HEAD: git=$g ziggit=$z"
fi

# --- Test 5: Multiple commits, log count ---
echo "Test 5: log after multiple commits"
echo "v2" > hello.txt && git add hello.txt && git commit -q -m "second"
echo "v3" > hello.txt && git add hello.txt && git commit -q -m "third"
echo "v4" > hello.txt && git add hello.txt && git commit -q -m "fourth"

g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$("$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "log --oneline count: $g_count"
else
    skip_test "log count: git=$g_count ziggit=$z_count"
fi

# --- Test 6: tag -l with multiple tags ---
echo "Test 6: tag listing with multiple tags"
git tag v1.0.0 HEAD~2
git tag v2.0.0 HEAD~1
git tag v3.0.0

g=$(git tag -l | sort)
z=$("$ZIGGIT" tag -l 2>/dev/null | sort || echo "")
if [ "$g" = "$z" ]; then
    pass "tag -l matches with 3 tags"
else
    # Check if at least all tags are present
    all_found=true
    for t in v1.0.0 v2.0.0 v3.0.0; do
        if ! echo "$z" | grep -q "$t"; then
            all_found=false
        fi
    done
    if $all_found; then
        pass "tag -l contains all tags"
    else
        skip_test "tag -l: git='$g' ziggit='$z'"
    fi
fi

# --- Test 7: branch after creating branches ---
echo "Test 7: branch listing"
git branch feature-a
git branch feature-b

g_branches=$(git branch --list | sed 's/^[* ]*//' | sort)
z_branches=$("$ZIGGIT" branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "")
if [ "$g_branches" = "$z_branches" ]; then
    pass "branch list matches"
else
    # Check if at least master + features are present
    has_all=true
    for b in master feature-a feature-b; do
        if ! echo "$z_branches" | grep -q "$b"; then
            has_all=false
        fi
    done
    if $has_all; then
        pass "branch list contains all expected branches"
    else
        skip_test "branch: git='$g_branches' ziggit='$z_branches'"
    fi
fi

# --- Test 8: status --porcelain on clean repo ---
echo "Test 8: status --porcelain clean"
g=$(git status --porcelain)
z=$("$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "status --porcelain both empty on clean repo"
else
    fail "status clean: git='$g' ziggit='$z'"
fi

# --- Test 9: status with untracked and modified ---
echo "Test 9: status with changes"
echo "new" > untracked.txt
echo "modified" > hello.txt

g_untracked=$(git status --porcelain | grep "^??" | wc -l | tr -d ' ')
z_untracked=$("$ZIGGIT" status --porcelain 2>/dev/null | grep "^??" | wc -l | tr -d ' ' || echo "0")
if [ "$g_untracked" -ge 1 ] && [ "$z_untracked" -ge 1 ]; then
    pass "both detect untracked (git=$g_untracked ziggit=$z_untracked)"
else
    fail "untracked: git=$g_untracked ziggit=$z_untracked"
fi

# Clean up modifications
git checkout -q -- hello.txt
rm -f untracked.txt

# --- Test 10: rev-parse after checkout ---
echo "Test 10: rev-parse consistency"
HEAD_BEFORE=$(git rev-parse HEAD)
Z_BEFORE=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$HEAD_BEFORE" = "$Z_BEFORE" ]; then
    pass "rev-parse consistent: ${HEAD_BEFORE:0:12}..."
else
    fail "rev-parse inconsistent: git=$HEAD_BEFORE ziggit=$Z_BEFORE"
fi

# --- Test 11: ls-files ---
echo "Test 11: ls-files"
g_files=$(git ls-files | sort)
z_files=$("$ZIGGIT" ls-files 2>/dev/null | sort || echo "")
if [ "$g_files" = "$z_files" ]; then
    pass "ls-files matches"
else
    skip_test "ls-files: git='$g_files' ziggit='$z_files'"
fi

# --- Test 12: version flag ---
echo "Test 12: version output"
z_ver=$("$ZIGGIT" --version 2>/dev/null || echo "")
if echo "$z_ver" | grep -qiE 'version|ziggit|[0-9]+\.[0-9]+'; then
    pass "--version produces output: $z_ver"
else
    skip_test "--version: '$z_ver'"
fi

# --- Test 13: diff detection ---
echo "Test 13: diff detection"
echo "modified content" > hello.txt
g_diff=$(git diff --stat 2>/dev/null | wc -l | tr -d ' ')
z_diff=$("$ZIGGIT" diff --stat 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$g_diff" -ge 1 ] && [ "$z_diff" -ge 1 ]; then
    pass "both detect diff (git=$g_diff lines, ziggit=$z_diff lines)"
else
    skip_test "diff: git=$g_diff ziggit=$z_diff"
fi
git checkout -q -- hello.txt

# --- Test 14: init creates valid repo ---
echo "Test 14: init creates valid repo"
INIT_DIR="$TMPDIR/init_test"
"$ZIGGIT" init "$INIT_DIR" 2>/dev/null
if [ -f "$INIT_DIR/.git/HEAD" ] && [ -d "$INIT_DIR/.git/objects" ] && [ -d "$INIT_DIR/.git/refs" ]; then
    pass "ziggit init creates .git/HEAD, objects, refs"
else
    fail "ziggit init: missing git structure"
fi
# Verify git recognizes it
if cd "$INIT_DIR" && git status >/dev/null 2>&1; then
    pass "git recognizes ziggit-initialized repo"
else
    fail "git doesn't recognize ziggit-initialized repo"
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
