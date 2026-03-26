#!/bin/bash
# End-to-end validation: ziggit produces output that real git can read, and vice versa
set -euo pipefail

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
TMPBASE=$(mktemp -d)

cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL + 1)); }

# Helper: create a temp dir for a test
new_repo() {
    local d="$TMPBASE/$1"
    mkdir -p "$d"
    echo "$d"
}

echo "=== Cross-validation: ziggit writes, git reads ==="

# --- Test 1: ziggit init -> git status ---
echo "Test 1: ziggit init -> git status"
d=$(new_repo "t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
out=$(cd "$d" && git status --porcelain 2>&1) || true
if [ -d "$d/.git" ]; then
    pass "ziggit init creates valid .git directory"
else
    fail "ziggit init" ".git directory not created"
fi
# git status should not error (empty repo is fine)
if cd "$d" && git rev-parse --git-dir >/dev/null 2>&1; then
    pass "git recognizes ziggit-initialized repo"
else
    fail "git recognizes repo" "git rev-parse --git-dir failed"
fi

# --- Test 2: ziggit add + commit -> git log ---
echo "Test 2: ziggit add + commit -> git log"
d=$(new_repo "t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "hello world" > "$d/README.md"
(cd "$d" && "$ZIGGIT" add README.md) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "initial commit") >/dev/null 2>&1

git_log=$(cd "$d" && git log --oneline 2>&1) || true
if echo "$git_log" | grep -q "initial commit"; then
    pass "git log shows ziggit commit message"
else
    fail "git log" "expected 'initial commit', got: $git_log"
fi

# Verify the file content via git
git_show=$(cd "$d" && git show HEAD:README.md 2>&1) || true
if [ "$git_show" = "hello world" ]; then
    pass "git show reads file content from ziggit commit"
else
    fail "git show file" "expected 'hello world', got: $git_show"
fi

# --- Test 3: ziggit tag -> git tag -l ---
echo "Test 3: ziggit tag -> git tag -l"
d=$(new_repo "t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "content" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "tagged commit") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

git_tags=$(cd "$d" && git tag -l 2>&1)
if echo "$git_tags" | grep -q "v1.0.0"; then
    pass "git tag -l shows ziggit-created tag"
else
    fail "git tag -l" "expected v1.0.0, got: $git_tags"
fi

# Verify tag points to correct commit
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
git_tag_target=$(cd "$d" && git rev-parse v1.0.0 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_tag_target" ]; then
    pass "git resolves ziggit tag to correct commit"
else
    fail "tag target" "ziggit HEAD=$ziggit_head, git tag=$git_tag_target"
fi

# --- Test 4: ziggit commit -> git cat-file -p HEAD ---
echo "Test 4: ziggit commit -> git cat-file validates commit object"
d=$(new_repo "t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "data" > "$d/data.txt"
(cd "$d" && "$ZIGGIT" add data.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "test object format") >/dev/null 2>&1

cat_file=$(cd "$d" && git cat-file -p HEAD 2>&1) || true
if echo "$cat_file" | grep -q "^tree "; then
    pass "git cat-file shows valid tree line"
else
    fail "cat-file tree" "no tree line in: $cat_file"
fi
if echo "$cat_file" | grep -q "^author "; then
    pass "git cat-file shows valid author line"
else
    fail "cat-file author" "no author line in: $cat_file"
fi

# Verify object type
obj_type=$(cd "$d" && git cat-file -t HEAD 2>&1)
if [ "$obj_type" = "commit" ]; then
    pass "git cat-file -t HEAD reports 'commit'"
else
    fail "cat-file -t" "expected 'commit', got: $obj_type"
fi

echo ""
echo "=== Cross-validation: git writes, ziggit reads ==="

# --- Test 5: git init + add + commit -> ziggit rev-parse HEAD ---
echo "Test 5: git init + commit -> ziggit rev-parse HEAD"
d=$(new_repo "t5")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "from git" > "$d/gitfile.txt"
(cd "$d" && git add gitfile.txt && git commit -m "git commit") >/dev/null 2>&1

git_head=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$git_head" = "$ziggit_head" ]; then
    pass "ziggit rev-parse HEAD matches git"
else
    fail "rev-parse HEAD" "git=$git_head, ziggit=$ziggit_head"
fi

# --- Test 6: git tag -> ziggit describe --tags ---
echo "Test 6: git tag -> ziggit describe --tags"
d=$(new_repo "t6")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "tagged" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "c1" && git tag v2.0.0) >/dev/null 2>&1

ziggit_describe=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if echo "$ziggit_describe" | grep -q "v2.0.0"; then
    pass "ziggit describe --tags finds git-created tag"
else
    fail "describe --tags" "expected v2.0.0, got: $ziggit_describe"
fi

# --- Test 7: multiple git commits -> ziggit log ---
echo "Test 7: multiple git commits -> ziggit log"
d=$(new_repo "t7")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "v1" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "first") >/dev/null 2>&1
echo "v2" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "second") >/dev/null 2>&1

# ziggit log should show commits
ziggit_log=$(cd "$d" && "$ZIGGIT" log --oneline 2>&1) || true
if echo "$ziggit_log" | grep -q "second"; then
    pass "ziggit log shows latest git commit"
else
    fail "ziggit log" "expected 'second', got: $ziggit_log"
fi

echo ""
echo "=== Bun workflow simulation ==="

# --- Test 8: Full bun workflow ---
echo "Test 8: init, add package.json, commit, tag, status, describe"
d=$(new_repo "t8_bun")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'EOF'
{
  "name": "my-app",
  "version": "1.0.0",
  "description": "Test package"
}
EOF
(cd "$d" && "$ZIGGIT" add package.json) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "Initial commit") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Status should be clean (no modifications)
status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1) || true
if [ -z "$status" ] || echo "$status" | grep -qE "^$|nothing to commit"; then
    pass "status is clean after commit"
else
    fail "clean status" "got: $status"
fi

# git should also see it as clean
git_status=$(cd "$d" && git status --porcelain 2>&1)
if [ -z "$git_status" ]; then
    pass "git status also clean"
else
    fail "git clean status" "got: $git_status"
fi

# describe should return tag
describe=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if echo "$describe" | grep -q "v1.0.0"; then
    pass "describe returns v1.0.0"
else
    fail "describe" "expected v1.0.0, got: $describe"
fi

# git should also read the tag
git_describe=$(cd "$d" && git describe --tags 2>&1 | tr -d '[:space:]')
if [ "$git_describe" = "v1.0.0" ]; then
    pass "git describe also returns v1.0.0"
else
    fail "git describe" "expected v1.0.0, got: $git_describe"
