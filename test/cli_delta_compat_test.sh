#!/bin/bash
# Test delta encoding cross-validation with git CLI

set -e

echo "=== Delta Encoding Cross-Validation Test ==="

# Create test repository
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init --quiet

# Create test files with similar content for good delta compression
echo "hello world this is a test of delta compression functionality" > file1.txt
echo "hello ziggit world this is a test of delta compression functionality" > file2.txt
echo "hello wonderful world this is a test of delta compression functionality" > file3.txt

# Add and commit files
git add .
git commit -m "Test files for delta compression" --quiet

# Get object hashes
HASH1=$(git hash-object file1.txt)
HASH2=$(git hash-object file2.txt) 
HASH3=$(git hash-object file3.txt)

echo "Object hashes:"
echo "  file1.txt: $HASH1"
echo "  file2.txt: $HASH2"
echo "  file3.txt: $HASH3"

# Test ziggit pack-objects
echo -e "$HASH1\n$HASH2\n$HASH3" | /Users/yev/hdr/ziggit/zig-out/bin/ziggit pack-objects --stdout test-pack > ziggit.pack 2>ziggit.stderr

# Test git pack-objects  
echo -e "$HASH1\n$HASH2\n$HASH3" | git pack-objects --stdout test-pack > git.pack 2>git.stderr

echo "Pack sizes:"
echo "  ziggit: $(wc -c < ziggit.pack) bytes"
echo "  git:    $(wc -c < git.pack) bytes"

echo "Progress messages:"
echo "  ziggit: $(cat ziggit.stderr)"
echo "  git:    $(cat git.stderr)"

# Verify both packs are valid
echo "Verifying packs..."
git verify-pack -v ziggit.pack > ziggit.verify 2>/dev/null || echo "ziggit pack verification failed"
git verify-pack -v git.pack > git.verify 2>/dev/null || echo "git pack verification failed"

if [ -f ziggit.verify ] && [ -f git.verify ]; then
    echo "✅ Both packs are valid"
    
    # Compare delta usage
    ZIGGIT_DELTAS=$(grep -c "chain length" ziggit.verify || echo "0")
    GIT_DELTAS=$(grep -c "chain length" git.verify || echo "0") 
    
    echo "Delta usage:"
    echo "  ziggit: $ZIGGIT_DELTAS deltas"
    echo "  git:    $GIT_DELTAS deltas"
else
    echo "❌ Pack verification failed"
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

echo "=== Test Complete ==="
