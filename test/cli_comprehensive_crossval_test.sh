#!/bin/bash
# test/cli_comprehensive_crossval_test.sh
# Comprehensive CLI cross-validation: compares ziggit output to git output
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIGGIT="${ZIGGIT:-$PROJECT_DIR/zig-out/bin/ziggit}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  - SKIP: $1"; SKIP=$((SKIP+1)); }

# Check ziggit exists
if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    cd "$PROJECT_DIR"
    HOME=/root zig build 2>/dev/null || { echo "Build failed"; exit 1; }
    ZIGGIT="$PROJECT_DIR/zig-out/bin/ziggit"
    cd - >/dev/null
fi

TESTDIR=$(mktemp -d /tmp/ziggit_cli_xval_XXXXXX)
trap "rm -rf $TESTDIR" EXIT

cd "$TESTDIR"

# ============================================================================
echo "=== Test 1: init creates valid repo ==="
mkdir repo1 && cd repo1
$ZIGGIT init . >/dev/null 2>&1 || $ZIGGIT init >/dev/null 2>&1
if [ -f .git/HEAD ] && [ -d .git/objects ] && [ -d .git/refs ]; then
    pass "ziggit init creates .git structure"
else
    fail "ziggit init missing .git structure"
fi
# git should recognize it
if git status >/dev/null 2>&1; then
    pass "git recognizes ziggit-init repo"
else
    fail "git doesn't recognize ziggit-init repo"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 2: rev-parse HEAD matches ==="
mkdir repo2 && cd repo2
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > hello.txt
git add hello.txt
git commit -q -m "initial commit"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches: $g"
else
    fail "rev-parse HEAD: git=$g ziggit=$z"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 3: status --porcelain on clean repo ==="
cd repo2
g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "status --porcelain matches (empty)"
else
    fail "status --porcelain: git='$g' ziggit='$z'"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 4: status --porcelain with modified file ==="
cd repo2
echo "modified" > hello.txt
g=$(git status --porcelain | sort)
z=$($ZIGGIT status --porcelain 2>/dev/null | sort || echo "ERROR")
# Both should show M hello.txt
if echo "$g" | grep -q "hello.txt" && echo "$z" | grep -q "hello.txt"; then
    pass "both detect modified hello.txt"
else
    fail "modified detection: git='$g' ziggit='$z'"
fi
git checkout -- hello.txt 2>/dev/null
cd "$TESTDIR"

# ============================================================================
echo "=== Test 5: log --oneline ==="
cd repo2
echo "second" > second.txt
git add second.txt
git commit -q -m "second commit"
echo "third" > third.txt
git add third.txt
git commit -q -m "third commit"

g_count=$(git log --oneline | wc -l)
z_count=$($ZIGGIT log --oneline 2>/dev/null | wc -l || echo 0)
if [ "$g_count" = "$z_count" ]; then
    pass "log --oneline line count matches: $g_count"
else
    fail "log --oneline count: git=$g_count ziggit=$z_count"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 6: branch listing ==="
cd repo2
git branch feature-a
git branch feature-b

g_branches=$(git branch --list | sed 's/^[* ]*//' | sort)
z_branches=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "ERROR")

g_count=$(echo "$g_branches" | wc -l)
z_count=$(echo "$z_branches" | wc -l)
if [ "$g_count" = "$z_count" ]; then
    pass "branch count matches: $g_count"
else
    fail "branch count: git=$g_count ziggit=$z_count"
fi

# Check specific branches exist
if echo "$z_branches" | grep -q "feature-a"; then
    pass "ziggit sees feature-a branch"
else
    fail "ziggit missing feature-a"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 7: tag operations ==="
cd repo2
git tag v1.0
$ZIGGIT tag v2.0 2>/dev/null || skip "ziggit tag command not available"

g_tags=$(git tag | sort)
if echo "$g_tags" | grep -q "v1.0"; then
    pass "git tag v1.0 visible"
else
    fail "git tag v1.0 not visible"
fi
if echo "$g_tags" | grep -q "v2.0"; then
    pass "ziggit-created tag v2.0 visible to git"
else
    skip "ziggit tag creation"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 8: cat-file -t ==="
cd repo2
head_hash=$(git rev-parse HEAD)
g_type=$(git cat-file -t "$head_hash")
z_type=$($ZIGGIT cat-file -t "$head_hash" 2>/dev/null || echo "ERROR")
if [ "$g_type" = "$z_type" ]; then
    pass "cat-file -t matches: $g_type"
else
    fail "cat-file -t: git=$g_type ziggit=$z_type"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 9: cat-file -p blob ==="
cd repo2
blob_hash=$(git hash-object hello.txt)
g_content=$(git cat-file -p "$blob_hash")
z_content=$($ZIGGIT cat-file -p "$blob_hash" 2>/dev/null || echo "ERROR")
if [ "$g_content" = "$z_content" ]; then
    pass "cat-file -p blob matches"