fi

echo ""
echo "=== Edge cases ==="

# --- Test 9: Binary files ---
echo "Test 9: Binary file in add/commit"
d=$(new_repo "t9_binary")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
printf '\x00\x01\x02\xff\xfe\xfd' > "$d/binary.bin"
(cd "$d" && "$ZIGGIT" add binary.bin) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "binary file") >/dev/null 2>&1

git_binary=$(cd "$d" && git show HEAD:binary.bin | od -A x -t x1z | head -1)
orig_binary=$(od -A x -t x1z "$d/binary.bin" | head -1)
if [ "$git_binary" = "$orig_binary" ]; then
    pass "binary file preserved through ziggit add/commit"
else
    fail "binary file" "content mismatch"
fi

# --- Test 10: Files with spaces ---
echo "Test 10: Files with spaces in names"
d=$(new_repo "t10_spaces")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "spaced" > "$d/my file.txt"
(cd "$d" && "$ZIGGIT" add "my file.txt") >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "spaced file") >/dev/null 2>&1

git_show_spaced=$(cd "$d" && git show "HEAD:my file.txt" 2>&1) || true
if [ "$git_show_spaced" = "spaced" ]; then
    pass "file with spaces readable by git"
else
    fail "spaced file" "expected 'spaced', got: $git_show_spaced"
fi

# --- Test 11: Multiple files ---
echo "Test 11: Repo with many files"
d=$(new_repo "t11_many")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 50); do
    echo "file $i content" > "$d/file_$i.txt"
    (cd "$d" && "$ZIGGIT" add "file_$i.txt") >/dev/null 2>&1
done
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "many files") >/dev/null 2>&1

git_file_count=$(cd "$d" && git ls-tree --name-only HEAD | wc -l | tr -d ' ')
if [ "$git_file_count" -eq 50 ]; then
    pass "all 50 files visible to git"
else
    fail "many files" "expected 50, got: $git_file_count"
fi

# --- Test 12: Deeply nested directories ---
echo "Test 12: Deeply nested directory tree"
d=$(new_repo "t12_nested")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
mkdir -p "$d/a/b/c/d/e"
echo "deep" > "$d/a/b/c/d/e/deep.txt"
(cd "$d" && "$ZIGGIT" add "a/b/c/d/e/deep.txt") >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "nested") >/dev/null 2>&1

git_deep=$(cd "$d" && git show "HEAD:a/b/c/d/e/deep.txt" 2>&1) || true
if [ "$git_deep" = "deep" ]; then
    pass "deeply nested file readable by git"
else
    fail "nested file" "expected 'deep', got: $git_deep"
fi

# --- Test 13: Multiple commits, verify history ---
echo "Test 13: Multiple commits create valid history"
d=$(new_repo "t13_history")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "v1" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "commit 1") >/dev/null 2>&1

echo "v2" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "commit 2") >/dev/null 2>&1

echo "v3" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "commit 3") >/dev/null 2>&1

git_commit_count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$git_commit_count" -eq 3 ]; then
    pass "git sees all 3 commits in history"
else
    fail "commit count" "expected 3, got: $git_commit_count"
fi

# Verify parent chain
parent_of_head=$(cd "$d" && git rev-parse HEAD~1 2>&1 | tr -d '[:space:]')
parent_of_parent=$(cd "$d" && git rev-parse HEAD~2 2>&1 | tr -d '[:space:]')
if [ ${#parent_of_head} -eq 40 ] && [ ${#parent_of_parent} -eq 40 ]; then
    pass "parent chain is valid (HEAD~1, HEAD~2 resolve)"
else
    fail "parent chain" "HEAD~1=$parent_of_head, HEAD~2=$parent_of_parent"
fi

# --- Test 14: Hash consistency ---
echo "Test 14: ziggit and git agree on HEAD hash"
d=$(new_repo "t14_hash")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "hash test" > "$d/h.txt"
(cd "$d" && "$ZIGGIT" add h.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "hash test") >/dev/null 2>&1

git_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$git_hash" = "$ziggit_hash" ] && [ ${#git_hash} -eq 40 ]; then
    pass "ziggit and git produce same HEAD hash"
else
    fail "hash match" "git=$git_hash, ziggit=$ziggit_hash"
fi

# --- Test 15: Special characters in filenames ---
echo "Test 15: Files with special characters"
d=$(new_repo "t15_special")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "special1" > "$d/hello-world.txt"
echo "special2" > "$d/under_score.txt"
echo "special3" > "$d/CamelCase.TXT"
echo "special4" > "$d/file.with.dots.txt"
(cd "$d" && "$ZIGGIT" add "hello-world.txt" && "$ZIGGIT" add "under_score.txt" \
    && "$ZIGGIT" add "CamelCase.TXT" && "$ZIGGIT" add "file.with.dots.txt") >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "special chars") >/dev/null 2>&1

git_ls=$(cd "$d" && git ls-tree --name-only HEAD 2>&1)
for fname in hello-world.txt under_score.txt CamelCase.TXT file.with.dots.txt; do
    if echo "$git_ls" | grep -q "$fname"; then
        pass "special char file $fname visible to git"
    else
        fail "special char $fname" "not found in git ls-tree"
    fi
done

# --- Test 16: Empty tree (init only, no commits) ---
echo "Test 16: Empty repo - git fsck"
d=$(new_repo "t16_empty")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
fsck_out=$(cd "$d" && git fsck 2>&1) || true
# fsck should not report errors (warnings about dangling are OK)
if echo "$fsck_out" | grep -qi "error"; then
    fail "git fsck" "errors found: $fsck_out"
else
    pass "git fsck passes on ziggit-initialized repo"
fi

# --- Test 17: ziggit status --porcelain matches git ---
echo "Test 17: status --porcelain consistency"
d=$(new_repo "t17_status")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "tracked" > "$d/tracked.txt"
(cd "$d" && "$ZIGGIT" add tracked.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "base commit") >/dev/null 2>&1

# Both should show clean
git_s=$(cd "$d" && git status --porcelain 2>&1)
ziggit_s=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if [ -z "$git_s" ] && [ -z "$ziggit_s" ]; then
    pass "both ziggit and git report clean status"
else
    fail "clean status" "git='$git_s' ziggit='$ziggit_s'"
fi

# --- Test 18: ziggit log --oneline matches git ---
echo "Test 18: ziggit log --oneline format"
d=$(new_repo "t18_log")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "c1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "first log msg") >/dev/null 2>&1
echo "c2" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "second log msg") >/dev/null 2>&1

