#!/bin/bash
# Git test runner for t0000-t4999 range
# Usage: bash test/git-test-runner-top.sh [start_pattern] [end_pattern]

RESULTS_FILE="test/git-test-results-top.txt"
TEST_DIR="/tmp/git-tests/t"
GIT_TEST_INSTALLED="/tmp/ziggit-as-git"
GIT_TEST_TEMPLATE_DIR="/tmp/git-tests/templates/blt"

START="${1:-t0000}"
END="${2:-t4999}"

echo "=== Git Test Results (t0000-t4999) ===" > "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "Range: $START - $END" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

total_pass=0
total_fail=0
total_error=0
total_tests=0

for test_script in "$TEST_DIR"/${START}*.sh "$TEST_DIR"/t[0-4]*.sh; do
    [ -f "$test_script" ] || continue
    name=$(basename "$test_script" .sh)
    
    # Skip if outside range
    num="${name%%-*}"
    num="${num#t}"
    if [ "$num" -lt "${START#t}" ] 2>/dev/null || [ "$num" -gt "${END#t}" ] 2>/dev/null; then
        continue
    fi

    cd "$TEST_DIR"
    output=$(GIT_TEST_INSTALLED="$GIT_TEST_INSTALLED" \
             GIT_TEST_TEMPLATE_DIR="$GIT_TEST_TEMPLATE_DIR" \
             timeout 120 bash "$test_script" 2>&1)
    exit_code=$?
    
    # Count pass/fail from output
    passed=$(echo "$output" | grep -c "^ok ")
    failed=$(echo "$output" | grep -c "^not ok ")
    
    total_pass=$((total_pass + passed))
    total_fail=$((total_fail + failed))
    total_tests=$((total_tests + 1))
    
    if [ $exit_code -eq 124 ]; then
        status="TIMEOUT"
        total_error=$((total_error + 1))
    elif [ $exit_code -eq 0 ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    
    echo "$name: $status (ok=$passed, fail=$failed, exit=$exit_code)" >> "$RESULTS_FILE"
    echo "$name: $status (ok=$passed, fail=$failed)"
done

echo "" >> "$RESULTS_FILE"
echo "=== SUMMARY ===" >> "$RESULTS_FILE"
echo "Total test scripts: $total_tests" >> "$RESULTS_FILE"
echo "Total subtests passed: $total_pass" >> "$RESULTS_FILE"
echo "Total subtests failed: $total_fail" >> "$RESULTS_FILE"
echo "Errors/timeouts: $total_error" >> "$RESULTS_FILE"
