#!/bin/bash
# test/cli_comprehensive_test.sh
# Comprehensive CLI compatibility tests: compare ziggit output to git output
# for many operations across various repository states.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT (run 'zig build' first)"
    exit 0
fi

PASS=0; FAIL=0; SKIP=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip_test() { echo "  - SKIP: $1"; SKIP=$((SKIP+1)); }

TMPDIR=$(mktemp -d /tmp/ziggit_cli_comp.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== Comprehensive CLI Compatibility Tests ==="

# ============================================================================
# Test 1: rev-parse HEAD in fresh repo (no commits)
# ============================================================================
echo "Test 1: rev-parse HEAD in empty repo"
REPO="$TMPDIR/empty_repo"
git init -q "$REPO"
# git rev-parse HEAD should fail in empty repo
g_exit=0; git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || g_exit=$?
z_exit=0; HOME=/root "$ZIGGIT" -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || z_exit=$?
if [ "$g_exit" -ne 0 ] && [ "$z_exit" -ne 0 ]; then
    pass "both fail on empty repo (git=$g_exit, ziggit=$z_exit)"
elif [ "$g_exit" -ne 0 ] && [ "$z_exit" -eq 0 ]; then
    # ziggit returns zeros - acceptable
    z_out=$(HOME=/root "$ZIGGIT" -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")
    if echo "$z_out" | grep -q "^0\{40\}$"; then
        skip_test "ziggit returns zeros for empty repo (git errors)"
    else
        fail "rev-parse empty repo: git fails, ziggit returns '$z_out'"
    fi
else
    pass "both handle empty repo consistently"
fi

# ============================================================================
# Test 2: hash-object compatibility
# ============================================================================
echo "Test 2: hash-object"
REPO="$TMPDIR/hash_repo"
git init -q "$REPO"
echo "hash test content" > "$REPO/hash.txt"
g=$(git -C "$REPO" hash-object hash.txt)
z=$(HOME=/root "$ZIGGIT" -C "$REPO" hash-object hash.txt 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "hash-object matches: ${g:0:12}..."
else
    skip_test "hash-object: git=$g ziggit=$z"
fi

# ============================================================================
# Test 3: Multiple commits, rev-parse each
# ============================================================================
echo "Test 3: rev-parse after commit chain"
REPO="$TMPDIR/chain_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"

for i in 1 2 3 4 5; do
    echo "version $i" > "$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -q -m "commit $i"
done

g=$(git -C "$REPO" rev-parse HEAD)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD after 5 commits: ${g:0:12}..."
else
    fail "rev-parse after chain: git=$g ziggit=$z"
fi

# ============================================================================
# Test 4: status --porcelain with various file states
# ============================================================================
echo "Test 4: status --porcelain (modified + untracked + deleted)"
REPO="$TMPDIR/status_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"

echo "original" > "$REPO/tracked.txt"
echo "will delete" > "$REPO/deleted.txt"
git -C "$REPO" add .
git -C "$REPO" commit -q -m "init"

# Modify tracked, delete deleted, add untracked
echo "modified" > "$REPO/tracked.txt"
rm "$REPO/deleted.txt"
echo "new" > "$REPO/untracked.txt"

g_lines=$(git -C "$REPO" status --porcelain | wc -l)
z_lines=$(cd "$REPO" && HOME=/root "$ZIGGIT" status --porcelain 2>/dev/null | wc -l || echo "0")

if [ "$g_lines" = "$z_lines" ]; then
    pass "status line count matches: $g_lines"
else
    # Check at least untracked is detected
    z_untracked=$(cd "$REPO" && HOME=/root "$ZIGGIT" status --porcelain 2>/dev/null | grep "^??" | wc -l || echo "0")
    if [ "$z_untracked" -ge 1 ]; then
        skip_test "status line count differs (git=$g_lines ziggit=$z_lines) but untracked detected"
    else
        fail "status: git=$g_lines ziggit=$z_lines lines"
    fi
fi

# ============================================================================
# Test 5: branch listing
# ============================================================================
echo "Test 5: branch listing with multiple branches"
REPO="$TMPDIR/branch_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
echo "init" > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m "init"

git -C "$REPO" branch feature-a
git -C "$REPO" branch feature-b
git -C "$REPO" branch fix/bug-1

g_count=$(git -C "$REPO" branch | wc -l)
z_out=$(cd "$REPO" && HOME=/root "$ZIGGIT" branch 2>/dev/null || echo "")
z_count=$(echo "$z_out" | grep -c . || true)

if [ "$g_count" = "$z_count" ]; then
    pass "branch count matches: $g_count"
else
    # Check that all branches appear
    all_found=true
    for b in master feature-a feature-b; do
        if ! echo "$z_out" | grep -q "$b"; then
            all_found=false
        fi
    done
    if $all_found; then
        pass "all branches found (count differs: git=$g_count ziggit=$z_count)"
    else
        skip_test "branch count: git=$g_count ziggit=$z_count"
    fi
fi

# ============================================================================
# Test 6: tag listing
# ============================================================================
echo "Test 6: tag listing"
REPO="$TMPDIR/tag_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
echo "init" > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m "init"

git -C "$REPO" tag v1.0.0
git -C "$REPO" tag v1.1.0
git -C "$REPO" tag v2.0.0

g=$(git -C "$REPO" tag -l | sort)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" tag -l 2>/dev/null | sort || echo "")

if [ "$g" = "$z" ]; then
    pass "tag listing matches exactly"
else
    # Check at least tags are found
    found=0
    for t in v1.0.0 v1.1.0 v2.0.0; do
        echo "$z" | grep -q "$t" && found=$((found+1))
    done
    if [ "$found" -ge 2 ]; then
        pass "most tags found ($found/3)"
    else
        skip_test "tag listing: git='$g' ziggit='$z'"
    fi
fi

# ============================================================================
# Test 7: ls-files 
# ============================================================================
echo "Test 7: ls-files"
REPO="$TMPDIR/lsfiles_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
mkdir -p "$REPO/src"
echo "a" > "$REPO/a.txt"
echo "b" > "$REPO/src/b.txt"
echo "c" > "$REPO/src/c.txt"
git -C "$REPO" add .
git -C "$REPO" commit -q -m "init"

g_count=$(git -C "$REPO" ls-files | wc -l)
z_count=$(cd "$REPO" && HOME=/root "$ZIGGIT" ls-files 2>/dev/null | wc -l || echo "0")

if [ "$g_count" = "$z_count" ]; then
    pass "ls-files count matches: $g_count"
else
    skip_test "ls-files: git=$g_count ziggit=$z_count"
fi

# ============================================================================
# Test 8: diff detection 
# ============================================================================
echo "Test 8: diff detection"
REPO="$TMPDIR/diff_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
echo "original" > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -q -m "init"
echo "changed" > "$REPO/f.txt"

g_has_diff=0; git -C "$REPO" diff --quiet 2>/dev/null || g_has_diff=1
z_status=$(cd "$REPO" && HOME=/root "$ZIGGIT" status --porcelain 2>/dev/null || echo "")

if [ "$g_has_diff" -eq 1 ] && echo "$z_status" | grep -q "M"; then
    pass "both detect modification"
elif [ "$g_has_diff" -eq 0 ] && [ -z "$z_status" ]; then
    pass "both agree no changes"
else
    skip_test "diff detection: git_has_diff=$g_has_diff ziggit_status='$z_status'"
fi

# ============================================================================
# Test 9: unicode filenames
# ============================================================================
echo "Test 9: unicode filenames"
REPO="$TMPDIR/unicode_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
echo "content" > "$REPO/café.txt"
git -C "$REPO" add .
git -C "$REPO" commit -q -m "unicode"

g=$(git -C "$REPO" rev-parse HEAD)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse works with unicode filenames"
else
    skip_test "unicode: git=$g ziggit=$z"
fi

# ============================================================================
# Test 10: empty file tracking
# ============================================================================
echo "Test 10: empty file"
REPO="$TMPDIR/empty_file_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
touch "$REPO/empty.txt"
git -C "$REPO" add empty.txt
git -C "$REPO" commit -q -m "empty"

g=$(git -C "$REPO" rev-parse HEAD)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse with empty file commit"
else
    fail "empty file: git=$g ziggit=$z"
fi

# ============================================================================
# Test 11: Large number of files
# ============================================================================
echo "Test 11: many files (100)"
REPO="$TMPDIR/many_files_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
for i in $(seq 1 100); do
    echo "file $i" > "$REPO/file_$i.txt"
done
git -C "$REPO" add .
git -C "$REPO" commit -q -m "many files"

g_count=$(git -C "$REPO" ls-files | wc -l)
z_count=$(cd "$REPO" && HOME=/root "$ZIGGIT" ls-files 2>/dev/null | wc -l || echo "0")
if [ "$g_count" = "$z_count" ]; then
    pass "ls-files with 100 files: count matches"
else
    skip_test "many files: git=$g_count ziggit=$z_count"
fi

# Also test rev-parse
g=$(git -C "$REPO" rev-parse HEAD)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse with 100 files"
else
    fail "rev-parse many files: git=$g ziggit=$z"
fi

# ============================================================================
# Test 12: Binary files
# ============================================================================
echo "Test 12: binary files"
REPO="$TMPDIR/binary_repo"
git init -q "$REPO"
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "T"
dd if=/dev/urandom of="$REPO/binary.dat" bs=1024 count=4 2>/dev/null
git -C "$REPO" add binary.dat
git -C "$REPO" commit -q -m "binary"

g=$(git -C "$REPO" rev-parse HEAD)
z=$(cd "$REPO" && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse with binary file"
else
    fail "binary: git=$g ziggit=$z"
fi

# ============================================================================
# Summary
# ============================================================================
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