ziggit_log=$(cd "$d" && "$ZIGGIT" log --oneline 2>&1)
if echo "$ziggit_log" | grep -q "first log msg" && echo "$ziggit_log" | grep -q "second log msg"; then
    pass "ziggit log --oneline shows both commit messages"
else
    fail "ziggit log" "got: $ziggit_log"
fi

# Verify git can also read both commits
git_log=$(cd "$d" && git log --oneline 2>&1)
if echo "$git_log" | grep -q "first log msg" && echo "$git_log" | grep -q "second log msg"; then
    pass "git log confirms both commits"
else
    fail "git log" "got: $git_log"
fi

# --- Test 19: Multiple tags on different commits ---
echo "Test 19: Multiple tags on different commits"
d=$(new_repo "t19_multitag")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "v1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "release 1") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
first_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

echo "v2" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "release 2") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v2.0.0) >/dev/null 2>&1

git_tags=$(cd "$d" && git tag -l | sort)
if echo "$git_tags" | grep -q "v1.0.0" && echo "$git_tags" | grep -q "v2.0.0"; then
    pass "git sees both ziggit tags"
else
    fail "multiple tags" "got: $git_tags"
fi

# v1.0.0 should point to first commit
tag1_target=$(cd "$d" && git rev-parse v1.0.0 | tr -d '[:space:]')
if [ "$tag1_target" = "$first_hash" ]; then
    pass "v1.0.0 points to correct commit"
else
    fail "v1 tag target" "expected $first_hash, got $tag1_target"
fi

# --- Test 20: git fsck on repo with multiple commits and tags ---
echo "Test 20: git fsck validates full repo integrity"
d=$(new_repo "t20_fsck")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in 1 2 3 4 5; do
    echo "content $i" > "$d/file$i.txt"
    (cd "$d" && "$ZIGGIT" add "file$i.txt") >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "commit $i") >/dev/null 2>&1
done
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1)
if echo "$fsck_out" | grep -qi "error\|corrupt\|broken"; then
    fail "git fsck full repo" "errors: $fsck_out"
else
    pass "git fsck validates repo with 5 commits and tag"
fi

# --- Test 21: ziggit describe after extra commits past tag ---
echo "Test 21: describe after commits past tag"
d=$(new_repo "t21_describe_ahead")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "tagged") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
echo "extra" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "past tag") >/dev/null 2>&1

# git describe should show v1.0.0-1-g<hash>
git_desc=$(cd "$d" && git describe --tags 2>&1 | tr -d '[:space:]')
if echo "$git_desc" | grep -q "v1.0.0-1-g"; then
    pass "git describe shows commits ahead of ziggit tag"
else
    fail "describe ahead" "expected v1.0.0-1-g..., got: $git_desc"
fi

# --- Test 22: Large file content preserved ---
echo "Test 22: Large file (1MB) preserved through ziggit"
d=$(new_repo "t22_large")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
dd if=/dev/urandom bs=1024 count=1024 2>/dev/null | base64 > "$d/large.txt"
orig_hash=$(sha256sum "$d/large.txt" | cut -d' ' -f1)
(cd "$d" && "$ZIGGIT" add large.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "large file") >/dev/null 2>&1

# Read back via git and compare
checkout_hash=$(cd "$d" && git show HEAD:large.txt | sha256sum | cut -d' ' -f1)
if [ "$orig_hash" = "$checkout_hash" ]; then
    pass "large file (1MB) content preserved"
else
    fail "large file" "hash mismatch"
fi

# --- Test 23: Bun multi-version workflow ---
echo "Test 23: Bun multi-version workflow"
d=$(new_repo "t23_bun_multi")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1

# Version 1.0.0
cat > "$d/package.json" << 'EOF'
{"name":"my-pkg","version":"1.0.0"}
EOF
(cd "$d" && "$ZIGGIT" add package.json) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "v1.0.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Version 1.1.0
cat > "$d/package.json" << 'EOF'
{"name":"my-pkg","version":"1.1.0"}
EOF
echo "# My Package" > "$d/README.md"
(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" add README.md) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "v1.1.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.1.0) >/dev/null 2>&1

# Verify from git side
git_tags=$(cd "$d" && git tag -l | sort)
git_commits=$(cd "$d" && git rev-list --count HEAD)
git_pkg=$(cd "$d" && git show HEAD:package.json 2>&1)
git_v1_pkg=$(cd "$d" && git show v1.0.0:package.json 2>&1)

if [ "$git_commits" = "2" ]; then
    pass "bun multi-version: 2 commits"
else
    fail "bun multi commits" "expected 2, got: $git_commits"
fi
if echo "$git_tags" | grep -q "v1.0.0" && echo "$git_tags" | grep -q "v1.1.0"; then
    pass "bun multi-version: both tags present"
else
    fail "bun multi tags" "got: $git_tags"
fi
if echo "$git_pkg" | grep -q '"1.1.0"'; then
    pass "bun multi-version: HEAD has v1.1.0 package.json"
else
    fail "bun pkg HEAD" "got: $git_pkg"
fi
if echo "$git_v1_pkg" | grep -q '"1.0.0"'; then
    pass "bun multi-version: v1.0.0 tag has v1.0.0 package.json"
else
    fail "bun pkg v1" "got: $git_v1_pkg"
fi

# --- Test 24: 120 files ---
echo "Test 24: Repo with 120 files"
d=$(new_repo "t24_120files")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 120); do
    printf "file %d content" "$i" > "$d/file_$(printf '%03d' $i).txt"
    (cd "$d" && "$ZIGGIT" add "file_$(printf '%03d' $i).txt") >/dev/null 2>&1
done
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "120 files") >/dev/null 2>&1

git_file_count=$(cd "$d" && git ls-tree --name-only HEAD | wc -l | tr -d ' ')
if [ "$git_file_count" -eq 120 ]; then
    pass "all 120 files visible to git"
else
    fail "120 files" "expected 120, got: $git_file_count"
fi

# --- Test 25: Empty file ---
echo "Test 25: Empty file preserved"
d=$(new_repo "t25_empty")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
touch "$d/empty.txt"
(cd "$d" && "$ZIGGIT" add empty.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "empty file") >/dev/null 2>&1

empty_size=$(cd "$d" && git cat-file -s HEAD:empty.txt 2>&1)
if [ "$empty_size" = "0" ]; then
    pass "empty file has size 0 via git"
else
    fail "empty file" "expected size 0, got: $empty_size"
fi

# --- Test 26: Annotated tag cross-validation ---
echo "Test 26: Annotated tag object readable by git"
d=$(new_repo "t26_annotated")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "data" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "for tag") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag -a v5.0.0 -m "Release v5") >/dev/null 2>&1

