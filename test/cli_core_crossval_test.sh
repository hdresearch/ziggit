#!/bin/bash
# CLI core cross-validation test: compare ziggit output to git output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -x "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT"
    exit 0
fi

PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

TESTDIR="/tmp/ziggit_cli_crossval_$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
trap "rm -rf $TESTDIR" EXIT

# ============================================================================
echo "=== Test 1: init creates valid repo ==="
cd "$TESTDIR" && mkdir t1 && cd t1
$ZIGGIT init -q .
[ -f .git/HEAD ] && pass "init creates HEAD" || fail "init creates HEAD"
[ -d .git/objects ] && pass "init creates objects" || fail "init creates objects"
[ -d .git/refs ] && pass "init creates refs" || fail "init creates refs"

# ============================================================================
echo "=== Test 2: rev-parse HEAD matches after commit ==="
cd "$TESTDIR" && rm -rf t2 && mkdir t2 && cd t2
git init -q . && git config user.email t@t.com && git config user.name T
echo "hello" > f.txt
git add f.txt && git commit -q -m "initial"
GIT_HASH=$(git rev-parse HEAD)
ZIGGIT_HASH=$($ZIGGIT rev-parse HEAD)
[ "$GIT_HASH" = "$ZIGGIT_HASH" ] && pass "rev-parse HEAD" || fail "rev-parse HEAD: git=$GIT_HASH ziggit=$ZIGGIT_HASH"

# ============================================================================
echo "=== Test 3: status --porcelain matches on clean repo ==="
GIT_STATUS=$(git status --porcelain)
ZIGGIT_STATUS=$($ZIGGIT status --porcelain)
[ "$GIT_STATUS" = "$ZIGGIT_STATUS" ] && pass "status clean" || fail "status clean: git='$GIT_STATUS' ziggit='$ZIGGIT_STATUS'"

# ============================================================================
echo "=== Test 4: status --porcelain matches with untracked file ==="
echo "new" > untracked.txt
GIT_STATUS=$(git status --porcelain | sort)
ZIGGIT_STATUS=$($ZIGGIT status --porcelain | sort)
[ "$GIT_STATUS" = "$ZIGGIT_STATUS" ] && pass "status untracked" || fail "status untracked: git='$GIT_STATUS' ziggit='$ZIGGIT_STATUS'"
rm untracked.txt

# ============================================================================
echo "=== Test 5: hash-object matches ==="
echo "test content" > hash_test.txt
GIT_HASH=$(git hash-object hash_test.txt)
ZIGGIT_HASH=$($ZIGGIT hash-object hash_test.txt)
[ "$GIT_HASH" = "$ZIGGIT_HASH" ] && pass "hash-object" || fail "hash-object: git=$GIT_HASH ziggit=$ZIGGIT_HASH"
rm hash_test.txt

# ============================================================================
echo "=== Test 6: log --oneline matches ==="
cd "$TESTDIR" && rm -rf t6 && mkdir t6 && cd t6
git init -q . && git config user.email t@t.com && git config user.name T
echo a > a.txt && git add a.txt && git commit -q -m "first"
echo b > b.txt && git add b.txt && git commit -q -m "second"
GIT_LOG=$(git log --oneline | wc -l)
ZIGGIT_LOG=$($ZIGGIT log --oneline | wc -l)
[ "$GIT_LOG" = "$ZIGGIT_LOG" ] && pass "log count" || fail "log count: git=$GIT_LOG ziggit=$ZIGGIT_LOG"

# ============================================================================
echo "=== Test 7: tag listing matches ==="
git tag v1.0.0
git tag v2.0.0
GIT_TAGS=$(git tag | sort)
ZIGGIT_TAGS=$($ZIGGIT tag | sort)
[ "$GIT_TAGS" = "$ZIGGIT_TAGS" ] && pass "tag list" || fail "tag list: git='$GIT_TAGS' ziggit='$ZIGGIT_TAGS'"

# ============================================================================
echo "=== Test 8: branch listing matches ==="
GIT_BRANCHES=$(git branch | sed 's/^[* ]*//' | sort)
ZIGGIT_BRANCHES=$($ZIGGIT branch | sed 's/^[* ]*//' | sort)
[ "$GIT_BRANCHES" = "$ZIGGIT_BRANCHES" ] && pass "branch list" || fail "branch list: git='$GIT_BRANCHES' ziggit='$ZIGGIT_BRANCHES'"

# ============================================================================
echo ""
echo "CLI cross-validation: $PASS/$TOTAL passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
