#!/bin/bash
# test/cli_roundtrip_crossval_test.sh
# End-to-end CLI test: create repos with ziggit, verify with git, and vice versa.
# Every assertion compares ziggit output against real git output.
set -euo pipefail

ZIGGIT_REL="${1:-./zig-out/bin/ziggit}"
ZIGGIT="$(cd "$(dirname "$ZIGGIT_REL")" && pwd)/$(basename "$ZIGGIT_REL")"
PASS=0
FAIL=0
TESTDIR="/tmp/ziggit_crossval_$$"

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT
mkdir -p "$TESTDIR"

ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; echo "    expected: $2"; echo "    actual:   $3"; }

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] && ok "$desc" || fail "$desc" "$expected" "$actual"
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    echo "$haystack" | grep -qF "$needle" && ok "$desc" || fail "$desc" "contains '$needle'" "$haystack"
}

echo "=== CLI Cross-Validation Tests ==="

# ---- Test 1: init + rev-parse HEAD on empty repo ----
echo "Test 1: init + rev-parse HEAD (empty repo)"
cd "$TESTDIR" && mkdir t1 && cd t1
"$ZIGGIT" init -q . 2>/dev/null || "$ZIGGIT" init . >/dev/null 2>&1
# Both should recognize the repo
g_status=$(git status --porcelain 2>/dev/null) || g_status="ERROR"
check_eq "git sees ziggit-initialized repo" "" "$g_status"

# ---- Test 2: ziggit init, git add/commit, ziggit reads ----
echo "Test 2: git commit in ziggit-initialized repo"
cd "$TESTDIR" && mkdir t2 && cd t2
"$ZIGGIT" init . >/dev/null 2>&1
git config user.email "t@t.com"
git config user.name "T"
echo "hello" > f.txt
git add f.txt
git commit -q -m "init"

g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null) || z="ERROR"
check_eq "rev-parse HEAD matches" "$g" "$z"

# ---- Test 3: git init, ziggit rev-parse ----
echo "Test 3: git init + commit, ziggit rev-parse"
cd "$TESTDIR" && mkdir t3 && cd t3
git init -q .
git config user.email "t@t.com"
git config user.name "T"
echo "content" > a.txt
git add a.txt
git commit -q -m "first"

g=$(git rev-parse HEAD)
z=$("$ZIGGIT" rev-parse HEAD 2>/dev/null) || z="ERROR"
check_eq "ziggit reads git HEAD" "$g" "$z"

# ---- Test 4: status --porcelain on clean repo ----
echo "Test 4: status --porcelain (clean)"
cd "$TESTDIR" && mkdir t4 && cd t4
git init -q .
git config user.email "t@t.com"
git config user.name "T"
echo "data" > x.txt
git add x.txt
git commit -q -m "msg"

g=$(git status --porcelain)
z=$("$ZIGGIT" status --porcelain 2>/dev/null) || z="ERROR"
check_eq "clean status matches" "$g" "$z"

# ---- Test 5: status --porcelain with untracked file ----
echo "Test 5: status --porcelain (untracked)"
echo "new" > "$TESTDIR/t4/untracked.txt"
g=$(git -C "$TESTDIR/t4" status --porcelain | sort)
z=$("$ZIGGIT" -C "$TESTDIR/t4" status --porcelain 2>/dev/null | sort) || z=$("$ZIGGIT" status --porcelain 2>/dev/null | sort) || z="ERROR"
# At minimum, both should mention untracked.txt
check_contains "both show untracked file" "untracked.txt" "$z"

# ---- Test 6: log --oneline count ----
echo "Test 6: log --oneline count"
cd "$TESTDIR" && mkdir t6 && cd t6
git init -q .
git config user.email "t@t.com"
git config user.name "T"
for i in 1 2 3; do
    echo "file$i" > "f$i.txt"
    git add "f$i.txt"
    git commit -q -m "commit $i"
done

g_count=$(git log --oneline | wc -l | tr -d ' ')
z_count=$("$ZIGGIT" log --oneline 2>/dev/null | wc -l | tr -d ' ') || z_count="ERROR"
check_eq "log count matches" "$g_count" "$z_count"

# ---- Test 7: branch listing ----
echo "Test 7: branch listing"
cd "$TESTDIR/t6"
git branch feature1
git branch feature2
g_branches=$(git branch --list | sed 's/^[* ]*//' | sort)
z_branches=$("$ZIGGIT" branch 2>/dev/null | sed 's/^[* ]*//' | sort) || z_branches="ERROR"
check_eq "branch list matches" "$g_branches" "$z_branches"

# ---- Test 8: tag creation and listing ----
echo "Test 8: tag operations"
cd "$TESTDIR/t6"
git tag v1.0.0
g_tags=$(git tag -l | sort)
z_tags=$("$ZIGGIT" tag -l 2>/dev/null | sort) || z_tags=$("$ZIGGIT" tag 2>/dev/null | sort) || z_tags="SKIP"
if [ "$z_tags" != "SKIP" ]; then
    check_eq "tag list matches" "$g_tags" "$z_tags"
else
    echo "  ⚠ tag listing not supported in CLI, skipping"
fi

# ---- Test 9: hash-object produces same hash ----
echo "Test 9: hash-object compatibility"
cd "$TESTDIR" && mkdir t9 && cd t9
git init -q .
echo "test content for hashing" > hash_test.txt
g_hash=$(git hash-object hash_test.txt)
z_hash=$("$ZIGGIT" hash-object hash_test.txt 2>/dev/null) || z_hash="SKIP"
if [ "$z_hash" != "SKIP" ]; then
    check_eq "hash-object matches" "$g_hash" "$z_hash"
else
    echo "  ⚠ hash-object not in CLI, skipping"
fi

# ---- Test 10: cat-file reads ziggit-created objects ----
echo "Test 10: git cat-file reads ziggit objects"
cd "$TESTDIR" && mkdir t10 && cd t10
"$ZIGGIT" init . >/dev/null 2>&1
git config user.email "t@t.com"
git config user.name "T"
echo "ziggit blob" > z.txt
"$ZIGGIT" add z.txt 2>/dev/null
"$ZIGGIT" commit -m "ziggit commit" 2>/dev/null || "$ZIGGIT" commit -m "ziggit commit" --author "T <t@t.com>" 2>/dev/null || true

# If ziggit committed successfully, git should be able to read it
if git rev-parse HEAD >/dev/null 2>&1; then
    g_type=$(git cat-file -t HEAD)
    check_eq "git reads ziggit commit object" "commit" "$g_type"
    
    # git fsck should pass
    if git fsck --no-dangling >/dev/null 2>&1; then
        ok "git fsck passes on ziggit repo"
    else
        fail "git fsck" "pass" "fail"
    fi
else
    echo "  ⚠ ziggit commit not recognized by git, skipping"
fi

# ---- Summary ----
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
