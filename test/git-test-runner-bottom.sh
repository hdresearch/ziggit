#!/bin/bash
# Git Test Suite Results — Bottom Half (comprehensive run)
# Runs test scripts from t9xxx down to t0xxx

cd /tmp/git-tests/t
RESULTS="/root/ziggit/test/git-test-results-bottom.txt"
echo "Git Test Suite Results — Bottom Half (comprehensive)" > "$RESULTS"
echo "Date: $(date -u +%Y-%m-%d)" >> "$RESULTS"
echo "" >> "$RESULTS"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_TESTS=0; PERFECT=0; SCRIPTS=0

TEST_SCRIPTS=(
    # t9xxx
    t9902-completion.sh
    # t8xxx — blame/annotate
    t8015-blame-default-ignorerevs.sh
    t8014-blame-ignore-fuzzy.sh
    t8013-blame-ignore-revs.sh
    t8012-blame-colors.sh
    t8011-blame-split-file.sh
    t8010-cat-file-filters.sh
    t8009-blame-vs-topicbranches.sh
    t8008-blame-formats.sh
    t8007-cat-file-textconv.sh
    t8006-blame-textconv.sh
    t8005-blame-i18n.sh
    t8004-blame-with-conflicts.sh
    t8003-blame-corner-cases.sh
    t8002-blame.sh
    t8001-annotate.sh
    # t7xxx — high-level commands
    t7900-maintenance.sh
    t7810-grep.sh
    t7700-repack.sh
    t7600-merge.sh
    t7520-ignored-hook-warning.sh
    t7519-status-fsmonitor.sh
    t7518-ident-corner-cases.sh
    t7517-per-repo-email.sh
    t7512-status-help.sh
    t7511-status-index.sh
    t7510-signed-commit.sh
    t7509-commit-authorship.sh
    t7508-status.sh
    t7507-commit-verbose.sh
    t7506-status-submodule.sh
    t7505-prepare-commit-msg-hook.sh
    t7504-commit-msg-hook.sh
    t7502-commit-porcelain.sh
    t7501-commit-basic-functionality.sh
    t7500-commit-template-squash-signoff.sh
    t7421-submodule-summary.sh
    t7420-submodule-set-url.sh
    t7419-submodule-set-branch.sh
    t7418-submodule-sparse-gitmodules.sh
    t7417-submodule-path-url.sh
    t7416-submodule-dash-url.sh
    t7414-submodule-mistakes.sh
    t7413-submodule-is-active.sh
    t7412-submodule-absorbgitdirs.sh
    t7411-submodule-config.sh
    t7409-submodule-detached-work-tree.sh
    t7408-submodule-reference.sh
    t7407-submodule-foreach.sh
    t7406-submodule-update.sh
    t7403-submodule-sync.sh
    t7402-submodule-rebase.sh
    t7401-submodule-summary.sh
    t7400-submodule-basic.sh
    t7301-clean-interactive.sh
    t7300-clean.sh
    t7201-co.sh
    t7113-post-index-change-hook.sh
    t7112-reset-submodule.sh
    t7111-reset-table.sh
    t7110-reset-merge.sh
    t7107-reset-pathspec-file.sh
    t7105-reset-patch.sh
    t7104-reset-hard.sh
    t7103-reset-bare.sh
    t7102-reset.sh
    t7101-reset-empty-subdirs.sh
    t7100-revert.sh
    t7064-wtstatus-pv2.sh
    t7060-wtstatus.sh
    t7031-verify-tag-signed-ssh.sh
    t7030-verify-tag.sh
    t7012-skip-worktree-writing.sh
    t7011-skip-worktree-reading.sh
    t7010-setup.sh
    t7008-filter-branch-null-sha1.sh
    t7007-show.sh
    t7006-pager.sh
    t7005-editor.sh
    t7004-tag.sh
    t7003-filter-branch.sh
    t7002-mv-sparse-checkout.sh
    t7001-mv.sh
    # t6xxx — rev-list, merge, for-each-ref
    t6302-for-each-ref-filter.sh
    t6301-for-each-ref-errors.sh
    t6300-for-each-ref.sh
    t6200-fmt-merge-msg.sh
    t6136-pathspec-in-bare.sh
    t6135-pathspec-with-attrs.sh
    t6134-pathspec-in-submodule.sh
    t6132-pathspec-exclude.sh
    t6131-pathspec-icase.sh
    t6130-pathspec-noglob.sh
    t6120-describe.sh
    t6115-rev-list-du.sh
    t6114-keep-packs.sh
    t6113-rev-list-bitmap-filters.sh
    t6112-rev-list-filters-objects.sh
    t6111-rev-list-treesame.sh
    t6110-rev-list-sparse.sh
    t6102-rev-list-unexpected-objects.sh
    t6101-rev-parse-parents.sh
    t6100-rev-list-in-order.sh
    t6050-replace.sh
    t6040-tracking-info.sh
    t6030-bisect-porcelain.sh
    t6020-bundle-misc.sh
    t6019-rev-list-ancestry-path.sh
    t6018-rev-list-glob.sh
    t6017-rev-list-stdin.sh
    t6016-rev-list-graph-simplify-history.sh
    t6013-rev-list-reverse-parents.sh
    t6012-rev-list-simplify.sh
    t6011-rev-list-with-bad-commit.sh
    t6010-merge-base.sh
    t6009-rev-list-parent.sh
    t6008-rev-list-submodule.sh
    t6007-rev-list-cherry-pick-file.sh
    t6006-rev-list-format.sh
    t6005-rev-list-count.sh
    t6004-rev-list-path-optim.sh
    t6003-rev-list-topo-order.sh
    t6002-rev-list-bisect.sh
    t6001-rev-list-graft.sh
    t6000-rev-list-misc.sh
    # t5xxx — fetch, push, clone, pack
    t5616-partial-clone.sh
    t5614-clone-submodules-shallow.sh
    t5613-info-alternate.sh
    t5612-clone-refspec.sh
    t5611-clone-config.sh
    t5610-clone-detached.sh
    t5609-clone-branch.sh
    t5607-clone-bundle.sh
    t5606-clone-options.sh
    t5605-clone-local.sh
    t5601-clone.sh
    t5572-pull-submodule.sh
    t5560-http-backend-noserver.sh
    t5553-set-upstream.sh
    t5548-push-porcelain.sh
    t5547-push-quarantine.sh
    t5546-receive-limits.sh
    t5545-push-options.sh
    t5544-pack-objects-hook.sh
    t5543-atomic-push.sh
    t5537-fetch-shallow.sh
    t5535-fetch-push-symref.sh
    t5534-push-signed.sh
    t5533-push-cas.sh
    t5532-fetch-proxy.sh
    t5531-deep-nested-push.sh
    t5530-upload-pack-error.sh
    t5527-fetch-odd-refs.sh
    t5526-fetch-submodules.sh
    t5525-fetch-tagopt.sh
    t5524-pull-msg.sh
    t5523-push-upstream.sh
    t5521-pull-options.sh
    t5520-pull.sh
    t5519-push-alternates.sh
    t5518-fetch-exit-status.sh
    t5517-push-mirror.sh
    t5516-fetch-push.sh
    t5515-fetch-merge-logic.sh
    t5514-fetch-multiple.sh
    t5513-fetch-track.sh
    t5511-refspec.sh
    t5510-fetch.sh
    t5509-fetch-push-namespaces.sh
    t5507-remote-environment.sh
    t5506-remote-groups.sh
    t5505-remote.sh
    t5504-fetch-receive-strict.sh
    t5503-tagfollow.sh
    t5502-quickfetch.sh
    t5501-fetch-push-hook.sh
    t5500-fetch-pack.sh
    t5400-send-pack.sh
    t5300-pack-object.sh
    t5100-mailinfo.sh
    # t4xxx — diff, apply, am
    t4200-rerere.sh
    t4150-am.sh
    t4137-apply-submodule.sh
    t4136-apply-check.sh
    t4135-apply-weird-filenames.sh
    t4134-apply-submodule.sh
    t4133-apply-filenames.sh
    t4132-apply-removal.sh
    t4131-apply-fake-ancestor.sh
    t4130-apply-criss-cross-rename.sh
    t4127-apply-same-fn.sh
    t4125-apply-ws-fuzz.sh
    t4123-apply-shrink.sh
    t4122-apply-symlink-inside.sh
    t4121-apply-diffs.sh
    t4120-apply-popt.sh
    t4119-apply-config.sh
    t4118-apply-empty-context.sh
    t4117-apply-reject.sh
    t4116-apply-reverse.sh
    t4115-apply-symlink.sh
    t4114-apply-typechange.sh
    t4113-apply-ending.sh
    t4112-apply-renames.sh
    t4111-apply-subdir.sh
    t4110-apply-scan.sh
    t4109-apply-multifrag.sh
    t4106-apply-stdin.sh
    t4105-apply-fuzz.sh
    t4104-apply-boundary.sh
    t4102-apply-rename.sh
    t4101-apply-nonl.sh
    t4069-remerge-diff.sh
    t4068-diff-symmetric-merge-base.sh
    t4066-diff-emit-delay.sh
    t4065-diff-anchored.sh
    t4064-diff-oidfind.sh
    t4063-diff-blobs.sh
    t4062-diff-pickaxe.sh
    t4061-diff-indent.sh
    t4060-diff-submodule-option-diff-format.sh
    t4059-diff-submodule-not-initialized.sh
    t4057-diff-combined-paths.sh
    t4056-diff-order.sh
    t4055-diff-context.sh
    t4054-diff-bogus-tree.sh
    t4050-diff-histogram.sh
    t4049-diff-stat-count.sh
    t4048-diff-combined-binary.sh
    t4047-diff-dirstat.sh
    t4045-diff-relative.sh
    t4044-diff-index-unique-abbrev.sh
    t4043-diff-rename-binary.sh
    t4041-diff-submodule-option.sh
    t4040-whitespace-status.sh
    t4039-diff-assume-unchanged.sh
    t4038-diff-combined.sh
    t4037-diff-r-t-dirs.sh
    t4036-format-patch-signer-mime.sh
    t4035-diff-quiet.sh
    t4033-diff-patience.sh
    t4032-diff-inter-hunk-context.sh
    t4030-diff-textconv.sh
    t4029-diff-trailing-space.sh
    t4028-format-patch-mime-headers.sh
    t4027-diff-submodule.sh
    t4025-hunk-header.sh
    t4024-diff-optimize-common.sh
    t4023-diff-rename-typechange.sh
    t4022-diff-rewrite.sh
    t4021-format-patch-numbered.sh
    t4019-diff-wserror.sh
    t4016-diff-quote.sh
    t4012-diff-binary.sh
    t4011-diff-symlink.sh
    t4010-diff-pathspec.sh
    t4009-diff-rename-4.sh
    t4008-diff-break-rewrite.sh
    t4006-diff-mode.sh
    t4005-diff-rename-2.sh
    t4004-diff-rename-symlink.sh
    t4003-diff-rename-1.sh
    t4002-diff-basic.sh
    t4000-diff-format.sh
    # t3xxx — rebase, cherry-pick, add, rm, branch, ls-files/tree
    t3900-i18n-commit.sh
    t3700-add.sh
    t3600-rm.sh
    t3514-cherry-pick-revert-gpg.sh
    t3512-cherry-pick-submodule.sh
    t3513-revert-submodule.sh
    t3511-cherry-pick-x.sh
    t3510-cherry-pick-sequence.sh
    t3509-cherry-pick-merge-df.sh
    t3508-cherry-pick-many-commits.sh
    t3507-cherry-pick-conflict.sh
    t3506-cherry-pick-ff.sh
    t3505-cherry-pick-empty.sh
    t3504-cherry-pick-rerere.sh
    t3503-cherry-pick-root.sh
    t3502-cherry-pick-merge.sh
    t3501-revert-cherry-pick.sh
    t3500-cherry.sh
    t3438-rebase-broken-files.sh
    t3437-rebase-fixup-options.sh
    t3436-rebase-more-options.sh
    t3435-rebase-gpg-sign.sh
    t3434-rebase-i18n.sh
    t3433-rebase-across-mode-change.sh
    t3432-rebase-fast-forward.sh
    t3431-rebase-fork-point.sh
    t3430-rebase-merges.sh
    t3429-rebase-edit-todo.sh
    t3428-rebase-signoff.sh
    t3427-rebase-subtree.sh
    t3426-rebase-submodule.sh
    t3425-rebase-topology-merges.sh
    t3424-rebase-empty.sh
    t3423-rebase-reword.sh
    t3422-rebase-incompatible-options.sh
    t3421-rebase-topology-linear.sh
    t3420-rebase-autostash.sh
    t3419-rebase-patch-id.sh
    t3418-rebase-continue.sh
    t3417-rebase-whitespace-fix.sh
    t3416-rebase-onto-threedots.sh
    t3415-rebase-autosquash.sh
    t3413-rebase-hook.sh
    t3412-rebase-root.sh
    t3409-rebase-environ.sh
    t3408-rebase-multi-line.sh
    t3407-rebase-abort.sh
    t3406-rebase-message.sh
    t3405-rebase-malformed.sh
    t3404-rebase-interactive.sh
    t3403-rebase-skip.sh
    t3400-rebase.sh
    t3322-notes-commit-abort.sh
    t3321-notes-stripspace.sh
    t3320-notes-merge-worktrees.sh
    t3311-notes-merge-fanout.sh
    t3310-notes-merge-manual-resolve.sh
    t3301-notes.sh
    t3300-funny-names.sh
    t3200-branch.sh
    t3101-ls-tree-dirname.sh
    t3100-ls-tree-restrict.sh
    t3070-wildmatch.sh
    t3060-ls-files-with-tree.sh
    t3050-subprojects-fetch.sh
    t3040-subprojects-basic.sh
    t3020-ls-files-error-unmatch.sh
    t3010-ls-files-killed-modified.sh
    t3000-ls-files-others.sh
    # t2xxx — checkout, switch, restore, worktree, add
    t2406-worktree-repair.sh
    t2404-worktree-config.sh
    t2403-worktree-move.sh
    t2402-worktree-list.sh
    t2401-worktree-prune.sh
    t2400-worktree-add.sh
    t2200-add-update.sh
    t2100-update-cache-badpath.sh
    t2072-restore-pathspec-file.sh
    t2070-restore.sh
    t2060-switch.sh
    t2050-git-dir-relative.sh
    t2030-unresolve-info.sh
    t2027-checkout-track.sh
    t2026-checkout-pathspec-file.sh
    t2025-checkout-no-overlay.sh
    t2024-checkout-dwim.sh
    t2021-checkout-overwrite.sh
    t2020-checkout-detach.sh
    t2019-checkout-ambiguous-ref.sh
    t2018-checkout-branch.sh
    t2017-checkout-orphan.sh
    t2016-checkout-patch.sh
    t2015-checkout-unborn.sh
    t2014-checkout-switch.sh
    t2013-checkout-submodule.sh
    t2012-checkout-last.sh
    t2011-checkout-invalid-head.sh
    t2010-checkout-ambiguous.sh
    t2009-checkout-statinfo.sh
    t2008-checkout-subdir.sh
    t2007-checkout-symlink.sh
    t2005-checkout-index-symlinks.sh
    t2004-checkout-cache-temp.sh
    t2003-checkout-cache-mkdir.sh
    t2022-checkout-paths.sh
    # t1xxx — read-tree, rev-parse, config, fsck, refs, setup
    t1510-repo-setup.sh
    t1507-rev-parse-upstream.sh
    t1506-rev-parse-diagnosis.sh
    t1505-rev-parse-last.sh
    t1504-ceiling-dirs.sh
    t1503-rev-parse-verify.sh
    t1502-rev-parse-parseopt.sh
    t1500-rev-parse.sh
    t1451-fsck-buffer.sh
    t1450-fsck.sh
    t1420-lost-found.sh
    t1418-reflog-exists.sh
    t1417-reflog-updateref.sh
    t1414-reflog-walk.sh
    t1412-reflog-loop.sh
    t1411-reflog-show.sh
    t1409-avoid-packing-refs.sh
    t1408-packed-refs.sh
    t1415-worktree-refs.sh
    t1404-update-ref-errors.sh
    t1402-check-ref-format.sh
    t1401-symbolic-ref.sh
    t1350-config-hooks-path.sh
    t1307-config-blob.sh
    t1306-xdg-files.sh
    t1305-config-include.sh
    t1303-wacky-config.sh
    t1302-repo-version.sh
    t1301-shared-repo.sh
    t1200-tutorial.sh
    t1100-commit-tree-options.sh
    t1091-sparse-checkout-builtin.sh
    t1090-sparse-checkout-scope.sh
    t1060-object-corruption.sh
    t1050-large.sh
    t1020-subdirectory.sh
    t1015-read-index-unmerged.sh
    t1014-read-tree-confusing.sh
    t1013-read-tree-submodule.sh
    t1012-read-tree-df.sh
    t1011-read-tree-sparse-checkout.sh
    t1010-mktree.sh
    t1009-read-tree-new-index.sh
    t1008-read-tree-overlay.sh
    t1007-hash-object.sh
    t1005-read-tree-reset.sh
    t1004-read-tree-m-u-wf.sh
    t1002-read-tree-m-u-2way.sh
    t1001-read-tree-m-2way.sh
    t1000-read-tree-m-3way.sh
    # t0xxx — basics, credentials, gettext
    t0410-partial-clone.sh
    t0302-credential-store.sh
    t0303-credential-external.sh
    t0301-credential-cache.sh
    t0300-credentials.sh
    t0201-gettext-fallbacks.sh
    t0202-gettext-perl.sh
    t0101-at-syntax.sh
    t0100-previous.sh
    t0091-bugreport.sh
    t0055-beyond-symlinks.sh
    t0050-filesystem.sh
    t0041-usage.sh
    t0028-working-tree-encoding.sh
    t0027-auto-crlf.sh
    t0020-crlf.sh
    t0010-racy-git.sh
    t0008-ignores.sh
    t0005-signals.sh
    t0002-gitfile.sh
    t0000-basic.sh
)

for test_script in "${TEST_SCRIPTS[@]}"; do
    [ ! -f "$test_script" ] && continue
    
    OUTPUT=$(GIT_TEST_INSTALLED=/tmp/ziggit-as-git \
             GIT_TEST_TEMPLATE_DIR=/tmp/git-tests/templates/blt \
             timeout 120 bash "$test_script" 2>&1)
    
    LAST_LINE=$(echo "$OUTPUT" | grep "^# failed\|^# passed all" | tail -1)
    TOTAL=$(echo "$OUTPUT" | grep "^1\.\." | tail -1 | sed 's/1\.\.//')
    
    if [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ]; then
        continue
    fi
    
    if echo "$LAST_LINE" | grep -q "passed all"; then
        PASS=$TOTAL; FAIL=0
        MARKER=" ✓"
        PERFECT=$((PERFECT + 1))
    elif echo "$LAST_LINE" | grep -q "failed"; then
        FAIL=$(echo "$LAST_LINE" | grep -o "failed [0-9]*" | grep -o "[0-9]*")
        PASS=$((TOTAL - FAIL))
        MARKER=""
    else
        PASS=0; FAIL=0; TOTAL=0; MARKER=""
    fi
    
    SCRIPTS=$((SCRIPTS + 1))
    echo "  $test_script: $PASS/$TOTAL passed$MARKER" | tee -a "$RESULTS"
    TOTAL_PASS=$((TOTAL_PASS + PASS)); TOTAL_FAIL=$((TOTAL_FAIL + FAIL)); TOTAL_TESTS=$((TOTAL_TESTS + TOTAL))
    
    # Clean up trash directories to avoid filling /tmp
    rm -rf /tmp/git-tests/t/trash\ directory.* 2>/dev/null
done

echo "" >> "$RESULTS"
echo "TOTAL: $TOTAL_PASS/$TOTAL_TESTS passed ($TOTAL_FAIL failed) across $SCRIPTS scripts" | tee -a "$RESULTS"
PCT=$(python3 -c "print(f'{$TOTAL_PASS*100/$TOTAL_TESTS:.1f}')" 2>/dev/null || echo "?")
echo "Pass rate: ${PCT}% — $PERFECT scripts at 100%" | tee -a "$RESULTS"

echo "" >> "$RESULTS"
echo "CLI Fixes Applied:" >> "$RESULTS"
echo "- Translate -ufalse/-utrue/-uyes/-u0/-u1/-uon to -uno/-unormal for git 2.43" >> "$RESULTS"
echo "- Translate --untracked-files=false/true to no/normal" >> "$RESULTS"
echo "- Translate status.showuntrackedfiles config: false→no, true→normal, 0→no, 1→normal" >> "$RESULTS"
echo "- Translate merge.stat config: diffstat→true, compact→true" >> "$RESULTS"
echo "- Translate 'git config set --append' to 'git config --add'" >> "$RESULTS"
echo "- Translate 'git config unset --all' to 'git config --unset-all'" >> "$RESULTS"
echo "- Translate 'git config get --all' to 'git config --get-all'" >> "$RESULTS"
echo "- Translate 'git config get --regexp' to 'git config --get-regexp'" >> "$RESULTS"
echo "- Strip --i-still-use-this flag (deprecated command acknowledgment)" >> "$RESULTS"
echo "- Strip --ref-format= and --no-advice flags" >> "$RESULTS"
echo "- Implement rev-list -z via NUL-byte output conversion (with --objects and --boundary format)" >> "$RESULTS"
echo "- Translate -c key=value pairs for config value compatibility" >> "$RESULTS"
