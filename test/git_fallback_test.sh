#!/bin/bash

# git_fallback_test.sh - Comprehensive test for git CLI fallback functionality

set -e

# Create a temporary directory for testing
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
echo "Testing in directory: $TEST_DIR"

# Ensure ziggit binary path is available
ZIGGIT_BIN="${ZIGGIT_BIN:-$HOME/ziggit/zig-out/bin/ziggit}"
if [[ ! -x "$ZIGGIT_BIN" ]]; then
    echo "Error: ziggit binary not found at $ZIGGIT_BIN"
    echo "Set ZIGGIT_BIN environment variable to the correct path"
    exit 1
fi

# Set up git user for testing
git config --global user.name "Test User" || true
git config --global user.email "test@example.com" || true

# Initialize a test repository
echo "=== Setting up test repository ==="
git init
echo "Hello World" > test.txt
git add test.txt
git commit -m "Initial commit"
echo "Modified" >> test.txt
git add test.txt  
git commit -m "Second commit"
git tag v1.0
git stash push -m "Test stash" || git stash save "Test stash" # fallback for older git

echo ""
echo "=== Testing native ziggit commands ==="

# Test native commands that should work in ziggit
echo "Testing ziggit status (native)..."
$ZIGGIT_BIN status &>/dev/null && echo "✓ status works" || echo "✗ status failed"

echo "Testing ziggit rev-parse (native)..."
HEAD_HASH=$($ZIGGIT_BIN rev-parse HEAD 2>/dev/null) && echo "✓ rev-parse works: $HEAD_HASH" || echo "✗ rev-parse failed"

echo "Testing ziggit log (native)..."
$ZIGGIT_BIN log --oneline -2 &>/dev/null && echo "✓ log works" || echo "✗ log failed"

echo "Testing ziggit branch (native)..."
$ZIGGIT_BIN branch &>/dev/null && echo "✓ branch works" || echo "✗ branch failed"

echo "Testing ziggit tag (native)..."
$ZIGGIT_BIN tag &>/dev/null && echo "✓ tag works" || echo "✗ tag failed"

echo "Testing ziggit describe (native)..."
$ZIGGIT_BIN describe --tags &>/dev/null && echo "✓ describe works" || echo "✗ describe failed"

echo "Testing ziggit diff (native)..."
$ZIGGIT_BIN diff HEAD~1 HEAD &>/dev/null && echo "✓ diff works" || echo "✗ diff failed"

echo ""
echo "=== Testing git fallback commands ==="

# Test commands that should fall back to git
echo "Testing ziggit stash list (fallback)..."
STASH_OUTPUT=$($ZIGGIT_BIN stash list 2>/dev/null) && echo "✓ stash list works: found $(echo "$STASH_OUTPUT" | wc -l) stashes" || echo "✗ stash list failed"

echo "Testing ziggit remote -v (fallback)..."
$ZIGGIT_BIN remote -v &>/dev/null && echo "✓ remote -v works" || echo "✗ remote -v failed"

echo "Testing ziggit show HEAD (fallback)..."  
$ZIGGIT_BIN show HEAD --quiet &>/dev/null && echo "✓ show HEAD works" || echo "✗ show HEAD failed"

echo "Testing ziggit ls-files (fallback)..."
FILES_OUTPUT=$($ZIGGIT_BIN ls-files 2>/dev/null) && echo "✓ ls-files works: found $(echo "$FILES_OUTPUT" | wc -l) files" || echo "✗ ls-files failed"

echo "Testing ziggit cat-file -t HEAD (fallback)..."
TYPE_OUTPUT=$($ZIGGIT_BIN cat-file -t HEAD 2>/dev/null) && echo "✓ cat-file works: HEAD is $TYPE_OUTPUT" || echo "✗ cat-file failed"

echo "Testing ziggit rev-list --count HEAD (fallback)..."
COUNT_OUTPUT=$($ZIGGIT_BIN rev-list --count HEAD 2>/dev/null) && echo "✓ rev-list works: $COUNT_OUTPUT commits" || echo "✗ rev-list failed"

