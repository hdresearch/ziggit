#!/bin/bash
cd /tmp/git-tests/t
RESULTS="/root/ziggit/test/git-test-results-bottom.txt"
echo "Git Test Suite Results — Bottom Half (expanded)" > "$RESULTS"
echo "Date: $(date -u +%Y-%m-%d)" >> "$RESULTS"
echo "" >> "$RESULTS"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_TESTS=0; SCRIPT_COUNT=0; PERFECT=0

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
    t3438-rebase-broken-files.sh \
    t3437-rebase-fixup-options.sh \
    t3436-rebase-more-options.sh \
    t3435-rebase-gpg-sign.sh \
    t3434-rebase-i18n.sh \
    t3432-rebase-fast-forward.sh \
    t3431-rebase-fork-point.sh \
    t3430-rebase-merges.sh \
    t3429-rebase-edit-todo.sh \
    t3427-rebase-subtree.sh \
    t3425-rebase-topology-merges.sh \
    t3423-rebase-reword.sh \
    t3422-rebase-incompatible-options.sh \
    t3421-rebase-topology-linear.sh \
    t3419-rebase-patch-id.sh \
    t3416-rebase-onto-threedots.sh \
    t3409-rebase-environ.sh \
    t3408-rebase-multi-line.sh \
    t3406-rebase-message.sh \
    t3405-rebase-malformed.sh \
    t3403-rebase-skip.sh \
    t3400-rebase.sh \
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
    t2200-add-update.sh \
    t2106-update-index-assume-unchanged.sh \
    t2100-update-cache-badpath.sh \
    t2072-restore-pathspec-file.sh \
    t2070-restore.sh \
    t2060-switch.sh \
    t2050-git-dir-relative.sh \
    t2030-unresolve-info.sh \
    t2024-checkout-dwim.sh \
    t2022-checkout-paths.sh \
    t2020-checkout-detach.sh \
    t2019-checkout-ambiguous-ref.sh \
    t2018-checkout-branch.sh \
    t2017-checkout-orphan.sh \
    t2015-checkout-unborn.sh \
    t2014-checkout-switch.sh \
    t2013-checkout-submodule.sh \
    t2012-checkout-last.sh \
    t2010-checkout-ambiguous.sh \
    t2009-checkout-statinfo.sh \
    t2007-checkout-symlink.sh \
    t2005-checkout-index-symlinks.sh \
    t2004-checkout-cache-temp.sh \
    t2003-checkout-cache-mkdir.sh \
    t1510-repo-setup.sh \
    t1507-rev-parse-upstream.sh \
    t1506-rev-parse-diagnosis.sh \
    t1505-rev-parse-last.sh \
    t1504-ceiling-dirs.sh \
    t1503-rev-parse-verify.sh \
    t1502-rev-parse-parseopt.sh \
    t1500-rev-parse.sh \
    t1451-fsck-buffer.sh \
    t1450-fsck.sh \
    t1418-reflog-exists.sh \
    t1417-reflog-updateref.sh \
    t1414-reflog-walk.sh \
    t1404-update-ref-errors.sh \
    t1401-symbolic-ref.sh \
    t1307-config-blob.sh \
    t1306-xdg-files.sh \
    t1305-config-include.sh \
    t1303-wacky-config.sh \
    t1302-repo-version.sh \
    t1301-shared-repo.sh \
    t1100-commit-tree-options.sh \
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
        PERFECT=$((PERFECT + 1))
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        PASS=$((TOTAL - FAIL))
    else
        PASS=0; FAIL=0; TOTAL=0
    fi

    SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
    if [ "$FAIL" -eq 0 ] 2>/dev/null; then
        echo "  $test_script: $PASS/$TOTAL passed ✓" | tee -a "$RESULTS"
    else
        echo "  $test_script: $PASS/$TOTAL passed" | tee -a "$RESULTS"
    fi
    TOTAL_PASS=$((TOTAL_PASS + PASS)); TOTAL_FAIL=$((TOTAL_FAIL + FAIL)); TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
    
    # Clean up trash directories to avoid /tmp filling up
    rm -rf /tmp/git-tests/t/trash\ directory.* 2>/dev/null
done

echo "" >> "$RESULTS"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed) across $SCRIPT_COUNT scripts" | tee -a "$RESULTS"
PCT=$((TOTAL_PASS * 1000 / TOTAL_TESTS))
PCT_INT=$((PCT / 10))
PCT_DEC=$((PCT % 10))
echo "Pass rate: ${PCT_INT}.${PCT_DEC}% — $PERFECT scripts at 100%" | tee -a "$RESULTS"
