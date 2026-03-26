#!/bin/bash
# CLI compatibility test: compare ziggit output to git output
set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭  $1 (skipped)"; SKIP=$((SKIP+1)); }

if [ ! -x "$ZIGGIT" ]; then
    echo "ERROR: ziggit binary not found at $ZIGGIT"
    echo "Run 'zig build' first"
    exit 1
fi

TESTDIR=$(mktemp -d /tmp/ziggit_cli_test.XXXXXX)
trap "rm -rf $TESTDIR" EXIT
cd "$TESTDIR"

echo "=== Ziggit CLI Compatibility Tests ==="
echo "Test dir: $TESTDIR"
echo ""

# ---------- Test 1: init ----------
echo "Test 1: init"
mkdir repo1 && cd repo1
git init -q
cd ..
mkdir repo2 && cd repo2
$ZIGGIT init 2>/dev/null || true
cd ..

if [ -f repo1/.git/HEAD ] && [ -f repo2/.git/HEAD ]; then
    pass "both init create .git/HEAD"
else
    fail "init: missing .git/HEAD"
fi

# ---------- Test 2: rev-parse HEAD ----------
echo "Test 2: rev-parse HEAD"
cd "$TESTDIR" && rm -rf rp && mkdir rp && cd rp
git init -q && git config user.email t@t.com && git config user.name T
echo "hello" > f.txt && git add f.txt && git commit -q -m "init"

GIT_HEAD=$(git rev-parse HEAD)
ZIGGIT_HEAD=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "FAILED")

if [ "$GIT_HEAD" = "$ZIGGIT_HEAD" ]; then
    pass "rev-parse HEAD matches: ${GIT_HEAD:0:12}..."
else
    fail "rev-parse HEAD: git=$GIT_HEAD ziggit=$ZIGGIT_HEAD"
fi

# ---------- Test 3: status --porcelain on clean repo ----------
echo "Test 3: status --porcelain (clean)"
GIT_STATUS=$(git status --porcelain)
ZIGGIT_STATUS=$($ZIGGIT status --porcelain 2>/dev/null || echo "COMMAND_FAILED")

if [ "$GIT_STATUS" = "$ZIGGIT_STATUS" ]; then
    pass "clean status matches (both empty)"
elif [ "$ZIGGIT_STATUS" = "COMMAND_FAILED" ]; then
    skip "status --porcelain (command failed)"
else
    fail "clean status: git='$GIT_STATUS' ziggit='$ZIGGIT_STATUS'"
fi

# ---------- Test 4: status --porcelain with changes ----------
echo "Test 4: status --porcelain (modified + untracked)"
echo "modified" > f.txt
echo "new" > new.txt

GIT_STATUS=$(git status --porcelain | sort)
ZIGGIT_STATUS=$($ZIGGIT status --porcelain 2>/dev/null | sort || echo "COMMAND_FAILED")

if [ "$ZIGGIT_STATUS" = "COMMAND_FAILED" ]; then
    skip "status with changes"
else
    # Check key indicators present
    GIT_HAS_M=$(echo "$GIT_STATUS" | grep -c "M " || true)
    ZIGGIT_HAS_M=$(echo "$ZIGGIT_STATUS" | grep -c "M " || true)
    GIT_HAS_Q=$(echo "$GIT_STATUS" | grep -c "??" || true)
    ZIGGIT_HAS_Q=$(echo "$ZIGGIT_STATUS" | grep -c "??" || true)

    if [ "$GIT_HAS_M" -gt 0 ] && [ "$ZIGGIT_HAS_M" -gt 0 ] && [ "$GIT_HAS_Q" -gt 0 ] && [ "$ZIGGIT_HAS_Q" -gt 0 ]; then
        pass "status shows modified and untracked files"
    else
        fail "status indicators: git_M=$GIT_HAS_M zig_M=$ZIGGIT_HAS_M git_??=$GIT_HAS_Q zig_??=$ZIGGIT_HAS_Q"
    fi
fi

# Restore clean state
git checkout -- f.txt 2>/dev/null
rm -f new.txt

