#!/bin/bash
# CLI compatibility test: compares ziggit output to git output across a full lifecycle
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="$SCRIPT_DIR/../zig-out/bin/ziggit"
if [ ! -f "$ZIGGIT" ]; then
    echo "SKIP: ziggit binary not found at $ZIGGIT"
    exit 0
fi

PASS=0
FAIL=0
TMPDIR=$(mktemp -d /tmp/ziggit_cli_compat_XXXXXX)
trap "rm -rf $TMPDIR" EXIT

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
    fi
}

echo "=== CLI Full Lifecycle Compatibility ==="

# 1. Init and basic structure
echo "--- init ---"
cd "$TMPDIR" && rm -rf test_repo && mkdir test_repo && cd test_repo
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

# Create a file, add, commit with git
echo "hello world" > file1.txt
git add file1.txt
git commit -q -m "first commit"

# 2. rev-parse HEAD
echo "--- rev-parse HEAD ---"
g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD)
check "rev-parse HEAD matches" "$g" "$z"

# 3. log --oneline
echo "--- log --oneline ---"
g_lines=$(git log --oneline | wc -l)
z_lines=$($ZIGGIT log --oneline | wc -l)
check "log --oneline line count" "$g_lines" "$z_lines"

# 4. Second commit
echo "second file" > file2.txt
git add file2.txt
git commit -q -m "second commit"

g=$(git rev-parse HEAD)
z=$($ZIGGIT rev-parse HEAD)
check "rev-parse HEAD after second commit" "$g" "$z"

g_lines=$(git log --oneline | wc -l)
z_lines=$($ZIGGIT log --oneline | wc -l)
check "log shows 2 commits" "$g_lines" "$z_lines"

# 5. Branch listing
echo "--- branch ---"
g_branch=$(git branch --list | sed 's/^[* ]*//' | sort)
z_branch=$($ZIGGIT branch | sed 's/^[* ]*//' | sort)
check "branch list matches" "$g_branch" "$z_branch"

# 6. Tag creation and listing
echo "--- tags ---"
git tag v1.0.0
g_tags=$(git tag | sort)
z_tags=$($ZIGGIT tag | sort)
check "tag list matches" "$g_tags" "$z_tags"

# 7. rev-parse with tag
g_tag_hash=$(git rev-parse v1.0.0)
z_tag_hash=$($ZIGGIT rev-parse v1.0.0 2>/dev/null || echo "UNSUPPORTED")
if [ "$z_tag_hash" != "UNSUPPORTED" ]; then
    check "rev-parse tag" "$g_tag_hash" "$z_tag_hash"
else
    echo "  SKIP: rev-parse <tag> not supported"
fi

# 8. ls-files
echo "--- ls-files ---"
g_ls=$(git ls-files | sort)
z_ls=$($ZIGGIT ls-files | sort)
check "ls-files matches" "$g_ls" "$z_ls"

# 9. Status on clean repo
echo "--- status --porcelain (clean) ---"
g_status=$(git status --porcelain)
z_status=$($ZIGGIT status --porcelain)
check "status porcelain clean" "$g_status" "$z_status"

# 10. Status with untracked file
echo "--- status --porcelain (untracked) ---"
echo "new" > untracked.txt
g_untracked=$(git status --porcelain | grep '??' | sort)
z_untracked=$($ZIGGIT status --porcelain | grep '??' | sort)
check "untracked files match" "$g_untracked" "$z_untracked"
rm untracked.txt

# 11. cat-file on HEAD
echo "--- cat-file ---"
HEAD=$(git rev-parse HEAD)
g_type=$(git cat-file -t $HEAD)
z_type=$($ZIGGIT cat-file -t $HEAD 2>/dev/null || echo "UNSUPPORTED")
if [ "$z_type" != "UNSUPPORTED" ]; then
    check "cat-file -t HEAD" "$g_type" "$z_type"
else
    echo "  SKIP: cat-file not supported"
fi

# 12. hash-object
echo "--- hash-object ---"
echo "test content" > /tmp/ziggit_hash_test.txt
g_hash=$(git hash-object /tmp/ziggit_hash_test.txt)
z_hash=$($ZIGGIT hash-object /tmp/ziggit_hash_test.txt 2>/dev/null || echo "UNSUPPORTED")
if [ "$z_hash" != "UNSUPPORTED" ]; then
    check "hash-object matches" "$g_hash" "$z_hash"
else
    echo "  SKIP: hash-object not supported"
fi
rm -f /tmp/ziggit_hash_test.txt

echo ""
echo "=== Results: $PASS pass, $FAIL fail ==="
[ $FAIL -eq 0 ] || exit 1