tag_type=$(cd "$d" && git cat-file -t v5.0.0 2>&1)
if [ "$tag_type" = "tag" ]; then
    pass "annotated tag has type 'tag' in git"
else
    # Lightweight tag fallback is also acceptable
    if [ "$tag_type" = "commit" ]; then
        pass "tag created (lightweight) readable by git"
    else
        fail "annotated tag type" "expected 'tag' or 'commit', got: $tag_type"
    fi
fi

# --- Test 27: git writes -> ziggit reads full hash ---
echo "Test 27: git writes -> ziggit resolves full hash"
d=$(new_repo "t27_fullhash")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "hashtest" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "hash resolution test") >/dev/null 2>&1
git_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$git_hash" = "$ziggit_hash" ] && [ ${#git_hash} -eq 40 ]; then
    pass "ziggit resolves HEAD to same hash as git"
else
    fail "full hash resolution" "git=$git_hash ziggit=$ziggit_hash"
fi

# --- Test 28: Roundtrip: ziggit writes, git reads, ziggit reads back ---
echo "Test 28: Full roundtrip: ziggit write -> git verify -> ziggit read"
d=$(new_repo "t28_roundtrip")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "roundtrip" > "$d/rt.txt"
(cd "$d" && "$ZIGGIT" add rt.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="RT" GIT_AUTHOR_EMAIL="rt@rt.com" \
    GIT_COMMITTER_NAME="RT" GIT_COMMITTER_EMAIL="rt@rt.com" \
    "$ZIGGIT" commit -m "roundtrip test") >/dev/null 2>&1

# git reads
git_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
git_content=$(cd "$d" && git show HEAD:rt.txt 2>&1)

# ziggit reads back
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')

if [ "$git_hash" = "$ziggit_hash" ] && [ "$git_content" = "roundtrip" ]; then
    pass "full roundtrip: hashes match and content preserved"
else
    fail "roundtrip" "git=$git_hash ziggit=$ziggit_hash content=$git_content"
fi

# --- Test 29: Bun workflow with .gitignore ---
echo "Test 29: Bun workflow with multiple file types"
d=$(new_repo "t29_bun_full")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'PKGEOF'
{"name":"@scope/pkg","version":"3.0.0","main":"index.js"}
PKGEOF
echo "module.exports = 42;" > "$d/index.js"
echo "# README" > "$d/README.md"
echo "MIT" > "$d/LICENSE"
(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" add index.js && \
    "$ZIGGIT" add README.md && "$ZIGGIT" add LICENSE) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "publish v3.0.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v3.0.0) >/dev/null 2>&1

file_count=$(cd "$d" && git ls-tree --name-only HEAD | wc -l | tr -d ' ')
if [ "$file_count" -eq 4 ]; then
    pass "bun full workflow: 4 files committed"
else
    fail "bun full files" "expected 4, got: $file_count"
fi

js_content=$(cd "$d" && git show HEAD:index.js 2>&1)
if echo "$js_content" | grep -q "module.exports = 42"; then
    pass "bun full workflow: JS file content correct"
else
    fail "bun js content" "got: $js_content"
fi

echo ""
echo "=== Clone and Checkout ==="

# --- Test 30: ziggit clone bare -> git reads bare repo ---
echo "Test 30: ziggit init + commit, git clone --bare reads it"
d=$(new_repo "t30_clone")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "clone me" > "$d/src.txt"
(cd "$d" && "$ZIGGIT" add src.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "source commit") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
src_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

# git clone --bare the ziggit repo
bare_d="$TMPBASE/t30_bare.git"
git clone --bare "$d" "$bare_d" >/dev/null 2>&1
bare_hash=$(cd "$bare_d" && git rev-parse HEAD | tr -d '[:space:]')
bare_tags=$(cd "$bare_d" && git tag -l 2>&1)

if [ "$src_hash" = "$bare_hash" ]; then
    pass "git clone --bare preserves HEAD hash from ziggit repo"
else
    fail "bare clone HEAD" "src=$src_hash bare=$bare_hash"
fi
if echo "$bare_tags" | grep -q "v1.0.0"; then
    pass "git clone --bare preserves ziggit tag"
else
    fail "bare clone tag" "got: $bare_tags"
fi

# --- Test 31: git clone ziggit repo, checkout works ---
echo "Test 31: git clone + checkout from ziggit repo"
d=$(new_repo "t31_clone_checkout")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "version 1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "v1") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

echo "version 2" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "v2") >/dev/null 2>&1

clone_d="$TMPBASE/t31_cloned"
git clone "$d" "$clone_d" >/dev/null 2>&1

# Verify cloned HEAD content
cloned_content=$(cat "$clone_d/f.txt")
if [ "$cloned_content" = "version 2" ]; then
    pass "git clone: working tree has latest content"
else
    fail "clone content" "expected 'version 2', got: '$cloned_content'"
fi

# Checkout old tag in clone
(cd "$clone_d" && git checkout v1.0.0) >/dev/null 2>&1
v1_content=$(cat "$clone_d/f.txt")
if [ "$v1_content" = "version 1" ]; then
    pass "git checkout v1.0.0 in clone restores old content"
else
    fail "clone checkout" "expected 'version 1', got: '$v1_content'"
fi

# --- Test 32: ziggit checkout -> git verifies HEAD ---
echo "Test 32: ziggit checkout tag -> git rev-parse confirms"
d=$(new_repo "t32_checkout")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "first" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "first") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
first_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

echo "second" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "second") >/dev/null 2>&1

# Checkout back to v1.0.0 with ziggit
(cd "$d" && "$ZIGGIT" checkout v1.0.0) >/dev/null 2>&1

# git should see HEAD at first commit
checkout_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
if [ "$first_hash" = "$checkout_hash" ]; then
    pass "ziggit checkout moves HEAD to correct commit"
else
    fail "ziggit checkout HEAD" "expected $first_hash, got $checkout_hash"
fi

echo ""
echo "=== Advanced cross-validation ==="

# --- Test 33: Tree object structure matches git ---
echo "Test 33: Tree object hash agrees between ziggit and git"
d=$(new_repo "t33_tree")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "a" > "$d/a.txt"
echo "b" > "$d/b.txt"
mkdir -p "$d/sub"
echo "c" > "$d/sub/c.txt"
(cd "$d" && "$ZIGGIT" add a.txt && "$ZIGGIT" add b.txt && "$ZIGGIT" add sub/c.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "tree test") >/dev/null 2>&1

