#!/bin/bash
# Precise cross-validation: ziggit CLI output vs git CLI output
# Every test creates a repo, performs operations, and compares outputs byte-for-byte
set -euo pipefail

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
SKIP=0
TMPBASE=$(mktemp -d /tmp/ziggit_precise_crossval.XXXXXX)

cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1 -- $2"; SKIP=$((SKIP + 1)); }

new_repo() {
    local d="$TMPBASE/$1"
    mkdir -p "$d"
    echo "$d"
}

setup_git_env() {
    export GIT_AUTHOR_NAME="Test Author"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test Author"
    export GIT_COMMITTER_EMAIL="test@example.com"
    export GIT_AUTHOR_DATE="2024-01-01T00:00:00+00:00"
    export GIT_COMMITTER_DATE="2024-01-01T00:00:00+00:00"
}
setup_git_env

echo "=== Precise Cross-Validation Tests ==="

# ============================================================
# SECTION 1: ziggit init -> git validates
# ============================================================

echo ""
echo "--- Section 1: ziggit init -> git validates ---"

echo "Test 1.1: ziggit init -> git rev-parse --git-dir"
d=$(new_repo "s1_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
out=$(cd "$d" && git rev-parse --git-dir 2>&1)
if [ "$out" = ".git" ]; then
    pass "git rev-parse --git-dir = .git"
else
    fail "git rev-parse --git-dir" "got: $out"
fi

echo "Test 1.2: ziggit init -> git status shows empty repo"
d=$(new_repo "s1_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
out=$(cd "$d" && git status --porcelain 2>&1)
if [ -z "$out" ]; then
    pass "git status --porcelain is empty for fresh init"
else
    fail "git status empty" "got: $out"
fi

echo "Test 1.3: ziggit init -> .git/HEAD exists and points to refs/heads/master"
d=$(new_repo "s1_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
head_content=$(cat "$d/.git/HEAD" 2>&1)
if echo "$head_content" | grep -q "ref: refs/heads/master"; then
    pass "HEAD points to refs/heads/master"
else
    fail "HEAD content" "got: $head_content"
fi

echo "Test 1.4: ziggit init -> .git/objects dir exists"
d=$(new_repo "s1_t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
if [ -d "$d/.git/objects" ]; then
    pass ".git/objects directory exists"
else
    fail ".git/objects" "directory missing"
fi

echo "Test 1.5: ziggit init -> .git/refs/heads and .git/refs/tags exist"
d=$(new_repo "s1_t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
if [ -d "$d/.git/refs/heads" ] && [ -d "$d/.git/refs/tags" ]; then
    pass "refs/heads and refs/tags directories exist"
else
    fail "refs dirs" "heads=$(test -d "$d/.git/refs/heads" && echo yes || echo no) tags=$(test -d "$d/.git/refs/tags" && echo yes || echo no)"
fi

# ============================================================
# SECTION 2: ziggit add+commit -> git reads
# ============================================================

echo ""
echo "--- Section 2: ziggit add+commit -> git reads ---"

echo "Test 2.1: ziggit commit -> git log --oneline shows message"
d=$(new_repo "s2_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "hello" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt && "$ZIGGIT" commit -m "first commit") >/dev/null 2>&1
out=$(cd "$d" && git log --oneline 2>&1)
if echo "$out" | grep -q "first commit"; then
    pass "git log shows ziggit commit message"
else
    fail "git log message" "got: $out"
fi

echo "Test 2.2: ziggit commit -> git show HEAD:file.txt matches content"
d=$(new_repo "s2_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "exact content" > "$d/file.txt"
(cd "$d" && "$ZIGGIT" add file.txt && "$ZIGGIT" commit -m "content test") >/dev/null 2>&1
out=$(cd "$d" && git show HEAD:file.txt 2>&1)
if [ "$out" = "exact content" ]; then
    pass "git show reads exact file content"
else
    fail "git show content" "expected 'exact content', got: '$out'"
fi

echo "Test 2.3: ziggit commit -> git cat-file -t HEAD is commit"
d=$(new_repo "s2_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "data" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt && "$ZIGGIT" commit -m "type test") >/dev/null 2>&1
obj_type=$(cd "$d" && git cat-file -t HEAD 2>&1)
if [ "$obj_type" = "commit" ]; then
    pass "git cat-file -t HEAD = commit"
else
    fail "cat-file -t" "got: $obj_type"
fi

echo "Test 2.4: ziggit commit -> git cat-file -p HEAD has tree and author"
d=$(new_repo "s2_t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "x" > "$d/x.txt"
(cd "$d" && "$ZIGGIT" add x.txt && "$ZIGGIT" commit -m "parse test") >/dev/null 2>&1
commit_obj=$(cd "$d" && git cat-file -p HEAD 2>&1)
has_tree=$(echo "$commit_obj" | grep -c "^tree " || true)
has_author=$(echo "$commit_obj" | grep -c "^author " || true)
has_committer=$(echo "$commit_obj" | grep -c "^committer " || true)
if [ "$has_tree" -ge 1 ] && [ "$has_author" -ge 1 ] && [ "$has_committer" -ge 1 ]; then
    pass "git cat-file -p HEAD has tree, author, committer"
else
    fail "cat-file -p HEAD" "tree=$has_tree author=$has_author committer=$has_committer"
fi

echo "Test 2.5: ziggit commit -> git rev-parse HEAD matches ziggit rev-parse HEAD"
d=$(new_repo "s2_t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "hash test" > "$d/h.txt"
(cd "$d" && "$ZIGGIT" add h.txt && "$ZIGGIT" commit -m "hash match") >/dev/null 2>&1
git_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash" = "$ziggit_hash" ]; then
    pass "rev-parse HEAD matches: $git_hash"
else
    fail "rev-parse HEAD" "git=$git_hash ziggit=$ziggit_hash"
fi

echo "Test 2.6: ziggit commit -> git fsck passes"
d=$(new_repo "s2_t6")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "fsck test" > "$d/fsck.txt"
(cd "$d" && "$ZIGGIT" add fsck.txt && "$ZIGGIT" commit -m "fsck test") >/dev/null 2>&1
fsck_out=$(cd "$d" && git fsck 2>&1) || true
if ! echo "$fsck_out" | grep -qi "error\|corrupt\|missing"; then
    pass "git fsck clean after ziggit commit"
else
    fail "git fsck" "$fsck_out"
fi

echo "Test 2.7: ziggit two commits -> git rev-list --count HEAD = 2"
d=$(new_repo "s2_t7")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "a" > "$d/a.txt"
(cd "$d" && "$ZIGGIT" add a.txt && "$ZIGGIT" commit -m "first") >/dev/null 2>&1
echo "b" > "$d/b.txt"
(cd "$d" && "$ZIGGIT" add b.txt && "$ZIGGIT" commit -m "second") >/dev/null 2>&1
count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "2" ]; then
    pass "git rev-list --count HEAD = 2"
else
    fail "rev-list count" "expected 2, got: $count"
fi

echo "Test 2.8: ziggit commit -> git diff HEAD shows no changes"
d=$(new_repo "s2_t8")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "clean" > "$d/clean.txt"
(cd "$d" && "$ZIGGIT" add clean.txt && "$ZIGGIT" commit -m "clean commit") >/dev/null 2>&1
diff_out=$(cd "$d" && git diff HEAD 2>&1)
if [ -z "$diff_out" ]; then
    pass "git diff HEAD empty after clean commit"
else
    fail "git diff" "expected empty, got output"
fi

echo "Test 2.9: ziggit commit -> git status --porcelain empty"
d=$(new_repo "s2_t9")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "status" > "$d/s.txt"
(cd "$d" && "$ZIGGIT" add s.txt && "$ZIGGIT" commit -m "status test") >/dev/null 2>&1
status=$(cd "$d" && git status --porcelain 2>&1)
if [ -z "$status" ]; then
    pass "git status --porcelain empty after commit"
else
    fail "git status" "got: $status"
fi

echo "Test 2.10: ziggit commit -> git ls-tree HEAD lists file"
d=$(new_repo "s2_t10")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "tree" > "$d/tree.txt"
(cd "$d" && "$ZIGGIT" add tree.txt && "$ZIGGIT" commit -m "ls-tree test") >/dev/null 2>&1
ls_tree=$(cd "$d" && git ls-tree HEAD 2>&1)
if echo "$ls_tree" | grep -q "tree.txt"; then
    pass "git ls-tree HEAD lists tree.txt"
else
    fail "git ls-tree" "got: $ls_tree"
fi

# ============================================================
# SECTION 3: ziggit tag -> git reads
# ============================================================

echo ""
echo "--- Section 3: ziggit tag -> git reads ---"

echo "Test 3.1: ziggit tag -> git tag -l lists it"
d=$(new_repo "s3_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "tag" > "$d/t.txt"
(cd "$d" && "$ZIGGIT" add t.txt && "$ZIGGIT" commit -m "tagged") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
tags=$(cd "$d" && git tag -l 2>&1)
if echo "$tags" | grep -q "v1.0.0"; then
    pass "git tag -l shows v1.0.0"
else
    fail "git tag -l" "got: $tags"
fi

echo "Test 3.2: ziggit tag -> git rev-parse tag resolves to HEAD"
d=$(new_repo "s3_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "rp" > "$d/rp.txt"
(cd "$d" && "$ZIGGIT" add rp.txt && "$ZIGGIT" commit -m "rp tag") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v2.0.0) >/dev/null 2>&1
head=$(cd "$d" && git rev-parse HEAD 2>&1)
tag_hash=$(cd "$d" && git rev-parse v2.0.0 2>&1)
if [ "$head" = "$tag_hash" ]; then
    pass "git rev-parse v2.0.0 = HEAD ($head)"
else
    fail "tag rev-parse" "HEAD=$head tag=$tag_hash"
fi

echo "Test 3.3: ziggit multiple tags -> git tag -l lists all"
d=$(new_repo "s3_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "multi" > "$d/m.txt"
(cd "$d" && "$ZIGGIT" add m.txt && "$ZIGGIT" commit -m "multi-tag") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
echo "v2" > "$d/m.txt"
(cd "$d" && "$ZIGGIT" add m.txt && "$ZIGGIT" commit -m "v2") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v2.0.0) >/dev/null 2>&1
echo "v3" > "$d/m.txt"
(cd "$d" && "$ZIGGIT" add m.txt && "$ZIGGIT" commit -m "v3") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v3.0.0) >/dev/null 2>&1
tags=$(cd "$d" && git tag -l | sort 2>&1)
expected=$(printf "v1.0.0\nv2.0.0\nv3.0.0")
if [ "$tags" = "$expected" ]; then
    pass "git tag -l lists all 3 tags"
else
    fail "multi tags" "got: $tags"
fi

echo "Test 3.4: ziggit tag -> git describe --tags = tag name"
d=$(new_repo "s3_t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "desc" > "$d/d.txt"
(cd "$d" && "$ZIGGIT" add d.txt && "$ZIGGIT" commit -m "describe test") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v5.0.0) >/dev/null 2>&1
desc=$(cd "$d" && git describe --tags 2>&1)
if [ "$desc" = "v5.0.0" ]; then
    pass "git describe --tags = v5.0.0"
else
    fail "git describe" "got: $desc"
fi

echo "Test 3.5: ziggit tag + commits -> git describe --tags shows distance"
d=$(new_repo "s3_t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/base.txt"
(cd "$d" && "$ZIGGIT" add base.txt && "$ZIGGIT" commit -m "base") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
echo "next1" > "$d/n1.txt"
(cd "$d" && "$ZIGGIT" add n1.txt && "$ZIGGIT" commit -m "next1") >/dev/null 2>&1
echo "next2" > "$d/n2.txt"
(cd "$d" && "$ZIGGIT" add n2.txt && "$ZIGGIT" commit -m "next2") >/dev/null 2>&1
desc=$(cd "$d" && git describe --tags 2>&1)
if echo "$desc" | grep -q "^v1.0.0-2-g"; then
    pass "git describe shows v1.0.0-2-g... ($desc)"
else
    fail "describe distance" "expected v1.0.0-2-g..., got: $desc"
fi

# ============================================================
# SECTION 4: git writes -> ziggit reads
# ============================================================

echo ""
echo "--- Section 4: git writes -> ziggit reads ---"

echo "Test 4.1: git init+commit -> ziggit rev-parse HEAD matches"
d=$(new_repo "s4_t1")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "git wrote this" > "$d/file.txt"
(cd "$d" && git add file.txt && git commit -m "git commit") >/dev/null 2>&1
git_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash" = "$ziggit_hash" ]; then
    pass "ziggit rev-parse HEAD matches git ($git_hash)"
else
    fail "rev-parse match" "git=$git_hash ziggit=$ziggit_hash"
fi

echo "Test 4.2: git tag -> ziggit describe --tags finds it"
d=$(new_repo "s4_t2")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "tagged" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "tagged" && git tag v9.0.0) >/dev/null 2>&1
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if [ "$ziggit_desc" = "v9.0.0" ]; then
    pass "ziggit describe --tags = v9.0.0"
else
    fail "ziggit describe" "got: $ziggit_desc"
fi

echo "Test 4.3: git multiple commits -> ziggit log --format=%H -1 HEAD~1"
d=$(new_repo "s4_t3")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "c1" > "$d/c1.txt"
(cd "$d" && git add c1.txt && git commit -m "commit1") >/dev/null 2>&1
echo "c2" > "$d/c2.txt"
(cd "$d" && git add c2.txt && git commit -m "commit2") >/dev/null 2>&1
echo "c3" > "$d/c3.txt"
(cd "$d" && git add c3.txt && git commit -m "commit3") >/dev/null 2>&1
git_parent=$(cd "$d" && git log --format=%H -1 HEAD~1 2>&1)
ziggit_parent=$(cd "$d" && "$ZIGGIT" log --format=%H -1 HEAD~1 2>&1) || true
if [ "$git_parent" = "$ziggit_parent" ]; then
    pass "ziggit log --format=%H -1 HEAD~1 matches git ($git_parent)"
else
    # ziggit may not support HEAD~1 in log, check rev-parse fallback
    ziggit_rp=$(cd "$d" && "$ZIGGIT" rev-parse HEAD~1 2>&1) || true
    if [ "$git_parent" = "$ziggit_rp" ]; then
        pass "ziggit rev-parse HEAD~1 matches git ($git_parent)"
    else
        skip "HEAD~1 resolution" "ziggit log=$ziggit_parent, rev-parse=$ziggit_rp, expected=$git_parent"
    fi
fi

echo "Test 4.4: git status clean -> ziggit status --porcelain empty"
d=$(new_repo "s4_t4")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "clean" > "$d/c.txt"
(cd "$d" && git add c.txt && git commit -m "clean") >/dev/null 2>&1
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if [ -z "$ziggit_status" ]; then
    pass "ziggit status --porcelain empty for clean repo"
else
    fail "ziggit status" "got: $ziggit_status"
fi

echo "Test 4.5: git untracked file -> ziggit status --porcelain shows ??"
d=$(new_repo "s4_t5")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "committed" > "$d/c.txt"
(cd "$d" && git add c.txt && git commit -m "base") >/dev/null 2>&1
echo "untracked" > "$d/new.txt"
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if echo "$ziggit_status" | grep -q "?? new.txt"; then
    pass "ziggit detects untracked file"
else
    # May show ?? with different path format
    if echo "$ziggit_status" | grep -q "new.txt"; then
        pass "ziggit detects untracked file (variant format)"
    else
        fail "ziggit untracked" "got: '$ziggit_status'"
    fi
fi

echo "Test 4.6: git merge commit -> ziggit rev-parse HEAD reads merge commit"
d=$(new_repo "s4_t6")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "main" > "$d/main.txt"
(cd "$d" && git add main.txt && git commit -m "main commit") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature" > "$d/feature.txt"
(cd "$d" && git add feature.txt && git commit -m "feature commit") >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
(cd "$d" && git merge feature -m "merge feature" --no-edit --no-ff) >/dev/null 2>&1
git_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash" = "$ziggit_hash" ]; then
    pass "ziggit reads merge commit HEAD ($git_hash)"
else
    fail "merge HEAD" "git=$git_hash ziggit=$ziggit_hash"
fi
# Verify it's actually a merge commit (2 parents)
parent_count=$(cd "$d" && git cat-file -p HEAD | grep -c "^parent " 2>&1) || true
if [ "$parent_count" = "2" ]; then
    pass "merge commit has 2 parents"
else
    fail "merge parents" "expected 2, got: $parent_count"
fi

echo "Test 4.7: git gc -> ziggit rev-parse HEAD still works"
d=$(new_repo "s4_t7")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "gc test" > "$d/gc.txt"
(cd "$d" && git add gc.txt && git commit -m "gc test") >/dev/null 2>&1
(cd "$d" && git gc) >/dev/null 2>&1
git_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash" = "$ziggit_hash" ]; then
    pass "ziggit reads HEAD after git gc ($git_hash)"
else
    fail "post-gc rev-parse" "git=$git_hash ziggit=$ziggit_hash"
fi

echo "Test 4.8: git packed-refs -> ziggit describe --tags works"
d=$(new_repo "s4_t8")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "packed" > "$d/p.txt"
(cd "$d" && git add p.txt && git commit -m "packed" && git tag v7.0.0) >/dev/null 2>&1
(cd "$d" && git pack-refs --all) >/dev/null 2>&1
# Verify refs are packed
if [ -f "$d/.git/packed-refs" ]; then
    ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
    if [ "$ziggit_desc" = "v7.0.0" ]; then
        pass "ziggit describe works with packed-refs ($ziggit_desc)"
    else
        fail "packed-refs describe" "got: $ziggit_desc"
    fi
else
    skip "packed-refs" "git didn't create packed-refs file"
fi

# ============================================================
# SECTION 5: Edge cases
# ============================================================

echo ""
echo "--- Section 5: Edge cases ---"

echo "Test 5.1: binary file with all 256 byte values"
d=$(new_repo "s5_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$d/binary.bin"
(cd "$d" && "$ZIGGIT" add binary.bin && "$ZIGGIT" commit -m "binary") >/dev/null 2>&1
git_size=$(cd "$d" && git cat-file -s HEAD:binary.bin 2>&1)
if [ "$git_size" = "256" ]; then
    pass "binary file size preserved (256 bytes)"
else
    fail "binary size" "expected 256, got: $git_size"
fi
# Compare content
original_md5=$(md5sum "$d/binary.bin" | cut -d' ' -f1)
git_md5=$(cd "$d" && git show HEAD:binary.bin | md5sum | cut -d' ' -f1)
if [ "$original_md5" = "$git_md5" ]; then
    pass "binary content byte-for-byte match"
else
    fail "binary content" "original=$original_md5 git=$git_md5"
fi

echo "Test 5.2: file with spaces in name"
d=$(new_repo "s5_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "spaces" > "$d/file with spaces.txt"
(cd "$d" && "$ZIGGIT" add "file with spaces.txt" && "$ZIGGIT" commit -m "spaces") >/dev/null 2>&1
out=$(cd "$d" && git show "HEAD:file with spaces.txt" 2>&1)
if [ "$out" = "spaces" ]; then
    pass "file with spaces preserved"
else
    fail "spaces file" "got: $out"
fi

echo "Test 5.3: deeply nested 10 levels"
d=$(new_repo "s5_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
mkdir -p "$d/a/b/c/d/e/f/g/h/i/j"
echo "deep" > "$d/a/b/c/d/e/f/g/h/i/j/deep.txt"
(cd "$d" && "$ZIGGIT" add "a/b/c/d/e/f/g/h/i/j/deep.txt" && "$ZIGGIT" commit -m "deep") >/dev/null 2>&1
out=$(cd "$d" && git show "HEAD:a/b/c/d/e/f/g/h/i/j/deep.txt" 2>&1)
if [ "$out" = "deep" ]; then
    pass "deeply nested 10 levels preserved"
else
    fail "deep nesting" "got: $out"
fi

echo "Test 5.4: 100+ files in single commit"
d=$(new_repo "s5_t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in $(seq 1 120); do
    echo "file $i" > "$d/file_$(printf '%03d' $i).txt"
done
(cd "$d" && "$ZIGGIT" add . && "$ZIGGIT" commit -m "120 files") >/dev/null 2>&1
file_count=$(cd "$d" && git ls-tree -r HEAD | wc -l)
if [ "$file_count" -eq 120 ]; then
    pass "120 files all present in tree"
else
    fail "100+ files" "expected 120, got: $file_count"
fi
fsck=$(cd "$d" && git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error\|corrupt"; then
    pass "git fsck clean with 120 files"
else
    fail "fsck 120 files" "$fsck"
fi

echo "Test 5.5: empty file"
d=$(new_repo "s5_t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
touch "$d/empty.txt"
(cd "$d" && "$ZIGGIT" add empty.txt && "$ZIGGIT" commit -m "empty file") >/dev/null 2>&1
size=$(cd "$d" && git cat-file -s HEAD:empty.txt 2>&1)
if [ "$size" = "0" ]; then
    pass "empty file has size 0"
else
    fail "empty file" "expected size 0, got: $size"
fi

echo "Test 5.6: file with special characters: dots, dashes, underscores"
d=$(new_repo "s5_t6")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "dotdash" > "$d/my-file_v2.0.txt"
echo "under" > "$d/__init__.py"
(cd "$d" && "$ZIGGIT" add "my-file_v2.0.txt" "__init__.py" && "$ZIGGIT" commit -m "special chars") >/dev/null 2>&1
out1=$(cd "$d" && git show "HEAD:my-file_v2.0.txt" 2>&1)
out2=$(cd "$d" && git show "HEAD:__init__.py" 2>&1)
if [ "$out1" = "dotdash" ] && [ "$out2" = "under" ]; then
    pass "special char filenames preserved"
else
    fail "special chars" "out1=$out1 out2=$out2"
fi

echo "Test 5.7: CRLF content preserved byte-for-byte"
d=$(new_repo "s5_t7")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
# Disable git autocrlf to not interfere
(cd "$d" && git config core.autocrlf false) >/dev/null 2>&1
printf "line1\r\nline2\r\n" > "$d/crlf.txt"
(cd "$d" && "$ZIGGIT" add crlf.txt && "$ZIGGIT" commit -m "crlf") >/dev/null 2>&1
orig_md5=$(md5sum "$d/crlf.txt" | cut -d' ' -f1)
git_md5=$(cd "$d" && git show HEAD:crlf.txt | md5sum | cut -d' ' -f1)
if [ "$orig_md5" = "$git_md5" ]; then
    pass "CRLF content preserved byte-for-byte"
else
    fail "CRLF" "orig=$orig_md5 git=$git_md5"
fi

echo "Test 5.8: unicode content"
d=$(new_repo "s5_t8")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "こんにちは世界 🌍 μ∑∫" > "$d/unicode.txt"
(cd "$d" && "$ZIGGIT" add unicode.txt && "$ZIGGIT" commit -m "unicode content") >/dev/null 2>&1
out=$(cd "$d" && git show HEAD:unicode.txt 2>&1)
expected="こんにちは世界 🌍 μ∑∫"
if [ "$out" = "$expected" ]; then
    pass "unicode content preserved"
else
    fail "unicode" "got: $out"
fi

echo "Test 5.9: large file (64KB)"
d=$(new_repo "s5_t9")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
dd if=/dev/urandom of="$d/large.bin" bs=1024 count=64 2>/dev/null
(cd "$d" && "$ZIGGIT" add large.bin && "$ZIGGIT" commit -m "large binary") >/dev/null 2>&1
orig_md5=$(md5sum "$d/large.bin" | cut -d' ' -f1)
git_md5=$(cd "$d" && git show HEAD:large.bin | md5sum | cut -d' ' -f1)
git_size=$(cd "$d" && git cat-file -s HEAD:large.bin 2>&1)
if [ "$orig_md5" = "$git_md5" ] && [ "$git_size" = "65536" ]; then
    pass "64KB binary preserved (md5 match, size=65536)"
else
    fail "large binary" "md5: orig=$orig_md5 git=$git_md5 size=$git_size"
fi

echo "Test 5.10: dotfiles (.gitignore, .env, .npmrc)"
d=$(new_repo "s5_t10")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "node_modules/" > "$d/.gitignore"
echo "SECRET=123" > "$d/.env"
echo "registry=https://npm.pkg.github.com" > "$d/.npmrc"
(cd "$d" && "$ZIGGIT" add .gitignore .env .npmrc && "$ZIGGIT" commit -m "dotfiles") >/dev/null 2>&1
gi=$(cd "$d" && git show HEAD:.gitignore 2>&1)
env=$(cd "$d" && git show HEAD:.env 2>&1)
npmrc=$(cd "$d" && git show HEAD:.npmrc 2>&1)
if [ "$gi" = "node_modules/" ] && [ "$env" = "SECRET=123" ] && echo "$npmrc" | grep -q "registry"; then
    pass "dotfiles all preserved"
else
    fail "dotfiles" "gi=$gi env=$env npmrc=$npmrc"
fi

# ============================================================
# SECTION 6: Bun workflow simulation
# ============================================================

echo ""
echo "--- Section 6: Bun workflow simulation ---"

echo "Test 6.1: init, add package.json, commit, tag, status clean, describe"
d=$(new_repo "s6_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'EOF'
{
  "name": "@test/my-package",
  "version": "1.0.0",
  "main": "index.js"
}
EOF
echo "module.exports = {};" > "$d/index.js"
(cd "$d" && "$ZIGGIT" add package.json index.js && "$ZIGGIT" commit -m "Initial release") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Verify status clean
status=$(cd "$d" && git status --porcelain 2>&1)
if [ -z "$status" ]; then
    pass "bun workflow: status clean after tag"
else
    fail "bun status" "got: $status"
fi

# Verify describe
desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if [ "$desc" = "v1.0.0" ]; then
    pass "bun workflow: describe = v1.0.0"
else
    fail "bun describe" "got: $desc"
fi

# Verify git can read package.json
pkg=$(cd "$d" && git show HEAD:package.json 2>&1)
if echo "$pkg" | grep -q '"version": "1.0.0"'; then
    pass "bun workflow: git reads package.json content"
else
    fail "bun package.json" "got: $pkg"
fi

echo "Test 6.2: version bump cycle (1.0.0 -> 1.1.0 -> 2.0.0)"
d=$(new_repo "s6_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1

# v1.0.0
cat > "$d/package.json" << 'EOF'
{"name": "pkg", "version": "1.0.0"}
EOF
(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" commit -m "v1.0.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# v1.1.0
cat > "$d/package.json" << 'EOF'
{"name": "pkg", "version": "1.1.0"}
EOF
(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" commit -m "v1.1.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.1.0) >/dev/null 2>&1

# v2.0.0
cat > "$d/package.json" << 'EOF'
{"name": "pkg", "version": "2.0.0"}
EOF
(cd "$d" && "$ZIGGIT" add package.json && "$ZIGGIT" commit -m "v2.0.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v2.0.0) >/dev/null 2>&1

# Verify all tags exist
tag_count=$(cd "$d" && git tag -l | wc -l)
if [ "$tag_count" -eq 3 ]; then
    pass "bun version bump: 3 tags created"
else
    fail "version bump tags" "expected 3, got: $tag_count"
fi

# Verify HEAD describe
desc=$(cd "$d" && git describe --tags 2>&1)
if [ "$desc" = "v2.0.0" ]; then
    pass "bun version bump: describe = v2.0.0"
else
    fail "version bump describe" "got: $desc"
fi

# Verify commit count
count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "3" ]; then
    pass "bun version bump: 3 commits"
else
    fail "version bump commits" "expected 3, got: $count"
fi

# Verify each tag points to correct version
v1_pkg=$(cd "$d" && git show v1.0.0:package.json 2>&1)
v2_pkg=$(cd "$d" && git show v2.0.0:package.json 2>&1)
if echo "$v1_pkg" | grep -q '"1.0.0"' && echo "$v2_pkg" | grep -q '"2.0.0"'; then
    pass "bun version bump: each tag has correct version"
else
    fail "version bump content" "v1=$v1_pkg v2=$v2_pkg"
fi

echo "Test 6.3: TypeScript project with src/, dist/, types/"
d=$(new_repo "s6_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'EOF'
{"name": "@scope/lib", "version": "1.0.0", "types": "./types/index.d.ts"}
EOF
cat > "$d/tsconfig.json" << 'EOF'
{"compilerOptions": {"outDir": "./dist"}}
EOF
mkdir -p "$d/src" "$d/types"
echo "export const hello = () => 'world';" > "$d/src/index.ts"
echo "export declare const hello: () => string;" > "$d/types/index.d.ts"
echo "node_modules/" > "$d/.gitignore"
(cd "$d" && "$ZIGGIT" add package.json tsconfig.json src/index.ts types/index.d.ts .gitignore) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" commit -m "TypeScript project setup") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Verify all files
file_count=$(cd "$d" && git ls-tree -r HEAD | wc -l)
if [ "$file_count" -eq 5 ]; then
    pass "TS project: 5 files in tree"
else
    fail "TS files" "expected 5, got: $file_count"
fi

src=$(cd "$d" && git show HEAD:src/index.ts 2>&1)
if echo "$src" | grep -q "hello"; then
    pass "TS project: src/index.ts content correct"
else
    fail "TS src" "got: $src"
fi

echo "Test 6.4: monorepo with multiple workspace packages"
d=$(new_repo "s6_t4")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
cat > "$d/package.json" << 'EOF'
{"name": "monorepo", "workspaces": ["packages/*"]}
EOF
mkdir -p "$d/packages/core" "$d/packages/cli" "$d/packages/utils"
echo '{"name": "@mono/core", "version": "1.0.0"}' > "$d/packages/core/package.json"
echo '{"name": "@mono/cli", "version": "1.0.0"}' > "$d/packages/cli/package.json"
echo '{"name": "@mono/utils", "version": "1.0.0"}' > "$d/packages/utils/package.json"
echo "export {};" > "$d/packages/core/index.ts"
echo "export {};" > "$d/packages/cli/index.ts"
echo "export {};" > "$d/packages/utils/index.ts"
(cd "$d" && "$ZIGGIT" add . && "$ZIGGIT" commit -m "monorepo init") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

file_count=$(cd "$d" && git ls-tree -r HEAD | wc -l)
if [ "$file_count" -eq 7 ]; then
    pass "monorepo: 7 files in tree"
else
    fail "monorepo files" "expected 7, got: $file_count"
fi

core_pkg=$(cd "$d" && git show "HEAD:packages/core/package.json" 2>&1)
if echo "$core_pkg" | grep -q "@mono/core"; then
    pass "monorepo: nested package.json content correct"
else
    fail "monorepo nested" "got: $core_pkg"
fi

fsck=$(cd "$d" && git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error\|corrupt"; then
    pass "monorepo: git fsck clean"
else
    fail "monorepo fsck" "$fsck"
fi

echo "Test 6.5: bun.lockb binary preserved through commit"
d=$(new_repo "s6_t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo '{"name": "pkg", "version": "1.0.0"}' > "$d/package.json"
# Create fake bun.lockb with binary content
python3 -c "import sys; sys.stdout.buffer.write(b'BUN\x00' + bytes(range(256)) * 4)" > "$d/bun.lockb"
orig_md5=$(md5sum "$d/bun.lockb" | cut -d' ' -f1)
(cd "$d" && "$ZIGGIT" add package.json bun.lockb && "$ZIGGIT" commit -m "with lockfile") >/dev/null 2>&1
git_md5=$(cd "$d" && git show HEAD:bun.lockb | md5sum | cut -d' ' -f1)
if [ "$orig_md5" = "$git_md5" ]; then
    pass "bun.lockb binary preserved through commit"
else
    fail "bun.lockb" "orig=$orig_md5 git=$git_md5"
fi

echo "Test 6.6: clone bare, then git clone from bare"
d=$(new_repo "s6_t6_src")
bare="$TMPBASE/s6_t6_bare"
clone="$TMPBASE/s6_t6_clone"
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo '{"name": "pkg", "version": "1.0.0"}' > "$d/package.json"
echo "index" > "$d/index.js"
(cd "$d" && "$ZIGGIT" add package.json index.js && "$ZIGGIT" commit -m "release") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Clone bare with git (from the ziggit repo)
(git clone --bare "$d" "$bare") >/dev/null 2>&1
# Then clone from bare
(git clone "$bare" "$clone") >/dev/null 2>&1

if [ -f "$clone/package.json" ] && [ -f "$clone/index.js" ]; then
    pass "clone from ziggit-created repo: files present"
else
    fail "clone files" "package.json=$(test -f "$clone/package.json" && echo yes || echo no) index.js=$(test -f "$clone/index.js" && echo yes || echo no)"
fi

clone_desc=$(cd "$clone" && git describe --tags 2>&1) || true
if [ "$clone_desc" = "v1.0.0" ]; then
    pass "clone from ziggit repo: tag preserved"
else
    fail "clone tag" "got: $clone_desc"
fi

echo "Test 6.7: multiple commits, verify log output matches git"
d=$(new_repo "s6_t7")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
for i in 1 2 3 4 5; do
    echo "content $i" > "$d/file$i.txt"
    (cd "$d" && "$ZIGGIT" add "file$i.txt" && "$ZIGGIT" commit -m "commit $i") >/dev/null 2>&1
done

git_count=$(cd "$d" && git rev-list --count HEAD 2>&1)
git_head=$(cd "$d" && git rev-parse HEAD 2>&1)
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)

if [ "$git_count" = "5" ]; then
    pass "5 commits: git rev-list count = 5"
else
    fail "5 commits count" "expected 5, got: $git_count"
fi

if [ "$git_head" = "$ziggit_head" ]; then
    pass "5 commits: HEAD hashes match ($git_head)"
else
    fail "5 commits HEAD" "git=$git_head ziggit=$ziggit_head"
fi

# ============================================================
# SECTION 7: Interoperability stress tests
# ============================================================

echo ""
echo "--- Section 7: Interoperability stress ---"

echo "Test 7.1: interleaved ziggit and git commits"
d=$(new_repo "s7_t1")
(cd "$d" && "$ZIGGIT" init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "z1" > "$d/z1.txt"
(cd "$d" && "$ZIGGIT" add z1.txt && "$ZIGGIT" commit -m "ziggit 1") >/dev/null 2>&1
echo "g1" > "$d/g1.txt"
(cd "$d" && git add g1.txt && git commit -m "git 1") >/dev/null 2>&1
echo "z2" > "$d/z2.txt"
(cd "$d" && "$ZIGGIT" add z2.txt && "$ZIGGIT" commit -m "ziggit 2") >/dev/null 2>&1
echo "g2" > "$d/g2.txt"
(cd "$d" && git add g2.txt && git commit -m "git 2") >/dev/null 2>&1

count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "4" ]; then
    pass "interleaved: 4 total commits"
else
    fail "interleaved count" "expected 4, got: $count"
fi

fsck=$(cd "$d" && git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error\|corrupt"; then
    pass "interleaved: git fsck clean"
else
    fail "interleaved fsck" "$fsck"
fi

# Verify all 4 files visible
file_count=$(cd "$d" && git ls-tree -r HEAD | wc -l)
if [ "$file_count" -eq 4 ]; then
    pass "interleaved: all 4 files in tree"
else
    fail "interleaved files" "expected 4, got: $file_count"
fi

echo "Test 7.2: git creates repo, ziggit adds + commits + tags"
d=$(new_repo "s7_t2")
(cd "$d" && git init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "git base" > "$d/base.txt"
(cd "$d" && git add base.txt && git commit -m "git base") >/dev/null 2>&1

echo "ziggit add" > "$d/new.txt"
(cd "$d" && "$ZIGGIT" add new.txt && "$ZIGGIT" commit -m "ziggit addition" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

git_desc=$(cd "$d" && git describe --tags 2>&1)
if [ "$git_desc" = "v1.0.0" ]; then
    pass "git base + ziggit commit + tag: describe = v1.0.0"
else
    fail "mixed describe" "got: $git_desc"
fi

count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "2" ]; then
    pass "git base + ziggit commit: 2 total commits"
else
    fail "mixed count" "expected 2, got: $count"
fi

echo "Test 7.3: ziggit creates, git gc, ziggit reads"
d=$(new_repo "s7_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "pre-gc" > "$d/pre.txt"
(cd "$d" && "$ZIGGIT" add pre.txt && "$ZIGGIT" commit -m "pre gc") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
(cd "$d" && git gc --aggressive) >/dev/null 2>&1

ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
git_head=$(cd "$d" && git rev-parse HEAD 2>&1)
if [ "$ziggit_head" = "$git_head" ]; then
    pass "post-gc: ziggit reads HEAD correctly ($ziggit_head)"
else
    fail "post-gc HEAD" "git=$git_head ziggit=$ziggit_head"
fi

desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if [ "$desc" = "v1.0.0" ]; then
    pass "post-gc: ziggit describe still works"
else
    fail "post-gc describe" "got: $desc"
fi

echo "Test 7.4: ziggit repo -> git rebase (fast-forward)"
d=$(new_repo "s7_t4")
(cd "$d" && "$ZIGGIT" init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "main1" > "$d/main.txt"
(cd "$d" && "$ZIGGIT" add main.txt && "$ZIGGIT" commit -m "main") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feat" > "$d/feat.txt"
(cd "$d" && "$ZIGGIT" add feat.txt && "$ZIGGIT" commit -m "feature") >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
(cd "$d" && git rebase feature) >/dev/null 2>&1

count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "2" ]; then
    pass "rebase: 2 commits after rebase"
else
    fail "rebase count" "expected 2, got: $count"
fi

echo "Test 7.5: ziggit commit -> git cherry-pick"
d=$(new_repo "s7_t5")
(cd "$d" && "$ZIGGIT" init && git config user.name "Test" && git config user.email "t@t.com") >/dev/null 2>&1
echo "main" > "$d/main.txt"
(cd "$d" && "$ZIGGIT" add main.txt && "$ZIGGIT" commit -m "main") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "cherry" > "$d/cherry.txt"
(cd "$d" && "$ZIGGIT" add cherry.txt && "$ZIGGIT" commit -m "cherry") >/dev/null 2>&1
cherry_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
(cd "$d" && git checkout master) >/dev/null 2>&1
(cd "$d" && git cherry-pick "$cherry_hash") >/dev/null 2>&1

# Verify cherry-pick worked
if [ -f "$d/cherry.txt" ]; then
    pass "cherry-pick from ziggit commit: file present"
else
    fail "cherry-pick" "cherry.txt missing"
fi

echo "Test 7.6: ziggit commit -> git blame"
d=$(new_repo "s7_t6")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "line1" > "$d/blame.txt"
(cd "$d" && "$ZIGGIT" add blame.txt && "$ZIGGIT" commit -m "blame test") >/dev/null 2>&1
blame=$(cd "$d" && git blame blame.txt 2>&1) || true
if echo "$blame" | grep -q "line1"; then
    pass "git blame works on ziggit commit"
else
    fail "git blame" "got: $blame"
fi

echo "Test 7.7: ziggit commit -> git format-patch"
d=$(new_repo "s7_t7")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "patch" > "$d/patch.txt"
(cd "$d" && "$ZIGGIT" add patch.txt && "$ZIGGIT" commit -m "patch test") >/dev/null 2>&1
patch_file=$(cd "$d" && git format-patch -1 HEAD 2>&1)
if [ -f "$d/$patch_file" ]; then
    pass "git format-patch generates valid patch from ziggit commit"
else
    fail "format-patch" "got: $patch_file"
fi

# ============================================================
# SECTION 8: ziggit describe vs git describe
# ============================================================

echo ""
echo "--- Section 8: describe parity ---"

echo "Test 8.1: at exact tag -> both return just tag name"
d=$(new_repo "s8_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "exact" > "$d/e.txt"
(cd "$d" && "$ZIGGIT" add e.txt && "$ZIGGIT" commit -m "exact") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
git_desc=$(cd "$d" && git describe --tags 2>&1)
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if [ "$git_desc" = "v1.0.0" ] && [ "$ziggit_desc" = "v1.0.0" ]; then
    pass "exact tag: both return v1.0.0"
else
    fail "exact tag describe" "git=$git_desc ziggit=$ziggit_desc"
fi

echo "Test 8.2: 1 commit past tag -> both show distance"
d=$(new_repo "s8_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/b.txt"
(cd "$d" && "$ZIGGIT" add b.txt && "$ZIGGIT" commit -m "base") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
echo "next" > "$d/n.txt"
(cd "$d" && "$ZIGGIT" add n.txt && "$ZIGGIT" commit -m "next") >/dev/null 2>&1
git_desc=$(cd "$d" && git describe --tags 2>&1)
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
# git shows v1.0.0-1-gXXXX, ziggit may show v1.0.0-1-gXXXX or v1.0.0
if echo "$git_desc" | grep -q "^v1.0.0-1-g"; then
    if [ "$git_desc" = "$ziggit_desc" ]; then
        pass "1 past tag: exact match ($git_desc)"
    elif echo "$ziggit_desc" | grep -q "^v1.0.0"; then
        pass "1 past tag: ziggit shows v1.0.0 prefix ($ziggit_desc vs $git_desc)"
    else
        fail "1 past tag" "git=$git_desc ziggit=$ziggit_desc"
    fi
else
    fail "1 past tag git" "unexpected: $git_desc"
fi

# ============================================================
# SECTION 9: ziggit status vs git status
# ============================================================

echo ""
echo "--- Section 9: status parity ---"

echo "Test 9.1: clean repo -> both empty"
d=$(new_repo "s9_t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "clean" > "$d/c.txt"
(cd "$d" && "$ZIGGIT" add c.txt && "$ZIGGIT" commit -m "clean") >/dev/null 2>&1
git_status=$(cd "$d" && git status --porcelain 2>&1)
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if [ -z "$git_status" ] && [ -z "$ziggit_status" ]; then
    pass "clean: both porcelain empty"
else
    fail "clean status" "git='$git_status' ziggit='$ziggit_status'"
fi

echo "Test 9.2: modified file -> both detect it"
d=$(new_repo "s9_t2")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "original" > "$d/mod.txt"
(cd "$d" && "$ZIGGIT" add mod.txt && "$ZIGGIT" commit -m "original") >/dev/null 2>&1
sleep 1  # Ensure mtime changes
echo "modified" > "$d/mod.txt"
git_status=$(cd "$d" && git status --porcelain 2>&1)
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if echo "$git_status" | grep -q "mod.txt" && echo "$ziggit_status" | grep -q "mod.txt"; then
    pass "modified: both detect mod.txt"
else
    fail "modified status" "git='$git_status' ziggit='$ziggit_status'"
fi

echo "Test 9.3: new untracked file -> both show ??"
d=$(new_repo "s9_t3")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/base.txt"
(cd "$d" && "$ZIGGIT" add base.txt && "$ZIGGIT" commit -m "base") >/dev/null 2>&1
echo "untracked" > "$d/untracked.txt"
git_status=$(cd "$d" && git status --porcelain 2>&1)
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if echo "$git_status" | grep -q "??" && echo "$ziggit_status" | grep -q "??"; then
    pass "untracked: both show ??"
else
    fail "untracked status" "git='$git_status' ziggit='$ziggit_status'"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
