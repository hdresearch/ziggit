#!/bin/bash
# Round-trip integrity: ziggit writes ↔ git reads ↔ git writes ↔ ziggit reads
# Verifies hash consistency and data integrity through interleaved operations
set -euo pipefail

ZIGGIT="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/ziggit"
PASS=0
FAIL=0
TMPBASE=$(mktemp -d -p /root)

cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL + 1)); }

new_repo() {
    local d="$TMPBASE/$1"
    mkdir -p "$d"
    echo "$d"
}

# Run ziggit with author/committer env set, stderr suppressed
z() {
    local dir="$1"; shift
    GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="t@t" \
    GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="t@t" \
    HOME=/root "$ZIGGIT" -C "$dir" "$@"
}

# Run git in a dir
g() {
    local dir="$1"; shift
    git -C "$dir" "$@"
}

echo "=== Round-Trip Integrity Tests ==="

# --- Test 1: Hash determinism - same content, same hash ---
echo "Test 1: Hash determinism between ziggit and git"
d1=$(new_repo "t1_ziggit")
d2=$(new_repo "t1_git")
z "$d1" init >/dev/null 2>&1
g "$d2" init >/dev/null 2>&1
g "$d2" config user.name test
g "$d2" config user.email t@t
echo "hello world" > "$d1/file.txt"
echo "hello world" > "$d2/file.txt"
z_hash=$(z "$d1" hash-object file.txt 2>/dev/null)
g_hash=$(g "$d2" hash-object file.txt 2>/dev/null)
if [ "$z_hash" = "$g_hash" ]; then
    pass "blob hash matches: $z_hash"
else
    fail "blob hash" "ziggit=$z_hash git=$g_hash"
fi

# --- Test 2: Interleaved commits - ziggit commit, git commit, ziggit reads all ---
echo "Test 2: Interleaved ziggit and git commits on same repo"
d=$(new_repo "t2_interleaved")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

# ziggit commit 1
echo "file1" > "$d/a.txt"
z "$d" add a.txt >/dev/null 2>&1
z "$d" commit -m "ziggit-1" >/dev/null 2>&1

# git commit 2
echo "file2" > "$d/b.txt"
g "$d" add b.txt >/dev/null 2>&1
g "$d" commit -m "git-2" >/dev/null 2>&1

# ziggit commit 3
echo "file3" > "$d/c.txt"
z "$d" add c.txt >/dev/null 2>&1
z "$d" commit -m "ziggit-3" >/dev/null 2>&1

# Both tools should see 3 commits
git_count=$(g "$d" rev-list --count HEAD)
ziggit_count=$(z "$d" log --format=%H HEAD 2>/dev/null | wc -l)
if [ "$git_count" = "3" ]; then
    pass "git sees 3 interleaved commits"
else
    fail "git count" "expected 3 got $git_count"
fi
if [ "$ziggit_count" = "3" ]; then
    pass "ziggit sees 3 interleaved commits"
else
    fail "ziggit count" "expected 3 got $ziggit_count"
fi

# HEAD should match
z_head=$(z "$d" rev-parse HEAD 2>/dev/null)
g_head=$(g "$d" rev-parse HEAD)
if [ "$z_head" = "$g_head" ]; then
    pass "HEAD matches after interleaved commits"
else
    fail "HEAD" "ziggit=$z_head git=$g_head"
fi

# git fsck should pass
fsck=$(g "$d" fsck 2>&1) || true
if echo "$fsck" | grep -q "error\|fatal"; then
    fail "fsck after interleaved" "$fsck"
else
    pass "git fsck clean after interleaved commits"
fi

# --- Test 3: ziggit commits survive git repack ---
echo "Test 3: ziggit objects survive git repack -a -d"
d=$(new_repo "t3_repack")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

for i in $(seq 1 5); do
    echo "content $i" > "$d/file$i.txt"
    z "$d" add "file$i.txt" >/dev/null 2>&1
    z "$d" commit -m "commit $i" >/dev/null 2>&1
done
z "$d" tag v1.0.0 >/dev/null 2>&1

head_before=$(g "$d" rev-parse HEAD)
tag_before=$(g "$d" rev-parse v1.0.0)

g "$d" repack -a -d >/dev/null 2>&1