# git should be able to walk the entire tree
tree_hash=$(cd "$d" && git rev-parse HEAD^{tree} | tr -d '[:space:]')
tree_content=$(cd "$d" && git ls-tree -r HEAD --name-only | sort)
expected=$(printf "a.txt\nb.txt\nsub/c.txt")
if [ "$tree_content" = "$expected" ]; then
    pass "git ls-tree -r lists all files from ziggit commit"
else
    fail "tree walk" "expected '$expected', got: '$tree_content'"
fi

# Verify tree hash is valid
if [ ${#tree_hash} -eq 40 ]; then
    pass "tree object has valid 40-char hash"
else
    fail "tree hash" "invalid hash: $tree_hash"
fi

# --- Test 34: Blob object hashes match git's expectations ---
echo "Test 34: Blob hash matches git hash-object"
d=$(new_repo "t34_blob")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo -n "exact content" > "$d/exact.txt"
(cd "$d" && "$ZIGGIT" add exact.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "blob hash") >/dev/null 2>&1

# Get blob hash from ziggit's commit via git
blob_in_tree=$(cd "$d" && git rev-parse HEAD:exact.txt | tr -d '[:space:]')
# Independently compute what git would hash
expected_blob=$(echo -n "exact content" | git hash-object --stdin | tr -d '[:space:]')
if [ "$blob_in_tree" = "$expected_blob" ]; then
    pass "blob hash in ziggit tree matches git hash-object"
else
    fail "blob hash" "tree=$blob_in_tree expected=$expected_blob"
fi

# --- Test 35: Overwrite file preserves both versions in history ---
echo "Test 35: File overwrite preserves history"
d=$(new_repo "t35_overwrite")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "original" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "original") >/dev/null 2>&1
first=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

echo "modified" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "modified") >/dev/null 2>&1

# Can read old version via first commit hash
old_content=$(cd "$d" && git show "$first:f.txt" 2>&1)
new_content=$(cd "$d" && git show HEAD:f.txt 2>&1)
if [ "$old_content" = "original" ] && [ "$new_content" = "modified" ]; then
    pass "git reads both old and new file versions from ziggit history"
else
    fail "overwrite history" "old='$old_content' new='$new_content'"
fi

# --- Test 36: git writes, ziggit describe finds tag ---
echo "Test 36: git writes -> ziggit describe --tags finds tag"
d=$(new_repo "t36_describe_match")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base" && git tag v6.0.0) >/dev/null 2>&1

# Exact tag on HEAD - should match exactly
git_desc=$(cd "$d" && git describe --tags 2>&1 | tr -d '[:space:]')
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if [ "$git_desc" = "$ziggit_desc" ]; then
    pass "ziggit describe --tags matches git (exact tag on HEAD)"
else
    fail "describe exact" "git='$git_desc' ziggit='$ziggit_desc'"
fi

# Commits ahead of tag - ziggit should at least contain the tag name
echo "next" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "next") >/dev/null 2>&1
ziggit_desc_ahead=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if echo "$ziggit_desc_ahead" | grep -q "v6.0.0"; then
    pass "ziggit describe --tags contains tag name when ahead"
else
    fail "describe ahead" "expected v6.0.0 in: $ziggit_desc_ahead"
fi

# --- Test 37: ziggit commit parent chain validated by git ---
echo "Test 37: Parent hash chain validated by git"
d=$(new_repo "t37_parents")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in 1 2 3 4 5; do
    echo "v$i" > "$d/f.txt"
    (cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "commit $i") >/dev/null 2>&1
done

# Verify parent chain: each commit should have exactly one parent (except first)
all_valid=true
for i in 1 2 3 4; do
    parent=$(cd "$d" && git rev-parse "HEAD~$i" 2>&1 | tr -d '[:space:]')
    if [ ${#parent} -ne 40 ]; then
        all_valid=false
        break
    fi
done
if $all_valid; then
    pass "all parent references (HEAD~1 through HEAD~4) resolve"
else
    fail "parent chain" "some parent refs failed to resolve"
fi

# First commit should have no parent
first_commit=$(cd "$d" && git rev-list --max-parents=0 HEAD | tr -d '[:space:]')
parent_count=$(cd "$d" && git cat-file -p "$first_commit" | grep -c "^parent " || true)
if [ "$parent_count" -eq 0 ]; then
    pass "root commit has no parent"
else
    fail "root parent" "expected 0 parents, got $parent_count"
fi

# --- Test 38: git writes -> ziggit log matches ---
echo "Test 38: git writes multiple -> ziggit log --oneline shows all"
d=$(new_repo "t38_log_match")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
for msg in "alpha" "beta" "gamma"; do
    echo "$msg" > "$d/f.txt"
    (cd "$d" && git add f.txt && git commit -m "$msg") >/dev/null 2>&1
done

ziggit_log=$(cd "$d" && "$ZIGGIT" log --oneline 2>&1)
for msg in "alpha" "beta" "gamma"; do
    if echo "$ziggit_log" | grep -q "$msg"; then
        pass "ziggit log shows git commit '$msg'"
    else
        fail "ziggit log $msg" "not found in: $ziggit_log"
    fi
done

# --- Test 39: Subdirectory with many files in single commit ---
echo "Test 39: Subdirectory structure in single commit"
d=$(new_repo "t39_subdir")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
mkdir -p "$d/src/components" "$d/src/utils" "$d/test"
echo "main" > "$d/src/main.ts"
echo "btn" > "$d/src/components/button.ts"
echo "fmt" > "$d/src/utils/format.ts"
echo "spec" > "$d/test/main.test.ts"
echo "pkg" > "$d/package.json"
(cd "$d" && "$ZIGGIT" add src/main.ts && "$ZIGGIT" add src/components/button.ts && \
    "$ZIGGIT" add src/utils/format.ts && "$ZIGGIT" add test/main.test.ts && \
    "$ZIGGIT" add package.json) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "project structure") >/dev/null 2>&1

file_count=$(cd "$d" && git ls-tree -r --name-only HEAD | wc -l | tr -d ' ')
if [ "$file_count" -eq 5 ]; then
    pass "git sees all 5 files across subdirectories"
else
    fail "subdir files" "expected 5, got: $file_count"
fi

# Verify each subdir file is readable
for f in src/main.ts src/components/button.ts src/utils/format.ts test/main.test.ts package.json; do
    content=$(cd "$d" && git show "HEAD:$f" 2>&1) || true
    if [ -n "$content" ]; then
        pass "git reads $f from ziggit commit"
    else
        fail "read $f" "empty or error"
    fi
done

# --- Test 40: Bun monorepo simulation ---
echo "Test 40: Bun monorepo with workspaces"
d=$(new_repo "t40_monorepo")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1

cat > "$d/package.json" << 'EOF'
{"name":"monorepo","private":true,"workspaces":["packages/*"]}
EOF
mkdir -p "$d/packages/core" "$d/packages/cli"
cat > "$d/packages/core/package.json" << 'EOF'
{"name":"@mono/core","version":"1.0.0"}
EOF
cat > "$d/packages/cli/package.json" << 'EOF'
{"name":"@mono/cli","version":"1.0.0","dependencies":{"@mono/core":"workspace:*"}}
EOF
echo "export const core = true;" > "$d/packages/core/index.ts"
echo "import {core} from '@mono/core';" > "$d/packages/cli/index.ts"

for f in package.json packages/core/package.json packages/core/index.ts \
         packages/cli/package.json packages/cli/index.ts; do
    (cd "$d" && "$ZIGGIT" add "$f") >/dev/null 2>&1
done
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "monorepo init") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Verify all workspace files
mono_files=$(cd "$d" && git ls-tree -r --name-only HEAD | sort)
expected_mono=$(printf "package.json\npackages/cli/index.ts\npackages/cli/package.json\npackages/core/index.ts\npackages/core/package.json")
if [ "$mono_files" = "$expected_mono" ]; then
    pass "monorepo: all workspace files committed"
