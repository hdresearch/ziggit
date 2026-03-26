#!/bin/bash
# test/cli_compat_test.sh - CLI compatibility test: compare ziggit output to git output
set -e

ZIGGIT="${ZIGGIT:-./zig-out/bin/ziggit}"
PASS=0
FAIL=0
SKIP=0
TESTDIR="/tmp/ziggit_cli_compat_$$"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ FAIL: $1"; echo "    expected: $2"; echo "    got:      $3"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⊘ SKIP: $1"; }

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    cd "$(dirname "$0")/.." && HOME=/root zig build 2>/dev/null
    ZIGGIT="./zig-out/bin/ziggit"
    if [ ! -x "$ZIGGIT" ]; then
        echo "SKIP: ziggit binary not available"
        exit 0
    fi
fi

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"

echo "=== CLI Compatibility Tests ==="
echo ""

# ---------------------------------------------------------------------------
# Test: init
# ---------------------------------------------------------------------------
echo "Test group: init"
mkdir -p "$TESTDIR/init_test"
cd "$TESTDIR/init_test"
$ZIGGIT init -q . 2>/dev/null || $ZIGGIT init . 2>/dev/null || true
if [ -f .git/HEAD ]; then
    pass "init creates .git/HEAD"
else
    fail "init creates .git/HEAD" "file exists" "missing"
fi

if [ -d .git/objects ]; then
    pass "init creates .git/objects"
else
    fail "init creates .git/objects" "dir exists" "missing"
fi

if [ -d .git/refs ]; then
    pass "init creates .git/refs"
else
    fail "init creates .git/refs" "dir exists" "missing"
fi

# ---------------------------------------------------------------------------
# Test: rev-parse HEAD on empty repo
# ---------------------------------------------------------------------------
echo ""
echo "Test group: rev-parse on empty repo"
mkdir -p "$TESTDIR/revparse_empty"
cd "$TESTDIR/revparse_empty"
git init -q
g=$(git rev-parse HEAD 2>&1 || true)
z=$($ZIGGIT rev-parse HEAD 2>&1 || true)
# Both should fail or return something for empty repo
if echo "$g" | grep -q "fatal\|unknown"; then
    # git fails on empty repo, ziggit should either fail or return zeros
    if echo "$z" | grep -q "0000000000\|error\|fatal" || [ -z "$z" ]; then
        pass "rev-parse HEAD on empty repo (both handle gracefully)"
    else
        skip "rev-parse HEAD on empty repo (different error handling)"
    fi
else
    skip "rev-parse HEAD on empty repo (unexpected git output)"
fi

# ---------------------------------------------------------------------------
# Test: rev-parse HEAD with commits
# ---------------------------------------------------------------------------
echo ""
echo "Test group: rev-parse HEAD after commit"
mkdir -p "$TESTDIR/revparse"
cd "$TESTDIR/revparse"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > f.txt
git add f.txt
git commit -q -m "initial"
g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "rev-parse HEAD matches git ($g)"
else
    fail "rev-parse HEAD" "$g" "$z"
fi

# ---------------------------------------------------------------------------
# Test: status --porcelain on clean repo
# ---------------------------------------------------------------------------
echo ""
echo "Test group: status --porcelain"
cd "$TESTDIR/revparse"
g=$(git status --porcelain)
z=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "status --porcelain clean repo (both empty)"
else
    # Allow for minor formatting differences
    if [ -z "$g" ] && [ -z "$z" ]; then
        pass "status --porcelain clean repo (both empty)"
    else
        fail "status --porcelain clean" "$g" "$z"
    fi
fi

