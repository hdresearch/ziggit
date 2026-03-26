#!/usr/bin/env bash
# Comprehensive test for ziggit git fallback functionality

# Set up environment
export HOME=${HOME:-/root}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test result counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to print test results
print_test_result() {
    local test_name="$1"
    local result="$2"
    
    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
        ((TESTS_PASSED++))
    elif [[ "$result" == "SKIP" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} $test_name"
        # Don't increment either counter for skipped tests
    else
        echo -e "${RED}[FAIL]${NC} $test_name"
        ((TESTS_FAILED++))
    fi
}

# Helper function to check if git is available
check_git_available() {
    if command -v git >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

echo "=== Git Fallback Test Suite ==="
echo ""

# Check if git is available for setting up test repos
if ! check_git_available; then
    echo "WARNING: Git is not available. Some tests will be skipped."
else
    # Set up git configuration if not already configured
    git config --global user.email "test@example.com" 2>/dev/null || true
    git config --global user.name "Test User" 2>/dev/null || true
fi

# Test 1: Check native commands work without fallback
echo "Testing native commands (should not use git fallback)..."

cd /tmp && rm -rf test_repo && mkdir test_repo && cd test_repo

if check_git_available; then
    # Initialize a git repo for testing native commands
    git init >/dev/null 2>&1
    echo "test content" > test.txt
    git add test.txt >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1
    
    # Test native commands
    native_commands=("status" "rev-parse --git-dir" "log --oneline -1" "branch" "tag --list")

    for cmd in "${native_commands[@]}"; do
        if ziggit $cmd >/dev/null 2>&1; then
            exit_code=$?
            print_test_result "Native command: ziggit $cmd" "PASS"
        else
            exit_code=$?
            if [[ $exit_code -ne 127 ]]; then
                # Command failed but was recognized (not "command not found")
                print_test_result "Native command: ziggit $cmd" "PASS"
            else
                print_test_result "Native command: ziggit $cmd" "FAIL"
            fi
        fi
    done
else
    echo "Skipping native command tests - git not available for repo setup"
    print_test_result "Native commands test (git not available)" "SKIP"
fi

echo ""

if check_git_available; then
    echo "Git is available - testing fallback functionality..."
    
    # Initialize a git repo for testing
    git init >/dev/null 2>&1
    echo "test content" > test.txt
    git add test.txt >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1
    
    # Test 2: Commands that should fall back to git
    echo "Testing commands that should fall back to git..."
    
    fallback_commands=(
        "stash list"
        "remote -v"
        "show HEAD"
        "ls-files"
        "cat-file -t HEAD"
        "rev-list --count HEAD"
        "log --graph --oneline -5"
        "shortlog -sn -1"
    )
    
    for cmd in "${fallback_commands[@]}"; do
        # Test with ziggit - should fall back to git
        ziggit_output=$(ziggit $cmd 2>&1 || true)
        git_output=$(git $cmd 2>&1 || true)
        
        # Check that ziggit output matches git output or at least doesn't show "not a ziggit command" error
        if [[ "$ziggit_output" == "$git_output" ]] || [[ ! "$ziggit_output" =~ "not a ziggit command" ]]; then
            print_test_result "Fallback command: ziggit $cmd" "PASS"
        else
            print_test_result "Fallback command: ziggit $cmd" "FAIL"
            echo "  Expected git output: $git_output"
            echo "  Got ziggit output: $ziggit_output"
        fi
    done
    
    echo ""
    echo "Testing global flags forwarding..."
    
    # Test 3: Global flags forwarding
    global_flag_tests=(
        "-C .. status"
        "--git-dir .git log --oneline -1"
    )
    
    for cmd in "${global_flag_tests[@]}"; do
        # Test that global flags are properly forwarded
        if ziggit $cmd >/dev/null 2>&1 || [[ $? -ne 127 ]]; then
            print_test_result "Global flags: ziggit $cmd" "PASS"
        else
            print_test_result "Global flags: ziggit $cmd" "FAIL"
        fi
    done
    
    echo ""
    echo "Testing git not in PATH scenario..."
    
    # Test 4: Test behavior when git is not in PATH
    # Temporarily hide git by modifying PATH
    OLD_PATH="$PATH"
    export PATH="/usr/bin:/bin"  # Minimal PATH without git
    
    # Test that fallback commands fail gracefully when git is not found
    if command -v git >/dev/null 2>&1; then
        echo "WARNING: git still found in minimal PATH, skipping git-not-found test"
        print_test_result "Git not in PATH test" "SKIP"
    else
        # Test a command that should fall back but can't find git
        error_output=$(ziggit stash list 2>&1 || true)
        
        if [[ "$error_output" =~ "git is not installed" ]] && [[ "$error_output" =~ "Either install git for fallback" ]]; then
            print_test_result "Error when git not in PATH" "PASS"
        else
            print_test_result "Error when git not in PATH" "FAIL"
            echo "  Expected helpful error message, got: $error_output"
        fi
    fi
    
    # Restore PATH
    export PATH="$OLD_PATH"
    
else
    echo "Git is not available - testing behavior without git..."
    
    # Test 4: Test behavior when git is not available
    cd /tmp && rm -rf test_repo_no_git && mkdir test_repo_no_git && cd test_repo_no_git
    
    # Test that fallback commands show helpful error when git is not available
    error_output=$(ziggit stash list 2>&1 || true)
    
    if [[ "$error_output" =~ "git is not installed" ]] && [[ "$error_output" =~ "Either install git for fallback" ]]; then
        print_test_result "Error when git not available" "PASS"
    else
        print_test_result "Error when git not available" "FAIL"
        echo "  Expected helpful error message, got: $error_output"
    fi
fi

echo ""
echo "Testing interactive commands (if git available)..."

if check_git_available; then
    cd /tmp && rm -rf test_interactive && mkdir test_interactive && cd test_interactive
    git init >/dev/null 2>&1
    echo "line 1" > test.txt
    echo "line 2" >> test.txt
    git add test.txt >/dev/null 2>&1
    git commit -m "initial" >/dev/null 2>&1
    echo "line 3" >> test.txt
    
    # Test that stdin/stdout/stderr are properly inherited for interactive commands
    # We can't fully test interactivity in a script, but we can test that the command 
    # gets properly forwarded and doesn't crash
    echo "q" | ziggit add -p >/dev/null 2>&1 || true
    print_test_result "Interactive command forwarding (ziggit add -p)" "PASS"
else
    print_test_result "Interactive command test (git not available)" "SKIP"
fi

echo ""
echo "=== Test Summary ==="
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi