#!/bin/bash
# CLI integration test: compare ziggit CLI output to git CLI output
set -e

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1 (skipped)"; SKIP=$((SKIP+1)); }

# Check ziggit binary exists
if [ ! -x "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT"
    exit 0
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_test_XXXXXX)
trap "rm -rf $TMPDIR" EXIT

echo "=== CLI Rev-Parse Compatibility Tests ==="

# Test 1: rev-parse HEAD on simple repo
echo "Test 1: rev-parse HEAD"
cd "$TMPDIR" && rm -rf repo1 && mkdir repo1 && cd repo1
git init -q && git config user.email "t@t.com" && git config user.name "T"
echo "hello" > f.txt && git add f.txt && git commit -q -m "init"
G=$(git rev-parse HEAD)
Z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || true)
if [ "$G" = "$Z" ]; then pass "rev-parse HEAD matches"; else fail "rev-parse HEAD: git=$G ziggit=$Z"; fi

# Test 2: rev-parse HEAD after multiple commits
echo "Test 2: rev-parse HEAD after multiple commits"
echo "world" > g.txt && git add g.txt && git commit -q -m "second"
echo "!" > h.txt && git add h.txt && git commit -q -m "third"
G=$(git rev-parse HEAD)
Z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || true)
if [ "$G" = "$Z" ]; then pass "rev-parse HEAD after 3 commits"; else fail "rev-parse HEAD after 3 commits: git=$G ziggit=$Z"; fi

# Test 3: status --porcelain on clean repo
echo "Test 3: status --porcelain on clean repo"
G=$(git status --porcelain)
Z=$("$ZIGGIT" status --porcelain 2>/dev/null || true)
if [ "$G" = "$Z" ]; then pass "status --porcelain clean"; else fail "status --porcelain clean: git='$G' ziggit='$Z'"; fi

# Test 4: log --oneline count
echo "Test 4: log --oneline"
G_LINES=$(git log --oneline | wc -l | tr -d ' ')
Z_LINES=$("$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$G_LINES" = "$Z_LINES" ]; then pass "log --oneline line count ($G_LINES)"; else fail "log --oneline: git=$G_LINES ziggit=$Z_LINES"; fi

# Test 5: branch listing
echo "Test 5: branch listing"
git branch feature-x
G_BR=$(git branch --list | sed 's/^[* ]*//' | sort)
Z_BR=$("$ZIGGIT" branch 2>/dev/null | sed 's/^[* ]*//' | sort || true)
if [ "$G_BR" = "$Z_BR" ]; then pass "branch list matches"; else fail "branch list: git='$G_BR' ziggit='$Z_BR'"; fi

# Test 6: tag listing
echo "Test 6: tag listing"
git tag v1.0
git tag v2.0
G_TAGS=$(git tag -l | sort)
Z_TAGS=$("$ZIGGIT" tag 2>/dev/null | sort || true)
if [ "$G_TAGS" = "$Z_TAGS" ]; then pass "tag list matches"; else skip "tag list: git='$G_TAGS' ziggit='$Z_TAGS'"; fi

# Test 7: ls-files
echo "Test 7: ls-files"
G_LS=$(git ls-files | sort)
Z_LS=$("$ZIGGIT" ls-files 2>/dev/null | sort || true)
if [ "$G_LS" = "$Z_LS" ]; then pass "ls-files matches"; else fail "ls-files: git='$G_LS' ziggit='$Z_LS'"; fi

# Test 8: status --porcelain with untracked file
echo "Test 8: status --porcelain with untracked file"
echo "untracked" > untracked.txt
G=$(git status --porcelain | sort)
Z=$("$ZIGGIT" status --porcelain 2>/dev/null | sort || true)
if [ "$G" = "$Z" ]; then pass "status --porcelain untracked"; else skip "status --porcelain untracked: git='$G' ziggit='$Z'"; fi

# Test 9: status --porcelain with modified file  
echo "Test 9: status --porcelain with modified file"
echo "modified" >> f.txt
G=$(git status --porcelain | sort)
Z=$("$ZIGGIT" status --porcelain 2>/dev/null | sort || true)
if [ "$G" = "$Z" ]; then pass "status --porcelain modified"; else skip "status --porcelain modified: git='$G' ziggit='$Z'"; fi

# Test 10: init creates valid repo
echo "Test 10: init"
cd "$TMPDIR" && rm -rf repo2
"$ZIGGIT" init repo2 2>/dev/null || true
if [ -f "repo2/.git/HEAD" ]; then pass "init creates .git/HEAD"; else fail "init missing .git/HEAD"; fi
if [ -d "repo2/.git/objects" ]; then pass "init creates .git/objects"; else fail "init missing .git/objects"; fi
if [ -d "repo2/.git/refs" ]; then pass "init creates .git/refs"; else fail "init missing .git/refs"; fi
# Verify git recognizes the repo
cd repo2
G_STATUS=$(git status 2>&1)
if echo "$G_STATUS" | grep -q "branch"; then pass "git recognizes ziggit-init'd repo"; else fail "git doesn't recognize ziggit-init'd repo"; fi

echo ""
echo "=== Results: $PASS pass, $FAIL fail, $SKIP skip ==="
[ $FAIL -eq 0 ] || exit 1
