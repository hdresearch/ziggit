#!/usr/bin/env bash
# Cross-validation: ziggit CLI output vs git CLI output
# Tests that ziggit-created repos are fully readable by git, and vice versa.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/../zig-out/bin/ziggit}"
ZIGGIT="$(cd "$(dirname "$ZIGGIT")" && pwd)/$(basename "$ZIGGIT")"
PASS=0
FAIL=0
TMPBASE=$(mktemp -d /tmp/ziggit_crossval_XXXXXX)

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected: $2, got: $3)"; }

cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

# Helper: create a ziggit repo with a file and commit
setup_ziggit_repo() {
    local d="$1"
    mkdir -p "$d"
    (cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
    echo "content" > "$d/file.txt"
    (cd "$d" && "$ZIGGIT" add file.txt >/dev/null 2>&1)
    (cd "$d" && "$ZIGGIT" commit -m "initial" >/dev/null 2>&1)
}

# Helper: create a git repo with a file and commit
setup_git_repo() {
    local d="$1"
    mkdir -p "$d"
    (cd "$d" && git init -q && git config user.email "test@test.com" && git config user.name "Test")
    echo "content" > "$d/file.txt"
    (cd "$d" && git add file.txt && git commit -q -m "initial")
}

########################################################################
# TEST BLOCK 1: ziggit writes, git reads
########################################################################

echo "=== Block 1: ziggit writes, git reads ==="

# Test 1: git status on ziggit-created clean repo
echo "Test 1: ziggit init+commit -> git status clean"
d="$TMPBASE/t1"
setup_ziggit_repo "$d"
git_status=$(cd "$d" && git status --porcelain 2>&1)
if [ -z "$git_status" ]; then
    pass "git status --porcelain is empty on clean ziggit repo"
else
    fail "git status clean" "empty" "$git_status"
fi

# Test 2: git log shows ziggit commit
echo "Test 2: ziggit commit -> git log --format=%s"
d="$TMPBASE/t2"
setup_ziggit_repo "$d"
git_subject=$(cd "$d" && git log --format='%s' -1 2>&1)
if [ "$git_subject" = "initial" ]; then
    pass "git log shows correct commit message"
else
    fail "commit message" "initial" "$git_subject"
fi

# Test 3: git cat-file -t HEAD shows commit
echo "Test 3: ziggit commit -> git cat-file -t HEAD"
d="$TMPBASE/t3"
setup_ziggit_repo "$d"
obj_type=$(cd "$d" && git cat-file -t HEAD 2>&1)
if [ "$obj_type" = "commit" ]; then
    pass "git cat-file -t HEAD = commit"
else
    fail "object type" "commit" "$obj_type"
fi

# Test 4: git cat-file -p HEAD shows valid commit structure
echo "Test 4: ziggit commit -> git cat-file -p HEAD has tree line"
d="$TMPBASE/t4"
setup_ziggit_repo "$d"
commit_obj=$(cd "$d" && git cat-file -p HEAD 2>&1)
if echo "$commit_obj" | grep -q "^tree [0-9a-f]\{40\}"; then
    pass "commit object has valid tree line"
else
    fail "tree line" "tree <sha>" "$commit_obj"
fi

# Test 5: git show HEAD:file.txt reads blob content
echo "Test 5: ziggit commit -> git show HEAD:file.txt"
d="$TMPBASE/t5"
setup_ziggit_repo "$d"
blob=$(cd "$d" && git show HEAD:file.txt 2>&1)
if [ "$blob" = "content" ]; then
    pass "git show reads correct blob content"
else
    fail "blob content" "content" "$blob"
fi

# Test 6: ziggit tag -> git tag -l
echo "Test 6: ziggit tag -> git tag -l"
d="$TMPBASE/t6"
setup_ziggit_repo "$d"
(cd "$d" && "$ZIGGIT" tag v1.0.0 >/dev/null 2>&1)
tags=$(cd "$d" && git tag -l 2>&1)
if echo "$tags" | grep -q "v1.0.0"; then
    pass "git tag -l finds ziggit-created tag"
else
    fail "tag list" "v1.0.0" "$tags"
fi

# Test 7: git rev-parse HEAD matches ziggit rev-parse HEAD
echo "Test 7: ziggit rev-parse HEAD == git rev-parse HEAD"
d="$TMPBASE/t7"
setup_ziggit_repo "$d"
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
git_hash=$(cd "$d" && git rev-parse HEAD 2>&1)
if [ "$ziggit_hash" = "$git_hash" ]; then
    pass "rev-parse HEAD matches between ziggit and git"
else
    fail "rev-parse" "$git_hash" "$ziggit_hash"
fi

# Test 8: git fsck on ziggit repo
echo "Test 8: ziggit repo -> git fsck"
d="$TMPBASE/t8"
setup_ziggit_repo "$d"
fsck_out=$(cd "$d" && git fsck --full 2>&1)
fsck_exit=$?
if [ $fsck_exit -eq 0 ]; then
    pass "git fsck --full passes on ziggit repo"
else
    fail "git fsck" "exit 0" "exit $fsck_exit: $fsck_out"
fi

# Test 9: Multiple files, one commit -> git ls-tree
echo "Test 9: ziggit multi-file commit -> git ls-tree"
d="$TMPBASE/t9"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
for f in a.txt b.txt c.txt; do
    echo "$f content" > "$d/$f"
    (cd "$d" && "$ZIGGIT" add "$f" >/dev/null 2>&1)
done
(cd "$d" && "$ZIGGIT" commit -m "three files" >/dev/null 2>&1)
file_count=$(cd "$d" && git ls-tree -r HEAD | wc -l | tr -d ' ')
if [ "$file_count" = "3" ]; then
    pass "git ls-tree shows 3 files"
else
    fail "file count" "3" "$file_count"
fi

# Test 10: Nested directory structure
echo "Test 10: ziggit nested dirs -> git ls-tree -r"
d="$TMPBASE/t10"
mkdir -p "$d/src/lib" "$d/src/bin"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
echo "lib code" > "$d/src/lib/mod.zig"
echo "bin code" > "$d/src/bin/main.zig"
echo "readme" > "$d/README.md"
(cd "$d" && "$ZIGGIT" add src/lib/mod.zig >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" add src/bin/main.zig >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" add README.md >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "nested" >/dev/null 2>&1)
tree_files=$(cd "$d" && git ls-tree -r HEAD --name-only | sort)
expected=$'README.md\nsrc/bin/main.zig\nsrc/lib/mod.zig'
if [ "$tree_files" = "$expected" ]; then
    pass "git ls-tree -r shows correct nested file paths"
else
    fail "nested files" "$expected" "$tree_files"
fi

# Test 11: Binary file preserved
echo "Test 11: ziggit binary file -> git preserves bytes"
d="$TMPBASE/t11"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
printf '\x00\x01\x02\xff\xfe\xfd' > "$d/binary.bin"
orig_md5=$(md5sum "$d/binary.bin" | cut -d' ' -f1)
(cd "$d" && "$ZIGGIT" add binary.bin >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "binary" >/dev/null 2>&1)
git_md5=$(cd "$d" && git show HEAD:binary.bin | md5sum | cut -d' ' -f1)
if [ "$orig_md5" = "$git_md5" ]; then
    pass "binary file content preserved through ziggit commit"
else
    fail "binary md5" "$orig_md5" "$git_md5"
fi

# Test 12: File with spaces in name
echo "Test 12: ziggit file with spaces -> git reads"
d="$TMPBASE/t12"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
echo "spaced" > "$d/my file.txt"
(cd "$d" && "$ZIGGIT" add "my file.txt" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "spaces" >/dev/null 2>&1)
spaced_content=$(cd "$d" && git show "HEAD:my file.txt" 2>&1)
if [ "$spaced_content" = "spaced" ]; then
    pass "git reads file with spaces in name"
else
    fail "spaced file" "spaced" "$spaced_content"
fi

# Test 13: Two commits -> git rev-list count
echo "Test 13: ziggit two commits -> git rev-list --count"
d="$TMPBASE/t13"
setup_ziggit_repo "$d"
echo "second" > "$d/second.txt"
(cd "$d" && "$ZIGGIT" add second.txt >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "second" >/dev/null 2>&1)
count=$(cd "$d" && git rev-list --count HEAD 2>&1)
if [ "$count" = "2" ]; then
    pass "git rev-list --count shows 2 commits"
else
    fail "commit count" "2" "$count"
fi

# Test 14: Lightweight tag -> git cat-file -t shows commit (ziggit CLI creates lightweight tags)
echo "Test 14: ziggit lightweight tag -> git cat-file -t"
d="$TMPBASE/t14"
setup_ziggit_repo "$d"
(cd "$d" && "$ZIGGIT" tag v2.0.0 >/dev/null 2>&1)
tag_type=$(cd "$d" && git cat-file -t v2.0.0 2>&1)
if [ "$tag_type" = "commit" ]; then
    pass "git cat-file -t shows commit for lightweight tag"
else
    fail "tag type" "commit" "$tag_type"
fi

# Test 15: git gc + fsck after ziggit commits
echo "Test 15: ziggit commits -> git gc -> git fsck"
d="$TMPBASE/t15"
setup_ziggit_repo "$d"
for i in $(seq 1 5); do
    echo "file $i" > "$d/f$i.txt"
    (cd "$d" && "$ZIGGIT" add "f$i.txt" >/dev/null 2>&1)
    (cd "$d" && "$ZIGGIT" commit -m "commit $i" >/dev/null 2>&1)
done
(cd "$d" && git gc --quiet 2>&1)
fsck2=$(cd "$d" && git fsck --full 2>&1)
fsck2_exit=$?
if [ $fsck2_exit -eq 0 ]; then
    pass "git fsck passes after gc on ziggit repo with 6 commits"
else
    fail "fsck after gc" "exit 0" "exit $fsck2_exit: $fsck2"
fi

# Test 16: 50 files in single commit
echo "Test 16: ziggit 50 files -> git ls-tree count"
d="$TMPBASE/t16"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
for i in $(seq 1 50); do
    echo "file $i" > "$d/file_$i.txt"
    (cd "$d" && "$ZIGGIT" add "file_$i.txt" >/dev/null 2>&1)
done
(cd "$d" && "$ZIGGIT" commit -m "50 files" >/dev/null 2>&1)
count50=$(cd "$d" && git ls-tree -r HEAD | wc -l | tr -d ' ')
if [ "$count50" = "50" ]; then
    pass "git ls-tree shows 50 files"
else
    fail "50 files" "50" "$count50"
fi

# Test 17: Deeply nested (8 levels)
echo "Test 17: ziggit 8-level nesting -> git reads"
d="$TMPBASE/t17"
mkdir -p "$d/a/b/c/d/e/f/g/h"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)
echo "deep" > "$d/a/b/c/d/e/f/g/h/deep.txt"
(cd "$d" && "$ZIGGIT" add a/b/c/d/e/f/g/h/deep.txt >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "deep nesting" >/dev/null 2>&1)
deep_content=$(cd "$d" && git show HEAD:a/b/c/d/e/f/g/h/deep.txt 2>&1)
if [ "$deep_content" = "deep" ]; then
    pass "git reads 8-level nested file"
else
    fail "deep content" "deep" "$deep_content"
fi

########################################################################
# TEST BLOCK 2: git writes, ziggit reads
########################################################################

echo ""
echo "=== Block 2: git writes, ziggit reads ==="

# Test 18: git commit -> ziggit rev-parse HEAD
echo "Test 18: git commit -> ziggit rev-parse HEAD"
d="$TMPBASE/t18"
setup_git_repo "$d"
git_hash=$(cd "$d" && git rev-parse HEAD)
ziggit_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash" = "$ziggit_hash" ]; then
    pass "ziggit rev-parse HEAD matches git"
else
    fail "rev-parse" "$git_hash" "$ziggit_hash"
fi

# Test 19: git tag -> ziggit describe --tags
echo "Test 19: git tag -> ziggit describe --tags"
d="$TMPBASE/t19"
setup_git_repo "$d"
(cd "$d" && git tag v3.0.0)
desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if echo "$desc" | grep -q "v3.0.0"; then
    pass "ziggit describe --tags finds git tag"
else
    fail "describe" "v3.0.0" "$desc"
fi

# Test 20: git 3 commits -> ziggit rev-parse HEAD still correct
echo "Test 20: git 3 commits -> ziggit rev-parse HEAD"
d="$TMPBASE/t20"
setup_git_repo "$d"
for i in 2 3; do
    echo "commit $i" > "$d/f$i.txt"
    (cd "$d" && git add "f$i.txt" && git commit -q -m "commit $i")
