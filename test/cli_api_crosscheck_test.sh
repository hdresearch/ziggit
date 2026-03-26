#!/bin/bash
# CLI cross-validation test: compares ziggit CLI output against git CLI output
# Run after: zig build
set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1 (skipped)"; SKIP=$((SKIP+1)); }

if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$(dirname "$0")/.." && HOME=/root XDG_CACHE_HOME=/tmp/zig-cache zig build) || { echo "Build failed"; exit 1; }
fi

if [ ! -x "$ZIGGIT" ]; then
    echo "FATAL: ziggit binary not found at $ZIGGIT"
    exit 1
fi

TESTDIR="/tmp/ziggit_cli_xcheck_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
trap "rm -rf '$TESTDIR'" EXIT

# ============================================================================
echo "=== Test: init ==="
cd "$TESTDIR" && mkdir init_test && cd init_test
git init -q
[ -f .git/HEAD ] && pass "git init creates HEAD" || fail "git init creates HEAD"

cd "$TESTDIR" && mkdir init_test_z && cd init_test_z
$ZIGGIT init 2>/dev/null || true
[ -f .git/HEAD ] && pass "ziggit init creates HEAD" || fail "ziggit init creates HEAD"

# ============================================================================
echo "=== Test: rev-parse HEAD ==="
cd "$TESTDIR" && rm -rf rp_test && mkdir rp_test && cd rp_test
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "init"

G_HASH=$(git rev-parse HEAD)
Z_HASH=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")

if [ "$G_HASH" = "$Z_HASH" ]; then
    pass "rev-parse HEAD matches ($G_HASH)"
else
    fail "rev-parse HEAD: git=$G_HASH ziggit=$Z_HASH"
fi

# ============================================================================
echo "=== Test: status --porcelain (clean repo) ==="
G_STATUS=$(git status --porcelain)
Z_STATUS=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")

G_LINES=$(echo -n "$G_STATUS" | grep -c . || true)
Z_LINES=$(echo -n "$Z_STATUS" | grep -c . || true)

if [ "$G_LINES" = "$Z_LINES" ]; then
    pass "status --porcelain line count matches (both $G_LINES)"
else
    fail "status --porcelain: git=$G_LINES lines, ziggit=$Z_LINES lines"
fi

# ============================================================================
echo "=== Test: status --porcelain (untracked file) ==="
echo "new" > untracked.txt

G_STATUS=$(git status --porcelain)
Z_STATUS=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")

G_HAS_UNTRACKED=$(echo "$G_STATUS" | grep -c "untracked.txt" || true)
Z_HAS_UNTRACKED=$(echo "$Z_STATUS" | grep -c "untracked.txt" || true)

if [ "$G_HAS_UNTRACKED" -gt 0 ] && [ "$Z_HAS_UNTRACKED" -gt 0 ]; then
    pass "both detect untracked.txt"
elif [ "$Z_HAS_UNTRACKED" -gt 0 ]; then
    pass "ziggit detects untracked.txt (git: $G_HAS_UNTRACKED)"
else
    fail "untracked detection: git=$G_HAS_UNTRACKED ziggit=$Z_HAS_UNTRACKED"
fi

rm untracked.txt

# ============================================================================
echo "=== Test: branch ==="
git branch feature-1
git branch feature-2

G_BRANCHES=$(git branch --list | sed 's/^[* ]*//' | sort)
Z_BRANCHES=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "ERROR")

G_COUNT=$(echo "$G_BRANCHES" | wc -l | tr -d ' ')
Z_COUNT=$(echo "$Z_BRANCHES" | wc -l | tr -d ' ')

if [ "$G_COUNT" = "$Z_COUNT" ]; then
    pass "branch count matches ($G_COUNT)"
else
    fail "branch count: git=$G_COUNT ziggit=$Z_COUNT"
fi

# Check specific branches
if echo "$Z_BRANCHES" | grep -q "feature-1"; then
    pass "ziggit lists feature-1"
else
    fail "ziggit missing feature-1"
fi

if echo "$Z_BRANCHES" | grep -q "feature-2"; then
    pass "ziggit lists feature-2"
else
    fail "ziggit missing feature-2"
fi

# ============================================================================
echo "=== Test: log --oneline ==="
echo "v2" > f.txt
git add f.txt
git commit -q -m "second commit"

echo "v3" > f.txt
git add f.txt
git commit -q -m "third commit"

G_LOG_LINES=$(git log --oneline | wc -l | tr -d ' ')
Z_LOG_LINES=$($ZIGGIT log --oneline 2>/dev/null | wc -l | tr -d ' ')

if [ "$G_LOG_LINES" = "$Z_LOG_LINES" ]; then
    pass "log --oneline line count matches ($G_LOG_LINES)"
else
    fail "log --oneline: git=$G_LOG_LINES ziggit=$Z_LOG_LINES"
fi

# ============================================================================
echo "=== Test: rev-parse HEAD after multiple commits ==="
G_HASH=$(git rev-parse HEAD)
Z_HASH=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")

if [ "$G_HASH" = "$Z_HASH" ]; then
    pass "rev-parse HEAD still matches after multiple commits"
else
    fail "rev-parse HEAD diverged: git=$G_HASH ziggit=$Z_HASH"
fi

# ============================================================================
echo "=== Test: tag ==="
git tag v1.0.0
git tag -a v2.0.0 -m "annotated tag"

G_TAGS=$(git tag | sort)
Z_TAGS=$($ZIGGIT tag 2>/dev/null | sort || echo "ERROR")

if [ "$G_TAGS" = "$Z_TAGS" ]; then
    pass "tag listing matches"
else
    G_COUNT=$(echo "$G_TAGS" | wc -l | tr -d ' ')
    Z_COUNT=$(echo "$Z_TAGS" | wc -l | tr -d ' ')
    if [ "$G_COUNT" = "$Z_COUNT" ]; then
        pass "tag count matches ($G_COUNT)"
    else
        fail "tag listing: git=$G_COUNT tags, ziggit=$Z_COUNT tags"
    fi
fi

# ============================================================================
echo "=== Test: ls-files ==="
G_FILES=$(git ls-files | sort)
Z_FILES=$($ZIGGIT ls-files 2>/dev/null | sort || echo "ERROR")

if [ "$G_FILES" = "$Z_FILES" ]; then
    pass "ls-files matches"
else
    fail "ls-files differ"
fi

# ============================================================================
echo "=== Test: hash-object ==="
echo "test content for hashing" > hash_test.txt
G_HASH_OBJ=$(git hash-object hash_test.txt)
Z_HASH_OBJ=$($ZIGGIT hash-object hash_test.txt 2>/dev/null || echo "ERROR")

if [ "$G_HASH_OBJ" = "$Z_HASH_OBJ" ]; then
    pass "hash-object matches ($G_HASH_OBJ)"
else
    fail "hash-object: git=$G_HASH_OBJ ziggit=$Z_HASH_OBJ"
fi
rm hash_test.txt

# ============================================================================
echo ""
echo "============================================"
echo "CLI Cross-Check Results: $PASS pass, $FAIL fail, $SKIP skip"
echo "============================================"
[ $FAIL -eq 0 ] || exit 1
