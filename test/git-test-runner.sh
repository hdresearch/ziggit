#!/bin/bash
# test/git-test-runner.sh — Run git's official test suite against ziggit
set -u

cd /tmp/git-tests/t

RESULTS_FILE="/root/ziggit/test/git-test-results.txt"
echo "Git Test Suite Results (ziggit as drop-in replacement)" > "$RESULTS_FILE"
echo "Date: $(date -u '+%Y-%m-%d %H:%M UTC')" >> "$RESULTS_FILE"
echo "Ziggit version: $(/root/ziggit/zig-out/bin/ziggit --version 2>&1)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"
printf "%-40s %s\n" "Test Script" "Result" >> "$RESULTS_FILE"
printf "%-40s %s\n" "----------------------------------------" "----------" >> "$RESULTS_FILE"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
SCRIPTS_RUN=0

TEST_SCRIPTS=(
    t0001-init.sh
    t0002-gitfile.sh
    t0003-attributes.sh
    t0005-signals.sh
    t0006-date.sh
    t0008-ignores.sh
    t0012-help.sh
    t0020-crlf.sh
    t0040-parse-options.sh
    t0050-filesystem.sh
    t0060-path-utils.sh
    t1000-read-tree-m-3way.sh
    t1001-read-tree-m-2way.sh
    t1300-config.sh
    t1400-update-ref.sh
    t1500-rev-parse.sh
    t1700-split-index.sh
    t2000-conflict-when-checking-files-out.sh
    t2200-add-update.sh
    t3000-ls-files-others.sh
    t3100-ls-tree-restrict.sh
    t3200-branch.sh
    t3400-rebase.sh
    t3600-rm.sh
    t3700-add.sh
    t3900-i18n-commit.sh
)

for test_script in "${TEST_SCRIPTS[@]}"; do
    if [ ! -f "$test_script" ]; then
        echo "  SKIP $test_script (not found)"
        printf "%-40s %s\n" "$test_script" "SKIP (not found)" >> "$RESULTS_FILE"
        continue
    fi

    SCRIPTS_RUN=$((SCRIPTS_RUN + 1))
    echo -n "  Running $test_script ... "

    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    EXIT_CODE=$?

    # Parse results from TAP output
    TOTAL_LINE=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')
    SUMMARY_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)

    if [ $EXIT_CODE -eq 124 ]; then
        # Timeout
        PASS=0
        FAIL=0
        TOTAL=${TOTAL_LINE:-0}
        RESULT="TIMEOUT"
    elif echo "$SUMMARY_LINE" | grep -q "passed all"; then
        TOTAL=${TOTAL_LINE:-0}
        PASS=$TOTAL
        FAIL=0
        RESULT="ALL PASSED ($PASS/$TOTAL)"
    elif echo "$SUMMARY_LINE" | grep -q "failed"; then
        FAIL=$(echo "$SUMMARY_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        TOTAL=${TOTAL_LINE:-0}
        if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
            PASS=$((TOTAL - FAIL))
        else
            PASS=0
        fi
        RESULT="$PASS/$TOTAL passed ($FAIL failed)"
    else
        PASS=0
        FAIL=0
        TOTAL=0
        RESULT="NO RESULTS (exit=$EXIT_CODE)"
    fi

    echo "$RESULT"
    printf "%-40s %s\n" "$test_script" "$RESULT" >> "$RESULTS_FILE"

    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
done

echo "" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)" >> "$RESULTS_FILE"
echo "Scripts run: $SCRIPTS_RUN" >> "$RESULTS_FILE"
if [ $TOTAL_TESTS -gt 0 ]; then
    PCT=$((TOTAL_PASS * 100 / TOTAL_TESTS))
    echo "Pass rate: ${PCT}%" >> "$RESULTS_FILE"
fi

echo ""
echo "=== SUMMARY ==="
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)"
if [ $TOTAL_TESTS -gt 0 ]; then
    echo "Pass rate: $((TOTAL_PASS * 100 / TOTAL_TESTS))%"
fi
echo "Results saved to $RESULTS_FILE"
