#!/bin/bash
# Comprehensive test for git CLI fallback functionality

set -e

echo "Testing ziggit git fallback functionality..."

# Build path
ZIGGIT="./zig-out/bin/ziggit"
BUILD_CMD="HOME=/tmp zig build"

# Build ziggit first
echo "Building ziggit..."
if ! eval "$BUILD_CMD" >/dev/null 2>&1; then
    echo "FAIL: Unable to build ziggit"
    exit 1
fi

if [ ! -f "$ZIGGIT" ]; then
    echo "FAIL: ziggit binary not found at $ZIGGIT"
    exit 1
fi

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

test_command() {
    local description="$1"
    shift
    local expected_exit_code="${1:-0}"
    shift
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing: $description... "
    
    # Run command and capture output and exit code
    if output=$("$@" 2>&1); then
        actual_exit_code=0
    else
        actual_exit_code=$?
    fi
    
    if [ $actual_exit_code -eq $expected_exit_code ]; then
        echo "PASS"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAIL (expected exit code $expected_exit_code, got $actual_exit_code)"
        echo "  Command: $*"
        echo "  Output: $output"
    fi
}

test_command_output_contains() {
    local description="$1"
    local expected_text="$2"
    shift 2
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing: $description... "
    
    if output=$("$@" 2>&1) && echo "$output" | grep -q "$expected_text"; then
        echo "PASS"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAIL (expected output to contain '$expected_text')"
        echo "  Command: $*"
        echo "  Output: $output"
    fi
}

# Test that we're in a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: Not in a git repository. Run this test from the ziggit repository root."
    exit 1
fi

echo "Running tests in $(pwd)"

# === Test native commands work ===
echo
echo "=== Testing native commands ==="

test_command "native help command" 0 "$ZIGGIT" --help
test_command_output_contains "native status command shows branch" "On branch" "$ZIGGIT" status
test_command "native rev-parse HEAD" 0 "$ZIGGIT" rev-parse HEAD  
test_command "native log command" 0 "$ZIGGIT" log -1
test_command_output_contains "native branch command" "master" "$ZIGGIT" branch
test_command "native describe command" 0 "$ZIGGIT" describe --always
test_command_output_contains "native tag command" "" "$ZIGGIT" tag --list

# Test diff command (may have issues with current implementation, but should not crash)
test_command "native diff command (exit code only)" 0 "$ZIGGIT" diff --exit-code || true

# === Test commands that fall back to git ===
echo
echo "=== Testing fallback commands ==="

test_command_output_contains "fallback stash list" "stash@" "$ZIGGIT" stash list || test_command "fallback stash list (no stashes)" 0 "$ZIGGIT" stash list
test_command_output_contains "fallback remote -v" "origin" "$ZIGGIT" remote -v
test_command "fallback show HEAD" 0 "$ZIGGIT" show --name-only HEAD
test_command "fallback ls-files" 0 "$ZIGGIT" ls-files
test_command_output_contains "fallback cat-file" "commit" "$ZIGGIT" cat-file -t HEAD
test_command "fallback rev-list count" 0 "$ZIGGIT" rev-list --count HEAD
test_command "fallback log with complex args" 0 "$ZIGGIT" log --graph --oneline -5
test_command "fallback shortlog" 0 "$ZIGGIT" shortlog -sn -1

# === Test global flag forwarding ===
echo
echo "=== Testing global flag forwarding ==="

# Test -C flag (change directory)
test_command "fallback with -C flag to current dir" 0 "$ZIGGIT" -C . log --oneline -1
test_command "fallback with -C flag to parent dir" 128 "$ZIGGIT" -C .. log --oneline -1  # Should fail - not a git repo

# Test -c flag (config override) - should be ignored but forwarded
test_command "fallback with -c flag" 0 "$ZIGGIT" -c core.longpaths=true log --oneline -1

# === Test error handling when git is not available ===
echo
echo "=== Testing error handling without git ==="

# Remove git from PATH and test
test_command_output_contains "error message when git not found" "git is not installed" env PATH="" "$ZIGGIT" stash list

# === Test that native commands still work with global flags ===
echo
echo "=== Testing native commands with global flags ==="

test_command "native command with -C flag" 0 "$ZIGGIT" -C . --help
test_command_output_contains "native status with -C flag" "On branch" "$ZIGGIT" -C . status

# === Summary ===
echo
echo "=== Test Summary ==="
echo "Tests run: $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $((TESTS_RUN - TESTS_PASSED))"

if [ $TESTS_PASSED -eq $TESTS_RUN ]; then
    echo "All tests PASSED!"
    exit 0
else
    echo "Some tests FAILED!"
    exit 1
fi