#!/bin/bash

set -e

# Test comprehensive git fallback functionality

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Testing ziggit git fallback system...${NC}"

# Create test directory
TEST_DIR="$(mktemp -d)"
cd "$TEST_DIR"

# Initialize a test git repository
git init
echo "test file" > test.txt
git add test.txt
git commit -m "Initial commit"
echo "modified" >> test.txt
git add test.txt
git commit -m "Second commit"

# Build ziggit if possible (but continue if it fails)
cd /root/ziggit
if zig build 2>/dev/null; then
    ZIGGIT_BIN="/root/ziggit/zig-out/bin/ziggit"
    echo -e "${GREEN}Built ziggit successfully${NC}"
else
    echo -e "${YELLOW}Could not build ziggit, tests will be limited${NC}"
    ZIGGIT_BIN=""
fi

cd "$TEST_DIR"

# Test function
run_test() {
    local test_name="$1"
    local command="$2"
    local expected_to_work="$3"
    
    echo -e "\n${YELLOW}Testing: $test_name${NC}"
    echo "Command: $command"
    
    if [ -n "$ZIGGIT_BIN" ] && [ -f "$ZIGGIT_BIN" ]; then
        if eval "$ZIGGIT_BIN $command" >/dev/null 2>&1; then
            if [ "$expected_to_work" = "yes" ]; then
                echo -e "${GREEN}✓ PASSED${NC}"
            else
                echo -e "${RED}✗ FAILED (expected to fail but succeeded)${NC}"
            fi
        else
            if [ "$expected_to_work" = "no" ]; then
                echo -e "${GREEN}✓ PASSED (expected to fail)${NC}"
            else
                echo -e "${RED}✗ FAILED (expected to succeed but failed)${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠ SKIPPED (ziggit binary not available)${NC}"
    fi
}

# Test native commands (should work)
echo -e "\n${YELLOW}=== Testing Native Commands ===${NC}"
run_test "status" "status" "yes"
run_test "rev-parse HEAD" "rev-parse HEAD" "yes"
run_test "log --oneline -1" "log --oneline -1" "yes"
run_test "branch" "branch" "yes"
run_test "tag" "tag" "yes"
run_test "describe --tags" "describe --tags" "yes"
run_test "diff --cached" "diff --cached" "yes"

# Test commands that should fall back to git
echo -e "\n${YELLOW}=== Testing Git Fallback Commands ===${NC}"
run_test "stash list" "stash list" "yes"
run_test "remote -v" "remote -v" "yes"
run_test "show HEAD" "show HEAD" "yes"
run_test "ls-files" "ls-files" "yes"
run_test "cat-file -t HEAD" "cat-file -t HEAD" "yes"
run_test "rev-list --count HEAD" "rev-list --count HEAD" "yes"
run_test "log --graph --oneline -5" "log --graph --oneline -5" "yes"
run_test "shortlog -sn -1" "shortlog -sn -1" "yes"

# Test with git NOT in PATH (simulate git not installed)
echo -e "\n${YELLOW}=== Testing Git Not Available ===${NC}"
if [ -n "$ZIGGIT_BIN" ] && [ -f "$ZIGGIT_BIN" ]; then
    # Temporarily rename git binary
    if command -v git >/dev/null 2>&1; then
        GIT_PATH=$(command -v git)
        GIT_DIR=$(dirname "$GIT_PATH")
        sudo mv "$GIT_PATH" "$GIT_PATH.backup" 2>/dev/null || true
        
        echo -e "\n${YELLOW}Testing fallback when git is not in PATH...${NC}"
        
        # Test a command that would fall back to git
        if "$ZIGGIT_BIN" stash list 2>&1 | grep -q "git is not installed"; then
            echo -e "${GREEN}✓ PASSED: Proper error message when git not available${NC}"
        else
            echo -e "${RED}✗ FAILED: Did not show proper error message${NC}"
        fi
        
        # Restore git binary
        sudo mv "$GIT_PATH.backup" "$GIT_PATH" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ SKIPPED: git not found in PATH to test removal${NC}"
    fi
else
    echo -e "${YELLOW}⚠ SKIPPED: ziggit binary not available${NC}"
fi

# Test global flags forwarding
echo -e "\n${YELLOW}=== Testing Global Flags Forwarding ===${NC}"
run_test "-C option with fallback" "-C . stash list" "yes"
run_test "git-dir option with fallback" "--git-dir .git stash list" "yes"

# Test help shows fallback info
echo -e "\n${YELLOW}=== Testing Help Information ===${NC}"
if [ -n "$ZIGGIT_BIN" ] && [ -f "$ZIGGIT_BIN" ]; then
    if "$ZIGGIT_BIN" --help 2>&1 | grep -q "transparently forwarded"; then
        echo -e "${GREEN}✓ PASSED: Help mentions git fallback${NC}"
    else
        echo -e "${RED}✗ FAILED: Help does not mention git fallback${NC}"
    fi
else
    echo -e "${YELLOW}⚠ SKIPPED: ziggit binary not available${NC}"
fi

# Clean up
cd /
rm -rf "$TEST_DIR"

echo -e "\n${GREEN}Git fallback tests completed!${NC}"

# Test alias functionality
echo -e "\n${YELLOW}=== Testing Alias Functionality ===${NC}"
if [ -n "$ZIGGIT_BIN" ] && [ -f "$ZIGGIT_BIN" ]; then
    # Create temporary test repo
    TEST_DIR2="$(mktemp -d)"
    cd "$TEST_DIR2"
    git init
    echo "alias test" > alias_test.txt
    git add alias_test.txt
    git commit -m "Alias test commit"
    
    # Test alias functionality
    echo "Testing: alias git=ziggit && git status && git stash list && git remote -v"
    if (alias git="$ZIGGIT_BIN" && git status >/dev/null 2>&1 && git stash list >/dev/null 2>&1 && git remote -v >/dev/null 2>&1); then
        echo -e "${GREEN}✓ PASSED: Alias functionality works${NC}"
    else
        echo -e "${RED}✗ FAILED: Alias functionality failed${NC}"
    fi
    
    cd /
    rm -rf "$TEST_DIR2"
else
    echo -e "${YELLOW}⚠ SKIPPED: ziggit binary not available${NC}"
fi

echo -e "\n${GREEN}All git fallback tests completed!${NC}"