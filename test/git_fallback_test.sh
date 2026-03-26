#!/bin/bash

# Test script for git CLI fallback functionality

set -e

ZIGGIT="./zig-out/bin/ziggit"
EXIT_CODE=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Running git fallback tests..."

# Function to run a test
run_test() {
    local test_name="$1"
    local command="$2"
    local expected_exit="$3"
    
    echo -n "Testing $test_name... "
    
    if eval "$command" >/dev/null 2>&1; then
        actual_exit=0
    else
        actual_exit=$?
    fi
    
    if [[ "$actual_exit" == "$expected_exit" ]]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC} (expected exit $expected_exit, got $actual_exit)"
        EXIT_CODE=1
    fi
}

# Test native implementations work
echo "Testing native commands..."
run_test "status" "$ZIGGIT status" 0
run_test "rev-parse HEAD" "$ZIGGIT rev-parse HEAD" 0
run_test "log -1" "$ZIGGIT log -1" 0
run_test "branch" "$ZIGGIT branch" 0
run_test "tag" "$ZIGGIT tag" 0
run_test "describe" "$ZIGGIT describe" 0
run_test "diff --stat" "$ZIGGIT diff --stat" 0

echo ""
echo "Testing fallback commands..."

# Test commands that fall back to git
run_test "stash list" "$ZIGGIT stash list" 0
run_test "remote -v" "$ZIGGIT remote -v" 0
run_test "show HEAD" "$ZIGGIT show HEAD" 0
run_test "ls-files" "$ZIGGIT ls-files" 0
run_test "cat-file -t HEAD" "$ZIGGIT cat-file -t HEAD" 0
run_test "rev-list --count HEAD" "$ZIGGIT rev-list --count HEAD" 0
run_test "log --graph --oneline -5" "$ZIGGIT log --graph --oneline -5" 0
run_test "shortlog -sn -1" "$ZIGGIT shortlog -sn -1" 0

echo ""
echo "Testing error handling when git is not in PATH..."

# Test when git is NOT in PATH, fallback commands should print clear error and exit 1
PATH="" run_test "bisect (no git)" "$ZIGGIT bisect" 1
PATH="" run_test "rebase (no git)" "$ZIGGIT rebase" 1
PATH="" run_test "cherry-pick (no git)" "$ZIGGIT cherry-pick" 1

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}Some tests failed!${NC}"
fi

exit $EXIT_CODE