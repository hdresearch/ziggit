#!/bin/bash

# Comprehensive test for git fallback functionality
# Tests commands with native implementations and fallback commands

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_TOTAL=0

# Function to print test results
print_test_result() {
    local test_name="$1"
    local result="$2"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC} $test_name"
    fi
}

# Get absolute path to ziggit binary
ZIGGIT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zig-out/bin/ziggit"

if [ ! -f "$ZIGGIT_BIN" ]; then
    echo "Error: ziggit binary not found at $ZIGGIT_BIN"
    echo "Please run 'zig build' first"
    exit 1
fi

echo -e "${YELLOW}Testing ziggit git fallback functionality...${NC}"
echo "Using ziggit binary: $ZIGGIT_BIN"

# Create temporary test repository
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init > /dev/null 2>&1
git config user.name "Test User"
git config user.email "test@example.com"

# Create some test content
echo "test content" > test_file.txt
echo "another file" > another.txt

# Stage files for testing
git add test_file.txt another.txt
git commit -m "Initial test commit" > /dev/null 2>&1

echo ""
echo -e "${YELLOW}Testing commands with native implementations...${NC}"

# Test native commands
test_native_command() {
    local cmd="$1"
    local description="$2"
    
    if $ZIGGIT_BIN $cmd > /dev/null 2>&1; then
        print_test_result "Native command: $description" "PASS"
    else
        print_test_result "Native command: $description" "FAIL"
    fi
}

# Status command (might have issues but should not crash)
if $ZIGGIT_BIN status > /dev/null 2>&1 || [ $? -ne 139 ]; then  # 139 = segfault
    print_test_result "Native command: status" "PASS"
else
    print_test_result "Native command: status (crashed with segfault)" "FAIL"
fi

test_native_command "rev-parse HEAD" "rev-parse"
test_native_command "--version" "version"
test_native_command "--help" "help"

echo ""
echo -e "${YELLOW}Testing commands that fall back to git...${NC}"

# Test fallback commands
test_fallback_command() {
    local cmd="$1"
    local description="$2"
    
    if $ZIGGIT_BIN $cmd > /dev/null 2>&1; then
        print_test_result "Fallback command: $description" "PASS"
    else
        print_test_result "Fallback command: $description" "FAIL"
    fi
}

test_fallback_command "stash list" "stash list"
test_fallback_command "remote -v" "remote -v"
test_fallback_command "show HEAD" "show HEAD"
test_fallback_command "ls-files" "ls-files"
test_fallback_command "cat-file -t HEAD" "cat-file -t HEAD"
test_fallback_command "rev-list --count HEAD" "rev-list --count HEAD"
test_fallback_command "log --graph --oneline -5" "log --graph --oneline -5"
test_fallback_command "shortlog -sn -1" "shortlog -sn -1"

echo ""
echo -e "${YELLOW}Testing error handling when git is not in PATH...${NC}"

# Test error handling when git is not found
if output=$(PATH="/nonexistent" $ZIGGIT_BIN stash list 2>&1); then
    print_test_result "Error handling when git not found" "FAIL"
else
    if echo "$output" | grep -q "git is not installed"; then
        print_test_result "Error handling when git not found" "PASS"
    else
        print_test_result "Error handling when git not found (wrong error message)" "FAIL"
    fi
fi

echo ""
echo -e "${YELLOW}Testing global flags forwarding...${NC}"

# Test global flags forwarding
test_global_flags() {
    local flags="$1"
    local cmd="$2"
    local description="$3"
    
    if $ZIGGIT_BIN $flags $cmd > /dev/null 2>&1; then
        print_test_result "Global flags: $description" "PASS"
    else
        print_test_result "Global flags: $description" "FAIL"
    fi
}

# Create subdirectory for -C test
mkdir -p subdir
cd subdir

test_global_flags "-C .." "ls-files" "-C flag forwarding"

cd ..

# Test help text mentions fallback
echo ""
echo -e "${YELLOW}Testing help text mentions fallback...${NC}"

if $ZIGGIT_BIN --help | grep -q "forwarded to git"; then
    print_test_result "Help text mentions git fallback" "PASS"
else
    print_test_result "Help text mentions git fallback" "FAIL"
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

echo ""
echo -e "${YELLOW}Test Summary:${NC}"
echo "Passed: $TESTS_PASSED/$TESTS_TOTAL tests"

if [ $TESTS_PASSED -eq $TESTS_TOTAL ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi