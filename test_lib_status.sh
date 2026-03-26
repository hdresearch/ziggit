#!/bin/bash

# Test script for library status functionality

set -e

# Create a temporary test repository
TEST_REPO="/tmp/test_lib_status_$$"
rm -rf "$TEST_REPO"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"

echo "Creating test repository..."

# Initialize git repository
git init > /dev/null 2>&1
git config user.email "test@example.com" > /dev/null 2>&1
git config user.name "Test User" > /dev/null 2>&1

# Create and commit initial file
echo "Initial content" > file1.txt
git add file1.txt > /dev/null 2>&1
git commit -m "Initial commit" > /dev/null 2>&1

echo "Test 1: Clean repository"
GIT_OUTPUT=$(git status --porcelain)
echo "Git output: '$GIT_OUTPUT'"
echo "Library output: (TODO: implement C test call)"

echo ""
echo "Test 2: Modified file"
echo "Modified content" > file1.txt
GIT_OUTPUT=$(git status --porcelain)
echo "Git output: '$GIT_OUTPUT'"
echo "Library output: (TODO: implement C test call)"

echo ""
echo "Test 3: New untracked file"
echo "New file content" > file2.txt
GIT_OUTPUT=$(git status --porcelain)
echo "Git output: '$GIT_OUTPUT'"
echo "Library output: (TODO: implement C test call)"

echo ""
echo "Test 4: Deleted file"
# Reset first
echo "Initial content" > file1.txt
git add file1.txt > /dev/null 2>&1
git commit -m "Reset file1" > /dev/null 2>&1
rm file1.txt
GIT_OUTPUT=$(git status --porcelain)
echo "Git output: '$GIT_OUTPUT'"
echo "Library output: (TODO: implement C test call)"

# Cleanup
cd /
rm -rf "$TEST_REPO"

echo ""
echo "Test completed. TODO: Add actual library calls to compare outputs."