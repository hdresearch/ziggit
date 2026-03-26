#!/bin/bash
# Git CLI fallback test suite for ziggit
# Tests both native implementations and fallback to git

# set -e  # Temporarily disabled for debugging

ZIGGIT_BIN="${ZIGGIT_BIN:-$(realpath ./zig-out/bin/ziggit 2>/dev/null || echo /root/ziggit/zig-out/bin/ziggit)}"
TEST_DIR="/tmp/ziggit_fallback_test_$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0

log_test() {
    echo -e "${YELLOW}Testing:${NC} $1"
}

pass_test() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((PASSED++))
}

fail_test() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    echo -e "  ${RED}Error:${NC} $2"
    ((FAILED++))
}

# Setup test environment
setup_test_repo() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Initialize repo with real git to have a baseline
    git init > /dev/null 2>&1
    git config user.name "Test User" > /dev/null 2>&1
    git config user.email "test@example.com" > /dev/null 2>&1
    
    # Create some test files
    echo "Hello World" > file1.txt
    echo "Another file" > file2.txt
    mkdir subdir
    echo "Nested file" > subdir/nested.txt
    
    git add . > /dev/null 2>&1
    git commit -m "Initial commit" > /dev/null 2>&1
    
    # Create a tag for describe tests
    git tag v1.0.0 > /dev/null 2>&1
    
    # Create a branch for testing
    git checkout -b feature-branch > /dev/null 2>&1
    echo "Feature change" > feature.txt
    git add feature.txt > /dev/null 2>&1
    git commit -m "Feature commit" > /dev/null 2>&1
    git checkout master > /dev/null 2>&1
}

