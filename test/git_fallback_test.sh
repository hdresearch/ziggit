#!/bin/bash

# test/git_fallback_test.sh - Comprehensive test for git CLI fallback functionality

set -e
TEST_DIR="/tmp/ziggit_test_$$"
ZIGGIT_BIN="$(pwd)/zig-out/bin/ziggit"
ORIGINAL_PATH="$PATH"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

function log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

function log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    exit 1
}

function setup_test_repo() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Initialize repo with ziggit
    "$ZIGGIT_BIN" init >/dev/null 2>&1
    
    # Configure git user (needed for commits)
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create some test content
    echo "Initial content" > file1.txt
    echo "Another file" > file2.txt
    mkdir subdir
    echo "Nested file" > subdir/file3.txt
    
    # Add and commit some content for testing
    git add file1.txt file2.txt subdir/file3.txt
    git commit -m "Initial commit" >/dev/null 2>&1
    
    # Create a tag for testing
    git tag v1.0 >/dev/null 2>&1
    
    # Make some changes for testing diff/status
    echo "Modified content" >> file1.txt
    echo "New file" > file4.txt
}

function cleanup() {
    cd /
    rm -rf "$TEST_DIR"
    export PATH="$ORIGINAL_PATH"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

log_test "Setting up test repository..."
setup_test_repo

log_test "Testing native commands work correctly..."

# Test native commands
log_test "Testing ziggit status (native)"
"$ZIGGIT_BIN" status >/dev/null || log_error "Native status command failed"
log_success "Native status works"

log_test "Testing ziggit rev-parse HEAD (native)"
"$ZIGGIT_BIN" rev-parse HEAD >/dev/null || log_error "Native rev-parse command failed"
log_success "Native rev-parse works"

log_test "Testing ziggit log -1 --format=%H (native)"
"$ZIGGIT_BIN" log -1 --format=%H >/dev/null || log_error "Native log command failed"
log_success "Native log works"

log_test "Testing ziggit branch (native)"
"$ZIGGIT_BIN" branch >/dev/null || log_error "Native branch command failed"
log_success "Native branch works"

log_test "Testing ziggit tag (native)"
"$ZIGGIT_BIN" tag >/dev/null || log_error "Native tag command failed"
log_success "Native tag works"

log_test "Testing ziggit describe --tags (native)"
"$ZIGGIT_BIN" describe --tags >/dev/null || log_error "Native describe command failed"
log_success "Native describe works"

log_test "Testing ziggit diff (native)"
"$ZIGGIT_BIN" diff >/dev/null || log_error "Native diff command failed"
log_success "Native diff works"

log_test "Testing git fallback commands work correctly..."

# Test fallback commands
log_test "Testing ziggit stash list (fallback)"
"$ZIGGIT_BIN" stash list >/dev/null 2>&1 || log_error "Fallback stash command failed"
log_success "Fallback stash works"

log_test "Testing ziggit remote -v (fallback)"
"$ZIGGIT_BIN" remote -v >/dev/null 2>&1 || log_error "Fallback remote command failed"
log_success "Fallback remote works"

log_test "Testing ziggit show HEAD (fallback)"
"$ZIGGIT_BIN" show HEAD >/dev/null 2>&1 || log_error "Fallback show command failed"
log_success "Fallback show works"

log_test "Testing ziggit ls-files (fallback)"
"$ZIGGIT_BIN" ls-files >/dev/null 2>&1 || log_error "Fallback ls-files command failed"
log_success "Fallback ls-files works"

log_test "Testing ziggit cat-file -t HEAD (fallback)"
"$ZIGGIT_BIN" cat-file -t HEAD >/dev/null 2>&1 || log_error "Fallback cat-file command failed"
log_success "Fallback cat-file works"

log_test "Testing ziggit rev-list --count HEAD (fallback)"
"$ZIGGIT_BIN" rev-list --count HEAD >/dev/null 2>&1 || log_error "Fallback rev-list command failed"
log_success "Fallback rev-list works"

log_test "Testing ziggit log --graph --oneline -5 (fallback)"
"$ZIGGIT_BIN" log --graph --oneline -5 >/dev/null 2>&1 || log_error "Fallback log with graph failed"
log_success "Fallback log with graph works"

log_test "Testing ziggit shortlog -sn -1 (fallback)"
"$ZIGGIT_BIN" shortlog -sn -1 >/dev/null 2>&1 || log_error "Fallback shortlog command failed"
log_success "Fallback shortlog works"

log_test "Testing global flags are forwarded correctly..."

# Test global flags forwarding
log_test "Testing ziggit -C .. status (global flag forwarding)"
cd /tmp
"$ZIGGIT_BIN" -C "$(basename "$TEST_DIR")" status >/dev/null 2>&1 || log_error "Global flag -C forwarding failed"
cd "$TEST_DIR"
log_success "Global flag -C forwarding works"

log_test "Testing error handling when git is not in PATH..."

# Test error handling when git is not found
# Create a temporary PATH without git but keep essential utilities
TEMP_PATH="/tmp/no_git_path_$$"
mkdir -p "$TEMP_PATH"

# Copy essential utilities to temp path
cp /bin/bash "$TEMP_PATH/"
cp /bin/grep "$TEMP_PATH/" 2>/dev/null || cp /usr/bin/grep "$TEMP_PATH/"
cp /bin/rm "$TEMP_PATH/" 2>/dev/null || cp /usr/bin/rm "$TEMP_PATH/"
cp /bin/cat "$TEMP_PATH/" 2>/dev/null || cp /usr/bin/cat "$TEMP_PATH/"

# Set PATH to only include our temp directory (no git)
export PATH="$TEMP_PATH"

log_test "Testing fallback error when git is not available"
if "$ZIGGIT_BIN" stash list 2>/tmp/error_output_$$ >/dev/null; then
    log_error "Fallback should have failed when git is not available"
fi

# Restore PATH to check error message
export PATH="$ORIGINAL_PATH"

# Check the error message
if grep -q "is not a ziggit command and git is not installed" /tmp/error_output_$$; then
    log_success "Correct error message when git is not found"
else
    log_error "Incorrect error message when git is not found"
fi

if grep -q "Either install git for fallback functionality" /tmp/error_output_$$; then
    log_success "Helpful suggestion message provided"
else
    log_error "Missing helpful suggestion when git is not found"
fi

# Clean up error output
rm -f /tmp/error_output_$$

log_test "Testing that native commands still work when git is not available..."

# Set PATH to not have git again, test native commands still work
export PATH="$TEMP_PATH"

log_test "Testing ziggit status (native) works without git in PATH"
"$ZIGGIT_BIN" status >/dev/null 2>&1 || log_error "Native status should work even without git"
log_success "Native commands work without git in PATH"

# Restore PATH
export PATH="$ORIGINAL_PATH"

log_test "Testing interactive command forwarding..."

# Test that interactive commands forward properly (limited testing in non-interactive environment)
log_test "Testing ziggit help (should work even if not interactive)"
"$ZIGGIT_BIN" help >/dev/null 2>&1 || log_error "Help command failed"
log_success "Help command works"

log_test "Testing exit code propagation..."

# Test exit code propagation from git
log_test "Testing that git exit codes are properly propagated"
set +e  # Allow failures for this test

# Test a command that should fail and return non-zero exit code
"$ZIGGIT_BIN" show non_existent_commit >/dev/null 2>&1
EXIT_CODE=$?

set -e  # Re-enable exit on error

if [ $EXIT_CODE -eq 0 ]; then
    log_error "Expected non-zero exit code for invalid commit, got 0"
fi
log_success "Exit codes are properly propagated (got exit code $EXIT_CODE)"

# Clean up temp directory
rm -rf "$TEMP_PATH"

log_success "All git fallback tests passed!"

echo ""
echo "=== TEST SUMMARY ==="
echo "✓ Native commands work correctly"
echo "✓ Fallback commands work when git is available" 
echo "✓ Proper error handling when git is not available"
echo "✓ Global flags are forwarded correctly"
echo "✓ Exit codes are propagated correctly"
echo "✓ Native commands work even when git is not in PATH"
echo ""
echo -e "${GREEN}Git fallback functionality is working correctly!${NC}"