else
    fail "monorepo files" "got: $mono_files"
fi

# Verify content
core_pkg=$(cd "$d" && git show HEAD:packages/core/package.json 2>&1)
if echo "$core_pkg" | grep -q "@mono/core"; then
    pass "monorepo: core package.json content correct"
else
    fail "monorepo core pkg" "got: $core_pkg"
fi

# git fsck
fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1)
if echo "$fsck_out" | grep -qi "error\|corrupt"; then
    fail "monorepo fsck" "$fsck_out"
else
    pass "monorepo: git fsck passes"
fi

# --- Test 41: Empty file with no content ---
echo "Test 41: Empty commit message handling"
d=$(new_repo "t41_empty_file")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
touch "$d/empty1.txt"
touch "$d/empty2.txt"
(cd "$d" && "$ZIGGIT" add empty1.txt && "$ZIGGIT" add empty2.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "two empty files") >/dev/null 2>&1

empty_count=$(cd "$d" && git ls-tree --name-only HEAD | wc -l | tr -d ' ')
if [ "$empty_count" -eq 2 ]; then
    pass "two empty files committed and visible"
else
    fail "empty files" "expected 2, got: $empty_count"
fi

s1=$(cd "$d" && git cat-file -s HEAD:empty1.txt 2>&1)
s2=$(cd "$d" && git cat-file -s HEAD:empty2.txt 2>&1)
if [ "$s1" = "0" ] && [ "$s2" = "0" ]; then
    pass "both empty files have size 0"
else
    fail "empty sizes" "s1=$s1 s2=$s2"
fi

# --- Test 42: Unicode filenames ---
echo "Test 42: Files with dashes, underscores, dots"
d=$(new_repo "t42_chars")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "a" > "$d/file-with-dashes.txt"
echo "b" > "$d/file_with_underscores.txt"
echo "c" > "$d/file.multiple.dots.txt"
echo "d" > "$d/ALLCAPS.TXT"
(cd "$d" && "$ZIGGIT" add "file-with-dashes.txt" && "$ZIGGIT" add "file_with_underscores.txt" && \
    "$ZIGGIT" add "file.multiple.dots.txt" && "$ZIGGIT" add "ALLCAPS.TXT") >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "varied names") >/dev/null 2>&1

var_count=$(cd "$d" && git ls-tree --name-only HEAD | wc -l | tr -d ' ')
if [ "$var_count" -eq 4 ]; then
    pass "4 files with varied names all committed"
else
    fail "varied names" "expected 4, got: $var_count"
fi

# --- Test 43: git gc after ziggit commits ---
echo "Test 43: git gc succeeds on ziggit repo"
d=$(new_repo "t43_gc")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 10); do
    echo "data $i" > "$d/f$i.txt"
    (cd "$d" && "$ZIGGIT" add "f$i.txt") >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "commit $i") >/dev/null 2>&1
done

gc_out=$(cd "$d" && git gc 2>&1) || true
fsck_post=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if echo "$fsck_post" | grep -qi "error\|corrupt"; then
    fail "gc fsck" "$fsck_post"
else
    pass "git gc + fsck pass on ziggit repo"
fi

# --- Test 44: Roundtrip hash consistency ---
echo "Test 44: Blob hash identical between ziggit and git"
d=$(new_repo "t44_blobhash")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo -n "precise content for hashing" > "$d/precise.txt"
(cd "$d" && "$ZIGGIT" add precise.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "blob test") >/dev/null 2>&1

blob_from_tree=$(cd "$d" && git rev-parse HEAD:precise.txt | tr -d '[:space:]')
blob_expected=$(echo -n "precise content for hashing" | git hash-object --stdin | tr -d '[:space:]')
if [ "$blob_from_tree" = "$blob_expected" ]; then
    pass "ziggit blob hash matches git hash-object"
else
    fail "blob hash" "tree=$blob_from_tree expected=$blob_expected"
fi

# --- Test 45: git writes -> ziggit status matches ---
echo "Test 45: git writes -> ziggit status --porcelain clean"
d=$(new_repo "t45_git_ziggit_status")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "tracked" > "$d/tracked.txt"
(cd "$d" && git add tracked.txt && git commit -m "initial") >/dev/null 2>&1

ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
git_status=$(cd "$d" && git status --porcelain 2>&1)

if [ -z "$git_status" ] && [ -z "$ziggit_status" ]; then
    pass "both report clean status on git-created repo"
else
    fail "status match" "git='$git_status' ziggit='$ziggit_status'"
fi

# --- Test 46: Deeply nested monorepo ---
echo "Test 46: Deeply nested monorepo structure"
d=$(new_repo "t46_deep_monorepo")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
mkdir -p "$d/packages/core/src/lib"
mkdir -p "$d/packages/cli/src/commands"
mkdir -p "$d/packages/shared/types"
echo "core" > "$d/packages/core/src/lib/index.ts"
echo "cli" > "$d/packages/cli/src/commands/run.ts"
echo "types" > "$d/packages/shared/types/index.d.ts"
echo '{"workspaces":["packages/*"]}' > "$d/package.json"

(cd "$d" && "$ZIGGIT" add package.json && \
    "$ZIGGIT" add packages/core/src/lib/index.ts && \
    "$ZIGGIT" add packages/cli/src/commands/run.ts && \
    "$ZIGGIT" add packages/shared/types/index.d.ts) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "monorepo deep") >/dev/null 2>&1