done
git_hash3=$(cd "$d" && git rev-parse HEAD)
ziggit_hash3=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_hash3" = "$ziggit_hash3" ]; then
    pass "ziggit rev-parse HEAD after 3 git commits"
else
    fail "rev-parse 3" "$git_hash3" "$ziggit_hash3"
fi

# Test 21: git merge commit -> ziggit rev-parse HEAD
echo "Test 21: git merge -> ziggit rev-parse HEAD"
d="$TMPBASE/t21"
setup_git_repo "$d"
(cd "$d" && git checkout -q -b feature)
echo "feat" > "$d/feat.txt"
(cd "$d" && git add feat.txt && git commit -q -m "feature")
(cd "$d" && git checkout -q master)
echo "main" > "$d/main.txt"
(cd "$d" && git add main.txt && git commit -q -m "main change")
(cd "$d" && git merge feature -m "merge" --no-edit -q 2>/dev/null) || true
git_merge_hash=$(cd "$d" && git rev-parse HEAD)
ziggit_merge_hash=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>&1)
if [ "$git_merge_hash" = "$ziggit_merge_hash" ]; then
    pass "ziggit reads merge commit HEAD"
else
    fail "merge rev-parse" "$git_merge_hash" "$ziggit_merge_hash"
fi

# Test 22: git tag on old commit -> ziggit describe shows distance
echo "Test 22: git tag on old commit -> ziggit describe distance"
d="$TMPBASE/t22"
setup_git_repo "$d"
(cd "$d" && git tag v0.1.0)
echo "second" > "$d/s.txt"
(cd "$d" && git add s.txt && git commit -q -m "second")
desc2=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if echo "$desc2" | grep -q "v0.1.0"; then
    pass "ziggit describe shows tag with distance"
