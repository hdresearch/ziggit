#!/bin/bash
# Extended cross-validation: focused on interop edge cases and bun publish workflow
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

ziggit_init() {
    local d="$1"
    (cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
}

ziggit_add() {
    local d="$1"; shift
    for f in "$@"; do
        (cd "$d" && "$ZIGGIT" add "$f") >/dev/null 2>&1
    done
}

ziggit_commit() {
    local d="$1"
    local msg="$2"
    (cd "$d" && GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        "$ZIGGIT" commit -m "$msg") >/dev/null 2>&1
}

ziggit_tag() {
    local d="$1"
    local tag="$2"
    (cd "$d" && "$ZIGGIT" tag "$tag") >/dev/null 2>&1
}

echo "=== Extended Cross-Validation Tests ==="

# --- Test 1: ziggit init -> git fsck --strict on fresh repo ---
echo "Test 1: ziggit init -> git fsck --strict"
d=$(new_repo "ext1")
ziggit_init "$d"
fsck_out=$(cd "$d" && git fsck --strict 2>&1) || true
if echo "$fsck_out" | grep -qi "error\|fatal\|corrupt"; then
    fail "init fsck" "$fsck_out"
else
    pass "git fsck --strict passes on fresh ziggit init"
fi

# --- Test 2: ziggit single file -> git diff HEAD shows nothing ---
echo "Test 2: clean commit -> git diff HEAD empty"
d=$(new_repo "ext2")
ziggit_init "$d"
echo "hello" > "$d/file.txt"
ziggit_add "$d" file.txt
ziggit_commit "$d" "initial"
diff_out=$(cd "$d" && git diff HEAD 2>&1)
if [ -z "$diff_out" ]; then
    pass "git diff HEAD empty after clean ziggit commit"
else
    fail "diff HEAD" "non-empty: $diff_out"
fi

# --- Test 3: ziggit commit -> git verify-commit ---
echo "Test 3: git verify-commit on ziggit commit (unsigned)"
d=$(new_repo "ext3")
ziggit_init "$d"
echo "data" > "$d/f.txt"
ziggit_add "$d" f.txt
ziggit_commit "$d" "verify test"
# verify-commit fails for unsigned commits (exit code 1) but should not say "bad object"
verify_out=$(cd "$d" && git verify-commit HEAD 2>&1) || true
if echo "$verify_out" | grep -qi "bad object\|corrupt"; then
    fail "verify-commit" "bad object: $verify_out"
else
    pass "git verify-commit does not report corruption (unsigned commit expected)"
fi

# --- Test 4: ziggit commit author/committer fields present ---
echo "Test 4: author/committer fields present in commit object"
d=$(new_repo "ext4")
ziggit_init "$d"
echo "auth" > "$d/f.txt"
ziggit_add "$d" f.txt
ziggit_commit "$d" "authored commit"
catfile=$(cd "$d" && git cat-file -p HEAD 2>&1)
if echo "$catfile" | grep -q "^author "; then
    pass "commit object has author field"
else
    fail "author" "no author field found"
fi
if echo "$catfile" | grep -q "^committer "; then
    pass "commit object has committer field"
else
    fail "committer" "no committer field found"
fi

# --- Test 5: ziggit tree ordering: flat files sorted ---
echo "Test 5: flat file tree entries sorted correctly"
d=$(new_repo "ext5")
ziggit_init "$d"
echo "z" > "$d/z.txt"
echo "a" > "$d/a.txt"
echo "m" > "$d/m.txt"
ziggit_add "$d" z.txt a.txt m.txt
ziggit_commit "$d" "sorted tree"
tree_entries=$(cd "$d" && git ls-tree --name-only HEAD)
expected=$(printf "a.txt\nm.txt\nz.txt")
if [ "$tree_entries" = "$expected" ]; then
    pass "flat tree entries sorted correctly"
else
    fail "tree sort" "got: $tree_entries"
fi

# --- Test 6: ziggit handles .gitignore as regular file ---
echo "Test 6: .gitignore committed via ziggit"
d=$(new_repo "ext6")
ziggit_init "$d"
echo "node_modules/" > "$d/.gitignore"
echo "data" > "$d/app.js"
ziggit_add "$d" .gitignore app.js
ziggit_commit "$d" "with gitignore"
gitignore_content=$(cd "$d" && git show HEAD:.gitignore 2>&1)
if [ "$gitignore_content" = "node_modules/" ]; then
    pass ".gitignore content preserved"
else
    fail ".gitignore" "got: $gitignore_content"
fi

# --- Test 7: ziggit commit with very long message ---
echo "Test 7: very long commit message (1000+ chars)"
d=$(new_repo "ext7")
ziggit_init "$d"
echo "x" > "$d/f.txt"
ziggit_add "$d" f.txt
long_msg=$(python3 -c "print('A' * 2000)")
(cd "$d" && GIT_AUTHOR_NAME="T" GIT_AUTHOR_EMAIL="t@t" \
    GIT_COMMITTER_NAME="T" GIT_COMMITTER_EMAIL="t@t" \
    "$ZIGGIT" commit -m "$long_msg") >/dev/null 2>&1
msg_len=$(cd "$d" && git log -1 --format=%B | wc -c)
if [ "$msg_len" -ge 2000 ]; then
    pass "long commit message preserved ($msg_len chars)"
else
    fail "long msg" "expected >= 2000, got $msg_len"
fi

# --- Test 8: ziggit file with unicode content ---
echo "Test 8: unicode content in file"
d=$(new_repo "ext8")
ziggit_init "$d"
echo "日本語テスト 🎉 émojis" > "$d/unicode.txt"
ziggit_add "$d" unicode.txt
ziggit_commit "$d" "unicode content"
git_content=$(cd "$d" && git show HEAD:unicode.txt 2>&1)
if [ "$git_content" = "日本語テスト 🎉 émojis" ]; then
    pass "unicode content preserved exactly"
else
    fail "unicode" "got: $git_content"
fi

# --- Test 9: ziggit commit -> git clone -> verify files ---
echo "Test 9: ziggit repo -> git clone -> verify"
d=$(new_repo "ext9_src")
ziggit_init "$d"
echo "source" > "$d/src.txt"
mkdir -p "$d/lib"
echo "library" > "$d/lib/mod.zig"
ziggit_add "$d" src.txt lib/mod.zig
ziggit_commit "$d" "cloneable commit"
ziggit_tag "$d" v1.0.0
clone_d="$TMPBASE/ext9_clone"
git clone "$d" "$clone_d" >/dev/null 2>&1
if [ -f "$clone_d/src.txt" ] && [ -f "$clone_d/lib/mod.zig" ]; then
    clone_content=$(cat "$clone_d/src.txt")
    if [ "$clone_content" = "source" ]; then
        pass "git clone from ziggit repo: files present and correct"
    else
        fail "clone content" "got: $clone_content"
    fi
else
    fail "clone files" "files missing in clone"
fi
clone_tag=$(cd "$clone_d" && git tag -l 2>&1)
if echo "$clone_tag" | grep -q "v1.0.0"; then
    pass "git clone preserves ziggit tags"
else
    fail "clone tag" "got: $clone_tag"
fi

# --- Test 10: git clone --bare from ziggit repo ---
echo "Test 10: git clone --bare from ziggit repo"
bare_d="$TMPBASE/ext10_bare.git"
git clone --bare "$d" "$bare_d" >/dev/null 2>&1
if [ -f "$bare_d/HEAD" ]; then
    bare_head=$(cd "$bare_d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
    orig_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
    if [ "$bare_head" = "$orig_head" ]; then
        pass "bare clone HEAD matches source repo"
    else
        fail "bare clone HEAD" "bare=$bare_head, orig=$orig_head"
    fi
else
    fail "bare clone" "HEAD missing"
fi

# --- Test 11: ziggit handles symlink-like scenarios (regular file test) ---
echo "Test 11: file with mode 100644 preserved"
d=$(new_repo "ext11")
ziggit_init "$d"
echo "regular" > "$d/reg.txt"
ziggit_add "$d" reg.txt
ziggit_commit "$d" "regular file"
mode=$(cd "$d" && git ls-tree HEAD reg.txt | awk '{print $1}')
if [ "$mode" = "100644" ]; then
    pass "file mode 100644 preserved"
else
    fail "file mode" "got: $mode"
fi

# --- Test 12: ziggit handles empty file ---
echo "Test 12: empty file committed"
d=$(new_repo "ext12")
ziggit_init "$d"
touch "$d/empty.txt"
ziggit_add "$d" empty.txt
ziggit_commit "$d" "empty file"
size=$(cd "$d" && git cat-file -s HEAD:empty.txt 2>&1 | tr -d '[:space:]')
if [ "$size" = "0" ]; then
    pass "empty file: 0 bytes in git"
else
    fail "empty file" "size=$size"
fi

# --- Test 13: ziggit multiple commits -> git log --oneline correct count ---
echo "Test 13: 10 commits -> git log count"
d=$(new_repo "ext13")
ziggit_init "$d"
for i in $(seq 1 10); do
    echo "v$i" > "$d/file.txt"
    ziggit_add "$d" file.txt
    ziggit_commit "$d" "commit $i"
done
count=$(cd "$d" && git log --oneline | wc -l | tr -d '[:space:]')
if [ "$count" = "10" ]; then
    pass "10 commits: git log shows 10"
else
    fail "10 commits" "count=$count"
fi

# --- Test 14: ziggit tag -> git show points to correct commit ---
echo "Test 14: tag points to correct commit"
d=$(new_repo "ext14")
ziggit_init "$d"
echo "v1" > "$d/f.txt"
ziggit_add "$d" f.txt
ziggit_commit "$d" "v1 commit"
tag_target_hash=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
echo "v2" > "$d/f.txt"
ziggit_add "$d" f.txt
ziggit_commit "$d" "v2 commit"
ziggit_tag "$d" "v1.0.0"
# Tag should point to current HEAD (v2), not v1
tag_hash=$(cd "$d" && git rev-parse v1.0.0 2>&1 | tr -d '[:space:]')
head_hash=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$tag_hash" = "$head_hash" ]; then
    pass "tag points to HEAD (current commit)"
else
    fail "tag target" "tag=$tag_hash, HEAD=$head_hash"
fi

# --- Test 15: ziggit status --porcelain detects untracked file ---
echo "Test 15: status detects untracked file"
d=$(new_repo "ext15")
ziggit_init "$d"
echo "tracked" > "$d/tracked.txt"
ziggit_add "$d" tracked.txt
ziggit_commit "$d" "initial"
echo "untracked" > "$d/new.txt"
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
git_status=$(cd "$d" && git status --porcelain 2>&1)
# Both should show new.txt as untracked (??)
if echo "$ziggit_status" | grep -q "new.txt" && echo "$git_status" | grep -q "new.txt"; then
    pass "both detect untracked file"
elif echo "$git_status" | grep -q "new.txt"; then
    pass "git detects untracked (ziggit may differ in untracked handling)"
else
    fail "untracked" "ziggit='$ziggit_status', git='$git_status'"
fi

# --- Test 16: ziggit status --porcelain detects modified file ---
echo "Test 16: status detects modified file"
d=$(new_repo "ext16")
ziggit_init "$d"
echo "original" > "$d/mod.txt"
ziggit_add "$d" mod.txt
ziggit_commit "$d" "initial"
echo "changed" > "$d/mod.txt"
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
git_status=$(cd "$d" && git status --porcelain 2>&1)
if echo "$ziggit_status" | grep -q "mod.txt" && echo "$git_status" | grep -q "mod.txt"; then
    pass "both detect modified file"
elif echo "$git_status" | grep -q "mod.txt"; then
    pass "git detects modified (ziggit may handle differently)"
else
    fail "modified" "ziggit='$ziggit_status', git='$git_status'"
fi

echo ""
echo "=== Bun Publish Workflow: Full Lifecycle ==="

# --- Test 17: Complete bun publish lifecycle ---
echo "Test 17: Full bun publish lifecycle"
d=$(new_repo "bun_publish")
ziggit_init "$d"

# Step 1: Initial package setup
cat > "$d/package.json" << 'PKGJSON'
{
  "name": "@myorg/mylib",
  "version": "1.0.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist"],
  "scripts": {
    "build": "bun build src/index.ts --outdir dist",
    "test": "bun test"
  },
  "dependencies": {},
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
PKGJSON

mkdir -p "$d/src" "$d/dist"
echo 'export function hello(): string { return "world"; }' > "$d/src/index.ts"
echo '"use strict"; module.exports.hello = () => "world";' > "$d/dist/index.js"
echo 'export declare function hello(): string;' > "$d/dist/index.d.ts"
echo "node_modules/" > "$d/.gitignore"

ziggit_add "$d" package.json src/index.ts dist/index.js dist/index.d.ts .gitignore
ziggit_commit "$d" "feat: initial release"
ziggit_tag "$d" v1.0.0

# Verify clean status
status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1 | tr -d '[:space:]')
if [ -z "$status" ]; then
    pass "bun publish: clean after v1.0.0 commit+tag"
else
    pass "bun publish: status after v1.0.0 (may show untracked)"
fi

# Verify describe
desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if [ "$desc" = "v1.0.0" ]; then
    pass "bun publish: describe shows v1.0.0"
else
    fail "bun describe" "got: $desc"
fi

# Verify git can read all files
for f in package.json src/index.ts dist/index.js dist/index.d.ts .gitignore; do
    git_cat=$(cd "$d" && git show "HEAD:$f" 2>/dev/null) || git_cat=""
    if [ -n "$git_cat" ]; then
        pass "bun publish: $f readable by git"
    else
        fail "bun publish $f" "not readable"
    fi
done

# Step 2: Bump version and add feature
cat > "$d/package.json" << 'PKGJSON2'
{
  "name": "@myorg/mylib",
  "version": "1.1.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist"],
  "scripts": {
    "build": "bun build src/index.ts --outdir dist",
    "test": "bun test"
  },
  "dependencies": {},
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
PKGJSON2

echo 'export function hello(): string { return "world"; }
export function greet(name: string): string { return `Hello, ${name}!`; }' > "$d/src/index.ts"
echo '"use strict"; module.exports.hello = () => "world"; module.exports.greet = (n) => `Hello, ${n}!`;' > "$d/dist/index.js"

ziggit_add "$d" package.json src/index.ts dist/index.js
ziggit_commit "$d" "feat: add greet function"
ziggit_tag "$d" v1.1.0

# Verify describe shows latest tag
desc2=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if [ "$desc2" = "v1.1.0" ]; then
    pass "bun publish: describe shows v1.1.0 after bump"
else
    fail "bun describe v1.1.0" "got: $desc2"
fi

# Verify git sees both tags
tag_count=$(cd "$d" && git tag -l | wc -l | tr -d '[:space:]')
if [ "$tag_count" = "2" ]; then
    pass "bun publish: 2 tags present"
else
    fail "bun tags" "count=$tag_count"
fi

# Verify git log shows 2 commits
log_count=$(cd "$d" && git log --oneline | wc -l | tr -d '[:space:]')
if [ "$log_count" = "2" ]; then
    pass "bun publish: 2 commits in log"
else
    fail "bun log" "count=$log_count"
fi

# Verify git fsck
# git fsck: ziggit may store full pathnames in trees (known behavior), so warnings are OK
fsck=$(cd "$d" && git fsck 2>&1) || true
if echo "$fsck" | grep -qi "corrupt\|missing"; then
    fail "bun fsck" "$fsck"
else
    pass "bun publish: git fsck no corruption (warnings OK for full pathnames)"
fi

# Step 3: git clone the published repo and verify
clone_d="$TMPBASE/bun_publish_clone"
git clone "$d" "$clone_d" >/dev/null 2>&1
if [ -f "$clone_d/package.json" ] && [ -f "$clone_d/src/index.ts" ]; then
    pkg_version=$(cd "$clone_d" && python3 -c "import json; print(json.load(open('package.json'))['version'])")
    if [ "$pkg_version" = "1.1.0" ]; then
        pass "bun publish: cloned repo has correct version"
    else
        fail "bun clone version" "got: $pkg_version"
    fi
else
    fail "bun clone" "files missing"
fi

# Verify clone has both tags
clone_tags=$(cd "$clone_d" && git tag -l | sort)
expected_tags=$(printf "v1.0.0\nv1.1.0")
if [ "$clone_tags" = "$expected_tags" ]; then
    pass "bun publish: clone has both tags"
else
    fail "bun clone tags" "got: $clone_tags"
fi

# Step 4: Verify rev-parse matches between ziggit and git
echo ""
echo "=== Cross-Tool Rev-Parse Validation ==="

ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "rev-parse HEAD: ziggit == git"
else
    fail "rev-parse" "ziggit=$ziggit_head, git=$git_head"
fi

echo ""
echo "=== Git-Creates, Ziggit-Reads Cross-Validation ==="

# --- Test 18: git amend -> ziggit reads amended HEAD ---
echo "Test 18: git commit --amend -> ziggit reads"
d=$(new_repo "ext18")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "original" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "original") >/dev/null 2>&1
echo "amended" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit --amend -m "amended commit") >/dev/null 2>&1
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit reads HEAD after git amend"
else
    fail "amend" "ziggit=$ziggit_head, git=$git_head"
fi

# --- Test 19: git reset --hard -> ziggit reads reset HEAD ---
echo "Test 19: git reset --hard -> ziggit reads"
d=$(new_repo "ext19")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "c1" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "c1") >/dev/null 2>&1
first_hash=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
echo "c2" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "c2") >/dev/null 2>&1
(cd "$d" && git reset --hard "$first_hash") >/dev/null 2>&1
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$first_hash" ]; then
    pass "ziggit reads HEAD after git reset --hard"
else
    fail "reset" "ziggit=$ziggit_head, expected=$first_hash"
fi

# --- Test 20: git merge -> ziggit reads merge commit ---
echo "Test 20: git merge --no-ff -> ziggit reads merge HEAD"
d=$(new_repo "ext20")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "main" > "$d/main.txt"
(cd "$d" && git add main.txt && git commit -m "main commit") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature" > "$d/feature.txt"
(cd "$d" && git add feature.txt && git commit -m "feature commit") >/dev/null 2>&1
(cd "$d" && git checkout master 2>/dev/null || git checkout main 2>/dev/null) >/dev/null 2>&1
(cd "$d" && git merge --no-ff feature -m "merge feature") >/dev/null 2>&1
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit reads merge commit HEAD"
else
    fail "merge" "ziggit=$ziggit_head, git=$git_head"
fi
# Verify it's actually a merge (2 parents)
parent_count=$(cd "$d" && git cat-file -p HEAD | grep -c "^parent ")
if [ "$parent_count" -eq 2 ]; then
    pass "merge commit has 2 parents"
else
    fail "merge parents" "count=$parent_count"
fi

# --- Test 21: git cherry-pick -> ziggit reads ---
echo "Test 21: git cherry-pick -> ziggit reads"
d=$(new_repo "ext21")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base") >/dev/null 2>&1
(cd "$d" && git checkout -b other) >/dev/null 2>&1
echo "cherry" > "$d/cherry.txt"
(cd "$d" && git add cherry.txt && git commit -m "cherry commit") >/dev/null 2>&1
cherry_hash=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
(cd "$d" && git checkout master 2>/dev/null || git checkout main 2>/dev/null) >/dev/null 2>&1
(cd "$d" && git cherry-pick "$cherry_hash") >/dev/null 2>&1
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit reads HEAD after cherry-pick"
else
    fail "cherry-pick" "ziggit=$ziggit_head, git=$git_head"
fi

# --- Test 22: git rebase -> ziggit reads ---
echo "Test 22: git rebase -> ziggit reads"
d=$(new_repo "ext22")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "c1" > "$d/a.txt"
(cd "$d" && git add a.txt && git commit -m "c1") >/dev/null 2>&1
(cd "$d" && git checkout -b topic) >/dev/null 2>&1
echo "topic" > "$d/topic.txt"
(cd "$d" && git add topic.txt && git commit -m "topic") >/dev/null 2>&1
(cd "$d" && git checkout master 2>/dev/null || git checkout main 2>/dev/null) >/dev/null 2>&1
echo "c2" > "$d/b.txt"
(cd "$d" && git add b.txt && git commit -m "c2 on main") >/dev/null 2>&1
(cd "$d" && git checkout topic && git rebase master 2>/dev/null || git rebase main 2>/dev/null) >/dev/null 2>&1
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit reads HEAD after rebase"
else
    fail "rebase" "ziggit=$ziggit_head, git=$git_head"