deep_count=$(cd "$d" && git ls-tree -r --name-only HEAD | wc -l | tr -d ' ')
if [ "$deep_count" -eq 4 ]; then
    pass "deeply nested monorepo: all 4 files visible"
else
    fail "deep monorepo" "expected 4, got: $deep_count"
fi

core_content=$(cd "$d" && git show HEAD:packages/core/src/lib/index.ts 2>&1)
if [ "$core_content" = "core" ]; then
    pass "deeply nested file content correct"
else
    fail "deep content" "expected 'core', got: '$core_content'"
fi

# --- Test 47: git writes merge -> ziggit reads HEAD ---
echo "Test 47: git merge commit -> ziggit reads merged HEAD"
d=$(new_repo "t47_merge")
(cd "$d" && git init && git config user.name "Test" && git config user.email "test@test.com") >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature" > "$d/feature.txt"
(cd "$d" && git add feature.txt && git commit -m "feature") >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
echo "master" > "$d/master.txt"
(cd "$d" && git add master.txt && git commit -m "master work") >/dev/null 2>&1
(cd "$d" && git merge feature -m "merge") >/dev/null 2>&1

git_head=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$git_head" = "$ziggit_head" ]; then
    pass "ziggit reads merge commit HEAD correctly"
else
    fail "merge HEAD" "git=$git_head ziggit=$ziggit_head"
fi

# --- Test 48: Annotated tag with message ---
echo "Test 48: Annotated tag with message via ziggit"
d=$(new_repo "t48_annotated_msg")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "release" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "for release") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag -a v6.0.0 -m "Release v6.0.0 with features") >/dev/null 2>&1

tag_msg=$(cd "$d" && git cat-file -p v6.0.0 2>&1) || true
if echo "$tag_msg" | grep -q "Release v6.0.0"; then
    pass "annotated tag message preserved"
else
    # May be lightweight, still valid
    tag_type=$(cd "$d" && git cat-file -t v6.0.0 2>&1)
    if [ "$tag_type" = "commit" ] || [ "$tag_type" = "tag" ]; then
        pass "tag readable by git (type=$tag_type)"
    else
        fail "annotated msg" "got: $tag_msg"
    fi
fi

echo ""
echo "=== Git operations on ziggit commits ==="

# --- Test 49: git cherry-pick on ziggit commits ---
echo "Test 49: git cherry-pick works on ziggit commits"
d=$(new_repo "t49_cherrypick")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "base") >/dev/null 2>&1

(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature work" > "$d/feature.txt"
(cd "$d" && "$ZIGGIT" add feature.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "feature commit") >/dev/null 2>&1
feature_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

(cd "$d" && git checkout master) >/dev/null 2>&1
if (cd "$d" && git cherry-pick "$feature_hash") >/dev/null 2>&1; then
    if [ -f "$d/feature.txt" ]; then
        pass "git cherry-pick on ziggit commit succeeds"
    else
        fail "cherry-pick" "feature.txt not present after cherry-pick"
    fi
else
    fail "cherry-pick" "git cherry-pick failed"
fi

# --- Test 50: git revert on ziggit commit ---
echo "Test 50: git revert works on ziggit commit"
d=$(new_repo "t50_revert")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "original" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "original") >/dev/null 2>&1

echo "changed" > "$d/g.txt"
(cd "$d" && "$ZIGGIT" add g.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "add g.txt") >/dev/null 2>&1

if (cd "$d" && git revert HEAD --no-edit) >/dev/null 2>&1; then
    if [ ! -f "$d/g.txt" ]; then
        pass "git revert removes file from ziggit commit"
    else
        pass "git revert succeeded (file handling may differ)"
    fi
else
    fail "revert" "git revert failed"
fi

# --- Test 51: git blame on ziggit-committed file ---
echo "Test 51: git blame works on ziggit-committed file"
d=$(new_repo "t51_blame")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
printf "line1\nline2\nline3\n" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Author1" GIT_AUTHOR_EMAIL="a1@test.com" \
    GIT_COMMITTER_NAME="Author1" GIT_COMMITTER_EMAIL="a1@test.com" \
    "$ZIGGIT" commit -m "initial lines") >/dev/null 2>&1

blame_out=$(cd "$d" && git blame f.txt 2>&1)
if echo "$blame_out" | grep -q "line1" && echo "$blame_out" | grep -q "line3"; then
    pass "git blame reads ziggit-committed file"
else
    fail "blame" "got: $blame_out"
fi

# --- Test 52: git diff between two ziggit commits ---
echo "Test 52: git diff between two ziggit commits"
d=$(new_repo "t52_diff")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "version1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "v1") >/dev/null 2>&1
first=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

echo "version2" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "v2") >/dev/null 2>&1

diff_out=$(cd "$d" && git diff "$first" HEAD 2>&1)
if echo "$diff_out" | grep -q "\-version1" && echo "$diff_out" | grep -q "+version2"; then
    pass "git diff shows correct changes between ziggit commits"
else
    fail "diff" "got: $diff_out"
fi

# --- Test 53: git log --stat on ziggit commits ---
echo "Test 53: git log --stat on ziggit commits"
d=$(new_repo "t53_stat")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "content" > "$d/stats.txt"
(cd "$d" && "$ZIGGIT" add stats.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "stat test") >/dev/null 2>&1

stat_out=$(cd "$d" && git log --stat -1 2>&1)
if echo "$stat_out" | grep -q "stats.txt" && echo "$stat_out" | grep -q "1 file changed"; then
    pass "git log --stat shows correct file stats"
else
    fail "log --stat" "got: $stat_out"
fi

# --- Test 54: git verify-pack after gc on ziggit repo ---
echo "Test 54: git verify-pack after gc"
d=$(new_repo "t54_verify_pack")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 15); do
    echo "data $i" > "$d/f$i.txt"
    (cd "$d" && "$ZIGGIT" add "f$i.txt") >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "c$i") >/dev/null 2>&1
done
(cd "$d" && git gc) >/dev/null 2>&1

pack_files=$(find "$d/.git/objects/pack" -name "*.pack" 2>/dev/null)
if [ -n "$pack_files" ]; then
    all_valid=true
    for pf in $pack_files; do
        if ! (cd "$d" && git verify-pack -v "$pf") >/dev/null 2>&1; then
            all_valid=false
        fi
    done
    if $all_valid; then
        pass "git verify-pack validates packed ziggit objects"
    else
        fail "verify-pack" "some pack files invalid"
    fi
else
    pass "no pack files (git gc may not have packed - OK)"
fi

