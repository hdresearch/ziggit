#!/bin/bash
set -e

# Create test repo
mkdir -p /tmp/status_test
cd /tmp/status_test
rm -rf .git *

# Initialize repo
git init
git config user.name "Test User"
git config user.email "test@example.com"

echo "=== Test 1: Clean repo (should be empty) ==="
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain
echo

echo "=== Test 2: Untracked file ==="
echo "hello" > test.txt
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain
echo

echo "=== Test 3: After commit (should be clean) ==="
git add test.txt
git commit -m "Initial commit"
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain
echo

echo "=== Test 4: Modified file ==="
echo "modified" > test.txt
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain
echo

echo "=== Test 5: Staged file ==="
echo "staged content" > staged.txt
git add staged.txt
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain
echo

echo "=== Test 6: Mixed (staged and modified) ==="
git add test.txt  # Stage the modification
echo "more changes" > test.txt  # Then modify again
echo "Git status:"
git status --porcelain
echo "Ziggit status:"
/root/ziggit/zig-out/bin/ziggit status --porcelain

# Cleanup
cd /root/ziggit
rm -rf /tmp/status_test