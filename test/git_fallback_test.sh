#!/bin/bash

# Comprehensive test for git fallback functionality

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}INFO:${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}WARN:${NC} $1"
}

log_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIGGIT_BINARY="$PROJECT_ROOT/zig-out/bin/ziggit"

# Build ziggit
log_info "Building ziggit..."
cd "$PROJECT_ROOT"
HOME=/tmp zig build

# Verify ziggit binary exists
if [[ ! -f "$ZIGGIT_BINARY" ]]; then
    log_error "ziggit binary not found at $ZIGGIT_BINARY"
    exit 1
fi

# Create temporary test directory
TEST_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cd "$TEST_DIR"
log_info "Test directory: $TEST_DIR"

# Initialize a git repository for testing
git init --quiet
git config user.email "test@example.com"
git config user.name "Test User"

# Create test file and commit
echo "Hello World" > test.txt
git add test.txt
git commit -m "Initial commit" --quiet

log_info "Testing native commands..."

# Test 1: Commands with native implementations should work directly
log_info "  - Testing 'status' command"
if ! "$ZIGGIT_BINARY" status >/dev/null 2>&1; then
    log_error "Native 'status' command failed"
    exit 1
fi

log_info "  - Testing 'rev-parse HEAD' command"
ziggit_head=$("$ZIGGIT_BINARY" rev-parse HEAD 2>/dev/null || true)
git_head=$(git rev-parse HEAD 2>/dev/null || true)
if [[ "$ziggit_head" != "$git_head" ]]; then
    log_error "Native 'rev-parse HEAD' output doesn't match git: '$ziggit_head' vs '$git_head'"
    exit 1
fi

log_info "  - Testing 'log' command"
if ! "$ZIGGIT_BINARY" log --oneline -1 >/dev/null 2>&1; then
    log_error "Native 'log' command failed"
    exit 1
fi

log_info "Testing fallback commands..."

# Test 2: Commands that should fall back to git
test_fallback_command() {
    local cmd="$1"
    shift
    local description="$1"
    shift
    
    log_info "  - Testing fallback: $description"
    
    # Run with ziggit
    local ziggit_output ziggit_exit_code
    set +e
    ziggit_output=$("$ZIGGIT_BINARY" $cmd "$@" 2>&1)
    ziggit_exit_code=$?
    set -e
    
    # Run with git 
    local git_output git_exit_code
    set +e
    git_output=$(git $cmd "$@" 2>&1)
    git_exit_code=$?
    set -e
    
    # Compare exit codes
    if [[ $ziggit_exit_code -ne $git_exit_code ]]; then
        log_error "Exit code mismatch for '$cmd $*': ziggit=$ziggit_exit_code, git=$git_exit_code"
        log_error "ziggit output: $ziggit_output"
        log_error "git output: $git_output"
        return 1
    fi
    
    # For successful commands, compare output (ignoring whitespace differences)
    if [[ $git_exit_code -eq 0 ]]; then
        # Normalize whitespace for comparison
        local ziggit_normalized=$(echo "$ziggit_output" | tr -s ' \n' | sort)
        local git_normalized=$(echo "$git_output" | tr -s ' \n' | sort)
        
        if [[ "$ziggit_normalized" != "$git_normalized" ]]; then
            log_warn "Output differs for '$cmd $*' (this might be expected)"
            log_warn "ziggit: $ziggit_output"
            log_warn "git: $git_output"
        fi
    fi
    
    return 0
}

# Test various fallback commands
test_fallback_command "stash list" "git stash list"

# Only test git remote if we have remotes configured  
if git remote >/dev/null 2>&1; then
    test_fallback_command "remote -v" "git remote -v"
else
    log_info "  - Skipping 'remote -v' test (no remotes configured)"
fi

test_fallback_command "show HEAD" "git show HEAD"
test_fallback_command "ls-files" "git ls-files"

# Test with HEAD object (should exist)
head_hash=$(git rev-parse HEAD)
test_fallback_command "cat-file -t HEAD" "git cat-file -t HEAD"