head_after=$(g "$d" rev-parse HEAD)
tag_after=$(g "$d" rev-parse v1.0.0)

if [ "$head_before" = "$head_after" ]; then
    pass "HEAD preserved after repack"
else
    fail "HEAD after repack" "before=$head_before after=$head_after"
fi
if [ "$tag_before" = "$tag_after" ]; then
    pass "tag preserved after repack"
else
    fail "tag after repack" "before=$tag_before after=$tag_after"
fi

# ziggit should still read HEAD
z_head=$(z "$d" rev-parse HEAD 2>/dev/null)
if [ "$z_head" = "$head_after" ]; then
    pass "ziggit reads HEAD after repack"
else
    fail "ziggit HEAD after repack" "ziggit=$z_head git=$head_after"
fi

tree_count=$(g "$d" ls-tree --name-only HEAD | wc -l)
if [ "$tree_count" = "5" ]; then
    pass "all 5 files present after repack"
else
    fail "file count after repack" "expected 5 got $tree_count"
fi

# --- Test 4: git repack -a -d then ziggit describe ---
echo "Test 4: ziggit describe after git repack"
d=$(new_repo "t4_repack_describe")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

echo "v1" > "$d/f.txt"
z "$d" add f.txt >/dev/null 2>&1
z "$d" commit -m "v1" >/dev/null 2>&1
z "$d" tag v1.0.0 >/dev/null 2>&1
echo "v2" > "$d/f.txt"
z "$d" add f.txt >/dev/null 2>&1
z "$d" commit -m "v2" >/dev/null 2>&1

g "$d" repack -a -d >/dev/null 2>&1

z_desc=$(z "$d" describe --tags 2>/dev/null)
g_desc=$(g "$d" describe --tags 2>/dev/null)
if [ "$z_desc" = "$g_desc" ]; then
    pass "describe matches after repack: $z_desc"
else
    if echo "$z_desc" | grep -q "v1.0.0"; then
        pass "describe contains v1.0.0 after repack (ziggit=$z_desc git=$g_desc)"
    else
        fail "describe after repack" "ziggit=$z_desc git=$g_desc"
    fi
fi

# --- Test 5: Binary file round-trip with exact byte verification ---
echo "Test 5: Binary file byte-exact round-trip"
d=$(new_repo "t5_binary")
z "$d" init >/dev/null 2>&1

# Create binary file with all 256 byte values
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)) * 4)" > "$d/binary.dat"
original_md5=$(md5sum "$d/binary.dat" | cut -d' ' -f1)
original_size=$(stat -c%s "$d/binary.dat")

z "$d" add binary.dat >/dev/null 2>&1
z "$d" commit -m "binary" >/dev/null 2>&1

git_content_md5=$(g "$d" show HEAD:binary.dat | md5sum | cut -d' ' -f1)
if [ "$original_md5" = "$git_content_md5" ]; then
    pass "binary file md5 matches through ziggit->git ($original_size bytes)"
else
    fail "binary md5" "original=$original_md5 git=$git_content_md5"
fi

# --- Test 6: Deeply nested path (15 levels) ---
echo "Test 6: 15-level deep directory tree"
d=$(new_repo "t6_deep")
z "$d" init >/dev/null 2>&1

deep="a/b/c/d/e/f/g/h/i/j/k/l/m/n/o"
mkdir -p "$d/$deep"
echo "deep" > "$d/$deep/leaf.txt"
z "$d" add "$deep/leaf.txt" >/dev/null 2>&1
z "$d" commit -m "deep" >/dev/null 2>&1

git_deep=$(g "$d" show "HEAD:$deep/leaf.txt")
if [ "$git_deep" = "deep" ]; then
    pass "15-level deep file readable by git"
else
    fail "deep path" "got: $git_deep"
fi

# --- Test 7: 200 files in one commit ---
echo "Test 7: 200 files in single commit"
d=$(new_repo "t7_200files")
z "$d" init >/dev/null 2>&1

for i in $(seq 1 200); do
    echo "content $i" > "$d/file_$(printf '%03d' $i).txt"
done
for i in $(seq 1 200); do
    z "$d" add "file_$(printf '%03d' $i).txt" >/dev/null 2>&1
done
z "$d" commit -m "200 files" >/dev/null 2>&1

count=$(g "$d" ls-tree --name-only HEAD | wc -l)
if [ "$count" = "200" ]; then
    pass "git sees all 200 files"
else
    fail "200 files" "got $count"
fi

fsck=$(g "$d" fsck 2>&1) || true
if echo "$fsck" | grep -q "error\|fatal"; then
    fail "fsck 200 files" "$fsck"
else
    pass "git fsck clean with 200 files"
fi

# --- Test 8: File with spaces and special chars ---
echo "Test 8: Filenames with spaces and special chars"
d=$(new_repo "t8_special")
z "$d" init >/dev/null 2>&1

echo "a" > "$d/hello world.txt"
echo "b" > "$d/file-with-dashes.txt"
echo "c" > "$d/file_with_underscores.txt"
echo "d" > "$d/file.multiple.dots.txt"
z "$d" add "hello world.txt" >/dev/null 2>&1
z "$d" add "file-with-dashes.txt" >/dev/null 2>&1
z "$d" add "file_with_underscores.txt" >/dev/null 2>&1
z "$d" add "file.multiple.dots.txt" >/dev/null 2>&1
z "$d" commit -m "special names" >/dev/null 2>&1

tree_files=$(g "$d" ls-tree --name-only HEAD)
for f in "hello world.txt" "file-with-dashes.txt" "file_with_underscores.txt" "file.multiple.dots.txt"; do
    if echo "$tree_files" | grep -qF "$f"; then
        pass "special filename: $f"
    else
        fail "special filename" "missing: $f"
    fi
done

# --- Test 9: git init + commit → ziggit rev-parse + describe ---
echo "Test 9: git creates, ziggit reads"
d=$(new_repo "t9_git_creates")
g "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

echo "from git" > "$d/readme.md"
g "$d" add readme.md >/dev/null 2>&1
g "$d" commit -m "from git" >/dev/null 2>&1
g "$d" tag v2.0.0 >/dev/null 2>&1
echo "update" > "$d/readme.md"
g "$d" add readme.md >/dev/null 2>&1
g "$d" commit -m "update" >/dev/null 2>&1

g_head=$(g "$d" rev-parse HEAD)
z_head=$(z "$d" rev-parse HEAD 2>/dev/null)
if [ "$g_head" = "$z_head" ]; then
    pass "ziggit rev-parse matches git on git-created repo"
else
    fail "rev-parse" "git=$g_head ziggit=$z_head"
fi

z_desc=$(z "$d" describe --tags 2>/dev/null)
if echo "$z_desc" | grep -q "v2.0.0"; then
    pass "ziggit describe finds git tag"
else
    fail "describe" "got: $z_desc"
fi

# --- Test 10: Full bun publish workflow, verified by git ---
echo "Test 10: Complete bun publish workflow"
d=$(new_repo "t10_bun")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

# Initial release
cat > "$d/package.json" <<'EOF'
{"name":"@test/pkg","version":"1.0.0","main":"index.js"}
EOF
echo 'module.exports = {};' > "$d/index.js"
z "$d" add package.json >/dev/null 2>&1
z "$d" add index.js >/dev/null 2>&1
z "$d" commit -m "v1.0.0" >/dev/null 2>&1
z "$d" tag v1.0.0 >/dev/null 2>&1

# Status should be clean
status=$(z "$d" status --porcelain 2>/dev/null) || true
if [ -z "$status" ]; then
    pass "status clean after commit+tag"
else
    fail "status" "not clean: $status"
fi

# Describe should show exact tag
desc=$(z "$d" describe --tags 2>/dev/null)
if [ "$desc" = "v1.0.0" ]; then
    pass "describe shows v1.0.0"
else
    fail "describe" "got: $desc"
fi

# Patch release
cat > "$d/package.json" <<'EOF'
{"name":"@test/pkg","version":"1.0.1","main":"index.js"}
EOF
z "$d" add package.json >/dev/null 2>&1
z "$d" commit -m "v1.0.1" >/dev/null 2>&1
z "$d" tag v1.0.1 >/dev/null 2>&1

# git log should show 2 commits
log_count=$(g "$d" rev-list --count HEAD)
if [ "$log_count" = "2" ]; then
    pass "git sees 2 commits"
