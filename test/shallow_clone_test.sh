#!/bin/bash
# Test shallow clone functionality
set -e

ZIGGIT="./zig-out/bin/ziggit"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup() {
    rm -rf /tmp/shallow-test-*
}
trap cleanup EXIT
cleanup

# Test 1: --depth 1 bare clone creates shallow file
echo "=== Test 1: shallow bare clone creates shallow file ==="
$ZIGGIT clone --depth 1 --bare https://github.com/nicknisi/dotfiles.git /tmp/shallow-test-bare 2>/dev/null
if [ -f /tmp/shallow-test-bare/shallow ]; then
    pass "shallow file exists"
else
    fail "shallow file missing"
fi

# Test 2: shallow file contains valid hex hashes
echo "=== Test 2: shallow file contains valid hashes ==="
if grep -qE '^[0-9a-f]{40}$' /tmp/shallow-test-bare/shallow; then
    pass "shallow file has valid hashes"
else
    fail "shallow file has invalid content"
fi

# Test 3: git log shows limited history
echo "=== Test 3: limited history ==="
COMMIT_COUNT=$(cd /tmp/shallow-test-bare && git log --oneline --all 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -le 20 ]; then
    pass "limited history ($COMMIT_COUNT commits)"
else
    fail "too many commits ($COMMIT_COUNT)"
fi

# Test 4: git fsck passes (no errors about missing objects)
echo "=== Test 4: git fsck passes ==="
FSCK_ERRORS=$(cd /tmp/shallow-test-bare && git fsck 2>&1 | grep -c "error:" || true)
if [ "$FSCK_ERRORS" -eq 0 ]; then
    pass "git fsck clean"
else
    fail "git fsck has $FSCK_ERRORS errors"
fi

# Test 5: full clone (no --depth) does NOT create shallow file
echo "=== Test 5: full clone has no shallow file ==="
$ZIGGIT clone --bare https://github.com/nicknisi/dotfiles.git /tmp/shallow-test-full 2>/dev/null
if [ ! -f /tmp/shallow-test-full/shallow ]; then
    pass "no shallow file in full clone"
else
    fail "unexpected shallow file in full clone"
fi

# Test 6: --depth=N syntax (equals form)
echo "=== Test 6: --depth=1 syntax ==="
$ZIGGIT clone --depth=1 --bare https://github.com/nicknisi/dotfiles.git /tmp/shallow-test-eq 2>/dev/null
if [ -f /tmp/shallow-test-eq/shallow ]; then
    pass "--depth=1 syntax works"
else
    fail "--depth=1 syntax failed"
fi

# Test 7: --depth 1 non-bare clone
echo "=== Test 7: non-bare shallow clone ==="
$ZIGGIT clone --depth 1 https://github.com/nicknisi/dotfiles.git /tmp/shallow-test-nonbare 2>/dev/null
if [ -f /tmp/shallow-test-nonbare/.git/shallow ]; then
    pass "non-bare shallow clone has shallow file"
else
    fail "non-bare shallow clone missing shallow file"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
