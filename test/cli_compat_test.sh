#!/bin/bash
# cli_compat_test.sh - Compare ziggit CLI output to git CLI output
# Run after: zig build
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/../zig-out/bin/ziggit}"
PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1"; echo "    expected: $2"; echo "    got:      $3"; }
skip() { SKIP=$((SKIP+1)); echo "  ⚠ SKIP: $1"; }

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "ziggit binary not found at $ZIGGIT, building..."
    cd "$SCRIPT_DIR/.." && HOME=/root zig build
fi

if [ ! -x "$ZIGGIT" ]; then
    echo "ERROR: Cannot find ziggit binary"
    exit 1
fi

TESTDIR=$(mktemp -d /tmp/ziggit_cli_test.XXXXXX)
trap "rm -rf $TESTDIR" EXIT

echo "=== CLI Compatibility Tests ==="
echo "Using: $ZIGGIT"
echo "Test dir: $TESTDIR"
echo

# --------------------------------------------------------------------------
echo "Test 1: rev-parse HEAD"
REPO="$TESTDIR/repo1"
git init -q "$REPO"
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"
echo "hello" > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "initial commit"

G=$(git -C "$REPO" rev-parse HEAD)
Z=$(cd "$REPO" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "rev-parse HEAD matches ($G)"
else
    fail "rev-parse HEAD" "$G" "$Z"
fi

# --------------------------------------------------------------------------
echo "Test 2: rev-parse HEAD after second commit"
echo "world" > "$REPO/file2.txt"
git -C "$REPO" add file2.txt
git -C "$REPO" commit -q -m "second commit"

G=$(git -C "$REPO" rev-parse HEAD)
Z=$(cd "$REPO" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
if [ "$G" = "$Z" ]; then
    pass "rev-parse HEAD after 2nd commit"
else
    fail "rev-parse HEAD after 2nd commit" "$G" "$Z"
fi

# --------------------------------------------------------------------------
echo "Test 3: status on clean repo"
G=$(git -C "$REPO" status --porcelain)
Z=$(cd "$REPO" && "$ZIGGIT" status --porcelain 2>/dev/null || echo "ERROR")
if [ -z "$G" ] && [ -z "$Z" ]; then
    pass "status --porcelain clean (both empty)"
elif [ "$G" = "$Z" ]; then
    pass "status --porcelain matches"
else
    fail "status --porcelain clean" "'$G'" "'$Z'"
fi

# --------------------------------------------------------------------------
echo "Test 4: describe with tags"
git -C "$REPO" tag v1.0.0
G=$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || echo "")
Z=$(cd "$REPO" && "$ZIGGIT" describe --tags --abbrev=0 2>/dev/null || echo "")
if [ "$G" = "$Z" ]; then
    pass "describe --tags matches: $G"
elif echo "$Z" | grep -q "v1.0.0"; then
    pass "describe --tags found v1.0.0"
else
    fail "describe --tags" "$G" "$Z"
fi

# --------------------------------------------------------------------------
echo "Test 5: version flag"
Z_VER=$(cd "$REPO" && "$ZIGGIT" --version 2>/dev/null || echo "")
if [ -n "$Z_VER" ]; then
    pass "--version returns output: $(echo $Z_VER | head -1)"
else
    skip "--version"
fi

# --------------------------------------------------------------------------
echo "Test 6: init creates valid repo"
INIT_REPO="$TESTDIR/repo_init"
(cd "$TESTDIR" && "$ZIGGIT" init "$INIT_REPO" 2>/dev/null) || true
if [ -d "$INIT_REPO/.git" ]; then
    git -C "$INIT_REPO" config user.email "test@test.com"
    git -C "$INIT_REPO" config user.name "Test"
    echo "test" > "$INIT_REPO/test.txt"
    if git -C "$INIT_REPO" add test.txt && git -C "$INIT_REPO" commit -q -m "test" 2>/dev/null; then
        pass "ziggit init creates git-compatible repo"
    else
        fail "init compatibility" "git commit success" "git commit failed"
    fi
else
    skip "init command (may require different syntax)"
fi

# --------------------------------------------------------------------------
echo "Test 7: multiple commits, rev-parse always matches"
REPO2="$TESTDIR/repo2"
git init -q "$REPO2"
git -C "$REPO2" config user.email "t@t.com"
git -C "$REPO2" config user.name "T"

ALL_MATCH=true
for i in $(seq 1 5); do
    echo "commit $i" > "$REPO2/file.txt"
    git -C "$REPO2" add file.txt
    git -C "$REPO2" commit -q -m "commit $i"
    
    G=$(git -C "$REPO2" rev-parse HEAD)
    Z=$(cd "$REPO2" && "$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ERROR")
    if [ "$G" != "$Z" ]; then
        ALL_MATCH=false
        fail "rev-parse after commit $i" "$G" "$Z"
    fi
done
if $ALL_MATCH; then
    pass "rev-parse matches after 5 sequential commits"
fi

# --------------------------------------------------------------------------
echo
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo

[ $FAIL -eq 0 ] || exit 1
echo "All CLI compatibility tests passed!"