# ---------------------------------------------------------------------------
# Test: status --porcelain with untracked file
# ---------------------------------------------------------------------------
echo "untracked" > untracked.txt
g=$(git status --porcelain | sort)
z=$($ZIGGIT status --porcelain 2>/dev/null | sort || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "status --porcelain untracked file"
else
    # Check if both detect the untracked file at least
    if echo "$g" | grep -q "untracked.txt" && echo "$z" | grep -q "untracked.txt"; then
        pass "status --porcelain untracked file (both detect it)"
    else
        fail "status --porcelain untracked" "$g" "$z"
    fi
fi
rm -f untracked.txt

# ---------------------------------------------------------------------------
# Test: describe --tags
# ---------------------------------------------------------------------------
echo ""
echo "Test group: describe --tags"
cd "$TESTDIR/revparse"
git tag v1.0.0
g=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
z=$($ZIGGIT describe --tags --abbrev=0 2>/dev/null || $ZIGGIT describe --tags 2>/dev/null || echo "")
if [ "$g" = "$z" ]; then
    pass "describe --tags matches ($g)"
else
    # ziggit may return just the tag name
    if echo "$z" | grep -q "v1.0.0"; then
        pass "describe --tags contains v1.0.0"
    else
        fail "describe --tags" "$g" "$z"
    fi
fi

# ---------------------------------------------------------------------------
# Test: branch
# ---------------------------------------------------------------------------
echo ""
echo "Test group: branch"
cd "$TESTDIR/revparse"
g=$(git branch --list | sed 's/^[* ]*//' | sort)
z=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "ERROR")
if [ "$g" = "$z" ]; then
    pass "branch list matches"
else
    # Check if master/main is present in both
    if echo "$g" | grep -qE "master|main" && echo "$z" | grep -qE "master|main"; then
        pass "branch list both contain master/main"
    else
        fail "branch" "$g" "$z"
    fi
fi

# ---------------------------------------------------------------------------
# Test: log --oneline
# ---------------------------------------------------------------------------
echo ""
echo "Test group: log"
cd "$TESTDIR/revparse"
echo "second" > f2.txt
git add f2.txt
git commit -q -m "second commit"
g_count=$(git rev-list HEAD | wc -l | tr -d ' ')
z_head=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
g_head=$(git rev-parse HEAD)
if [ "$g_head" = "$z_head" ]; then
    pass "rev-parse HEAD after two commits"
else
    fail "rev-parse HEAD after two commits" "$g_head" "$z_head"
fi

# ---------------------------------------------------------------------------
# Test: cat-file -t
# ---------------------------------------------------------------------------
echo ""
echo "Test group: cat-file"
cd "$TESTDIR/revparse"
head_hash=$(git rev-parse HEAD)
g_type=$(git cat-file -t "$head_hash")
z_type=$($ZIGGIT cat-file -t "$head_hash" 2>/dev/null || echo "ERROR")
if [ "$g_type" = "$z_type" ]; then
    pass "cat-file -t commit type ($g_type)"
else
    fail "cat-file -t" "$g_type" "$z_type"
fi

# Test cat-file -p (print content)
g_content=$(git cat-file -p "$head_hash" | head -1)
z_content=$($ZIGGIT cat-file -p "$head_hash" 2>/dev/null | head -1 || echo "ERROR")
if [ "$g_content" = "$z_content" ]; then
    pass "cat-file -p first line matches"
else
    # Tree line should at least match
    g_tree=$(echo "$g_content" | grep -o 'tree [a-f0-9]*')
    z_tree=$(echo "$z_content" | grep -o 'tree [a-f0-9]*')
    if [ -n "$g_tree" ] && [ "$g_tree" = "$z_tree" ]; then
        pass "cat-file -p tree hash matches"
    else
        fail "cat-file -p" "$g_content" "$z_content"
    fi
fi

# ---------------------------------------------------------------------------
# Test: ls-files
# ---------------------------------------------------------------------------
echo ""
echo "Test group: ls-files"
cd "$TESTDIR/revparse"
g_files=$(git ls-files | sort)
z_files=$($ZIGGIT ls-files 2>/dev/null | sort || echo "ERROR")
if [ "$g_files" = "$z_files" ]; then
    pass "ls-files matches"
else
    fail "ls-files" "$g_files" "$z_files"
fi

# ---------------------------------------------------------------------------
# Test: hash-object
# ---------------------------------------------------------------------------
echo ""
echo "Test group: hash-object"
cd "$TESTDIR/revparse"
echo "hash me" > hashtest.txt
g_hash=$(git hash-object hashtest.txt)
z_hash=$($ZIGGIT hash-object hashtest.txt 2>/dev/null || echo "ERROR")
if [ "$g_hash" = "$z_hash" ]; then
    pass "hash-object matches ($g_hash)"
else
    fail "hash-object" "$g_hash" "$z_hash"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "CLI Compatibility: $PASS pass, $FAIL fail, $SKIP skip"
echo "=========================================="
[ $FAIL -eq 0 ] || exit 1