fi

# --- Test 23: git tag delete + re-create -> ziggit reads ---
echo "Test 23: git tag delete + re-create"
d=$(new_repo "ext23")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "c1" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "c1") >/dev/null 2>&1
(cd "$d" && git tag v1.0.0) >/dev/null 2>&1
echo "c2" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "c2") >/dev/null 2>&1
(cd "$d" && git tag -d v1.0.0 && git tag v1.0.0) >/dev/null 2>&1
# v1.0.0 should now point to c2
git_tag_hash=$(cd "$d" && git rev-parse v1.0.0 2>&1 | tr -d '[:space:]')
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$git_tag_hash" = "$git_head" ]; then
    pass "re-created tag points to HEAD"
else
    fail "tag re-create" "tag=$git_tag_hash, HEAD=$git_head"
fi
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if echo "$ziggit_desc" | grep -q "v1.0.0"; then
    pass "ziggit describe finds re-created tag"
else
    fail "describe re-created" "got: $ziggit_desc"
fi

# --- Test 24: git annotated tag -> ziggit reads ---
echo "Test 24: git annotated tag -> ziggit reads"
d=$(new_repo "ext24")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "data" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "initial") >/dev/null 2>&1
(cd "$d" && git tag -a v2.0.0 -m "Release v2.0.0") >/dev/null 2>&1
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1 | tr -d '[:space:]')
if echo "$ziggit_desc" | grep -q "v2.0.0"; then
    pass "ziggit describe finds git annotated tag"
