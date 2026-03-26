#!/bin/bash
# Test runner for git test suite t0000-t4999
# Usage: bash test/git-test-runner-top.sh [pattern]
# e.g., bash test/git-test-runner-top.sh "t00" for t00xx tests only

PATTERN="${1:-t[0-4]}"
RESULTS_FILE="test/git-test-results-top.txt"
TEST_DIR="/tmp/git-tests/t"

echo "=== Git Test Suite Results (t0000-t4999) ===" > "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "Range: $PATTERN" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

total_pass=0
total_fail=0
total_error=0
total_skip=0
total_tests=0

for test_script in "$TEST_DIR"/${PATTERN}*.sh; do
    test_name=$(basename "$test_script" .sh)
    echo "Running $test_name..."
    
    output=$(cd "$TEST_DIR" && \
        GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
        GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
        timeout 120 bash "$test_script" 2>&1)
    
    # Parse results from last lines
    pass=$(echo "$output" | grep -oP 'passed \K\d+' | tail -1)
    fail=$(echo "$output" | grep -oP 'failed \K\d+' | tail -1) 
    
    # Get summary line
    summary=$(echo "$output" | tail -3)
    
    echo "$test_name: $summary" >> "$RESULTS_FILE"
    echo "---" >> "$RESULTS_FILE"
done

echo "" >> "$RESULTS_FILE"
echo "=== Done ===" >> "$RESULTS_FILE"
