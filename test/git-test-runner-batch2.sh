#!/bin/bash
# test/git-test-runner-batch2.sh — Second batch of git tests
set -u
cd /tmp/git-tests/t

RESULTS_FILE="/root/ziggit/test/git-test-results.txt"
# Append to existing results
echo "" >> "$RESULTS_FILE"
echo "=== Batch 2 ===" >> "$RESULTS_FILE"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

TEST_LIST=(
    t0004-unwritable.sh
    t0007-git-var.sh
    t0009-git-dir-validation.sh
    t0010-racy-git.sh
    t0014-alias.sh
    t0017-env-helper.sh
    t0018-advice.sh
    t0021-conversion.sh
    t0022-crlf-rename.sh
    t0030-stripspace.sh
    t1001-read-tree-m-2way.sh
    t1002-read-tree-m-u-2way.sh
    t1003-read-tree-prefix.sh
    t1005-read-tree-reset.sh
    t1006-cat-file.sh
    t1007-hash-object.sh
    t1008-read-tree-overlay.sh
    t1009-read-tree-new-index.sh
    t1010-mktree.sh
    t4000-diff-format.sh
    t4001-diff-rename.sh
    t4002-diff-basic.sh
    t4003-diff-rename-1.sh
    t4010-diff-pathspec.sh
    t5300-pack-object.sh
    t6000-rev-list-misc.sh
    t6001-rev-list-graft.sh
    t6003-rev-list-topo-order.sh
    t6010-merge-base.sh
    t7001-mv.sh
    t7004-tag.sh
    t7005-editor.sh
    t7060-wtstatus.sh
    t7102-reset.sh
    t7300-clean.sh
    t7500-commit-template-squash-signoff.sh
    t7502-commit-porcelain.sh
    t7600-merge.sh
    t7700-repack.sh
)

for test_script in "${TEST_LIST[@]}"; do
    if [ ! -f "$test_script" ]; then
        echo "  $test_script: SKIPPED (not found)" | tee -a "$RESULTS_FILE"
        continue
    fi

    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    EXIT_CODE=$?

    LAST_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)
    TOTAL=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')

    if [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ]; then
        if [ $EXIT_CODE -eq 124 ]; then
            echo "  $test_script: TIMEOUT" | tee -a "$RESULTS_FILE"
        else
            echo "  $test_script: ERROR (no TAP output)" | tee -a "$RESULTS_FILE"
        fi
        continue
    fi

    if echo "$LAST_LINE" | grep -q "passed all"; then
        PASS=$TOTAL
        FAIL=0
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        PASS=$((TOTAL - FAIL))
    else
        PASS=0
        FAIL=$TOTAL
    fi

    echo "  $test_script: $PASS/$TOTAL passed ($FAIL failed)" | tee -a "$RESULTS_FILE"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
done

echo "" >> "$RESULTS_FILE"
echo "BATCH 2 TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)" | tee -a "$RESULTS_FILE"
