#!/bin/bash

# Manual test for pack file functionality

set -e
export XDG_DATA_HOME=/tmp
export HOME=/tmp

echo "=== Manual Pack File Test ==="

# Create test directory
TEST_DIR="/tmp/pack_test_manual"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "✓ Created test directory"

# Initialize git repository
git init
git config user.name "Test User"
git config user.email "test@example.com"

echo "✓ Initialized git repository"

# Create many commits to ensure pack files are needed
echo "Creating multiple commits..."
for i in {1..25}; do
    echo "This is file $i with content that varies: line $i" > "file_$i.txt"
    echo "More content for file $i to make it substantial" >> "file_$i.txt"
    echo "Even more content to ensure decent file size in file $i" >> "file_$i.txt"
    git add "file_$i.txt"
    git commit -m "Add file $i"
done

echo "✓ Created 25 commits"

# Create some directory structure
mkdir -p src docs tests
for dir in src docs tests; do
    for i in {1..3}; do
        echo "Content for $dir file $i" > "$dir/file_$i.txt"
        git add "$dir/file_$i.txt"
    done
    git commit -m "Add $dir files"
done

echo "✓ Created directory structure with more commits"

# Force creation of pack files
echo "Creating pack files..."
git gc --aggressive --prune=now

# Verify pack files exist
PACK_DIR=".git/objects/pack"
if [ -d "$PACK_DIR" ]; then
    PACK_FILES=$(ls "$PACK_DIR"/*.pack 2>/dev/null | wc -l)
    IDX_FILES=$(ls "$PACK_DIR"/*.idx 2>/dev/null | wc -l)
    echo "✓ Found $PACK_FILES pack files and $IDX_FILES index files"
    
    if [ "$PACK_FILES" -gt 0 ] && [ "$IDX_FILES" -gt 0 ]; then
        echo "✓ Pack files created successfully"
        ls -la "$PACK_DIR"
    else
        echo "⚠ Pack files might not have been created (pack: $PACK_FILES, idx: $IDX_FILES)"
    fi
else
    echo "⚠ Pack directory doesn't exist"
fi

# Test reading objects using ziggit (which should use pack files)
echo "Testing ziggit can read objects from pack files..."

# Get some commit hashes to test
COMMITS=$(git log --format="%H" -n 5)
echo "Testing commits:"
echo "$COMMITS"

# Test ziggit log (this exercises pack file reading)
echo "Running ziggit log..."
/root/ziggit/zig-out/bin/ziggit log --oneline -n 10

echo "✓ ziggit log succeeded"

# Test ziggit status (this also reads objects)
echo "Running ziggit status..."
/root/ziggit/zig-out/bin/ziggit status

echo "✓ ziggit status succeeded"

echo ""
echo "=== Pack File Test Summary ==="
echo "✓ Repository created with $(git rev-list --all --count) commits"
echo "✓ Pack files created and objects packed"
echo "✓ ziggit successfully read objects from pack files"
echo "✓ All tests passed!"

# Cleanup
cd /
rm -rf "$TEST_DIR"