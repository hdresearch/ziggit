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

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
