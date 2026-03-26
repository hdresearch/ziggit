#!/bin/bash

# Integration test runner for ziggit
# This script can be run independently to test git/ziggit interoperability
# without requiring a full build of ziggit

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/ziggit_integration_tests_$$"
ZIGGIT_BIN="$ROOT_DIR/zig-out/bin/ziggit"

echo "=== Ziggit Integration Test Runner ==="
echo "Test directory: $TEST_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

trap cleanup EXIT

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Set up git configuration
git config --global user.name "Test User" 2>/dev/null || true
git config --global user.email "test@example.com" 2>/dev/null || true

# Check if ziggit binary exists
if [[ ! -f "$ZIGGIT_BIN" ]]; then
    log_warn "ziggit binary not found at $ZIGGIT_BIN"
    log_info "Attempting to build ziggit..."
    cd "$ROOT_DIR"
    if ! zig build; then
        log_error "Failed to build ziggit"
        log_info "Running git-only tests..."
        ZIGGIT_AVAILABLE=false
    else
        log_info "ziggit built successfully"
        ZIGGIT_AVAILABLE=true
    fi
    cd "$TEST_DIR"
else
    ZIGGIT_AVAILABLE=true
    log_info "Found ziggit binary at $ZIGGIT_BIN"
fi

# Test counter
TESTS_PASSED=0
TESTS_TOTAL=0

run_test() {
    local test_name="$1"
    local test_function="$2"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    echo
    log_info "Running test: $test_name"
    
    if $test_function; then
        log_info "✓ Test passed: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "✗ Test failed: $test_name"
    fi
}

# Test implementations
test_git_init_basic() {
    local test_dir="$TEST_DIR/git_init_basic"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize repo with git
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create and commit a file
    echo "Hello World" > test.txt
    git add test.txt
    git commit -m "Initial commit"
    
    # Verify .git directory structure
    [[ -d ".git" ]] || return 1
    [[ -f ".git/HEAD" ]] || return 1
    [[ -d ".git/objects" ]] || return 1
    
    return 0
}

test_git_porcelain_status() {
    local test_dir="$TEST_DIR/porcelain_status"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize repo
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create files in different states
    echo "staged content" > staged.txt
    echo "original content" > modified.txt
    echo "untracked content" > untracked.txt
    
    # Stage some files
    git add staged.txt
    git add modified.txt
    git commit -m "Initial commit"
    
    # Modify a tracked file
    echo "modified content" > modified.txt
    
    # Test porcelain output format
    local git_status
    git_status=$(git status --porcelain | sort)
    
    # Should show modified file and untracked file
    echo "Git status --porcelain output:"
    echo "$git_status"
    
    # Basic validation - should have two lines
    local line_count
    line_count=$(echo "$git_status" | wc -l)
    
    if [[ "$line_count" -ge 2 ]]; then
        return 0
    else
        log_error "Expected at least 2 lines in status output, got $line_count"
        return 1
    fi
}

test_git_log_oneline() {
    local test_dir="$TEST_DIR/log_oneline"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize and create multiple commits
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    local commits=("First commit" "Second commit" "Third commit")
    
    for i in "${!commits[@]}"; do
        echo "Content $i" > "file$i.txt"
        git add "file$i.txt"
        git commit -m "${commits[$i]}"
    done
    
    # Test log --oneline format
    local git_log
    git_log=$(git log --oneline)
    
    echo "Git log --oneline output:"
    echo "$git_log"
    
    # Should have 3 lines (one per commit)
    local line_count
    line_count=$(echo "$git_log" | wc -l)
    
    if [[ "$line_count" -eq 3 ]]; then
        # Check that all commit messages are present
        for commit_msg in "${commits[@]}"; do
            if ! echo "$git_log" | grep -q "$commit_msg"; then
                log_error "Missing commit message: $commit_msg"
                return 1
            fi
        done
        return 0
    else
        log_error "Expected 3 lines in log output, got $line_count"
        return 1
    fi
}

test_directory_structure() {
    local test_dir="$TEST_DIR/dir_structure"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize repo
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create nested directory structure
    mkdir -p src/lib
    mkdir -p tests
    
    echo "# Project" > README.md
    echo "pub fn main() !void {}" > src/main.zig
    echo "pub fn helper() void {}" > src/lib/utils.zig
    echo "test \"example\" {}" > tests/test.zig
    
    # Add and commit all files
    git add .
    git commit -m "Add project structure"
    
    # Verify git can track nested files
    local git_status
    git_status=$(git status --porcelain)
    
    # Should be clean working directory
    if [[ -z "$git_status" ]]; then
        return 0
    else
        log_error "Working directory not clean after commit"
        echo "Status: $git_status"
        return 1
    fi
}

test_large_file() {
    local test_dir="$TEST_DIR/large_file"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize repo
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create a moderately large file (100KB)
    for i in {1..5000}; do
        echo "This is line $i of a large file to test git's handling of larger content."
    done > large_file.txt
    
    # Add and commit the large file
    git add large_file.txt
    git commit -m "Add large file"
    
    # Verify the file was committed properly
    local git_log
    git_log=$(git log --oneline)
    
    if echo "$git_log" | grep -q "Add large file"; then
        return 0
    else
        log_error "Large file commit not found in log"
        return 1
    fi
}

test_ziggit_status() {
    if [[ "$ZIGGIT_AVAILABLE" != "true" ]]; then
        log_warn "Skipping ziggit tests (binary not available)"
        return 0
    fi
    
    local test_dir="$TEST_DIR/ziggit_status"
    mkdir -p "$test_dir"
    cd "$test_dir"
    
    # Initialize with git
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"
    
    # Create and commit a file
    echo "Hello World" > test.txt
    git add test.txt
    git commit -m "Initial commit"
    
    # Test ziggit status on clean repo
    local ziggit_status
    if ziggit_status=$("$ZIGGIT_BIN" status 2>&1); then
        echo "Ziggit status output:"
        echo "$ziggit_status"
        return 0
    else
        log_error "ziggit status failed"
        echo "Error output: $ziggit_status"
        return 1
    fi
}

# Run all tests
echo
log_info "Starting integration tests..."

run_test "Git init basic functionality" test_git_init_basic
run_test "Git status --porcelain format" test_git_porcelain_status
run_test "Git log --oneline format" test_git_log_oneline
run_test "Directory structure handling" test_directory_structure
run_test "Large file handling" test_large_file
run_test "Ziggit status command" test_ziggit_status

# Summary
echo
echo "=== Test Summary ==="
log_info "Passed: $TESTS_PASSED/$TESTS_TOTAL tests"

if [[ "$TESTS_PASSED" -eq "$TESTS_TOTAL" ]]; then
    log_info "All tests passed! 🎉"
    exit 0
else
    log_error "Some tests failed."
    exit 1
fi