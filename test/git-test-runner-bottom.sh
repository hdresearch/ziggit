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
    t7501-commit.sh \
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
