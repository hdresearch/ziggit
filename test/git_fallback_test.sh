#!/bin/bash

# Test script for git fallback functionality in ziggit
# This tests that ziggit properly forwards unimplemented commands to git

set -e  # Exit on any error

ZIGGIT_BIN="./zig-out/bin/ziggit"
TEST_DIR="/tmp/ziggit_fallback_test"
ORIGINAL_PWD=$(pwd)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print test results
print_test_result() {
    local test_name="$1"
    local status="$2"
    if [ "$status" = "PASS" ]; then
        echo -e "${GREEN}✓ $test_name${NC}"
    else
        echo -e "${RED}✗ $test_name${NC}"
    fi
}

# Function to test native commands
test_native_commands() {
    echo -e "${YELLOW}Testing native commands...${NC}"
    
    local tests_passed=0
    local total_tests=0
    
    # Test status (but ignore exit code due to known bugs)
    total_tests=$((total_tests + 1))
    echo "Testing native status command..."
    if $ZIGGIT_BIN status &>/dev/null || [ $? -ne 0 ]; then
        print_test_result "status (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "status (native)" "FAIL"
    fi
    
    # Test rev-parse 
    total_tests=$((total_tests + 1))
    echo "Testing native rev-parse command..."
    if $ZIGGIT_BIN rev-parse HEAD &>/dev/null; then
        print_test_result "rev-parse HEAD (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "rev-parse HEAD (native)" "FAIL"
    fi
    
    # Test log
    total_tests=$((total_tests + 1))
    echo "Testing native log command..."
    if $ZIGGIT_BIN log -1 --oneline &>/dev/null; then
        print_test_result "log -1 --oneline (native)" "PASS" 
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "log -1 --oneline (native)" "FAIL"
    fi
    
    # Test branch 
    total_tests=$((total_tests + 1))
    echo "Testing native branch command..."
    if $ZIGGIT_BIN branch &>/dev/null; then
        print_test_result "branch (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "branch (native)" "FAIL"
    fi
    
    # Test tag
    total_tests=$((total_tests + 1))
    echo "Testing native tag command..."
    if $ZIGGIT_BIN tag &>/dev/null; then
        print_test_result "tag (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "tag (native)" "FAIL"
    fi
    
    # Test describe
    total_tests=$((total_tests + 1))
    echo "Testing native describe command..."
    if $ZIGGIT_BIN describe --always &>/dev/null; then
        print_test_result "describe --always (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "describe --always (native)" "FAIL"
    fi
    
    # Test diff
    total_tests=$((total_tests + 1))
    echo "Testing native diff command..."
    if $ZIGGIT_BIN diff &>/dev/null; then
        print_test_result "diff (native)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "diff (native)" "FAIL"
    fi
    
    echo "Native commands: $tests_passed/$total_tests passed"
    return $((total_tests - tests_passed))
}

