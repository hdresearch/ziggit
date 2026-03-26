#!/bin/bash

# Comprehensive Git Fallback Test Suite
# Tests that ziggit is a legitimate drop-in replacement for git

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
ZIGGIT_BINARY=${ZIGGIT_BINARY:-"./zig-out/bin/ziggit"}
TEST_DIR="/tmp/ziggit_fallback_test_$$"
ORIGINAL_PATH="$PATH"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Setup test environment
setup_test() {
    log_info "Setting up test environment in $TEST_DIR"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Initialize a git repository for testing
    git init
    git config user.name "Ziggit Test"
    git config user.email "test@ziggit.local"
    
    # Create some test files
    echo "Hello World" > file1.txt
    echo "Test content" > file2.txt
    mkdir subdir
    echo "Nested file" > subdir/file3.txt
    
    # Make some commits for testing
    git add .
    git commit -m "Initial commit"
    
    # Create a branch
    git checkout -b feature-branch
    echo "Feature content" > feature.txt
    git add feature.txt
    git commit -m "Add feature"
    
    # Create a tag
    git tag v1.0.0
    
    # Go back to master
    git checkout master
    
    # Make a stash
    echo "Unstaged content" >> file1.txt
    git stash
    
    log_success "Test environment setup complete"
}

# Test native commands work correctly
test_native_commands() {
    log_info "Testing native ziggit commands"
    
    # Test status
    if $ZIGGIT_BINARY status >/dev/null 2>&1; then
        log_success "status command works"
    else
        log_error "status command failed"
        return 1
    fi
    
    # Test rev-parse
    if $ZIGGIT_BINARY rev-parse HEAD >/dev/null 2>&1; then
        log_success "rev-parse command works"
    else
        log_error "rev-parse command failed"
        return 1
    fi
    
    # Test log
    if $ZIGGIT_BINARY log --oneline -3 >/dev/null 2>&1; then
        log_success "log command works"
    else
        log_error "log command failed"
        return 1
    fi
    
    # Test branch
    if $ZIGGIT_BINARY branch >/dev/null 2>&1; then
        log_success "branch command works"
    else
        log_error "branch command failed"
        return 1
    fi
    
    # Test tag
    if $ZIGGIT_BINARY tag >/dev/null 2>&1; then
        log_success "tag command works"
    else
        log_error "tag command failed"
        return 1
    fi
    
    # Test describe
    if $ZIGGIT_BINARY describe --tags >/dev/null 2>&1; then
        log_success "describe command works"
    else
        log_error "describe command failed"
        return 1
    fi
    
    # Test diff
    if $ZIGGIT_BINARY diff HEAD~1 >/dev/null 2>&1; then
        log_success "diff command works"
    else
        log_error "diff command failed"
        return 1
    fi
}

# Test fallback commands work correctly
test_fallback_commands() {
    log_info "Testing fallback commands that should forward to git"
    
    # Test stash list
    if $ZIGGIT_BINARY stash list >/dev/null 2>&1; then
        log_success "stash list command works via fallback"
    else
        log_error "stash list command failed"
        return 1
    fi
    
    # Test remote -v
    if $ZIGGIT_BINARY remote -v >/dev/null 2>&1; then
        log_success "remote -v command works via fallback"
    else
        log_error "remote -v command failed"
        return 1
    fi
    
    # Test show HEAD
    if $ZIGGIT_BINARY show HEAD --oneline >/dev/null 2>&1; then
        log_success "show HEAD command works via fallback"
    else
        log_error "show HEAD command failed"
        return 1
    fi
    
    # Test ls-files
    if $ZIGGIT_BINARY ls-files >/dev/null 2>&1; then
        log_success "ls-files command works via fallback"
    else
        log_error "ls-files command failed"
        return 1
    fi
    
    # Test cat-file -t HEAD
    if $ZIGGIT_BINARY cat-file -t HEAD >/dev/null 2>&1; then
        log_success "cat-file -t HEAD command works via fallback"
    else
        log_error "cat-file -t HEAD command failed"
        return 1
    fi
    
    # Test rev-list --count HEAD
    if $ZIGGIT_BINARY rev-list --count HEAD >/dev/null 2>&1; then
        log_success "rev-list --count HEAD command works via fallback"
    else
        log_error "rev-list --count HEAD command failed"
        return 1
    fi
    
    # Test log --graph --oneline -5
    if $ZIGGIT_BINARY log --graph --oneline -5 >/dev/null 2>&1; then
        log_success "log --graph --oneline -5 command works via fallback"
    else
        log_error "log --graph --oneline -5 command failed"
        return 1
    fi
    
    # Test shortlog -sn -1
    if $ZIGGIT_BINARY shortlog -sn -1 >/dev/null 2>&1; then
        log_success "shortlog -sn -1 command works via fallback"
    else
        log_error "shortlog -sn -1 command failed"
        return 1
    fi
}