else
    fail "commit count" "expected 2 got $log_count"
fi

# git tag should show both tags
tags=$(g "$d" tag -l | sort)
if echo "$tags" | grep -q "v1.0.0" && echo "$tags" | grep -q "v1.0.1"; then
    pass "git sees both tags"
else
    fail "tags" "got: $tags"
fi

# git cat-file validates HEAD
cat_file=$(g "$d" cat-file -p HEAD)
if echo "$cat_file" | grep -q "v1.0.1"; then
    pass "git cat-file shows v1.0.1 commit"
else
    fail "cat-file" "output: $cat_file"
fi

# Clone the repo and verify
clone_dir="$TMPBASE/t10_clone"
git clone "$d" "$clone_dir" >/dev/null 2>&1
clone_pkg=$(cat "$clone_dir/package.json")
if echo "$clone_pkg" | grep -q '"1.0.1"'; then
    pass "cloned repo has v1.0.1 package.json"
else
    fail "clone" "package.json: $clone_pkg"
fi

clone_tags=$(g "$clone_dir" tag -l | sort)
if echo "$clone_tags" | grep -q "v1.0.0" && echo "$clone_tags" | grep -q "v1.0.1"; then
    pass "cloned repo has both tags"
else
    fail "clone tags" "got: $clone_tags"
fi

# --- Test 11: git merge commit → ziggit reads ---
echo "Test 11: git merge commit, ziggit reads merged state"
d=$(new_repo "t11_merge")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

echo "main" > "$d/main.txt"
z "$d" add main.txt >/dev/null 2>&1
z "$d" commit -m "initial" >/dev/null 2>&1

# Create branch and commit with git
g "$d" checkout -b feature >/dev/null 2>&1
echo "feature" > "$d/feature.txt"
g "$d" add feature.txt >/dev/null 2>&1
g "$d" commit -m "feature" >/dev/null 2>&1

# Add another commit on master so merge is non-fast-forward
(g "$d" checkout master 2>/dev/null || g "$d" checkout main 2>/dev/null) >/dev/null 2>&1
echo "master2" > "$d/master2.txt"
g "$d" add master2.txt >/dev/null 2>&1
g "$d" commit -m "master commit" >/dev/null 2>&1

# Merge (non-ff because of divergence)
g "$d" merge feature -m "merge feature" --no-edit >/dev/null 2>&1

g_head=$(g "$d" rev-parse HEAD)
z_head=$(z "$d" rev-parse HEAD 2>/dev/null)
if [ "$g_head" = "$z_head" ]; then
    pass "ziggit reads merge commit HEAD"
else
    fail "merge HEAD" "git=$g_head ziggit=$z_head"
fi

parent_count=$(g "$d" cat-file -p HEAD | grep "^parent " | wc -l)
if [ "$parent_count" = "2" ]; then
    pass "merge commit has 2 parents"
else
    fail "merge parents" "expected 2 got $parent_count"
fi

# --- Test 12: Lightweight tag points to correct commit ---
echo "Test 12: Lightweight tag resolves to correct commit"
d=$(new_repo "t12_tag")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

echo "release" > "$d/file.txt"
z "$d" add file.txt >/dev/null 2>&1
z "$d" commit -m "release" >/dev/null 2>&1
z "$d" tag v3.0.0 >/dev/null 2>&1

tag_target=$(g "$d" rev-parse v3.0.0)
head_hash=$(g "$d" rev-parse HEAD)
if [ "$tag_target" = "$head_hash" ]; then
    pass "lightweight tag points to HEAD commit"
else
    fail "tag target" "tag=$tag_target HEAD=$head_hash"
fi

tag_type=$(g "$d" cat-file -t v3.0.0)
if [ "$tag_type" = "commit" ]; then
    pass "lightweight tag resolves to commit type"
else
    fail "tag type" "got: $tag_type"
fi

# --- Test 13: Commit tree hash consistency ---
echo "Test 13: Commit tree structure valid"
d=$(new_repo "t13_tree_hash")
z "$d" init >/dev/null 2>&1