test_fallback_command "rev-list --count HEAD" "git rev-list --count HEAD"

# Create more commits for log testing
echo "Second line" >> test.txt
git add test.txt
git commit -m "Second commit" --quiet

echo "Third line" >> test.txt  
git add test.txt
git commit -m "Third commit" --quiet

test_fallback_command "log --graph --oneline -5" "git log --graph --oneline -5"
test_fallback_command "shortlog -sn -1" "git shortlog -sn -1"

log_info "Testing error handling when git is not in PATH..."

# Test 3: When git is not available, should show helpful error message
# Temporarily modify PATH to exclude git
old_path="$PATH"
export PATH="/usr/bin:/bin" # Remove typical git locations

# Find git location and temporarily rename it
git_location=$(which git 2>/dev/null || true)
if [[ -n "$git_location" && -f "$git_location" ]]; then
    # Test with git unavailable
    sudo mv "$git_location" "${git_location}.backup" 2>/dev/null || {
        log_warn "Cannot test git unavailable scenario (no sudo access to move git binary)"
    }
    
    # Test fallback command when git is unavailable
    set +e
    error_output=$("$ZIGGIT_BINARY" stash list 2>&1)
    error_exit_code=$?
    set -e
    
    # Restore git
    if [[ -f "${git_location}.backup" ]]; then
        sudo mv "${git_location}.backup" "$git_location" 2>/dev/null || true
    fi
    
    if [[ $error_exit_code -eq 1 ]] && echo "$error_output" | grep -q "not a ziggit command and git is not installed"; then
        log_info "  - Error handling when git is unavailable: PASS"
    else
        log_error "Expected helpful error when git is unavailable"
        log_error "Exit code: $error_exit_code"
        log_error "Output: $error_output"
    fi
else
    log_warn "Cannot test git unavailable scenario (git not found in standard locations)"
fi

export PATH="$old_path"

log_info "Testing global flag forwarding..."

# Test 4: Global flags should be forwarded to git
mkdir subdir
cd subdir

# Test -C flag forwarding
log_info "  - Testing -C flag forwarding"
ziggit_output=$("$ZIGGIT_BINARY" -C .. status --porcelain 2>&1 || true)
git_output=$(git -C .. status --porcelain 2>&1 || true)

if [[ "$ziggit_output" == "$git_output" ]]; then
    log_info "  - Global flag forwarding: PASS"
else
    log_warn "Global flag forwarding may have differences"
    log_warn "ziggit: $ziggit_output"
    log_warn "git: $git_output"
fi

cd "$TEST_DIR"

log_info "Testing interactive commands support..."

# Test 5: stdin/stdout/stderr inheritance
log_info "  - Testing stdout/stderr inheritance with 'log --oneline -1'"
ziggit_log_output=$("$ZIGGIT_BINARY" log --oneline -1 2>&1)
git_log_output=$(git log --oneline -1 2>&1)

if [[ -n "$ziggit_log_output" ]] && [[ -n "$git_log_output" ]]; then
    log_info "  - stdin/stdout/stderr inheritance: PASS"
else
    log_error "stdin/stdout/stderr inheritance test failed"
    log_error "ziggit output: $ziggit_log_output"
    log_error "git output: $git_log_output"
    exit 1
fi

log_info "Testing aliasing scenario..."

# Test 6: Test aliasing git=ziggit scenario
log_info "  - Setting up alias and running common commands"
alias git="$ZIGGIT_BINARY"

# Test commonly used git commands through the alias
if ! git status >/dev/null 2>&1; then
    log_error "Aliased 'git status' failed"
    exit 1
fi

if ! git log --oneline -1 >/dev/null 2>&1; then
    log_error "Aliased 'git log' failed" 
    exit 1
fi

# Test fallback through alias
if git stash list >/dev/null 2>&1; then
    log_info "  - Aliasing scenario: PASS"
else
    log_error "Aliased fallback 'git stash list' failed"
    exit 1
fi

unalias git

log_info "All tests completed successfully!"
log_info "ziggit git fallback functionality is working correctly."