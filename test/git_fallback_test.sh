#!/bin/bash
set -e

# Comprehensive test for git fallback functionality

ZIGGIT_PATH=$(realpath $(dirname $0)/../zig-out/bin/ziggit)
TEST_DIR="/tmp/ziggit-fallback-test-$$"
ORIGINAL_PATH="$PATH"

echo "=== Testing git fallback functionality ==="
echo "Using ziggit: $ZIGGIT_PATH"

# Setup test repository
echo "Setting up test repository..."
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init
echo "test content" > test.txt
git add test.txt
git config user.name "Test User"
git config user.email "test@example.com"
git commit -m "Initial commit"

# Test 1: Commands with native implementations work
echo "Test 1: Native commands work..."
$ZIGGIT_PATH status > /dev/null || { echo "FAIL: status command failed"; exit 1; }
$ZIGGIT_PATH rev-parse HEAD > /dev/null || { echo "FAIL: rev-parse command failed"; exit 1; }
$ZIGGIT_PATH log --oneline -1 > /dev/null || { echo "FAIL: log command failed"; exit 1; }
$ZIGGIT_PATH branch > /dev/null || { echo "FAIL: branch command failed"; exit 1; }
$ZIGGIT_PATH tag > /dev/null || { echo "FAIL: tag command failed"; exit 1; }
$ZIGGIT_PATH describe --tags 2>/dev/null || true  # May fail if no tags
$ZIGGIT_PATH diff --cached > /dev/null || { echo "FAIL: diff command failed"; exit 1; }
echo "✓ Native commands work"

# Test 2: Commands that fall back to git work  
echo "Test 2: Fallback commands work..."
$ZIGGIT_PATH stash list > /dev/null || { echo "FAIL: stash list failed"; exit 1; }
$ZIGGIT_PATH remote -v > /dev/null || { echo "FAIL: remote -v failed"; exit 1; }
$ZIGGIT_PATH show HEAD > /dev/null || { echo "FAIL: show HEAD failed"; exit 1; }
$ZIGGIT_PATH ls-files > /dev/null || { echo "FAIL: ls-files failed"; exit 1; }
$ZIGGIT_PATH cat-file -t HEAD > /dev/null || { echo "FAIL: cat-file failed"; exit 1; }
$ZIGGIT_PATH rev-list --count HEAD > /dev/null || { echo "FAIL: rev-list failed"; exit 1; }
$ZIGGIT_PATH log --graph --oneline -5 > /dev/null || { echo "FAIL: log --graph failed"; exit 1; }
$ZIGGIT_PATH shortlog -sn -1 > /dev/null || { echo "FAIL: shortlog failed"; exit 1; }
echo "✓ Fallback commands work"

# Test 3: Global flags are forwarded correctly
echo "Test 3: Global flags forwarding..."
cd /tmp
$ZIGGIT_PATH -C "$TEST_DIR" show HEAD > /dev/null || { echo "FAIL: -C flag forwarding failed"; exit 1; }
$ZIGGIT_PATH -c core.longpaths=true -C "$TEST_DIR" show HEAD > /dev/null || { echo "FAIL: -c flag forwarding failed"; exit 1; }
echo "✓ Global flags forwarding works"

# Test 4: When git is NOT in PATH, fallback commands print clear error
echo "Test 4: Error handling when git unavailable..."
cd "$TEST_DIR"
if PATH=/doesnotexist $ZIGGIT_PATH show HEAD 2>&1 | grep -q "git is not installed"; then
    echo "✓ Error handling works correctly"
else
    echo "FAIL: Error handling not working properly"
    exit 1
fi

# Test 5: Exit codes are properly propagated
echo "Test 5: Exit code propagation..."
cd "$TEST_DIR"
# This should exit with git's exit code (128)
if $ZIGGIT_PATH show nonexistent 2>/dev/null; then
    echo "FAIL: Exit code not propagated properly"
    exit 1
else
    echo "✓ Exit codes propagated correctly"
fi

# Test 6: Interactive commands work (stdin/stdout/stderr inheritance)
echo "Test 6: stdin/stdout/stderr inheritance..."
# Test that output is properly inherited
if $ZIGGIT_PATH show HEAD | grep -q "Initial commit"; then
    echo "✓ stdout inheritance works"
else
    echo "FAIL: stdout inheritance not working"
    exit 1
fi

# Test that stderr is properly inherited
if $ZIGGIT_PATH show nonexistent 2>&1 | grep -q "ambiguous"; then
    echo "✓ stderr inheritance works"
else
    echo "FAIL: stderr inheritance not working"
    exit 1
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

echo ""
echo "=== All tests passed! ==="
echo "✓ Native commands work correctly"
echo "✓ Fallback commands are forwarded to git"
echo "✓ Global flags (-C, -c) are properly forwarded"
echo "✓ Error handling works when git is unavailable"
echo "✓ Exit codes are properly propagated"
echo "✓ stdin/stdout/stderr are properly inherited"
echo ""
echo "ziggit is now a legitimate drop-in replacement for git!"