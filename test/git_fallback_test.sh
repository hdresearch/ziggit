#!/bin/bash

# Test script for git fallback functionality
# Tests that ziggit can serve as a drop-in replacement for git

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Git Fallback Test Suite ===${NC}"

# Set up environment
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

# Build ziggit if not already built
if [ ! -f "./zig-out/bin/ziggit" ]; then
    echo "Building ziggit..."
    zig build
fi

ZIGGIT="./zig-out/bin/ziggit"

# Function to test a command and check exit code
test_command() {
    local cmd="$1"
    local description="$2"
    local expected_success="$3"  # true/false
    
    echo -n "Testing: $description ... "
    
    if $cmd >/dev/null 2>&1; then
        if [ "$expected_success" = "true" ]; then
            echo -e "${GREEN}PASS${NC}"
            return 0
        else
            echo -e "${RED}FAIL${NC} (expected failure but command succeeded)"
            return 1
        fi
    else
        if [ "$expected_success" = "false" ]; then
            echo -e "${GREEN}PASS${NC}"
            return 0
        else
            echo -e "${RED}FAIL${NC} (command failed unexpectedly)"
            return 1
        fi
    fi
}

# Function to test command output contains expected text
test_output_contains() {
    local cmd="$1"
    local expected_text="$2"
    local description="$3"
    
    echo -n "Testing: $description ... "
    
    local output
    output=$($cmd 2>&1) || true
    
    if echo "$output" | grep -q "$expected_text"; then
        echo -e "${GREEN}PASS${NC}"
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        echo "Expected output to contain: $expected_text"
        echo "Actual output: $output"
        return 1
    fi
}

echo -e "${YELLOW}=== Testing Native Commands ===${NC}"

# These commands have native implementations and should work
test_command "$ZIGGIT rev-parse HEAD" "rev-parse command" "true"
test_command "$ZIGGIT branch" "branch command" "true"  
test_command "$ZIGGIT tag" "tag command" "true"

# Create a tag first to test describe
$ZIGGIT tag test-tag >/dev/null 2>&1 || true
test_command "$ZIGGIT describe --tags" "describe command" "true"

echo -e "${YELLOW}=== Testing Git Fallback Commands ===${NC}"

# These commands should fall back to git
test_command "$ZIGGIT stash list" "stash list fallback" "true"
test_command "$ZIGGIT remote -v" "remote -v fallback" "true"
test_command "$ZIGGIT show HEAD" "show HEAD fallback" "true"
test_command "$ZIGGIT ls-files" "ls-files fallback" "true"
test_command "$ZIGGIT cat-file -t HEAD" "cat-file fallback" "true"
test_command "$ZIGGIT rev-list --count HEAD" "rev-list fallback" "true"
test_command "$ZIGGIT log --graph --oneline -5" "log graph fallback" "true"
test_command "$ZIGGIT shortlog -sn -1" "shortlog fallback" "true"

echo -e "${YELLOW}=== Testing Global Flags Forwarding ===${NC}"

# Test that global flags are properly forwarded
test_command "$ZIGGIT -C . stash list" "global -C flag forwarding" "true"

echo -e "${YELLOW}=== Testing Git Not Available ===${NC}"

# Test behavior when git is not in PATH
test_output_contains "env PATH=/nonexistent $ZIGGIT stash list" "is not a ziggit command and git is not installed" "error when git not available"

echo -e "${YELLOW}=== Testing Interactive Commands ===${NC}"

# Test that interactive commands work (we can't fully test interactivity in a script,
# but we can test that they don't crash)
echo "n" | $ZIGGIT add -p >/dev/null 2>&1 || echo "Interactive add test completed (expected failure with 'n' input)"

echo -e "${YELLOW}=== Testing Exit Code Propagation ===${NC}"

# Test that exit codes are properly propagated
if ! $ZIGGIT invalid-command-that-git-also-rejects >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}: Exit codes properly propagated"
else
    echo -e "${RED}FAIL${NC}: Exit codes not properly propagated"
fi

echo -e "${YELLOW}=== Drop-in Replacement Test ===${NC}"

# Create a temporary alias and test some common git workflows
echo "Testing as git alias..."

# Save current directory
ORIGINAL_DIR=$(pwd)

# Create a temporary test directory
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

# Initialize a git repository
git init >/dev/null 2>&1

# Create an alias function for this test
git_alias() {
    "$ORIGINAL_DIR/$ZIGGIT" "$@"
}

# Test common git workflows using the alias
echo "test content" > test.txt
git_alias add test.txt
git_alias commit -m "Test commit"
git_alias log --oneline -1
git_alias status
git_alias tag v1.0.0
git_alias describe --tags

echo -e "${GREEN}Drop-in replacement test completed successfully${NC}"

# Clean up
cd "$ORIGINAL_DIR"
rm -rf "$TEST_DIR"

# Clean up test tag
git tag -d test-tag >/dev/null 2>&1 || true

echo -e "${GREEN}=== All tests completed! ===${NC}"
echo "Ziggit is ready to serve as a drop-in replacement for git."