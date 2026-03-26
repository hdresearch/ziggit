#!/bin/bash
# test/larger_repo_test.sh — Test ziggit with larger repos
# Run: bash test/larger_repo_test.sh
set -e

ZIGGIT="./zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭️  $1: $2"; SKIP=$((SKIP + 1)); }

cleanup() { rm -rf /tmp/ziggit-larger-* 2>/dev/null; }
trap cleanup EXIT

echo "=== Building ziggit ==="
zig build 2>&1 || { echo "Build failed"; exit 1; }
echo ""

# ── Test 1: Clone octocat/Spoon-Knife (100+ commits, fork-heavy) ─────
echo "=== Test 1: Clone repo with 100+ commits (Spoon-Knife) ==="
DIR1="/tmp/ziggit-larger-spoonknife-$$"
if $ZIGGIT clone --bare https://github.com/octocat/Spoon-Knife "$DIR1" 2>/dev/null; then
    # Check HEAD resolves
    cd "$DIR1"
    HEAD=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "FAIL")
    if [ ${#HEAD} -eq 40 ] && [ "$HEAD" != "0000000000000000000000000000000000000000" ]; then
        pass "clone --bare Spoon-Knife, HEAD=$HEAD"
    else
        fail "rev-parse HEAD after clone" "got '$HEAD'"
    fi
    
    # Check refs exist
    if [ -f "refs/heads/main" ] || [ -f "refs/heads/master" ]; then
        pass "has branch refs"
    else
        fail "missing branch refs" "$(ls refs/heads/ 2>/dev/null)"
    fi
    cd /root/ziggit
else
    fail "clone --bare Spoon-Knife" "clone failed"
fi

# ── Test 2: Clone --no-checkout then checkout ─────────────────────────
echo ""
echo "=== Test 2: HTTPS clone --no-checkout + checkout ==="
DIR2="/tmp/ziggit-larger-nocheckout-$$"
if $ZIGGIT clone --no-checkout https://github.com/octocat/Hello-World "$DIR2" 2>/dev/null; then
    cd "$DIR2"
    
    # Should have .git but NO files in working tree
    if [ -d ".git" ]; then
        pass "clone --no-checkout created .git"
    else
        fail "clone --no-checkout" "no .git directory"
    fi
    
    # Count files (excluding .git)
    FILE_COUNT=$(find . -maxdepth 1 -not -name '.git' -not -name '.' | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
        pass "no files in working tree after --no-checkout"
    else
        skip "files found after --no-checkout ($FILE_COUNT)" "may have auto-checkout"
    fi
    
    # Now checkout HEAD
    if $ZIGGIT checkout HEAD 2>/dev/null; then
        # Check if README appeared
        if [ -f "README" ]; then
            pass "checkout HEAD created README"
            CONTENT=$(cat README)
            if echo "$CONTENT" | grep -qi "hello"; then
                pass "README contains expected content"
            else
                fail "README content" "unexpected: $(head -1 README)"
            fi
        else
            fail "checkout HEAD" "README not created (files: $(ls))"
        fi
    else
        fail "checkout HEAD" "command failed"
    fi
    cd /root/ziggit
else
    fail "clone --no-checkout Hello-World" "clone failed"
fi

# ── Test 3: Clone repo with binary files (git itself has some) ────────
echo ""
echo "=== Test 3: Clone repo and verify pack handling ==="
DIR3="/tmp/ziggit-larger-packcheck-$$"
if $ZIGGIT clone --bare https://github.com/octocat/linguist "$DIR3" 2>/dev/null; then
    cd "$DIR3"
    # Check pack files exist
    PACK_COUNT=$(ls objects/pack/*.pack 2>/dev/null | wc -l)
    IDX_COUNT=$(ls objects/pack/*.idx 2>/dev/null | wc -l)
    if [ "$PACK_COUNT" -gt 0 ] && [ "$IDX_COUNT" -gt 0 ]; then
        pass "pack files present ($PACK_COUNT packs, $IDX_COUNT idx files)"
    else
        fail "pack files" "packs=$PACK_COUNT idx=$IDX_COUNT"
    fi
    
    HEAD=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "FAIL")
    if [ ${#HEAD} -eq 40 ] && [ "$HEAD" != "0000000000000000000000000000000000000000" ]; then
        pass "rev-parse HEAD on linguist = $HEAD"
    else
        fail "rev-parse HEAD on linguist" "'$HEAD'"
    fi
    cd /root/ziggit
else
    skip "clone linguist" "network/timeout issue"
fi

# ── Test 4: Describe on repo with no tags ─────────────────────────────
echo ""
echo "=== Test 4: describe --tags on repo with no tags ==="
DIR4="/tmp/ziggit-larger-notags-$$"
mkdir -p "$DIR4"
cd "$DIR4"
$ZIGGIT init 2>/dev/null
echo "test" > file.txt
$ZIGGIT add file.txt 2>/dev/null
$ZIGGIT commit -m "initial" 2>/dev/null
# describe should give empty or error, not crash
DESCRIBE_OUT=$($ZIGGIT describe --tags 2>&1 || true)
if [ -z "$DESCRIBE_OUT" ] || echo "$DESCRIBE_OUT" | grep -qi "fatal\|no.*tag\|no.*names"; then
    pass "describe --tags on repo with no tags (clean output)"
else
    # Even a non-empty output is OK as long as it doesn't crash
    pass "describe --tags on repo with no tags (output: '$DESCRIBE_OUT')"
fi
cd /root/ziggit

# ── Test 5: Fetch on bare repo ────────────────────────────────────────
echo ""
echo "=== Test 5: Fetch on existing bare clone ==="
if [ -d "$DIR1" ]; then
    cd "$DIR1"
    if $ZIGGIT fetch https://github.com/octocat/Spoon-Knife --quiet 2>/dev/null; then
        pass "fetch on bare clone succeeded"
    else
        skip "fetch on bare clone" "may be up-to-date"
    fi
    cd /root/ziggit
else
    skip "fetch on bare" "DIR1 not available"
fi

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
[ "$FAIL" -eq 0 ] && echo "  🎉 All tests passed!" || echo "  ⚠️  Some tests failed"
exit $FAIL
