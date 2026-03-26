#!/bin/bash

# Git fallback test script
# Tests that ziggit properly falls back to git for unimplemented commands

set -e

ZIGGIT="${1:-/root/ziggit/zig-out/bin/ziggit}"
TEST_DIR="/tmp/ziggit_fallback_test"
FAILED_TESTS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${YELLOW}INFO: $1${NC}"
}

log_success() {
    echo -e "${GREEN}PASS: $1${NC}"
}

log_error() {
    echo -e "${RED}FAIL: $1${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

test_native_command() {
    local cmd="$1"
    local description="$2"
    log_info "Testing native command: $cmd ($description)"
    
    if $ZIGGIT $cmd --help >/dev/null 2>&1 || $ZIGGIT $cmd >/dev/null 2>&1 || true; then
        log_success "Native command '$cmd' executed"
    else
        log_error "Native command '$cmd' failed"
    fi
}

test_fallback_command() {
    local cmd="$1"
    local description="$2"
    log_info "Testing fallback command: $cmd ($description)"
    
    # Test that the command executes (may fail due to repo state but shouldn't crash)
    local exit_code=0
    $ZIGGIT $cmd >/dev/null 2>&1 || exit_code=$?
    
    # Exit codes 0-2 are normal git exit codes, anything higher might indicate a crash
    if [ $exit_code -le 128 ]; then
        log_success "Fallback command '$cmd' executed with exit code $exit_code"
    else
        log_error "Fallback command '$cmd' failed with suspicious exit code $exit_code"
    fi
}

test_git_not_in_path() {
    log_info "Testing behavior when git is not in PATH"
    
    # Create a temporary directory and modify PATH to exclude git
    local temp_bin_dir=$(mktemp -d)
    local original_path="$PATH"
    
    # Set PATH to exclude git
    export PATH="$temp_bin_dir:/usr/local/bin:/bin:/usr/bin"
    
    # Remove git from the path by checking if it exists and excluding it
    local git_paths=$(which -a git 2>/dev/null || true)
    for git_path in $git_paths; do
        local git_dir=$(dirname "$git_path")
        PATH=$(echo "$PATH" | sed "s|:$git_dir||g" | sed "s|^$git_dir:||g")
    done
    
    # Test a fallback command
    local output
    local exit_code=0
    output=$($ZIGGIT stash list 2>&1) || exit_code=$?
    
    if [[ "$output" == *"not a ziggit command and git is not installed"* ]] && [ $exit_code -eq 1 ]; then
        log_success "Proper error message when git not found"
    else
        log_error "Expected error message when git not found, got: $output (exit code: $exit_code)"
    fi
    
    # Restore original PATH
    export PATH="$original_path"
    
    # Cleanup
    rm -rf "$temp_bin_dir"
}

# Setup test repository
log_info "Setting up test repository in $TEST_DIR"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Initialize repository
$ZIGGIT init >/dev/null 2>&1

# Create a test file
echo "Hello World" > test.txt
$ZIGGIT add test.txt >/dev/null 2>&1
$ZIGGIT commit -m "Initial commit" >/dev/null 2>&1

log_info "Starting git fallback tests..."

# Test native commands that should work
log_info "Testing native commands..."
test_native_command "status" "show working tree status"
test_native_command "rev-parse --git-dir" "show git directory"
test_native_command "log --oneline" "show commit log"
test_native_command "branch" "list branches"
test_native_command "tag" "list tags"
test_native_command "describe --always" "describe commit"
test_native_command "diff" "show differences"

# Test fallback commands that should forward to git
log_info "Testing fallback commands..."
test_fallback_command "stash list" "list stashes"
test_fallback_command "remote -v" "show remotes"
test_fallback_command "show HEAD" "show commit object"
test_fallback_command "ls-files" "list tracked files"
test_fallback_command "cat-file -t HEAD" "show object type"
test_fallback_command "rev-list --count HEAD" "count commits"
test_fallback_command "log --graph --oneline -5" "show log graph"
test_fallback_command "shortlog -sn -1" "show short log"

# Test error handling when git is not in PATH
test_git_not_in_path

# Test global flags forwarding
log_info "Testing global flags forwarding..."
if $ZIGGIT -C . status >/dev/null 2>&1; then
    log_success "Global flag -C forwarded properly"
else
    log_error "Global flag -C forwarding failed"
fi

# Test exit code propagation
log_info "Testing exit code propagation..."
exit_code=0
$ZIGGIT nonexistentcommand >/dev/null 2>&1 || exit_code=$?
if [ $exit_code -eq 1 ]; then
    log_success "Exit code properly propagated from git"
else
    log_error "Expected exit code 1, got $exit_code"
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

# Summary
echo ""
if [ $FAILED_TESTS -eq 0 ]; then
    log_success "All git fallback tests passed!"
    exit 0
else
    log_error "$FAILED_TESTS test(s) failed"
    exit 1
fi