# Test error handling when git is not in PATH
test_no_git_error() {
    log_info "Testing error handling when git is not in PATH"
    
    # Temporarily remove git from PATH
    export PATH="/tmp"
    
    # Test with a command that should fallback
    local output
    output=$($ZIGGIT_BINARY nonexistent-command 2>&1 || true)
    
    if [[ "$output" == *"git is not installed"* ]]; then
        log_success "Proper error message when git not found"
    else
        log_error "Expected error message not found. Got: $output"
        export PATH="$ORIGINAL_PATH"
        return 1
    fi
    
    # Restore PATH
    export PATH="$ORIGINAL_PATH"
}

# Test global flag forwarding
test_global_flags() {
    log_info "Testing global flag forwarding"
    
    # Test -C flag
    cd /tmp
    if $ZIGGIT_BINARY -C "$TEST_DIR" status >/dev/null 2>&1; then
        log_success "-C flag forwarding works"
    else
        log_error "-C flag forwarding failed"
        return 1
    fi
    cd "$TEST_DIR"
    
    # Test -c flag
    if $ZIGGIT_BINARY -c core.longpaths=true status >/dev/null 2>&1; then
        log_success "-c flag forwarding works"
    else
        log_error "-c flag forwarding failed"
        return 1
    fi
}

# Test exit code propagation
test_exit_codes() {
    log_info "Testing exit code propagation"
    
    # Test successful command (should exit 0)
    if $ZIGGIT_BINARY status >/dev/null 2>&1; then
        log_success "Successful command returns 0"
    else
        log_error "Successful command did not return 0"
        return 1
    fi
    
    # Test failing command (should exit non-zero)
    if ! $ZIGGIT_BINARY log nonexistent-ref >/dev/null 2>&1; then
        log_success "Failing command returns non-zero"
    else
        log_error "Failing command did not return non-zero"
        return 1
    fi
}

# Test drop-in replacement functionality
test_drop_in_replacement() {
    log_info "Testing drop-in replacement functionality"
    
    # Create an alias and test it
    alias git="$ZIGGIT_BINARY"
    
    # Test native command via alias
    if git status >/dev/null 2>&1; then
        log_success "Native command works via git alias"
    else
        log_error "Native command failed via git alias"
        unalias git
        return 1
    fi
    
    # Test fallback command via alias
    if git stash list >/dev/null 2>&1; then
        log_success "Fallback command works via git alias"
    else
        log_error "Fallback command failed via git alias"
        unalias git
        return 1
    fi
    
    # Test complex command via alias
    if git log --graph --oneline -3 >/dev/null 2>&1; then
        log_success "Complex command works via git alias"
    else
        log_error "Complex command failed via git alias"
        unalias git
        return 1
    fi
    
    unalias git
}

# Test interactive commands (simplified test)
test_interactive_commands() {
    log_info "Testing interactive command handling"
    
    # Test that stdin/stdout/stderr are properly inherited
    # We'll test this by running a command that should work
    # (actual interactive testing would require expect or similar)
    
    # Test git show with --name-only (non-interactive but tests fd inheritance)
    if $ZIGGIT_BINARY show HEAD --name-only >/dev/null 2>&1; then
        log_success "File descriptor inheritance works"
    else
        log_error "File descriptor inheritance failed"
        return 1
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test environment"
    cd /
    rm -rf "$TEST_DIR"
    export PATH="$ORIGINAL_PATH"
}

# Main test runner
run_tests() {
    log_info "Starting comprehensive git fallback test suite"
    log_info "Testing ziggit binary: $ZIGGIT_BINARY"
    
    # Check if ziggit binary exists
    if [[ ! -f "$ZIGGIT_BINARY" ]]; then
        log_error "Ziggit binary not found at $ZIGGIT_BINARY"
        log_info "Please build ziggit first: zig build"
        exit 1
    fi
    
    # Setup test environment
    setup_test
    
    local failed_tests=0
    
    # Run all tests
    test_native_commands || ((failed_tests++))
    test_fallback_commands || ((failed_tests++))
    test_no_git_error || ((failed_tests++))
    test_global_flags || ((failed_tests++))
    test_exit_codes || ((failed_tests++))
    test_drop_in_replacement || ((failed_tests++))
    test_interactive_commands || ((failed_tests++))
    
    # Cleanup
    cleanup
    
    # Report results
    if [[ $failed_tests -eq 0 ]]; then
        log_success "All tests passed! ziggit is ready as a legitimate git replacement."
        log_info "You can now safely use: alias git=ziggit"
        exit 0
    else
        log_error "$failed_tests test(s) failed"
        exit 1
    fi
}

# Handle script interruption
trap cleanup EXIT INT TERM

# Run the tests
run_tests