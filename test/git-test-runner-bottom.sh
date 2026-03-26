#!/bin/bash
cd /tmp/git-tests/t
RESULTS="/root/ziggit/test/git-test-results-bottom.txt"
echo "Git Test Suite Results — Bottom Half" > "$RESULTS"
echo "Date: $(date -u +%Y-%m-%d)" >> "$RESULTS"
echo "" >> "$RESULTS"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_TESTS=0

for test_script in \
    t9902-completion.sh \
    t7900-maintenance.sh \
    t7810-grep.sh \
    t7700-repack.sh \
    t7600-merge.sh \
    t7508-status.sh \
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
    t4057-diff-combined-paths.sh \
    t4055-diff-context.sh \
    t4050-diff-histogram.sh \
    t4035-diff-quiet.sh \
    t4034-diff-words.sh \
    t4033-diff-patience.sh \
    t4030-diff-textconv.sh \
    t4027-diff-submodule.sh \
    t4026-color.sh \
    t4025-hunk-header.sh \
    t4024-diff-optimize-common.sh \
    t4023-diff-rename-typechange.sh \
    t4022-diff-rewrite.sh \
    t4017-diff-retval.sh \
    t4015-diff-whitespace.sh \
    t4013-diff-various.sh \
    t4012-diff-binary.sh \
    t4010-diff-pathspec.sh \
    t4005-diff-rename-2.sh \
    t4003-diff-rename-1.sh \
    t4001-diff-rename.sh \
    t4000-diff-format.sh \
    t3900-i18n-commit.sh \
    t3700-add.sh \
    t3600-rm.sh \
    t3301-notes.sh \
    t3200-branch.sh \
    t3101-ls-tree-dirname.sh \
    t3100-ls-tree-restrict.sh \
    t3070-wildmatch.sh \
    t3050-subprojects-fetch.sh \
    t3010-ls-files-killed-modified.sh \
    t3003-ls-files-exclude.sh \
    t3002-ls-files-dashpath.sh \
    t3000-ls-files-others.sh \
    t2100-update-cache-badpath.sh \
    t2010-checkout-ambiguous.sh \
    t1500-rev-parse.sh \
    t1050-large.sh \
    t1010-mktree.sh \
    t1005-read-tree-reset.sh \
    t1002-read-tree-m-u-2way.sh \
    t1001-read-tree-m-2way.sh \
    t1000-read-tree-m-3way.sh \
    t0050-filesystem.sh \
    t0027-auto-crlf.sh \
    t0020-crlf.sh \
    t0010-racy-git.sh \
    t0005-signals.sh \
    t0000-basic.sh \
; do
    if [ ! -f "$test_script" ]; then
        echo "  $test_script: SKIP (not found)" | tee -a "$RESULTS"
        continue
    fi

    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    RC=$?

    LAST_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)
    TOTAL=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')

    if [ $RC -eq 124 ]; then
        echo "  $test_script: TIMEOUT (120s)" | tee -a "$RESULTS"
        continue
    fi

    if echo "$LAST_LINE" | grep -q "passed all"; then
        PASS=$TOTAL; FAIL=0
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        PASS=$((TOTAL - FAIL))
    else
        PASS=0; FAIL=0; TOTAL=0
    fi

    echo "  $test_script: $PASS/$TOTAL passed" | tee -a "$RESULTS"
    TOTAL_PASS=$((TOTAL_PASS + PASS)); TOTAL_FAIL=$((TOTAL_FAIL + FAIL)); TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
done

echo "" >> "$RESULTS"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed)" | tee -a "$RESULTS"
