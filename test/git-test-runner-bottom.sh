#!/bin/bash
# Run git test suite t5000-t9999 against ziggit
# Usage: bash test/git-test-runner-bottom.sh [start_pattern] [end_pattern]

RESULTS_FILE="test/git-test-results-bottom.txt"
TEST_DIR="/tmp/git-tests/t"

echo "=== Git Test Suite Results (t5000-t9999) ===" > "$RESULTS_FILE"
echo "Date: $(date -u)" >> "$RESULTS_FILE"
echo "Range: t5000-t9999" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

total=0
passed=0
failed=0
errors=0

for script in "$TEST_DIR"/t[5-9]*.sh; do
    name=$(basename "$script" .sh)
    total=$((total + 1))
    
    result=$(cd "$TEST_DIR" && \
        GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
        GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
        timeout 120 bash "$script" 2>&1 | tail -3)
    
    if echo "$result" | grep -q "^# passed all"; then
        status="PASS"
        passed=$((passed + 1))
        detail=$(echo "$result" | grep "^# passed all")
    elif echo "$result" | grep -q "^# still have"; then
        status="PARTIAL"
        failed=$((failed + 1))
        detail=$(echo "$result" | grep "^# still have\|^# passed all\|^1\.\.")
    else
        status="ERROR"
        errors=$((errors + 1))
        detail=$(echo "$result" | tail -1)
    fi
    
    echo "$status $name: $detail" >> "$RESULTS_FILE"
    echo "$status $name"
done

echo "" >> "$RESULTS_FILE"
echo "=== SUMMARY ===" >> "$RESULTS_FILE"
echo "Total: $total" >> "$RESULTS_FILE"
echo "Passed: $passed" >> "$RESULTS_FILE"
echo "Failed/Partial: $failed" >> "$RESULTS_FILE"
echo "Error: $errors" >> "$RESULTS_FILE"
