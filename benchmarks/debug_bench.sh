#!/bin/bash

set -e

ZIGGIT=/root/ziggit/zig-out/bin/ziggit

# Create simple test repo
mkdir -p /tmp/simple_test
cd /tmp/simple_test
rm -rf .git
git init
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add file.txt
git commit -m "initial"
echo "modified" >> file.txt

echo "Testing git commands:"
echo "git status --porcelain:"
git status --porcelain
echo "git rev-parse HEAD:"
git rev-parse HEAD

echo ""
echo "Testing ziggit commands:"
echo "ziggit status --porcelain:"
$ZIGGIT status --porcelain
echo "ziggit rev-parse HEAD:"
$ZIGGIT rev-parse HEAD

echo ""
echo "Timing git status --porcelain:"
time git status --porcelain >/dev/null

echo ""  
echo "Timing ziggit status --porcelain:"
time $ZIGGIT status --porcelain >/dev/null

# Clean up
cd /
rm -rf /tmp/simple_test