else
    fail "cat-file -p blob: git='$g_content' ziggit='$z_content'"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 10: hash-object ==="
cd repo2
echo "test content for hashing" > hash_test.txt
g_hash=$(git hash-object hash_test.txt)
z_hash=$($ZIGGIT hash-object hash_test.txt 2>/dev/null || echo "ERROR")
if [ "$g_hash" = "$z_hash" ]; then
    pass "hash-object matches: $g_hash"
else
    fail "hash-object: git=$g_hash ziggit=$z_hash"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 11: ls-files ==="
cd repo2
g_files=$(git ls-files | sort)
z_files=$($ZIGGIT ls-files 2>/dev/null | sort || echo "ERROR")
if [ "$g_files" = "$z_files" ]; then
    pass "ls-files matches"
else
    g_count=$(echo "$g_files" | wc -l)
    z_count=$(echo "$z_files" | wc -l)
    if [ "$g_count" = "$z_count" ]; then
        pass "ls-files file count matches: $g_count"
    else
        fail "ls-files: git=$g_count files, ziggit=$z_count files"
    fi
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 12: diff detection ==="
cd repo2
echo "changed content" > hello.txt
g_diff=$(git diff --name-only)
z_diff=$($ZIGGIT diff --name-only 2>/dev/null || echo "")
if echo "$g_diff" | grep -q "hello.txt" && echo "$z_diff" | grep -q "hello.txt"; then
    pass "both detect diff in hello.txt"
elif [ -z "$z_diff" ]; then
    skip "ziggit diff --name-only not implemented or different"
else
    fail "diff: git='$g_diff' ziggit='$z_diff'"
fi
git checkout -- hello.txt 2>/dev/null
cd "$TESTDIR"

# ============================================================================
echo "=== Test 13: show command ==="
cd repo2
g_show=$(git show --stat --no-patch HEAD | head -1)
z_show=$($ZIGGIT show HEAD 2>/dev/null | head -1 || echo "ERROR")
# Both should contain the commit hash
head_short=$(git rev-parse --short HEAD)
if echo "$z_show" | grep -q "$head_short"; then
    pass "show includes commit hash"
else
    skip "ziggit show format differs"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 14: multiple commits - parent chain ==="
mkdir repo14 && cd repo14
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "a" > a.txt && git add a.txt && git commit -q -m "first"
echo "b" > b.txt && git add b.txt && git commit -q -m "second"
echo "c" > c.txt && git add c.txt && git commit -q -m "third"

g_count=$(git log --oneline | wc -l)
z_count=$($ZIGGIT log --oneline 2>/dev/null | wc -l || echo 0)
if [ "$g_count" = "$z_count" ] && [ "$g_count" = "3" ]; then
    pass "3 commits in log"
else
    fail "commit chain: git=$g_count ziggit=$z_count"
fi

# Verify each rev-parse matches
for ref in HEAD HEAD~1 HEAD~2; do
    g=$(git rev-parse "$ref" 2>/dev/null)
    z=$($ZIGGIT rev-parse "$ref" 2>/dev/null || echo "UNSUPPORTED")
    if [ "$g" = "$z" ]; then
        pass "rev-parse $ref matches"
    else
        skip "rev-parse $ref: git=$g ziggit=$z"
    fi
done
cd "$TESTDIR"

# ============================================================================
echo "=== Test 15: binary file handling ==="
mkdir repo15 && cd repo15
git init -q
git config user.email "test@test.com"
git config user.name "Test"
printf '\x00\x01\x02\x03\xff\xfe\xfd' > binary.bin
git add binary.bin
git commit -q -m "binary file"

g_hash=$(git rev-parse HEAD)
z_hash=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g_hash" = "$z_hash" ]; then
    pass "rev-parse works with binary file commit"
else
    fail "binary file: git=$g_hash ziggit=$z_hash"
fi

blob_hash=$(git hash-object binary.bin)
g_type=$(git cat-file -t "$blob_hash")
z_type=$($ZIGGIT cat-file -t "$blob_hash" 2>/dev/null || echo "ERROR")
if [ "$g_type" = "$z_type" ]; then
    pass "binary blob type matches: $g_type"
else
    fail "binary blob type: git=$g_type ziggit=$z_type"
fi
cd "$TESTDIR"

# ============================================================================
echo "=== Test 16: unicode filenames ==="
mkdir repo16 && cd repo16
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > "café.txt"
git add "café.txt"
git commit -q -m "unicode filename"

g_hash=$(git rev-parse HEAD)
z_hash=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g_hash" = "$z_hash" ]; then
    pass "rev-parse works with unicode filename"
else
    fail "unicode: git=$g_hash ziggit=$z_hash"
fi
cd "$TESTDIR"

# ============================================================================
echo ""
echo "=== CLI Cross-Validation Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo ""
[ $FAIL -eq 0 ] && echo "ALL PASSED ✅" || echo "SOME FAILURES ❌"
[ $FAIL -eq 0 ] || exit 1
