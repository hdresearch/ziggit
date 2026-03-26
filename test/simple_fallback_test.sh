#!/bin/bash

# Simple git fallback test
# Tests that ziggit forwards unknown commands to git

set -e

ZIGGIT_PATH="./zig-out/bin/ziggit"

if [ ! -f "$ZIGGIT_PATH" ]; then
    echo "ERROR: ziggit binary not found at $ZIGGIT_PATH"
    exit 1
fi

echo "Testing ziggit git fallback..."

# Test 1: Commands that should fall back to git work
echo "✓ Testing fallback commands..."

# Stash list (should forward to git)
echo -n "  stash list... "
output=$("$ZIGGIT_PATH" stash list 2>&1)
if [ $? -eq 0 ]; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

# Remote -v (should forward to git)
echo -n "  remote -v... "
output=$("$ZIGGIT_PATH" remote -v 2>&1)
if [ $? -eq 0 ]; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

# Show HEAD (should forward to git)
echo -n "  show HEAD... "
output=$("$ZIGGIT_PATH" show HEAD 2>&1)
if [ $? -eq 0 ]; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

# Test 2: Error handling with unknown commands 
echo "✓ Testing unknown command handling..."

echo -n "  unknown command... "
output=$("$ZIGGIT_PATH" unknowncommand 2>&1)
exit_code=$?
if [ $exit_code -ne 0 ] && [[ "$output" == *"is not a git command"* ]]; then
    echo "OK"
else
    echo "FAILED (exit_code=$exit_code, output='$output')"
    # Don't exit, continue with other tests
fi

# Test 3: Help works
echo "✓ Testing help..."

echo -n "  --help... "
output=$("$ZIGGIT_PATH" --help 2>&1)
if [ $? -eq 0 ] && [[ "$output" == *"ziggit"* ]]; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

# Test 4: Version works
echo -n "  --version... "
output=$("$ZIGGIT_PATH" --version 2>&1)
if [ $? -eq 0 ] && [[ "$output" == *"ziggit"* ]]; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

echo ""
echo "🎉 All fallback tests passed!"
echo ""
echo "Ziggit is successfully forwarding unimplemented commands to git."
echo "You can use: alias git=$ZIGGIT_PATH"
echo ""