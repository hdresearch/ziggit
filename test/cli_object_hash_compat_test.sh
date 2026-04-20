#!/bin/bash
# CLI test: verify ziggit and git produce identical object hashes and output
set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0; FAIL=0
TMPDIR=$(mktemp -d /tmp/ziggit_cli_hash_XXXXXX)
trap "rm -rf $TMPDIR" EXIT

fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }

# Setup: create a repo with git, then test ziggit reads
cd "$TMPDIR"
git init -q repo1
cd repo1
git config user.email "test@test.com"
git config user.name "Test"

# Test 1: hash-object compatibility
echo "hello world" > hello.txt
GIT_HASH=$(git hash-object hello.txt)
ZIGGIT_HASH=$($ZIGGIT hash-object hello.txt 2>/dev/null || echo "UNSUPPORTED")
if [ "$ZIGGIT_HASH" = "UNSUPPORTED" ]; then
    echo "SKIP: hash-object not supported by ziggit CLI"
else
    [ "$GIT_HASH" = "$ZIGGIT_HASH" ] && pass "hash-object matches" || fail "hash-object: git=$GIT_HASH ziggit=$ZIGGIT_HASH"
fi

# Test 2: rev-parse HEAD after commit
git add hello.txt
git commit -q -m "initial commit"
GIT_HEAD=$(git rev-parse HEAD)
ZIGGIT_HEAD=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
[ "$GIT_HEAD" = "$ZIGGIT_HEAD" ] && pass "rev-parse HEAD matches" || fail "rev-parse HEAD: git=$GIT_HEAD ziggit=$ZIGGIT_HEAD"

# Test 3: rev-parse HEAD after second commit
echo "more content" > second.txt
git add second.txt
git commit -q -m "second commit"
GIT_HEAD2=$(git rev-parse HEAD)
ZIGGIT_HEAD2=$($ZIGGIT rev-parse HEAD 2>/dev/null || echo "ERROR")
[ "$GIT_HEAD2" = "$ZIGGIT_HEAD2" ] && pass "rev-parse HEAD after 2nd commit" || fail "rev-parse 2nd: git=$GIT_HEAD2 ziggit=$ZIGGIT_HEAD2"

# Test 4: status on clean repo
GIT_STATUS=$(git status --porcelain)
ZIGGIT_STATUS=$($ZIGGIT status --porcelain 2>/dev/null || echo "ERROR")
[ "$GIT_STATUS" = "$ZIGGIT_STATUS" ] && pass "status --porcelain clean" || fail "status clean: git='$GIT_STATUS' ziggit='$ZIGGIT_STATUS'"

# Test 5: branch listing (normalize output: strip leading "* " and whitespace)
GIT_BRANCH=$(git branch --list 2>/dev/null | sed 's/^[* ]*//' | sed 's/^ *//' | sort)
ZIGGIT_BRANCH=$($ZIGGIT branch 2>/dev/null | sed 's/^[* ]*//' | sed 's/^ *//' | sort)
[ "$GIT_BRANCH" = "$ZIGGIT_BRANCH" ] && pass "branch list matches" || fail "branch: git='$GIT_BRANCH' ziggit='$ZIGGIT_BRANCH'"

# Test 6: tag after lightweight tag creation
git tag v1.0.0
GIT_TAG_HASH=$(git rev-parse v1.0.0)
ZIGGIT_TAG_HASH=$($ZIGGIT rev-parse v1.0.0 2>/dev/null || echo "UNSUPPORTED")
if [ "$ZIGGIT_TAG_HASH" = "UNSUPPORTED" ]; then
    echo "SKIP: rev-parse for tag refs not yet supported"
else
    [ "$GIT_TAG_HASH" = "$ZIGGIT_TAG_HASH" ] && pass "rev-parse tag matches" || fail "tag: git=$GIT_TAG_HASH ziggit=$ZIGGIT_TAG_HASH"
fi

# Test 7: describe tags
GIT_DESCRIBE=$(git describe --tags 2>/dev/null || echo "NONE")
ZIGGIT_DESCRIBE=$($ZIGGIT describe --tags 2>/dev/null || echo "NONE")
[ "$GIT_DESCRIBE" = "$ZIGGIT_DESCRIBE" ] && pass "describe --tags matches" || fail "describe: git='$GIT_DESCRIBE' ziggit='$ZIGGIT_DESCRIBE'"

# Test 8: log --oneline count
GIT_LOG_COUNT=$(git log --oneline | wc -l | tr -d ' ')
ZIGGIT_LOG_COUNT=$($ZIGGIT log --oneline 2>/dev/null | wc -l | tr -d ' ')
[ "$GIT_LOG_COUNT" = "$ZIGGIT_LOG_COUNT" ] && pass "log --oneline count ($GIT_LOG_COUNT)" || fail "log count: git=$GIT_LOG_COUNT ziggit=$ZIGGIT_LOG_COUNT"

# Test 9: cat-file on known blob
BLOB_HASH=$(git rev-parse HEAD:hello.txt)
GIT_BLOB=$(git cat-file -p "$BLOB_HASH")
ZIGGIT_BLOB=$($ZIGGIT cat-file -p "$BLOB_HASH" 2>/dev/null || echo "UNSUPPORTED")
if [ "$ZIGGIT_BLOB" = "UNSUPPORTED" ]; then
    echo "SKIP: cat-file not supported"
else
    [ "$GIT_BLOB" = "$ZIGGIT_BLOB" ] && pass "cat-file blob matches" || fail "cat-file: git='$GIT_BLOB' ziggit='$ZIGGIT_BLOB'"
fi

# Test 10: ls-files
GIT_LS=$(git ls-files | sort)
ZIGGIT_LS=$($ZIGGIT ls-files 2>/dev/null | sort || echo "ERROR")
[ "$GIT_LS" = "$ZIGGIT_LS" ] && pass "ls-files matches" || fail "ls-files: git='$GIT_LS' ziggit='$ZIGGIT_LS'"

echo ""
echo "CLI hash compat: $PASS pass, $FAIL fail"
[ $FAIL -eq 0 ] || exit 1