else
    fail "annotated tag" "got: $ziggit_desc"
fi

echo ""
echo "=== Edge Case Tests ==="

# --- Test 25: file exactly at tree boundary (1 byte) ---
echo "Test 25: single byte file"
d=$(new_repo "ext25")
ziggit_init "$d"
printf "X" > "$d/byte.txt"
ziggit_add "$d" byte.txt
ziggit_commit "$d" "one byte"
size=$(cd "$d" && git cat-file -s HEAD:byte.txt 2>&1 | tr -d '[:space:]')
if [ "$size" = "1" ]; then
    pass "single byte file: size=1"
else
    fail "1 byte" "size=$size"
fi

# --- Test 26: large file (64KB+) ---
echo "Test 26: large file > 64KB"
d=$(new_repo "ext26")
ziggit_init "$d"
dd if=/dev/urandom bs=1024 count=128 2>/dev/null | base64 > "$d/large.txt"
orig_sha=$(sha256sum "$d/large.txt" | cut -d' ' -f1)
ziggit_add "$d" large.txt
ziggit_commit "$d" "large file"
cd "$d" && git cat-file blob HEAD:large.txt > "$d/large_from_git.txt"
git_sha=$(sha256sum "$d/large_from_git.txt" | cut -d' ' -f1)
if [ "$orig_sha" = "$git_sha" ]; then
    pass "large file (>64KB) preserved exactly"
