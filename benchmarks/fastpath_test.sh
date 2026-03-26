#!/bin/bash

ZIGGIT=/root/ziggit/zig-out/bin/ziggit

# Create test repo
mkdir -p /tmp/fastpath_test
cd /tmp/fastpath_test
rm -rf .git
git init -q
git config user.email "test@test.com"
git config user.name "Test"

echo "Creating clean repository state..."
echo "content" > file1.txt
echo "content2" > file2.txt
git add .
git commit -q -m "initial"

echo ""
echo "Test 1: Clean repository (should hit fast path)"
echo "Git status --porcelain:"
time git status --porcelain
echo "Ziggit status --porcelain:"
time $ZIGGIT status --porcelain 2>/dev/null

echo ""
echo "Test 2: Modified file (should miss fast path)"
echo "modified" >> file1.txt
echo "Git status --porcelain:"
time git status --porcelain
echo "Ziggit status --porcelain:"
time $ZIGGIT status --porcelain 2>/dev/null

echo ""
echo "Test 3: After git add (should hit fast path again)"
git add file1.txt
echo "Git status --porcelain:"
time git status --porcelain
echo "Ziggit status --porcelain:"
time $ZIGGIT status --porcelain 2>/dev/null

cd /
rm -rf /tmp/fastpath_test