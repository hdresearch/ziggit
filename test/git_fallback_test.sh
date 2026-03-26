#!/bin/bash

# Git fallback comprehensive test script
# Tests both native ziggit commands and fallback functionality

# Exit on any error except for expected test failures
# set -e

echo "=== Git Fallback Functionality Test ==="
echo

# Setup test environment
cd /root/ziggit
ZIGGIT="./zig-out/bin/ziggit"

echo "Testing native ziggit commands (should work without fallback):"

# Test native commands
echo -n "  rev-parse HEAD: "
$ZIGGIT rev-parse HEAD > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  log --oneline -1: "
$ZIGGIT log --oneline -1 > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  branch: "
$ZIGGIT branch > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  tag: "
$ZIGGIT tag > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  describe --always: "
$ZIGGIT describe --always > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo

echo "Testing fallback commands (should forward to git):"

# Test fallback commands  
echo -n "  stash list: "
$ZIGGIT stash list > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  remote -v: "
$ZIGGIT remote -v > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  show HEAD: "
$ZIGGIT show HEAD > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  ls-files: "
$ZIGGIT ls-files > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  cat-file -t HEAD: "
$ZIGGIT cat-file -t HEAD > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  rev-list --count HEAD: "
$ZIGGIT rev-list --count HEAD > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  log --graph --oneline -5: "
$ZIGGIT log --graph --oneline -5 > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo -n "  shortlog -sn -1: "
$ZIGGIT shortlog -sn -1 > /dev/null 2>&1 && echo "✓ PASS" || echo "✗ FAIL"

echo

echo "Testing error handling when git is NOT in PATH:"

# Test error case with no git
echo -n "  stash list (no git): "
if PATH= $ZIGGIT stash list 2>&1 | grep -q "git is not installed"; then
    echo "✓ PASS (correct error message)"
else
    echo "✗ FAIL (wrong error message)"
fi

echo -n "  exit code 1 check: "
PATH= $ZIGGIT stash list > /dev/null 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 1 ]; then
    echo "✓ PASS (exit code 1)"
else
    echo "✗ FAIL (exit code $EXIT_CODE, expected 1)"
fi

echo

echo "Testing global flag forwarding:"

# Test global flags
echo -n "  -C flag forwarding: "
if $ZIGGIT -C /tmp remote -v 2>&1 | grep -q "not a git repository"; then
    echo "✓ PASS (global -C flag forwarded)"
else
    echo "✗ FAIL (global -C flag not forwarded properly)"
fi

echo

echo "=== Test Summary ==="
echo "All tests completed. Check above for any ✗ FAIL markers."
echo "If all are ✓ PASS, the git fallback system is working correctly."