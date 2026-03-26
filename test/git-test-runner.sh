#!/bin/bash
# test/git-test-runner.sh — Run git's test suite against ziggit
cd /tmp/git-tests/t

RESULTS_FILE="/root/ziggit/test/git-test-results.txt"
echo "Git Test Suite Results (ziggit as drop-in)" > "$RESULTS_FILE"
echo "Date: $(date -u +%Y-%m-%d)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

for test_script in \
    t0001-init.sh \
    t0002-gitfile.sh \
    t0003-attributes.sh \
    t0005-signals.sh \
    t0006-date.sh \
    t0008-ignores.sh \
    t0012-help.sh \
    t0020-crlf.sh \
    t0040-parse-options.sh \
    t0050-filesystem.sh \
    t0060-path-utils.sh \
    t1000-read-tree-m-3way.sh \
    t1300-config.sh \
    t1400-update-ref.sh \
    t1500-rev-parse.sh \
    t1700-split-index.sh \
    t2000-conflict-when-checking-files-out.sh \
    t2200-add-update.sh \
    t3000-ls-files-others.sh \
    t3100-ls-tree-restrict.sh \
    t3200-branch.sh \
    t3400-rebase.sh \
    t3600-rm.sh \
    t3700-add.sh \
    t3900-i18n-commit.sh; do

    if [ ! -f "$test_script" ]; then
        echo "  $test_script: SKIPPED (not found)" | tee -a "$RESULTS_FILE"
        continue
    fi

    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    EXIT_CODE=$?

    # Parse results
    LAST_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)
    TOTAL=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')

    if [ $EXIT_CODE -eq 124 ]; then
        echo "  $test_script: TIMEOUT (120s)" | tee -a "$RESULTS_FILE"
        continue
    elif echo "$LAST_LINE" | grep -q "passed all"; then
        PASS=${TOTAL:-0}
        FAIL=0
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        PASS=$((${TOTAL:-0} - ${FAIL:-0}))
    else
        PASS=0
        FAIL=0
        TOTAL=0
    fi

    echo "  $test_script: $PASS/$TOTAL passed" | tee -a "$RESULTS_FILE"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
done

echo "" >> "$RESULTS_FILE"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)" | tee -a "$RESULTS_FILE"