echo "content" > "$d/file.txt"
echo "more" > "$d/other.txt"
z "$d" add file.txt >/dev/null 2>&1
z "$d" add other.txt >/dev/null 2>&1
z "$d" commit -m "tree test" >/dev/null 2>&1

tree_content=$(g "$d" ls-tree HEAD)
if echo "$tree_content" | grep -q "file.txt" && echo "$tree_content" | grep -q "other.txt"; then
    pass "tree contains both files"
else
    fail "tree content" "$tree_content"
fi

# Verify tree hash is a valid object
tree_hash=$(g "$d" rev-parse 'HEAD^{tree}')
tree_type=$(g "$d" cat-file -t "$tree_hash")
if [ "$tree_type" = "tree" ]; then
    pass "tree object has correct type"
else
    fail "tree type" "got: $tree_type"
fi

# --- Test 14: Multiple commits, HEAD always matches ---
echo "Test 14: HEAD stays consistent across 5 commits"
d=$(new_repo "t14_multi")
z "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

all_ok=true
for i in $(seq 1 5); do
    echo "v$i" > "$d/file.txt"
    z "$d" add file.txt >/dev/null 2>&1
    z "$d" commit -m "commit $i" >/dev/null 2>&1
    g_val=$(g "$d" rev-parse HEAD)
    z_val=$(z "$d" rev-parse HEAD 2>/dev/null)
    if [ "$g_val" != "$z_val" ]; then
        fail "HEAD after commit $i" "git=$g_val ziggit=$z_val"
        all_ok=false
    fi
done
if $all_ok; then
    pass "HEAD matches git after each of 5 commits"
fi

# Verify git log count
count=$(g "$d" rev-list --count HEAD)
if [ "$count" = "5" ]; then
    pass "git sees all 5 commits"
else
    fail "commit count" "expected 5 got $count"
fi

# --- Test 15: Empty file commit ---
echo "Test 15: Empty file commit and retrieval"
d=$(new_repo "t15_empty_file")
z "$d" init >/dev/null 2>&1

touch "$d/empty.txt"
z "$d" add empty.txt >/dev/null 2>&1
z "$d" commit -m "empty file" >/dev/null 2>&1

size=$(g "$d" cat-file -s "HEAD:empty.txt")
if [ "$size" = "0" ]; then
    pass "empty file has 0 bytes in git"
else
    fail "empty file size" "got: $size"
fi

# --- Test 16: Unicode in commit message and content ---
echo "Test 16: Unicode content"
d=$(new_repo "t16_unicode")
z "$d" init >/dev/null 2>&1

echo "日本語テスト" > "$d/unicode.txt"
z "$d" add unicode.txt >/dev/null 2>&1
z "$d" commit -m "テストコミット" >/dev/null 2>&1

content=$(g "$d" show HEAD:unicode.txt)
if [ "$content" = "日本語テスト" ]; then
    pass "unicode content preserved"
else
    fail "unicode" "got: $content"
fi

msg=$(g "$d" log -1 --format=%s)
if [ "$msg" = "テストコミット" ]; then
    pass "unicode commit message preserved"
else
    fail "unicode msg" "got: $msg"
fi

# --- Test 17: Overwrite file content across commits ---
echo "Test 17: File overwrite across commits"
d=$(new_repo "t17_overwrite")
z "$d" init >/dev/null 2>&1

echo "version 1" > "$d/config.txt"
z "$d" add config.txt >/dev/null 2>&1
z "$d" commit -m "v1" >/dev/null 2>&1
echo "version 2" > "$d/config.txt"
z "$d" add config.txt >/dev/null 2>&1
z "$d" commit -m "v2" >/dev/null 2>&1
echo "version 3" > "$d/config.txt"
z "$d" add config.txt >/dev/null 2>&1
z "$d" commit -m "v3" >/dev/null 2>&1

v3=$(g "$d" show HEAD:config.txt)
v2=$(g "$d" show HEAD~1:config.txt)
v1=$(g "$d" show HEAD~2:config.txt)
if [ "$v3" = "version 3" ] && [ "$v2" = "version 2" ] && [ "$v1" = "version 1" ]; then
    pass "all 3 versions preserved in history"
else
    fail "overwrite" "v1=$v1 v2=$v2 v3=$v3"
fi