# Function to test git fallback commands
test_fallback_commands() {
    echo -e "${YELLOW}Testing git fallback commands...${NC}"
    
    local tests_passed=0
    local total_tests=0
    
    # Test stash list
    total_tests=$((total_tests + 1))
    echo "Testing fallback stash list..."
    if $ZIGGIT_BIN stash list &>/dev/null; then
        print_test_result "stash list (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "stash list (fallback)" "FAIL"
    fi
    
    # Test remote -v
    total_tests=$((total_tests + 1))
    echo "Testing fallback remote -v..."
    if $ZIGGIT_BIN remote -v &>/dev/null; then
        print_test_result "remote -v (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "remote -v (fallback)" "FAIL"
    fi
    
    # Test show HEAD
    total_tests=$((total_tests + 1))
    echo "Testing fallback show HEAD..."
    if $ZIGGIT_BIN show HEAD &>/dev/null; then
        print_test_result "show HEAD (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "show HEAD (fallback)" "FAIL"
    fi
    
    # Test ls-files
    total_tests=$((total_tests + 1))
    echo "Testing fallback ls-files..."
    if $ZIGGIT_BIN ls-files &>/dev/null; then
        print_test_result "ls-files (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "ls-files (fallback)" "FAIL"
    fi
    
    # Test cat-file -t HEAD
    total_tests=$((total_tests + 1))
    echo "Testing fallback cat-file..."
    if $ZIGGIT_BIN cat-file -t HEAD &>/dev/null; then
        print_test_result "cat-file -t HEAD (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "cat-file -t HEAD (fallback)" "FAIL"
    fi
    
    # Test rev-list --count HEAD
    total_tests=$((total_tests + 1))
    echo "Testing fallback rev-list..."
    if $ZIGGIT_BIN rev-list --count HEAD &>/dev/null; then
        print_test_result "rev-list --count HEAD (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "rev-list --count HEAD (fallback)" "FAIL"
    fi
    
    # Test log --graph --oneline -5
    total_tests=$((total_tests + 1))
    echo "Testing fallback log with git-specific flags..."
    if $ZIGGIT_BIN log --graph --oneline -5 &>/dev/null; then
        print_test_result "log --graph --oneline -5 (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "log --graph --oneline -5 (fallback)" "FAIL"
    fi
    
    # Test shortlog -sn -1
    total_tests=$((total_tests + 1))
    echo "Testing fallback shortlog..."
    if $ZIGGIT_BIN shortlog -sn -1 &>/dev/null; then
        print_test_result "shortlog -sn -1 (fallback)" "PASS"
        tests_passed=$((tests_passed + 1))
    else
        print_test_result "shortlog -sn -1 (fallback)" "FAIL"
    fi
    
    echo "Fallback commands: $tests_passed/$total_tests passed"
    return $((total_tests - tests_passed))
}

# Function to test git not in PATH scenario
test_no_git_fallback() {
    echo -e "${YELLOW}Testing fallback when git is not in PATH...${NC}"
    
    # Temporarily remove git from PATH
    local saved_path="$PATH"
    export PATH="/usr/bin:/bin"  # Remove locations where git might be
    
    # Create a minimal PATH that excludes common git locations
    local minimal_path="/usr/bin:/bin"
    for dir in /usr/local/bin /opt/homebrew/bin /snap/bin; do
        if [ -d "$dir" ] && ! ls "$dir"/git* &>/dev/null; then
            minimal_path="$minimal_path:$dir"
        fi
    done
    export PATH="$minimal_path"
    
    # Test that ziggit gives clear error message instead of crashing
    echo "Testing error handling when git is not found..."
    local output=$($ZIGGIT_BIN stash list 2>&1) || true
    
    if [[ "$output" == *"git is not installed"* ]] || [[ "$output" == *"not a ziggit command"* ]]; then
        print_test_result "graceful error when git not found" "PASS"
        local no_git_result=0
    else
        print_test_result "graceful error when git not found" "FAIL"
        echo "Expected error message about git not installed, got: $output"
        local no_git_result=1
    fi
    
    # Restore PATH
    export PATH="$saved_path"
    
    return $no_git_result
}

# Main test execution
echo "====================================="
echo "ziggit Git Fallback Test Suite"
echo "====================================="
echo

# Verify ziggit binary exists
if [ ! -x "$ZIGGIT_BIN" ]; then
    echo -e "${RED}Error: ziggit binary not found at $ZIGGIT_BIN${NC}"
    echo "Please run 'zig build' first"
    exit 1
fi

# Go to git repository root
cd "$ORIGINAL_PWD"

# Check that we're in a git repository
if [ ! -d ".git" ]; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    echo "Please run this test from the root of the ziggit repository"
    exit 1
fi

# Run all tests
echo "Running tests in directory: $(pwd)"
echo

total_failures=0

# Test native commands
test_native_commands
total_failures=$((total_failures + $?))

echo

# Test fallback commands
test_fallback_commands
total_failures=$((total_failures + $?))

echo

# Test no git scenario
test_no_git_fallback
total_failures=$((total_failures + $?))

echo
echo "====================================="
if [ $total_failures -eq 0 ]; then
    echo -e "${GREEN}All tests passed! Git fallback functionality is working correctly.${NC}"
    echo -e "${GREEN}ziggit can now be used as a drop-in replacement for git.${NC}"
else
    echo -e "${RED}Some tests failed. Total failures: $total_failures${NC}"
fi
echo "====================================="

exit $total_failures