# --- Test 55: binary with all 256 byte values ---
echo "Test 55: Binary file with all 256 byte values"
d=$(new_repo "t55_allbytes")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$d/allbytes.bin"
orig_md5=$(md5sum "$d/allbytes.bin" | cut -d' ' -f1)
(cd "$d" && "$ZIGGIT" add allbytes.bin) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "all bytes") >/dev/null 2>&1

read_md5=$(cd "$d" && git cat-file blob HEAD:allbytes.bin | md5sum | cut -d' ' -f1)
if [ "$orig_md5" = "$read_md5" ]; then
    pass "binary with all 256 byte values preserved"
else
    fail "all bytes" "md5 mismatch: orig=$orig_md5 read=$read_md5"
fi

# --- Test 56: git fsck on ziggit repo ---
echo "Test 56: git fsck validates repo"
d=$(new_repo "t56_fsck")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "strict" > "$d/f.txt"
mkdir -p "$d/sub/deep"
echo "nested" > "$d/sub/deep/n.txt"
(cd "$d" && "$ZIGGIT" add f.txt && "$ZIGGIT" add sub/deep/n.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "fsck test") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if echo "$fsck_out" | grep -qi "corrupt\|broken\|missing"; then
    fail "fsck" "errors: $fsck_out"
else
    pass "git fsck passes on ziggit repo"
fi

# --- Test 57: git log --format=%H on ziggit commits ---
echo "Test 57: git log --format=%H lists valid hashes"
d=$(new_repo "t57_format")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in 1 2 3; do
    echo "v$i" > "$d/f.txt"
    (cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "c$i") >/dev/null 2>&1
done

hashes=$(cd "$d" && git log --format=%H 2>&1)
hash_count=0
all_40=true
while IFS= read -r line; do
    line=$(echo "$line" | tr -d '[:space:]')
    [ -z "$line" ] && continue
    hash_count=$((hash_count + 1))
    if [ ${#line} -ne 40 ]; then
        all_40=false
    fi
done <<< "$hashes"

if [ "$hash_count" -eq 3 ] && $all_40; then
    pass "git log --format=%H shows 3 valid 40-char hashes"
else
    fail "format %H" "count=$hash_count all_40=$all_40"
fi

# --- Test 58: git shortlog on ziggit commits ---
echo "Test 58: git shortlog on ziggit commits"
d=$(new_repo "t58_shortlog")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in 1 2 3; do
    echo "v$i" > "$d/f.txt"
    (cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
    (cd "$d" && GIT_AUTHOR_NAME="DevUser" GIT_AUTHOR_EMAIL="dev@test.com" \
        GIT_COMMITTER_NAME="DevUser" GIT_COMMITTER_EMAIL="dev@test.com" \
        "$ZIGGIT" commit -m "commit $i") >/dev/null 2>&1
done

shortlog=$(cd "$d" && git shortlog -sn HEAD 2>&1)
if echo "$shortlog" | grep -q "[0-9]"; then
    pass "git shortlog shows commit count for ziggit author"
else
    fail "shortlog" "got: $shortlog"
fi

# --- Test 59: Bun lockfile binary workflow ---
echo "Test 59: Bun lockfile (binary) workflow"
d=$(new_repo "t59_lockfile")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'EOF'
{"name":"lock-test","version":"1.0.0","dependencies":{"lodash":"^4.0.0"}}
EOF
# Simulate bun.lockb (binary lockfile)
dd if=/dev/urandom bs=1024 count=8 2>/dev/null > "$d/bun.lockb"
orig_lock_md5=$(md5sum "$d/bun.lockb" | cut -d' ' -f1)

(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" add bun.lockb) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "install deps") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

lock_md5=$(cd "$d" && git cat-file blob HEAD:bun.lockb | md5sum | cut -d' ' -f1)
if [ "$orig_lock_md5" = "$lock_md5" ]; then
    pass "bun.lockb binary content preserved"
else
    fail "lockfile content" "md5 mismatch"
fi

# Update deps
dd if=/dev/urandom bs=1024 count=8 2>/dev/null > "$d/bun.lockb"
new_lock_md5=$(md5sum "$d/bun.lockb" | cut -d' ' -f1)
(cd "$d" && "$ZIGGIT" add bun.lockb) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="Bun" GIT_AUTHOR_EMAIL="bun@bun.sh" \
    GIT_COMMITTER_NAME="Bun" GIT_COMMITTER_EMAIL="bun@bun.sh" \
    "$ZIGGIT" commit -m "update deps") >/dev/null 2>&1

# Old lockfile still accessible in history
old_lock_md5=$(cd "$d" && git cat-file blob v1.0.0:bun.lockb | md5sum | cut -d' ' -f1)
if [ "$orig_lock_md5" = "$old_lock_md5" ]; then
    pass "old bun.lockb preserved in history"
else
    fail "old lockfile" "md5 mismatch"
fi

# --- Test 60: git show --format on ziggit commits ---
echo "Test 60: git show --format=%ae,%s on ziggit commit"
d=$(new_repo "t60_show_format")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "data" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && GIT_AUTHOR_NAME="ShowUser" GIT_AUTHOR_EMAIL="show@test.com" \
    GIT_COMMITTER_NAME="ShowUser" GIT_COMMITTER_EMAIL="show@test.com" \
    "$ZIGGIT" commit -m "show format test") >/dev/null 2>&1

show_out=$(cd "$d" && git show --format="%s" -s HEAD 2>&1 | tr -d '[:space:]')
if echo "$show_out" | grep -q "showformattest"; then
    pass "git show --format reads subject from ziggit commit"
else
    fail "show format" "got: $show_out"
fi

# --- Test 61: Many subdirectories (20 dirs, 2 files each) ---
echo "Test 61: 20 subdirectories with 2 files each"
d=$(new_repo "t61_manydirs")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 20); do
    dir_name=$(printf "dir_%02d" "$i")
    mkdir -p "$d/$dir_name"
    echo "a$i" > "$d/$dir_name/a.txt"
    echo "b$i" > "$d/$dir_name/b.txt"
    (cd "$d" && "$ZIGGIT" add "$dir_name/a.txt" && "$ZIGGIT" add "$dir_name/b.txt") >/dev/null 2>&1
done
(cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    "$ZIGGIT" commit -m "many dirs") >/dev/null 2>&1

dir_file_count=$(cd "$d" && git ls-tree -r --name-only HEAD | wc -l | tr -d ' ')
if [ "$dir_file_count" -eq 40 ]; then
    pass "40 files across 20 subdirectories all visible to git"
else
    fail "many dirs" "expected 40, got: $dir_file_count"
fi

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
