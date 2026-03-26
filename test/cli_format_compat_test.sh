#!/bin/bash
# test/cli_format_compat_test.sh - Verifies ziggit CLI produces same output as git CLI
# Tests: init, add, commit, rev-parse, status --porcelain, log --oneline, branch, tag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZIGGIT="${ZIGGIT:-$PROJECT_DIR/zig-out/bin/ziggit}"

# Build if needed
if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    cd "$PROJECT_DIR" && HOME=/root zig build 2>/dev/null
    if [ ! -x "$ZIGGIT" ]; then
        echo "SKIP: ziggit binary not available"
        exit 0
    fi
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ FAIL: $1 (expected='$2' got='$3')"; }

TESTDIR="/tmp/ziggit_cli_fmt_$$"
trap "rm -rf $TESTDIR" EXIT
mkdir -p "$TESTDIR"

echo "=== CLI Format Compatibility Tests ==="

# ─── Test: rev-parse HEAD after ziggit init+add+commit ───
echo "Test: rev-parse HEAD"
cd "$TESTDIR" && rm -rf repo1 && mkdir repo1 && cd repo1
"$ZIGGIT" init 2>/dev/null
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
"$ZIGGIT" add f.txt
"$ZIGGIT" commit -m "initial" --author "T <t@t.com>" 2>/dev/null || \
  "$ZIGGIT" commit -m "initial" 2>/dev/null || true

G=$(git rev-parse HEAD 2>/dev/null || echo "GIT_FAIL")
Z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ZIGGIT_FAIL")
if [ "$G" = "$Z" ]; then pass "rev-parse HEAD matches"; else fail "rev-parse HEAD" "$G" "$Z"; fi

# ─── Test: status on clean repo ───
echo "Test: status --porcelain on clean repo"
G=$(git status --porcelain 2>/dev/null)
Z=$("$ZIGGIT" status --porcelain 2>/dev/null || echo "ZIGGIT_FAIL")
if [ "$G" = "$Z" ]; then pass "status --porcelain clean"; else fail "status --porcelain clean" "$G" "$Z"; fi

# ─── Test: git reads ziggit-created objects ───
echo "Test: git cat-file on ziggit blob"
HEAD=$(git rev-parse HEAD)
TREE=$(git cat-file -p "$HEAD" | head -1 | awk '{print $2}')
TYPE=$(git cat-file -t "$TREE")
if [ "$TYPE" = "tree" ]; then pass "git reads ziggit tree object"; else fail "tree type" "tree" "$TYPE"; fi

# ─── Test: git log shows ziggit commit ───
echo "Test: git log on ziggit commit"
MSG=$(git log --format=%s -1)
if echo "$MSG" | grep -q "initial"; then pass "git log shows ziggit commit msg"; else fail "commit msg" "initial" "$MSG"; fi

# ─── Test: git-created content readable by ziggit ───
echo "Test: ziggit reads git-created repo"
cd "$TESTDIR" && rm -rf repo2 && mkdir repo2 && cd repo2
git init -q
git config user.email "t@t.com"
git config user.name "T"
echo "world" > g.txt
git add g.txt
git commit -q -m "git commit"
G=$(git rev-parse HEAD)
Z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null || echo "ZIGGIT_FAIL")
if [ "$G" = "$Z" ]; then pass "ziggit reads git rev-parse HEAD"; else fail "git-created rev-parse" "$G" "$Z"; fi

# ─── Test: log --oneline line count matches ───
echo "Test: log --oneline count"
echo "more" > g.txt && git add g.txt && git commit -q -m "second"
echo "even more" > g.txt && git add g.txt && git commit -q -m "third"
GL=$(git log --oneline | wc -l | tr -d ' ')
ZL=$("$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$GL" = "$ZL" ]; then pass "log --oneline count ($GL)"; else fail "log line count" "$GL" "$ZL"; fi

# ─── Test: branch listing ───
echo "Test: branch listing"
git branch feature-a
git branch feature-b
GB=$(git branch --list | sed 's/[* ]//g' | sort)
ZB=$("$ZIGGIT" branch 2>/dev/null | sed 's/[* ]//g' | sort)
if [ "$GB" = "$ZB" ]; then pass "branch list matches"; else fail "branch list" "$GB" "$ZB"; fi

# ─── Test: tag listing ───
echo "Test: tag operations"
git tag v1.0
# ziggit rev-parse only supports HEAD currently, so verify tag via describe
ZDESC=$("$ZIGGIT" describe --tags 2>/dev/null || echo "ZIGGIT_FAIL")
if echo "$ZDESC" | grep -q "v1.0"; then pass "ziggit describe shows tag v1.0"; else fail "describe tags" "v1.0" "$ZDESC"; fi

# ─── Test: status with modifications ───
echo "Test: status with modifications"
echo "changed" > g.txt
GP=$(git status --porcelain | head -1 | awk '{print $1}')
ZP=$("$ZIGGIT" status --porcelain 2>/dev/null | head -1 | awk '{print $1}')
# Both should show M for modified
if [ "$GP" = "$ZP" ]; then pass "modified file status code matches ($GP)"; else fail "modified status" "$GP" "$ZP"; fi

# ─── Summary ───
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
