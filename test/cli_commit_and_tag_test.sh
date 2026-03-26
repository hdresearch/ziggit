#!/bin/bash
# test/cli_commit_and_tag_test.sh
# CLI test: compare ziggit commit/tag/rev-parse/status output against git
set -euo pipefail

ZIGGIT_REL="${1:-./zig-out/bin/ziggit}"
ZIGGIT="$(cd "$(dirname "$ZIGGIT_REL")" && pwd)/$(basename "$ZIGGIT_REL")"
PASS=0
FAIL=0
TESTDIR="/tmp/ziggit_cli_commit_tag_$$"

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS+1))
    else
        echo "  ✗ $desc"
        echo "    expected: $(echo "$expected" | head -3)"
        echo "    actual:   $(echo "$actual" | head -3)"
        FAIL=$((FAIL+1))
    fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"
        PASS=$((PASS+1))
    else
        echo "  ✗ $desc (does not contain '$needle')"
        echo "    actual: $(echo "$haystack" | head -3)"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================================
echo "Test 1: init creates valid repo for git"
# ============================================================================
mkdir -p "$TESTDIR/t1" && cd "$TESTDIR/t1"
"$ZIGGIT" init -q .
g=$(git status --porcelain 2>&1 || true)
# git should be able to read ziggit-initialized repo
check "git can read ziggit-initialized repo" "" "$g"

# ============================================================================
echo "Test 2: rev-parse HEAD matches after git commit"
# ============================================================================
mkdir -p "$TESTDIR/t2" && cd "$TESTDIR/t2"
git init -q && git config user.email t@t.com && git config user.name T
echo "hello" > f.txt && git add f.txt && git commit -q -m "init"
g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD)
check "rev-parse HEAD matches" "$g" "$z"

# ============================================================================
echo "Test 3: rev-parse HEAD after multiple commits"
# ============================================================================
cd "$TESTDIR/t2"
echo "world" > g.txt && git add g.txt && git commit -q -m "second"
g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD)
check "rev-parse HEAD after second commit" "$g" "$z"

# ============================================================================
echo "Test 4: status --porcelain on clean repo"
# ============================================================================
cd "$TESTDIR/t2"
g=$(git status --porcelain)
z=$("$ZIGGIT" status --porcelain)
check "status --porcelain clean" "$g" "$z"

# ============================================================================
echo "Test 5: status --porcelain with untracked file"
# ============================================================================
cd "$TESTDIR/t2"
echo "untracked" > new.txt
g=$(git status --porcelain | sort)
z=$("$ZIGGIT" status --porcelain | sort)
check "status --porcelain untracked" "$g" "$z"
rm new.txt

# ============================================================================
echo "Test 6: status --porcelain with modified file"
# ============================================================================
cd "$TESTDIR/t2"
echo "modified" > f.txt
g_lines=$(git status --porcelain | wc -l)
z_lines=$("$ZIGGIT" status --porcelain | wc -l)
# Both should detect the modification (at least 1 line)
[ "$g_lines" -ge 1 ] && [ "$z_lines" -ge 1 ] && {
    echo "  ✓ both detect modification (git: $g_lines lines, ziggit: $z_lines lines)"
    PASS=$((PASS+1))
} || {
    echo "  ✗ modification detection (git: $g_lines lines, ziggit: $z_lines lines)"
    FAIL=$((FAIL+1))
}
git checkout -- f.txt

# ============================================================================
echo "Test 7: tag list"
# ============================================================================
cd "$TESTDIR/t2"
git tag v1.0 && git tag v2.0
g=$(git tag | sort)
z=$("$ZIGGIT" tag | sort)
check "tag list" "$g" "$z"

# ============================================================================
echo "Test 8: cat-file -t HEAD"
# ============================================================================
cd "$TESTDIR/t2"
hash=$(git rev-parse HEAD)
g=$(git cat-file -t "$hash")
z=$("$ZIGGIT" cat-file -t "$hash")
check "cat-file -t HEAD" "$g" "$z"

# ============================================================================
echo "Test 9: cat-file -s HEAD"
# ============================================================================
cd "$TESTDIR/t2"
g=$(git cat-file -s "$hash")
z=$("$ZIGGIT" cat-file -s "$hash")
check "cat-file -s HEAD" "$g" "$z"

# ============================================================================
echo "Test 10: branch list"
# ============================================================================
cd "$TESTDIR/t2"
git branch feature-x
g=$(git branch --list | sed 's/^[* ]*//' | sort)
z=$("$ZIGGIT" branch | sed 's/^[* ]*//' | sort)
check "branch list" "$g" "$z"

# ============================================================================
echo "Test 11: log --oneline line count"
# ============================================================================
cd "$TESTDIR/t2"
g=$(git log --oneline | wc -l | tr -d ' ')
z=$("$ZIGGIT" log --oneline | wc -l | tr -d ' ')
check "log --oneline line count" "$g" "$z"

# ============================================================================
echo "Test 12: hash-object"
# ============================================================================
cd "$TESTDIR/t2"
echo "test content" > hash_test.txt
g=$(git hash-object hash_test.txt)
z=$("$ZIGGIT" hash-object hash_test.txt)
check "hash-object" "$g" "$z"

# ============================================================================
echo ""
echo "=== CLI Commit/Tag Test Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ $FAIL -eq 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