else
    fail "describe distance" "v0.1.0-*" "$desc2"
fi

# Test 23: git status clean -> ziggit status clean
echo "Test 23: git clean -> ziggit status --porcelain empty"
d="$TMPBASE/t23"
setup_git_repo "$d"
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if [ -z "$ziggit_status" ]; then
    pass "ziggit status --porcelain empty on clean git repo"
else
    fail "status porcelain" "empty" "$ziggit_status"
fi

# Test 24: git creates untracked file -> ziggit detects it
echo "Test 24: git repo + untracked file -> ziggit status detects"
d="$TMPBASE/t24"
setup_git_repo "$d"
echo "untracked" > "$d/new.txt"
ziggit_status2=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if echo "$ziggit_status2" | grep -q "new.txt"; then
    pass "ziggit status detects untracked file in git repo"
else
    fail "untracked detection" "?? new.txt" "$ziggit_status2"
fi

########################################################################
# TEST BLOCK 3: Bun workflow simulation
########################################################################

echo ""
echo "=== Block 3: Bun workflow simulation ==="

# Test 25: Full bun publish workflow
echo "Test 25: bun publish workflow"
d="$TMPBASE/t25"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)

# Create package.json
cat > "$d/package.json" << 'EOF'
{
  "name": "@test/mypackage",
  "version": "1.0.0",
  "main": "index.js"
}
EOF
echo "module.exports = 42;" > "$d/index.js"

(cd "$d" && "$ZIGGIT" add package.json >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" add index.js >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "Initial release" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" tag v1.0.0 >/dev/null 2>&1)

# Verify with git
bun_status=$(cd "$d" && git status --porcelain 2>&1)
bun_tag=$(cd "$d" && git tag -l 2>&1)
bun_pkg=$(cd "$d" && git show HEAD:package.json 2>&1)
bun_fsck=$(cd "$d" && git fsck 2>&1)

if [ -z "$bun_status" ] && echo "$bun_tag" | grep -q "v1.0.0" && echo "$bun_pkg" | grep -q "mypackage"; then
    pass "bun publish workflow: commit, tag, content all valid"
else
    fail "bun workflow" "clean+tag+content" "status=$bun_status tag=$bun_tag"
fi

# Test 26: Version bump cycle
echo "Test 26: bun version bump cycle"
d="$TMPBASE/t26"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)

