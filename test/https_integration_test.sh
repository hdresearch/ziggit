#!/bin/bash
# Integration tests for native HTTPS networking
# Requires: network access to github.com, ziggit binary at ./zig-out/bin/ziggit
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIGGIT="$SCRIPT_DIR/zig-out/bin/ziggit"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

echo "=== HTTPS Integration Tests ==="

# Test 1: clone --bare from public GitHub repo
echo ""
echo "Test 1: clone --bare from public GitHub repo"
TARGET="/tmp/ziggit-test-clone-bare-$$"
rm -rf "$TARGET"
if $ZIGGIT clone --bare https://github.com/octocat/Hello-World.git "$TARGET" 2>&1; then
    if [ -f "$TARGET/HEAD" ] && [ -d "$TARGET/objects" ] && [ -d "$TARGET/refs" ]; then
        pass "bare clone created valid repo structure"
    else
        fail "bare clone" "missing HEAD/objects/refs"
    fi
else
    fail "bare clone" "command failed"
fi
rm -rf "$TARGET"

# Test 2: clone --no-checkout from public GitHub repo
echo ""
echo "Test 2: clone --no-checkout from public GitHub repo"
TARGET="/tmp/ziggit-test-nocheckout-$$"
rm -rf "$TARGET"
if $ZIGGIT clone --no-checkout https://github.com/octocat/Hello-World.git "$TARGET" 2>&1; then
    if [ -f "$TARGET/.git/HEAD" ] && [ -d "$TARGET/.git/objects" ]; then
        # Verify no working tree files (only .git dir)
        FILE_COUNT=$(ls -A "$TARGET" | grep -v '^\.git$' | wc -l)
        if [ "$FILE_COUNT" -eq 0 ]; then
            pass "no-checkout clone has no working tree files"
        else
            fail "no-checkout clone" "found $FILE_COUNT working tree files"
        fi
    else
        fail "no-checkout clone" "missing .git structure"
    fi
    # Check bare=false in config
    if grep -q "bare = false" "$TARGET/.git/config"; then
        pass "no-checkout clone has bare=false in config"
    else
        fail "no-checkout clone" "config does not have bare=false"
    fi
else
    fail "no-checkout clone" "command failed"
fi
rm -rf "$TARGET"

# Test 3: fetch on already-cloned bare repo
echo ""
echo "Test 3: fetch on already-cloned bare repo"
TARGET="/tmp/ziggit-test-fetch-$$"
rm -rf "$TARGET"
$ZIGGIT clone --bare https://github.com/octocat/Hello-World.git "$TARGET" 2>&1
if (cd "$TARGET" && $ZIGGIT fetch --quiet 2>&1); then
    pass "fetch on bare repo succeeded"
else
    fail "fetch on bare repo" "command failed"
fi
rm -rf "$TARGET"

# Test 4: fetch on no-checkout clone
echo ""
echo "Test 4: fetch on no-checkout clone"
TARGET="/tmp/ziggit-test-fetch-nc-$$"
rm -rf "$TARGET"
$ZIGGIT clone --no-checkout https://github.com/octocat/Hello-World.git "$TARGET" 2>&1
if (cd "$TARGET" && $ZIGGIT fetch --quiet 2>&1); then
    pass "fetch on no-checkout clone succeeded"
else
    fail "fetch on no-checkout clone" "command failed"
fi
rm -rf "$TARGET"

# Test 5: rev-parse HEAD on cloned repo returns valid hash
echo ""
echo "Test 5: rev-parse HEAD on cloned repo"
TARGET="/tmp/ziggit-test-revparse-$$"
rm -rf "$TARGET"
$ZIGGIT clone --no-checkout https://github.com/octocat/Hello-World.git "$TARGET" 2>&1
HASH=$(cd "$TARGET" && $ZIGGIT rev-parse HEAD 2>/dev/null)
if [ ${#HASH} -eq 41 ] || [ ${#HASH} -eq 40 ]; then
    # Trim newline
    HASH=$(echo "$HASH" | tr -d '\n')
    if echo "$HASH" | grep -qE '^[0-9a-f]{40}$'; then
        pass "rev-parse HEAD returned valid hash: $HASH"
    else
        fail "rev-parse HEAD" "invalid hash format: '$HASH'"
    fi
else
    fail "rev-parse HEAD" "unexpected length ${#HASH}: '$HASH'"
fi
rm -rf "$TARGET"

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