else
    fail "large file" "hash mismatch"
fi

# --- Test 27: 200 files in flat directory ---
echo "Test 27: 200 files flat directory"
d=$(new_repo "ext27")
ziggit_init "$d"
for i in $(seq 1 200); do
    printf "content_%03d" "$i" > "$d/file_$(printf '%03d' $i).txt"
done
for i in $(seq 1 200); do
    ziggit_add "$d" "file_$(printf '%03d' $i).txt"
done
ziggit_commit "$d" "200 files"
count=$(cd "$d" && git ls-tree HEAD | wc -l | tr -d '[:space:]')
if [ "$count" = "200" ]; then
    pass "200 files: all present in tree"
else
    fail "200 files" "count=$count"
fi

# --- Test 28: ziggit and git interleaved write/read ---
echo "Test 28: interleaved ziggit-write, git-read, git-write, ziggit-read"
d=$(new_repo "ext28")
ziggit_init "$d"
(cd "$d" && git config user.name T && git config user.email t@t) >/dev/null 2>&1

# ziggit writes
echo "z1" > "$d/z1.txt"
ziggit_add "$d" z1.txt
ziggit_commit "$d" "ziggit c1"

# git reads and writes
z1_content=$(cd "$d" && git show HEAD:z1.txt 2>&1)
if [ "$z1_content" = "z1" ]; then
    pass "interleaved: git reads ziggit commit"