cat > "$d/package.json" << 'EOF'
{"name": "bump-test", "version": "0.0.1"}
EOF
(cd "$d" && "$ZIGGIT" add package.json >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "v0.0.1" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" tag v0.0.1 >/dev/null 2>&1)

# Bump to 0.0.2
cat > "$d/package.json" << 'EOF'
{"name": "bump-test", "version": "0.0.2"}
EOF
(cd "$d" && "$ZIGGIT" add package.json >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "v0.0.2" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" tag v0.0.2 >/dev/null 2>&1)

# Bump to 0.1.0
cat > "$d/package.json" << 'EOF'
{"name": "bump-test", "version": "0.1.0"}
EOF
(cd "$d" && "$ZIGGIT" add package.json >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "v0.1.0" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" tag v0.1.0 >/dev/null 2>&1)

tag_count=$(cd "$d" && git tag -l | wc -l | tr -d ' ')
commit_count=$(cd "$d" && git rev-list --count HEAD 2>&1)
describe_out=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)

if [ "$tag_count" = "3" ] && [ "$commit_count" = "3" ] && echo "$describe_out" | grep -q "v0.1.0"; then
    pass "version bump: 3 tags, 3 commits, describe finds latest"
else
    fail "version bump" "3 tags, 3 commits" "tags=$tag_count commits=$commit_count desc=$describe_out"
fi

# Test 27: bun lockfile (binary) + package.json
echo "Test 27: bun lockfile binary + package.json"
d="$TMPBASE/t27"
mkdir -p "$d"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)

cat > "$d/package.json" << 'EOF'
{"name": "lock-test", "version": "1.0.0", "dependencies": {"lodash": "^4.0.0"}}
EOF
# Simulate bun.lockb as binary
dd if=/dev/urandom of="$d/bun.lockb" bs=1024 count=4 2>/dev/null
lockb_md5=$(md5sum "$d/bun.lockb" | cut -d' ' -f1)

(cd "$d" && "$ZIGGIT" add package.json >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" add bun.lockb >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" commit -m "add deps" >/dev/null 2>&1)

git_lockb_md5=$(cd "$d" && git show HEAD:bun.lockb | md5sum | cut -d' ' -f1)
if [ "$lockb_md5" = "$git_lockb_md5" ]; then
    pass "bun.lockb binary preserved exactly"
else
    fail "lockb binary" "$lockb_md5" "$git_lockb_md5"
fi

# Test 28: monorepo with workspaces
echo "Test 28: bun monorepo workspace structure"
d="$TMPBASE/t28"
mkdir -p "$d/packages/core" "$d/packages/cli"
(cd "$d" && "$ZIGGIT" init >/dev/null 2>&1)

cat > "$d/package.json" << 'EOF'
{"name": "monorepo", "workspaces": ["packages/*"]}
EOF
cat > "$d/packages/core/package.json" << 'EOF'
{"name": "@mono/core", "version": "1.0.0"}
EOF
cat > "$d/packages/cli/package.json" << 'EOF'
{"name": "@mono/cli", "version": "1.0.0", "dependencies": {"@mono/core": "workspace:*"}}
EOF
echo "export const hello = 'world';" > "$d/packages/core/index.ts"
echo "import { hello } from '@mono/core';" > "$d/packages/cli/index.ts"

for f in package.json packages/core/package.json packages/core/index.ts packages/cli/package.json packages/cli/index.ts; do
    (cd "$d" && "$ZIGGIT" add "$f" >/dev/null 2>&1)
done
(cd "$d" && "$ZIGGIT" commit -m "monorepo setup" >/dev/null 2>&1)
(cd "$d" && "$ZIGGIT" tag v1.0.0 >/dev/null 2>&1)

mono_files=$(cd "$d" && git ls-tree -r HEAD --name-only | wc -l | tr -d ' ')
mono_fsck=$(cd "$d" && git fsck 2>&1)
mono_fsck_exit=$?
if [ "$mono_files" = "5" ] && [ $mono_fsck_exit -eq 0 ]; then
    pass "monorepo: 5 files in tree, fsck passes"
else
    fail "monorepo" "5 files, fsck ok" "files=$mono_files fsck=$mono_fsck_exit"
fi

# Test 29: Status after modifying committed file
echo "Test 29: ziggit commit -> modify file -> status detects"
d="$TMPBASE/t29"
setup_ziggit_repo "$d"
echo "modified" > "$d/file.txt"
status29=$(cd "$d" && "$ZIGGIT" status --porcelain 2>&1)
if echo "$status29" | grep -q "file.txt"; then
    pass "ziggit status detects modified file"
else
    fail "modified detection" "M file.txt" "$status29"
fi

# Test 30: describe --tags on exact tag match
echo "Test 30: ziggit describe --tags on exact tag"
d="$TMPBASE/t30"
setup_ziggit_repo "$d"
(cd "$d" && "$ZIGGIT" tag v5.0.0 >/dev/null 2>&1)
desc30=$(cd "$d" && "$ZIGGIT" describe --tags 2>&1)
if [ "$desc30" = "v5.0.0" ]; then
    pass "describe --tags returns exact tag name"
else
    fail "describe exact" "v5.0.0" "$desc30"
fi

########################################################################
# RESULTS
########################################################################

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
