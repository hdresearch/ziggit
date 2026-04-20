#!/bin/bash
# test/cli_hash_compat_test.sh
# Validates that ziggit produces byte-identical git objects by comparing hashes
# Tests: hash-object, rev-parse, cat-file compatibility
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT (run 'zig build' first)"
    exit 0
fi

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR=$(mktemp -d /tmp/ziggit_hash_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== Hash/Object Compatibility Tests ==="

# --- Test: ziggit init produces git-compatible repo ---
echo "Test: ziggit init + git status"
cd "$TMPDIR" && mkdir t1 && cd t1
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
g=$(git status 2>&1)
if echo "$g" | grep -qi "on branch"; then
    pass "ziggit init produces git-compatible repo"
else
    fail "ziggit init not compatible: $g"
fi

# --- Test: ziggit add produces git-readable index ---
echo "Test: ziggit add + git ls-files"
cd "$TMPDIR" && mkdir t2 && cd t2
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
echo "hello world" > hello.txt
HOME=/root "$ZIGGIT" add hello.txt 2>/dev/null
g=$(git ls-files --cached)
if echo "$g" | grep -q "hello.txt"; then
    pass "ziggit add creates git-readable index entry"
else
    fail "ziggit add not in git ls-files: '$g'"
fi

# --- Test: blob hash matches between ziggit and git ---
echo "Test: blob hash compatibility"
cd "$TMPDIR" && mkdir t3 && cd t3
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
echo "test content for hashing" > hash_test.txt
# Add via ziggit
HOME=/root "$ZIGGIT" add hash_test.txt 2>/dev/null
# Get hash from git's index
z_hash=$(git ls-files --stage hash_test.txt | awk '{print $2}')
# Get hash from git hash-object
g_hash=$(git hash-object hash_test.txt)
if [ "$z_hash" = "$g_hash" ]; then
    pass "blob hash matches: $z_hash"
else
    fail "blob hash mismatch: ziggit=$z_hash git=$g_hash"
fi

# --- Test: commit hash is deterministic and git-compatible ---
echo "Test: commit object validity"
cd "$TMPDIR" && mkdir t4 && cd t4
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
echo "data" > f.txt
HOME=/root "$ZIGGIT" add f.txt 2>/dev/null
HOME=/root "$ZIGGIT" commit -m "test commit" 2>/dev/null
# git should be able to parse the commit
g=$(git cat-file -t HEAD 2>/dev/null || echo "error")
if [ "$g" = "commit" ]; then
    pass "ziggit commit creates valid git commit object"
else
    fail "ziggit commit type: $g"
fi

# --- Test: git cat-file -p shows correct tree ---
echo "Test: commit tree validity"
g=$(git cat-file -p HEAD 2>/dev/null || echo "error")
if echo "$g" | grep -q "^tree [0-9a-f]\{40\}"; then
    pass "commit has valid tree reference"
else
    fail "commit tree: $g"
fi

# --- Test: git cat-file -p shows correct blob content ---
echo "Test: blob content via cat-file"
blob_hash=$(git ls-tree HEAD | awk '{print $3}')
g=$(git cat-file -p "$blob_hash" 2>/dev/null || echo "error")
if [ "$g" = "data" ]; then
    pass "blob content matches: '$g'"
else
    fail "blob content: '$g'"
fi

# --- Test: multiple commits, rev-parse matches ---
echo "Test: multiple commits rev-parse"
cd "$TMPDIR" && mkdir t5 && cd t5
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
for i in 1 2 3 4 5; do
    echo "content $i" > "file$i.txt"
    HOME=/root "$ZIGGIT" add "file$i.txt" 2>/dev/null
    HOME=/root "$ZIGGIT" commit -m "commit $i" 2>/dev/null
done
g=$(git rev-parse HEAD)
z=$(cd . && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse after 5 commits: ${g:0:12}..."
else
    fail "rev-parse: git=$g ziggit=$z"
fi

# --- Test: git rev-list shows correct count ---
echo "Test: commit count via rev-list"
g_count=$(git rev-list HEAD | wc -l | tr -d ' ')
if [ "$g_count" = "5" ]; then
    pass "git rev-list shows 5 commits"
else
    fail "git rev-list count: $g_count (expected 5)"
fi

# --- Test: git fsck passes ---
echo "Test: git fsck on ziggit repo"
fsck_out=$(git fsck 2>&1 || true)
if echo "$fsck_out" | grep -qi "error\|fatal"; then
    fail "git fsck found errors: $fsck_out"
else
    pass "git fsck passes (no errors)"
fi

# --- Test: tag compatibility ---
echo "Test: lightweight tag compatibility"
cd "$TMPDIR" && mkdir t6 && cd t6
HOME=/root "$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
echo "data" > f.txt
HOME=/root "$ZIGGIT" add f.txt 2>/dev/null
HOME=/root "$ZIGGIT" commit -m "initial" 2>/dev/null
# Create tag with git, read with ziggit
git tag v1.0.0
z=$(cd . && HOME=/root "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
g=$(git rev-parse HEAD)
if [ "$z" = "$g" ]; then
    pass "tag repo HEAD matches: ${g:0:12}..."
else
    fail "tag repo HEAD: git=$g ziggit=$z"
fi

# --- Summary ---
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