# Test native implementations work
test_native_commands() {
    log_test "Native implementations"
    
    # status (native)
    if $ZIGGIT_BIN status > /dev/null 2>&1; then
        pass_test "status command works"
    else
        fail_test "status command failed" "Exit code: $?"
    fi
    
    # rev-parse (native)
    if result=$($ZIGGIT_BIN rev-parse HEAD 2>/dev/null); then
        if [[ ${#result} -eq 40 ]]; then
            pass_test "rev-parse HEAD returns 40-char hash"
        else
            fail_test "rev-parse HEAD" "Returned: $result"
        fi
    else
        fail_test "rev-parse command failed" "Exit code: $?"
    fi
    
    # log (native)
    if $ZIGGIT_BIN log --oneline -5 > /dev/null 2>&1; then
        pass_test "log --oneline -5 works"
    else
        fail_test "log command failed" "Exit code: $?"
    fi
    
    # branch (native)
    if $ZIGGIT_BIN branch > /dev/null 2>&1; then
        pass_test "branch listing works"
    else
        fail_test "branch command failed" "Exit code: $?"
    fi
    
    # tag (native)
    if $ZIGGIT_BIN tag > /dev/null 2>&1; then
        pass_test "tag listing works"
    else
        fail_test "tag command failed" "Exit code: $?"
    fi
    
    # describe (native)
    if $ZIGGIT_BIN describe --always > /dev/null 2>&1; then
        pass_test "describe --always works"
    else
        fail_test "describe command failed" "Exit code: $?"
    fi
    
    # diff (native)
    echo "Modified content" >> file1.txt
    if $ZIGGIT_BIN diff > /dev/null 2>&1; then
        pass_test "diff command works"
    else
        fail_test "diff command failed" "Exit code: $?"
    fi
    git checkout -- file1.txt > /dev/null 2>&1  # Reset for next tests
}

# Test commands that should fall back to git
test_fallback_commands() {
    log_test "Git fallback commands"
    
    # stash list (fallback)
    if $ZIGGIT_BIN stash list > /dev/null 2>&1; then
        pass_test "stash list fallback works"
    else
        fail_test "stash list fallback failed" "Exit code: $?"
    fi
    
    # remote -v (fallback)
    if $ZIGGIT_BIN remote -v > /dev/null 2>&1; then
        pass_test "remote -v fallback works"
    else
        fail_test "remote -v fallback failed" "Exit code: $?"
    fi
    
    # show HEAD (fallback)
    if $ZIGGIT_BIN show HEAD > /dev/null 2>&1; then
        pass_test "show HEAD fallback works"
    else
        fail_test "show HEAD fallback failed" "Exit code: $?"
    fi
    
    # ls-files (actually native, but let's test it works)
    if $ZIGGIT_BIN ls-files > /dev/null 2>&1; then
        pass_test "ls-files works"
    else
        fail_test "ls-files failed" "Exit code: $?"
    fi
    
    # cat-file -t HEAD (should be native but let's test)
    if $ZIGGIT_BIN cat-file -t HEAD > /dev/null 2>&1; then
        pass_test "cat-file -t HEAD works"
    else
        fail_test "cat-file -t HEAD failed" "Exit code: $?"
    fi
    
    # rev-list --count HEAD (fallback via git)
    if result=$($ZIGGIT_BIN rev-list --count HEAD 2>/dev/null); then
        if [[ "$result" =~ ^[0-9]+$ ]]; then
            pass_test "rev-list --count HEAD returns number"
        else
            fail_test "rev-list --count HEAD" "Returned: $result"
        fi
    else
        fail_test "rev-list --count HEAD failed" "Exit code: $?"
    fi
    
    # log --graph --oneline -5 (should use native with fallback for unsupported flags)
    if $ZIGGIT_BIN log --graph --oneline -5 > /dev/null 2>&1; then
        pass_test "log --graph --oneline -5 works"
    else
        fail_test "log --graph --oneline -5 failed" "Exit code: $?"
    fi
    
    # shortlog -sn -1 (fallback)
    if $ZIGGIT_BIN shortlog -sn -1 > /dev/null 2>&1; then
        pass_test "shortlog -sn -1 fallback works"
    else
        fail_test "shortlog -sn -1 fallback failed" "Exit code: $?"
    fi
}

# Test error handling when git is not available
test_git_not_available() {
    log_test "Git not available error handling"
    
    # Temporarily rename git to simulate it being unavailable
    if command -v git > /dev/null 2>&1; then
        GIT_PATH=$(command -v git)
        sudo mv "$GIT_PATH" "${GIT_PATH}.backup" 2>/dev/null || {
            echo -e "${YELLOW}Warning:${NC} Cannot test 'git not available' scenario (need sudo access)"
            return
        }
        
        # Test a fallback command when git is not available
        if output=$($ZIGGIT_BIN stash list 2>&1); then
            fail_test "stash list should fail when git not available" "Unexpectedly succeeded: $output"
        else
            exit_code=$?
            if [[ $exit_code -eq 1 ]] && [[ "$output" == *"git is not installed"* ]]; then
                pass_test "stash list fails gracefully when git not available"
            else
                fail_test "stash list error handling" "Exit code: $exit_code, Output: $output"
            fi
        fi
        
        # Restore git
        sudo mv "${GIT_PATH}.backup" "$GIT_PATH" 2>/dev/null
    else
        echo -e "${YELLOW}Warning:${NC} git not found, skipping 'git not available' tests"
    fi
}

# Test version and help commands
test_version_help() {
    log_test "Version and help commands"
    
    # --version
    if output=$($ZIGGIT_BIN --version 2>&1); then
        if [[ "$output" == *"ziggit version"* ]]; then
            pass_test "--version shows version info"
        else
            fail_test "--version format" "Output: $output"
        fi
    else
        fail_test "--version failed" "Exit code: $?"
    fi
    
    # --help
    if output=$($ZIGGIT_BIN --help 2>&1); then
        if [[ "$output" == *"usage: ziggit"* ]] && [[ "$output" == *"transparently forwarded to git"* ]]; then
            pass_test "--help shows usage and mentions fallback"
        else
            fail_test "--help format" "Missing expected text in: $output"
        fi
    else
        fail_test "--help failed" "Exit code: $?"
    fi
}

# Test global flags forwarding
test_global_flags() {
    log_test "Global flags forwarding"
    
    # Create a subdirectory for -C testing
    mkdir -p subdir_for_test
    cd subdir_for_test
    
    # Test -C flag (should work for both native and fallback commands)
    if $ZIGGIT_BIN -C .. status > /dev/null 2>&1; then
        pass_test "-C flag works with native command"
    else
        fail_test "-C flag with status" "Exit code: $?"
    fi
    
    if $ZIGGIT_BIN -C .. stash list > /dev/null 2>&1; then
        pass_test "-C flag works with fallback command"
    else
        fail_test "-C flag with stash list" "Exit code: $?"
    fi
    
    cd ..
}

# Main test execution
main() {
    echo "=== Git CLI Fallback Test Suite ==="
    echo "Testing ziggit binary: $ZIGGIT_BIN"
    echo
    
    # Check if ziggit binary exists
    if [[ ! -x "$ZIGGIT_BIN" ]]; then
        echo -e "${RED}Error:${NC} ziggit binary not found at $ZIGGIT_BIN"
        echo "Build it first with: zig build"
        exit 1
    fi
    
    setup_test_repo
    
    test_version_help
    test_native_commands
    test_fallback_commands
    test_global_flags
    test_git_not_available
    
    echo
    echo "=== Test Summary ==="
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Total:  $((PASSED + FAILED))"
    
    # Cleanup
    cd /
    rm -rf "$TEST_DIR"
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"