echo "Testing ziggit log --graph --oneline -5 (fallback)..."
$ZIGGIT_BIN log --graph --oneline -5 &>/dev/null && echo "✓ log with git-specific options works" || echo "✗ log with git-specific options failed"

echo "Testing ziggit shortlog -sn -1 (fallback)..."
$ZIGGIT_BIN shortlog -sn -1 &>/dev/null && echo "✓ shortlog works" || echo "✗ shortlog failed"

echo ""
echo "=== Testing global flags forwarding ==="

# Test that global flags are forwarded correctly
echo "Testing -C global flag..."
cd ..
$ZIGGIT_BIN -C "$(basename "$TEST_DIR")" status &>/dev/null && echo "✓ -C flag forwarded correctly" || echo "✗ -C flag forwarding failed"
cd "$TEST_DIR"

echo "Testing -c global flag..."
$ZIGGIT_BIN -c core.editor=true status &>/dev/null && echo "✓ -c flag forwarded correctly" || echo "✗ -c flag forwarding failed"

echo ""
echo "=== Testing git not found scenario ==="

# Test graceful failure when git is not available
# We'll temporarily rename git to simulate it not being installed
GIT_PATH=$(which git)
if [[ -n "$GIT_PATH" ]] && [[ -x "$GIT_PATH" ]]; then
    # Create a temporary directory without git in PATH
    TEMP_BIN_DIR=$(mktemp -d)
    
    # Copy all binaries except git to the temp directory  
    for binary in /usr/bin/* /bin/*; do
        if [[ -x "$binary" ]] && [[ "$(basename "$binary")" != "git" ]]; then
            cp "$binary" "$TEMP_BIN_DIR/" 2>/dev/null || true
        fi
    done
    
    # Test with git not in PATH
    echo "Testing fallback behavior when git is not installed..."
    
    # Run ziggit with modified PATH that doesn't include git
    PATH="$TEMP_BIN_DIR" $ZIGGIT_BIN stash list 2>/tmp/git_error.log || true
    
    # Check if the error message is helpful
    if grep -q "is not a ziggit command and git is not installed" /tmp/git_error.log; then
        echo "✓ Graceful error handling when git not found"
    else
        echo "✗ Error handling needs improvement"
        echo "Actual error output:"
        cat /tmp/git_error.log || echo "No error log found"
    fi
    
    # Clean up
    rm -rf "$TEMP_BIN_DIR"
    rm -f /tmp/git_error.log
else
    echo "⚠ Skipping git-not-found test (git not available or not executable)"
fi

echo ""
echo "=== Testing exit codes ==="

# Test that exit codes are properly propagated
echo "Testing successful command exit code..."
$ZIGGIT_BIN stash list >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    echo "✓ Successful command returns exit code 0"
else
    echo "✗ Successful command returned non-zero exit code: $?"
fi

echo "Testing failed command exit code..."
$ZIGGIT_BIN show nonexistent-ref >/dev/null 2>&1
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
    echo "✓ Failed command returns non-zero exit code: $EXIT_CODE"
else
    echo "✗ Failed command should return non-zero exit code"
fi

echo ""
echo "=== Testing interactive commands ==="

# Test that stdin/stdout/stderr are properly inherited
echo "Testing non-interactive command output..."
OUTPUT=$($ZIGGIT_BIN log --oneline -1 2>/dev/null)
if [[ -n "$OUTPUT" ]]; then
    echo "✓ Command output is captured correctly"
else
    echo "✗ Command output not captured"
fi

echo ""
echo "=== Test Summary ==="

# Clean up test directory
cd /
rm -rf "$TEST_DIR"

echo "Git fallback testing completed!"
echo "All tests run in temporary directory (now cleaned up)"
echo ""
echo "To use ziggit as a git replacement, run:"
echo "  alias git='$ZIGGIT_BIN'"
echo "  git status  # uses native ziggit"  
echo "  git stash list  # falls back to git"
echo "  git remote -v  # falls back to git"