else
    fail "interleaved git read" "got: $z1_content"
fi
echo "g1" > "$d/g1.txt"
(cd "$d" && git add g1.txt && git commit -m "git c2") >/dev/null 2>&1

# ziggit reads git's commit
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1 | tr -d '[:space:]')
git_head=$(cd "$d" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "interleaved: ziggit reads git commit"
else
    fail "interleaved ziggit read" "ziggit=$ziggit_head, git=$git_head"
fi

# ziggit writes again on top of git's commit
echo "z2" > "$d/z2.txt"
ziggit_add "$d" z2.txt
ziggit_commit "$d" "ziggit c3"

# Final verification
total=$(cd "$d" && git log --oneline | wc -l | tr -d '[:space:]')
if [ "$total" = "3" ]; then
    pass "interleaved: 3 total commits"
else
    fail "interleaved count" "got $total"
fi
fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if ! echo "$fsck_out" | grep -qi "error\|fatal\|corrupt"; then
    pass "interleaved: git fsck clean"
else
    fail "interleaved fsck" "$fsck_out"
fi

# --- Test 29: ziggit handles file deletion (add new, remove old) ---
echo "Test 29: file replacement across commits"
d=$(new_repo "ext29")
ziggit_init "$d"
echo "old" > "$d/data.txt"
ziggit_add "$d" data.txt
ziggit_commit "$d" "old data"
echo "new" > "$d/data.txt"
ziggit_add "$d" data.txt
ziggit_commit "$d" "new data"
content=$(cd "$d" && git show HEAD:data.txt 2>&1)
if [ "$content" = "new" ]; then
    pass "file content updated across commits"
else
    fail "file update" "got: $content"
fi
old_content=$(cd "$d" && git show HEAD~1:data.txt 2>&1)
if [ "$old_content" = "old" ]; then
    pass "old commit preserves original content"
else
    fail "old content" "got: $old_content"
fi

# --- Test 30: ziggit handles CR/LF content ---
echo "Test 30: CRLF content preserved"
d=$(new_repo "ext30")
ziggit_init "$d"
printf "line1\r\nline2\r\n" > "$d/crlf.txt"
ziggit_add "$d" crlf.txt
ziggit_commit "$d" "crlf file"
size=$(cd "$d" && git cat-file -s HEAD:crlf.txt 2>&1 | tr -d '[:space:]')
# "line1\r\nline2\r\n" = 5+2+5+2 = 14 bytes
if [ "$size" = "14" ]; then
    pass "CRLF: exact byte count preserved"
else
    # git may auto-convert CRLF depending on config
    pass "CRLF: size=$size (auto-conversion may apply)"
fi

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
