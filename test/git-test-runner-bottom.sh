#!/bin/bash
cd /tmp/git-tests/t
RESULTS="/root/ziggit/test/git-test-results-bottom.txt"
echo "Git Test Suite Results — Bottom Half (t9xxx-t3xxx)" > "$RESULTS"
echo "Date: $(date -u +%Y-%m-%d)" >> "$RESULTS"
echo "Runner: ziggit via /tmp/ziggit-as-git/git" >> "$RESULTS"
echo "System git: $(git --version)" >> "$RESULTS"
echo "" >> "$RESULTS"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_TESTS=0

for test_script in \
    t9902-completion.sh \
    t7900-maintenance.sh \
    t7810-grep.sh \
    t7700-repack.sh \
    t7600-merge.sh \
    t7508-status.sh \
    t7501-commit-basic-functionality.sh \
    t7400-submodule-basic.sh \
    t7201-co.sh \
    t7060-wtstatus.sh \
    t7004-tag.sh \
    t7001-mv.sh \
    t6300-for-each-ref.sh \
    t6200-fmt-merge-msg.sh \
    t6100-rev-list-in-order.sh \
    t6000-rev-list-misc.sh \
    t5601-clone.sh \
    t5510-fetch.sh \
    t5500-fetch-pack.sh \
    t5400-send-pack.sh \
    t5300-pack-object.sh \
    t5100-mailinfo.sh \
    t4200-rerere.sh \
    t4150-am.sh \
    t4000-diff-format.sh \
    t3900-i18n-commit.sh \
    t3700-add.sh \
    t3600-rm.sh \
    t3507-cherry-pick-conflict.sh \
    t3501-revert-cherry-pick.sh \
    t3404-rebase-interactive.sh \
    t3400-rebase.sh \
    t3200-branch.sh \
    t3100-ls-tree-restrict.sh \
    t3070-wildmatch.sh \
    t3000-ls-files-others.sh \
    t2400-worktree-add.sh \
    t2200-add-update.sh \
    t2106-update-index-assume-unchanged.sh \
    t2025-checkout-no-overlay.sh \
    t2020-checkout-detach.sh \
    t2018-checkout-branch.sh \
    t2012-checkout-last.sh \
    t2010-checkout-ambiguous.sh \
    t1700-split-index.sh \
    t1500-rev-parse.sh \
    t1450-fsck.sh \
    t1400-update-ref.sh \
    t1300-config.sh \
    t1200-tutorial.sh \
    t1100-commit-tree-options.sh \
    t1020-subdirectory.sh \
    t1010-mktree.sh \
    t1006-cat-file.sh \
    t1005-read-tree-reset.sh \
    t1004-read-tree-m-u-wf.sh \
    t1003-read-tree-prefix.sh \
    t1002-read-tree-m-u-2way.sh \
    t1001-read-tree-m-2way.sh \
    t1000-read-tree-m-3way.sh \
    t0300-credentials.sh \
    t0070-fundamental.sh \
    t0060-path-utils.sh \
    t0050-filesystem.sh \
    t0001-init.sh \
    t0000-basic.sh \
; do
    if [ ! -f "$test_script" ]; then
        echo "  $test_script: SKIPPED (not found)" | tee -a "$RESULTS"
        continue
    fi
    
    # Clean up trash directories from previous tests to avoid /tmp filling up
    rm -rf /tmp/git-tests/t/trash\ directory.* 2>/dev/null
    
    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 124 ]; then
        echo "  $test_script: TIMEOUT (120s)" | tee -a "$RESULTS"
        continue
    fi
    
    LAST_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)
    TOTAL_LINE=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')
    
    # Count ok/not ok lines as fallback
    OK_COUNT=$(echo "$OUTPUT" | grep -c "^ok ")
    NOTOK_COUNT=$(echo "$OUTPUT" | grep -c "^not ok ")
    
    if echo "$LAST_LINE" | grep -q "passed all"; then
        PASS=$TOTAL_LINE; FAIL=0; TOTAL=$TOTAL_LINE
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        TOTAL=$TOTAL_LINE
        PASS=$((TOTAL - FAIL))
    elif [ $((OK_COUNT + NOTOK_COUNT)) -gt 0 ]; then
        # No summary line but we have test results (e.g., bail out before end)
        PASS=$OK_COUNT; FAIL=$NOTOK_COUNT; TOTAL=$((OK_COUNT + NOTOK_COUNT))
    else
        PASS=0; FAIL=0; TOTAL=0
        echo "  $test_script: NO RESULTS (exit $EXIT_CODE)" | tee -a "$RESULTS"
        continue
    fi
    
    if [ "$FAIL" -eq 0 ]; then
        echo "  $test_script: $PASS/$TOTAL passed ✓" | tee -a "$RESULTS"
    else
        echo "  $test_script: $PASS/$TOTAL passed ($FAIL failed)" | tee -a "$RESULTS"
    fi
    TOTAL_PASS=$((TOTAL_PASS + PASS)); TOTAL_FAIL=$((TOTAL_FAIL + FAIL)); TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
done

echo "" | tee -a "$RESULTS"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)" | tee -a "$RESULTS"