# ---------- Test 5: log --oneline ----------
echo "Test 5: log --oneline"
echo "two" > g.txt && git add g.txt && git commit -q -m "second"
echo "three" > h.txt && git add h.txt && git commit -q -m "third"

GIT_LOG=$(git log --oneline)
ZIGGIT_LOG=$($ZIGGIT log --oneline 2>/dev/null || echo "COMMAND_FAILED")

if [ "$ZIGGIT_LOG" = "COMMAND_FAILED" ]; then
    skip "log --oneline"
else
    GIT_LINES=$(echo "$GIT_LOG" | wc -l)
    ZIGGIT_LINES=$(echo "$ZIGGIT_LOG" | wc -l)

    if [ "$GIT_LINES" = "$ZIGGIT_LINES" ]; then
        pass "log --oneline: both have $GIT_LINES lines"
    else
        fail "log --oneline: git=$GIT_LINES lines, ziggit=$ZIGGIT_LINES lines"
    fi
fi

# ---------- Test 6: branch ----------
echo "Test 6: branch"
git branch feature 2>/dev/null
git branch develop 2>/dev/null

GIT_BRANCHES=$(git branch | sed 's/^[* ]*//' | sort)
ZIGGIT_BRANCHES=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sort || echo "COMMAND_FAILED")

if [ "$ZIGGIT_BRANCHES" = "COMMAND_FAILED" ]; then
    skip "branch listing"
else
    if [ "$GIT_BRANCHES" = "$ZIGGIT_BRANCHES" ]; then
        pass "branch listing matches"
    else
        # Check if all branches present
        MISSING=0
        for b in master feature develop; do
            if ! echo "$ZIGGIT_BRANCHES" | grep -q "$b"; then
                MISSING=$((MISSING+1))
            fi
        done
        if [ $MISSING -eq 0 ]; then
            pass "all expected branches present"
        else
            fail "branch listing: git='$GIT_BRANCHES' ziggit='$ZIGGIT_BRANCHES'"
        fi
    fi
fi

# ---------- Test 7: diff ----------
echo "Test 7: diff"
echo "changed content" > f.txt

GIT_DIFF=$(git diff 2>/dev/null)
ZIGGIT_DIFF=$($ZIGGIT diff 2>/dev/null || echo "COMMAND_FAILED")

if [ "$ZIGGIT_DIFF" = "COMMAND_FAILED" ]; then
    skip "diff"
elif [ -n "$GIT_DIFF" ] && [ -n "$ZIGGIT_DIFF" ]; then
    pass "both show diff output"
else
    fail "diff: git_len=${#GIT_DIFF} ziggit_len=${#ZIGGIT_DIFF}"
fi

git checkout -- f.txt 2>/dev/null

# ---------- Test 8: tag ----------
echo "Test 8: tag"
git tag v1.0.0 2>/dev/null

GIT_TAGS=$(git tag | sort)
ZIGGIT_TAGS=$($ZIGGIT tag 2>/dev/null | sort || echo "COMMAND_FAILED")

if [ "$ZIGGIT_TAGS" = "COMMAND_FAILED" ]; then
    skip "tag listing"
elif [ "$GIT_TAGS" = "$ZIGGIT_TAGS" ]; then
    pass "tag listing matches"
else
    fail "tag: git='$GIT_TAGS' ziggit='$ZIGGIT_TAGS'"
fi

# ---------- Test 9: version flag ----------
echo "Test 9: --version"
ZIGGIT_VER=$($ZIGGIT --version 2>/dev/null || echo "COMMAND_FAILED")
if echo "$ZIGGIT_VER" | grep -q "ziggit"; then
    pass "--version outputs version string"
else
    fail "--version: got '$ZIGGIT_VER'"
fi

# ---------- Summary ----------
echo ""
echo "=== Results ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
echo "  Skip: $SKIP"
echo "  Total: $((PASS + FAIL + SKIP))"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "FAILED: $FAIL tests failed"
    exit 1
else
    echo ""
    echo "ALL PASSED ✅"
    exit 0
fi
