#!/bin/bash

# Comprehensive test for git fallback functionality
# Tests native implementations, fallback commands, and error handling

# set -e disabled to allow proper error handling in test functions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZIGGIT_BIN="${ZIGGIT_BIN:-$PROJECT_DIR/zig-out/bin/ziggit}"
TEST_DIR="/tmp/ziggit_fallback_test_$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
    ((TESTS_RUN++))
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

# Setup test repository
setup() {
    echo "Setting up test repository in $TEST_DIR"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Initialize with git first to create a proper repo
    git init -q
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create initial file and commit
    echo "initial content" > initial.txt
    git add initial.txt
    git commit -q -m "Initial commit"
    
    # Create branch for testing
    git checkout -q -b test-branch
    echo "branch content" > branch.txt  
    git add branch.txt
    git commit -q -m "Branch commit"
    git checkout -q master
    
    # Create a tag
    git tag v1.0.0
}

# Cleanup
cleanup() {
    echo "Cleaning up $TEST_DIR"
    rm -rf "$TEST_DIR"
}

# Test a native command that should work
test_native_command() {
    local cmd="$1"
    local expected_exit="$2"
    shift 2
    
    print_test "Native command: ziggit $cmd"
    
    set +e  # Temporarily disable exit on error
    $ZIGGIT_BIN $cmd "$@" >/dev/null 2>&1
    local exit_code=$?
    set -e  # Re-enable exit on error
    
    if [ "$exit_code" -eq "$expected_exit" ]; then
        print_pass "Native command '$cmd' exited with code $exit_code"
    else
        print_fail "Native command '$cmd' exited with code $exit_code, expected $expected_exit"
    fi
}

# Test a fallback command that should work
test_fallback_command() {
    local cmd="$1"
    local expected_exit="$2"
    shift 2
    
    print_test "Fallback command: ziggit $cmd"
    
    set +e  # Temporarily disable exit on error
    $ZIGGIT_BIN $cmd "$@" >/dev/null 2>&1
    local exit_code=$?
    set -e  # Re-enable exit on error
    
    if [ "$exit_code" -eq "$expected_exit" ]; then
        print_pass "Fallback command '$cmd' exited with code $exit_code"
    else
        print_fail "Fallback command '$cmd' exited with code $exit_code, expected $expected_exit"
    fi
}

# Test command with output
test_command_output() {
    local cmd="$1"
    local expected_pattern="$2"
    shift 2
    
    print_test "Command output: ziggit $cmd"
    
    set +e  # Temporarily disable exit on error
    local output
    output=$($ZIGGIT_BIN $cmd "$@" 2>&1)
    local exit_code=$?
    set -e  # Re-enable exit on error
    
    if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q "$expected_pattern"; then
        print_pass "Command '$cmd' produced expected output pattern '$expected_pattern'"
    else
        print_fail "Command '$cmd' failed or didn't match pattern '$expected_pattern'. Exit: $exit_code, Output: $output"
    fi
}

# Test error handling when git is not available
test_no_git_fallback() {
    print_test "Error handling when git is not available"
    
    # Temporarily rename git binary to test error handling
    local git_path
    git_path=$(which git)
    local git_backup="/tmp/git_backup_$$"
    
    # Move git binary temporarily
    sudo mv "$git_path" "$git_backup"
    
    # Test that fallback command shows proper error
    local output
    output=$($ZIGGIT_BIN stash list 2>&1 || true)
    local exit_code=$?
    
    # Restore git binary
    sudo mv "$git_backup" "$git_path"
    
    if [ "$exit_code" -eq 1 ] && echo "$output" | grep -q "git is not installed"; then
        print_pass "Proper error message when git is not available"
    else
        print_fail "Unexpected behavior when git is not available. Exit code: $exit_code, Output: $output"
    fi
}

# Main test execution
main() {
    echo "Starting git fallback comprehensive tests"
    echo "Using ziggit binary: $ZIGGIT_BIN"
    
    # Check if ziggit binary exists
    if [ ! -x "$ZIGGIT_BIN" ]; then
        echo "Error: ziggit binary not found at $ZIGGIT_BIN"
        echo "Please build ziggit first: zig build"
        exit 1
    fi
    
    setup
    
    echo
    echo "=== Testing Native Commands ==="
    
    # Test native commands that should work
    test_native_command "status" 0
    test_command_output "status" "On branch"
    
    test_native_command "rev-parse" 0 "HEAD"
    
    test_native_command "log" 0 "--oneline" "-1"
    test_command_output "log --oneline -1" "Initial commit"
    
    test_native_command "branch" 0
    test_command_output "branch" "master"
    
    test_native_command "tag" 0
    test_command_output "tag" "v1.0.0"
    
    test_native_command "describe" 0
    test_command_output "describe" "v1.0.0"
    
    test_native_command "diff" 0 "--name-only"
    
    echo
    echo "=== Testing Fallback Commands ==="
    
    # Test fallback commands that should work  
    test_fallback_command "stash list" 0
    
    test_fallback_command "remote -v" 0
    
    test_fallback_command "show HEAD" 0
    test_command_output "show HEAD" "Initial commit"
    
    test_fallback_command "ls-files" 0
    test_command_output "ls-files" "initial.txt"
    
    test_fallback_command "cat-file -t HEAD" 0
    test_command_output "cat-file -t HEAD" "commit"
    
    test_fallback_command "rev-list --count HEAD" 0
    test_command_output "rev-list --count HEAD" "1"
    
    test_fallback_command "log --graph --oneline -5" 0
    
    test_fallback_command "shortlog -sn -1" 0
    
    echo
    echo "=== Testing Error Handling ==="
    
    # Test error handling (this requires sudo, so we'll skip it in most cases)
    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        test_no_git_fallback
    else
        print_test "Error handling when git is not available (SKIPPED - requires sudo)"
        echo "Run as root or with sudo to test git unavailability handling"
    fi
    
    cleanup
    
    echo
    echo "=== Test Summary ==="
    echo "Tests run: $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED" 
    echo "Tests failed: $TESTS_FAILED"
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"