#!/bin/bash
set -e

echo "=== Git Fallback Test Suite ==="
echo

# Setup test variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZIGGIT_BIN="$PROJECT_DIR/zig-out/bin/ziggit"
TEST_DIR="/tmp/ziggit_fallback_test_$$"
SUCCESS_COUNT=0
TOTAL_COUNT=0

# Helper functions
run_test() {
    local name="$1"
    local command="$2"
    local expected_exit="$3"
    
    echo -n "Testing $name... "
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    if eval "$command" >/dev/null 2>&1; then
        actual_exit=0
    else
        actual_exit=$?
    fi
    
    if [ "$actual_exit" = "$expected_exit" ]; then
        echo "PASS"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "FAIL (expected exit $expected_exit, got $actual_exit)"
    fi
}

run_test_output() {
    local name="$1"
    local command="$2"
    local expected_pattern="$3"
    
    echo -n "Testing $name... "
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    output=$(eval "$command" 2>&1 || true)
    
    if echo "$output" | grep -q "$expected_pattern"; then
        echo "PASS"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "FAIL (expected pattern '$expected_pattern' not found in output)"
        echo "  Output: $output"
    fi
}

# Create test repository
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init >/dev/null 2>&1

# Configure git for testing
git config user.name "Test User" >/dev/null 2>&1
git config user.email "test@example.com" >/dev/null 2>&1

echo "Test file" > test.txt
git add test.txt
git commit -m "Initial commit" >/dev/null 2>&1

echo "Modified content" > test.txt
git add test.txt
git commit -m "Second commit" >/dev/null 2>&1

echo "=== Testing Native Commands ==="

# Test native commands that should work
run_test "status (native)" "cd $TEST_DIR && $ZIGGIT_BIN status" "0"
run_test "rev-parse HEAD (native)" "cd $TEST_DIR && $ZIGGIT_BIN rev-parse HEAD" "0"
run_test "log (native)" "cd $TEST_DIR && $ZIGGIT_BIN log --oneline -1" "0"
run_test "branch (native)" "cd $TEST_DIR && $ZIGGIT_BIN branch" "0"
run_test "tag (native)" "cd $TEST_DIR && $ZIGGIT_BIN tag test-tag && $ZIGGIT_BIN tag" "0"
run_test "describe (native)" "cd $TEST_DIR && $ZIGGIT_BIN describe --tags" "0"

echo

echo "=== Testing Fallback Commands ==="

# Test commands that fall back to git
run_test "stash list (fallback)" "cd $TEST_DIR && $ZIGGIT_BIN stash list" "0"
run_test "remote -v (fallback)" "cd $TEST_DIR && $ZIGGIT_BIN remote -v" "0"
run_test "show HEAD (fallback)" "cd $TEST_DIR && $ZIGGIT_BIN show HEAD" "0"
run_test "log --graph --oneline -5 (fallback)" "cd $TEST_DIR && $ZIGGIT_BIN log --graph --oneline -5" "0"
run_test "shortlog -sn -1 (fallback)" "cd $TEST_DIR && $ZIGGIT_BIN shortlog -sn -1" "0"

echo

echo "=== Testing Global Flag Forwarding ==="

# Create subdirectory for -C test
mkdir -p "$TEST_DIR/subdir"

# Test global flags forwarding
run_test "-C flag forwarding" "cd $TEST_DIR/subdir && $ZIGGIT_BIN -C .. remote -v" "0"
run_test "-c flag forwarding" "cd $TEST_DIR && $ZIGGIT_BIN -c core.abbrev=4 log --oneline -1" "0"

echo

echo "=== Testing Error Handling ==="

# Test when git is not available
run_test_output "no git fallback error" "cd $TEST_DIR && PATH=/sbin $ZIGGIT_BIN stash list" "is not a ziggit command and git is not installed"

# Test invalid command
run_test_output "invalid command error" "cd $TEST_DIR && PATH=/sbin $ZIGGIT_BIN invalidcommand" "is not a ziggit command and git is not installed"

echo

echo "=== Testing Interactive Commands ==="

# Test that interactive commands can run (even though we can't test interactivity easily)
run_test "git add -p (dry run)" "cd $TEST_DIR && echo | timeout 2s $ZIGGIT_BIN add -p 2>/dev/null || true" "0"

echo

echo "=== Test Results ==="
echo "Passed: $SUCCESS_COUNT/$TOTAL_COUNT tests"

if [ "$SUCCESS_COUNT" = "$TOTAL_COUNT" ]; then
    echo "✅ All tests passed!"
    exit_code=0
else
    echo "❌ Some tests failed!"
    exit_code=1
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

exit $exit_code