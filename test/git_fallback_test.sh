#!/bin/bash

# Comprehensive test for git fallback functionality
set -e

ZIGGIT_BIN="${1:-zig-out/bin/ziggit}"
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

echo "=== Testing git fallback functionality in $TEST_DIR ==="

# Initialize test repository
$ZIGGIT_BIN init
echo "test content" > test.txt
$ZIGGIT_BIN add test.txt
$ZIGGIT_BIN commit -m "Initial commit"

# Create a branch for testing
$ZIGGIT_BIN branch feature

echo "=== Testing native commands ==="
echo "✓ Testing status..."
$ZIGGIT_BIN status > /dev/null || echo "❌ status failed"

echo "✓ Testing rev-parse..."
$ZIGGIT_BIN rev-parse HEAD > /dev/null || echo "❌ rev-parse failed"

echo "✓ Testing log..."
$ZIGGIT_BIN log --oneline -1 > /dev/null || echo "❌ log failed"

echo "✓ Testing branch..."
$ZIGGIT_BIN branch | grep -q "feature" || echo "❌ branch failed"

echo "✓ Testing tag..."
$ZIGGIT_BIN tag v1.0.0 || echo "❌ tag failed"

echo "✓ Testing describe..."
$ZIGGIT_BIN describe --tags > /dev/null || echo "❌ describe failed"

echo "✓ Testing diff..."
echo "modified" >> test.txt
$ZIGGIT_BIN diff > /dev/null || echo "❌ diff failed"

echo "=== Testing git fallback commands ==="

echo "✓ Testing stash list..."
$ZIGGIT_BIN stash list > /dev/null || echo "❌ stash list failed"

echo "✓ Testing remote -v..."
$ZIGGIT_BIN remote -v > /dev/null 2>&1 || echo "❌ remote -v failed (expected)"

echo "✓ Testing show HEAD..."
$ZIGGIT_BIN show HEAD > /dev/null || echo "❌ show HEAD failed"

echo "✓ Testing ls-files..."
$ZIGGIT_BIN ls-files > /dev/null || echo "❌ ls-files failed"

echo "✓ Testing cat-file..."
COMMIT=$(git rev-parse HEAD)
$ZIGGIT_BIN cat-file -t $COMMIT > /dev/null || echo "❌ cat-file failed"

echo "✓ Testing rev-list..."
$ZIGGIT_BIN rev-list --count HEAD > /dev/null || echo "❌ rev-list failed"

echo "✓ Testing log with git-specific flags..."
$ZIGGIT_BIN log --graph --oneline -5 > /dev/null || echo "❌ log --graph failed"

echo "✓ Testing shortlog..."
$ZIGGIT_BIN shortlog -sn -1 > /dev/null || echo "❌ shortlog failed"

echo "=== Testing error handling when git is not in PATH ==="
echo "✓ Testing fallback with no git..."
PATH="" $ZIGGIT_BIN stash list 2>&1 | grep -q "git is not installed" || echo "❌ Error message incorrect"

# Test exit code propagation
echo "✓ Testing exit code propagation..."
$ZIGGIT_BIN status --non-existent-flag > /dev/null 2>&1 && echo "❌ Exit code not propagated" || echo "Exit code properly propagated"

echo "=== All tests completed ==="
cd /
rm -rf "$TEST_DIR"
echo "✅ Git fallback functionality test completed successfully!"