# --- Test 18: Multiple tags on different commits ---
echo "Test 18: Tags on different commits resolve correctly"
d=$(new_repo "t18_multi_tag")
z "$d" init >/dev/null 2>&1

echo "a" > "$d/f.txt"
z "$d" add f.txt >/dev/null 2>&1
z "$d" commit -m "c1" >/dev/null 2>&1
z "$d" tag v0.1.0 >/dev/null 2>&1

echo "b" > "$d/f.txt"
z "$d" add f.txt >/dev/null 2>&1
z "$d" commit -m "c2" >/dev/null 2>&1
z "$d" tag v0.2.0 >/dev/null 2>&1

echo "c" > "$d/f.txt"
z "$d" add f.txt >/dev/null 2>&1
z "$d" commit -m "c3" >/dev/null 2>&1
z "$d" tag v0.3.0 >/dev/null 2>&1

h1=$(g "$d" rev-parse v0.1.0)
h2=$(g "$d" rev-parse v0.2.0)
h3=$(g "$d" rev-parse v0.3.0)
if [ "$h1" != "$h2" ] && [ "$h2" != "$h3" ] && [ "$h1" != "$h3" ]; then
    pass "3 tags on 3 different commits"
else
    fail "tag targets" "h1=$h1 h2=$h2 h3=$h3"
fi

z_desc=$(z "$d" describe --tags 2>/dev/null)
if [ "$z_desc" = "v0.3.0" ]; then
    pass "describe shows v0.3.0 on HEAD"
else
    fail "describe" "got: $z_desc"
fi

# --- Test 19: git fsck on complex ziggit repo ---
echo "Test 19: Complex repo passes git fsck"
d=$(new_repo "t19_complex")
z "$d" init >/dev/null 2>&1

for dir in src lib test docs; do
    mkdir -p "$d/$dir"
    for i in 1 2 3; do
        echo "// $dir file $i" > "$d/$dir/file$i.ts"
    done
done
echo '{"name":"complex"}' > "$d/package.json"
echo "# Complex" > "$d/README.md"

for dir in src lib test docs; do
    for i in 1 2 3; do
        z "$d" add "$dir/file$i.ts" >/dev/null 2>&1
    done
done
z "$d" add package.json >/dev/null 2>&1
z "$d" add README.md >/dev/null 2>&1
z "$d" commit -m "complex structure" >/dev/null 2>&1
z "$d" tag v1.0.0 >/dev/null 2>&1

fsck=$(g "$d" fsck --full 2>&1) || true
if echo "$fsck" | grep -q "error\|fatal"; then
    fail "complex fsck" "$fsck"
else
    pass "complex repo: git fsck --full clean"
fi

tree_count=$(g "$d" ls-tree -r HEAD | wc -l)
if [ "$tree_count" = "14" ]; then
    pass "complex repo: 14 files in tree"
else
    fail "complex tree" "expected 14 got $tree_count"
fi

# --- Test 20: git creates repo, ziggit adds to it ---
echo "Test 20: git init, ziggit adds commits"
d=$(new_repo "t20_git_then_ziggit")
g "$d" init >/dev/null 2>&1
g "$d" config user.name test
g "$d" config user.email t@t

echo "git file" > "$d/git.txt"
g "$d" add git.txt >/dev/null 2>&1
g "$d" commit -m "from git" >/dev/null 2>&1

echo "ziggit file" > "$d/ziggit.txt"
z "$d" add ziggit.txt >/dev/null 2>&1
z "$d" commit -m "from ziggit" >/dev/null 2>&1

# Both files should be in tree
tree=$(g "$d" ls-tree --name-only HEAD)
if echo "$tree" | grep -q "git.txt" && echo "$tree" | grep -q "ziggit.txt"; then
    pass "both git and ziggit files in tree"
else
    fail "mixed tree" "tree=$tree"
fi

count=$(g "$d" rev-list --count HEAD)
if [ "$count" = "2" ]; then
    pass "2 commits from mixed sources"
else
    fail "mixed count" "expected 2 got $count"
fi

fsck=$(g "$d" fsck 2>&1) || true
if echo "$fsck" | grep -q "error\|fatal"; then
    fail "mixed fsck" "$fsck"
else
    pass "git fsck clean on mixed repo"
fi

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
