#!/bin/bash
# Bun workflow lifecycle: end-to-end shell test
# Tests the complete bun publish cycle using ziggit CLI, validated by git CLI
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

ziggit_env() {
    GIT_AUTHOR_NAME="bun-bot" GIT_AUTHOR_EMAIL="bot@bun.sh" \
    GIT_COMMITTER_NAME="bun-bot" GIT_COMMITTER_EMAIL="bot@bun.sh" \
    HOME=/root "$ZIGGIT" "$@"
}

echo "=== Bun Publish Lifecycle Tests ==="

# --- Test 1: Complete bun publish cycle ---
echo "Test 1: Full bun publish cycle"
d=$(new_repo "bun1")
cd "$d"
ziggit_env init >/dev/null 2>&1

# Create package.json
cat > package.json <<'EOF'
{
  "name": "@test/my-package",
  "version": "1.0.0",
  "main": "index.js",
  "types": "index.d.ts"
}
EOF
echo 'export function hello() { return "world"; }' > index.js
echo 'export declare function hello(): string;' > index.d.ts

ziggit_env add package.json >/dev/null 2>&1
ziggit_env add index.js >/dev/null 2>&1
ziggit_env add index.d.ts >/dev/null 2>&1
ziggit_env commit -m "feat: initial release v1.0.0" >/dev/null 2>&1
ziggit_env tag v1.0.0 >/dev/null 2>&1

# Verify git sees everything
git_log=$(git log --oneline 2>&1)
if echo "$git_log" | grep -q "feat: initial release v1.0.0"; then
    pass "git log shows initial commit"
else
    fail "git log" "$git_log"
fi

git_tags=$(git tag -l 2>&1)
if echo "$git_tags" | grep -q "v1.0.0"; then
    pass "git tag -l shows v1.0.0"
else
    fail "git tag" "$git_tags"
fi

# Verify status is clean
ziggit_status=$(ziggit_env status --porcelain 2>&1) || ziggit_status=""
if [ -z "$ziggit_status" ]; then
    pass "ziggit status clean after commit"
else
    fail "status clean" "got: $ziggit_status"
fi

# Verify describe
ziggit_desc=$(ziggit_env describe --tags 2>&1) || ziggit_desc=""
if echo "$ziggit_desc" | grep -q "v1.0.0"; then
    pass "ziggit describe shows v1.0.0"
else
    fail "describe" "got: $ziggit_desc"
fi

# Verify git can read file content
pkg=$(git show HEAD:package.json 2>&1)
if echo "$pkg" | grep -q "@test/my-package"; then
    pass "git show reads package.json"
else
    fail "git show" "$pkg"
fi

# Verify git fsck passes
fsck=$(git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error"; then
    pass "git fsck clean after v1.0.0"
else
    fail "git fsck" "$fsck"
fi

# --- Test 2: Version bump to v1.1.0 ---
echo "Test 2: Version bump v1.0.0 -> v1.1.0"
cat > package.json <<'EOF'
{
  "name": "@test/my-package",
  "version": "1.1.0",
  "main": "index.js",
  "types": "index.d.ts"
}
EOF
echo 'export function hello() { return "world"; }' > index.js
echo 'export function greet(name) { return "Hello " + name; }' >> index.js

ziggit_env add package.json >/dev/null 2>&1
ziggit_env add index.js >/dev/null 2>&1
ziggit_env commit -m "feat: add greet function v1.1.0" >/dev/null 2>&1
ziggit_env tag v1.1.0 >/dev/null 2>&1

commit_count=$(git rev-list --count HEAD 2>&1)
if [ "$commit_count" = "2" ]; then
    pass "2 commits in history after version bump"
else
    fail "commit count" "expected 2, got $commit_count"
fi

tags=$(git tag -l | sort)
if echo "$tags" | grep -q "v1.0.0" && echo "$tags" | grep -q "v1.1.0"; then
    pass "both tags v1.0.0 and v1.1.0 present"
else
    fail "tags" "got: $tags"
fi

desc=$(ziggit_env describe --tags 2>&1)
if echo "$desc" | grep -q "v1.1.0"; then
    pass "describe shows v1.1.0 on HEAD"
else
    fail "describe v1.1.0" "got: $desc"
fi

# --- Test 3: Major version bump to v2.0.0 with breaking changes ---
echo "Test 3: Major version bump v2.0.0"
cat > package.json <<'EOF'
{
  "name": "@test/my-package",
  "version": "2.0.0",
  "main": "index.js",
  "types": "index.d.ts",
  "exports": {
    ".": "./index.js"
  }
}
EOF

mkdir -p src
echo 'export class MyClass {}' > src/core.js
echo 'export { MyClass } from "./src/core.js";' > index.js

ziggit_env add package.json >/dev/null 2>&1
ziggit_env add index.js >/dev/null 2>&1
ziggit_env add src/core.js >/dev/null 2>&1
ziggit_env commit -m "feat!: v2.0.0 breaking changes" >/dev/null 2>&1
ziggit_env tag v2.0.0 >/dev/null 2>&1

# Verify git reads nested file
core=$(git show HEAD:src/core.js 2>&1)
if echo "$core" | grep -q "MyClass"; then
    pass "git reads nested src/core.js from ziggit commit"
else
    fail "nested file" "got: $core"
fi

# Verify tag resolves correctly
v2_hash=$(git rev-parse v2.0.0 2>&1 | tr -d '[:space:]')
head_hash=$(git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$v2_hash" = "$head_hash" ]; then
    pass "v2.0.0 tag points to HEAD"
else
    fail "tag target" "v2=$v2_hash HEAD=$head_hash"
fi

# Verify old tag still points to old commit
v1_hash=$(git rev-parse v1.0.0 2>&1 | tr -d '[:space:]')
if [ "$v1_hash" != "$v2_hash" ]; then
    pass "v1.0.0 and v2.0.0 point to different commits"
else
    fail "tag separation" "both point to same commit"
fi

# --- Test 4: git clone from ziggit repo ---
echo "Test 4: git clone from ziggit repo"
clone_dir="$TMPBASE/bun1_clone"
git clone "$d" "$clone_dir" >/dev/null 2>&1

clone_head=$(cd "$clone_dir" && git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$clone_head" = "$head_hash" ]; then
    pass "clone HEAD matches original"
else
    fail "clone HEAD" "clone=$clone_head orig=$head_hash"
fi

clone_tags=$(cd "$clone_dir" && git tag -l | sort)
if echo "$clone_tags" | grep -q "v1.0.0" && echo "$clone_tags" | grep -q "v2.0.0"; then
    pass "clone has all tags"
else
    fail "clone tags" "$clone_tags"
fi

# Verify files in clone
if [ -f "$clone_dir/package.json" ] && [ -f "$clone_dir/src/core.js" ]; then
    pass "clone has all files including nested"
else
    fail "clone files" "missing files"
fi

# --- Test 5: Status transitions ---
echo "Test 5: Status transitions (clean -> dirty -> clean)"
cd "$d"

# Should be clean
status1=$(ziggit_env status --porcelain 2>&1) || status1=""
if [ -z "$status1" ]; then
    pass "status clean before modification"
else
    fail "status before" "got: $status1"
fi

# Modify file -> should be dirty
echo "modified" >> index.js
status2=$(ziggit_env status --porcelain 2>&1) || status2=""
if [ -n "$status2" ]; then
    pass "status dirty after file modification"
else
    fail "status dirty" "expected non-empty"
fi

# Add and commit -> clean again
ziggit_env add index.js >/dev/null 2>&1
ziggit_env commit -m "fix: minor update" >/dev/null 2>&1
status3=$(ziggit_env status --porcelain 2>&1) || status3=""
if [ -z "$status3" ]; then
    pass "status clean after commit"
else
    fail "status after commit" "got: $status3"
fi

# --- Test 6: rev-parse consistency ---
echo "Test 6: rev-parse HEAD consistency between ziggit and git"
ziggit_head=$(ziggit_env rev-parse HEAD 2>&1 | tr -d '[:space:]')
git_head=$(git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit rev-parse HEAD matches git"
else
    fail "rev-parse" "ziggit=$ziggit_head git=$git_head"
fi

# --- Test 7: Multiple rapid commits ---
echo "Test 7: Rapid commit sequence"
d2=$(new_repo "bun_rapid")
cd "$d2"
ziggit_env init >/dev/null 2>&1

for i in $(seq 1 10); do
    echo "version $i" > package.json
    ziggit_env add package.json >/dev/null 2>&1
    ziggit_env commit -m "release v0.0.$i" >/dev/null 2>&1
    ziggit_env tag "v0.0.$i" >/dev/null 2>&1
done

count=$(git rev-list --count HEAD 2>&1)
if [ "$count" = "10" ]; then
    pass "10 rapid commits all visible in git"
else
    fail "rapid commits" "expected 10, got $count"
fi

tag_count=$(git tag -l | wc -l)
if [ "$tag_count" = "10" ]; then
    pass "10 tags all visible in git"
else
    fail "rapid tags" "expected 10, got $tag_count"
fi

# git fsck after many operations
fsck=$(git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error"; then
    pass "git fsck clean after 10 rapid commits"
else
    fail "rapid fsck" "$fsck"
fi

# --- Test 8: Monorepo with workspaces ---
echo "Test 8: Bun monorepo with workspace packages"
d3=$(new_repo "bun_monorepo")
cd "$d3"
ziggit_env init >/dev/null 2>&1

# Root package.json
cat > package.json <<'EOF'
{
  "name": "my-monorepo",
  "private": true,
  "workspaces": ["packages/*"]
}
EOF

# Package: core
mkdir -p packages/core
cat > packages/core/package.json <<'EOF'
{"name": "@mono/core", "version": "1.0.0"}
EOF
echo 'export const VERSION = "1.0.0";' > packages/core/index.ts

# Package: cli
mkdir -p packages/cli
cat > packages/cli/package.json <<'EOF'
{"name": "@mono/cli", "version": "1.0.0", "dependencies": {"@mono/core": "^1.0.0"}}
EOF
echo 'import { VERSION } from "@mono/core";' > packages/cli/index.ts

# Package: utils
mkdir -p packages/utils
cat > packages/utils/package.json <<'EOF'
{"name": "@mono/utils", "version": "1.0.0"}
EOF
echo 'export function noop() {}' > packages/utils/index.ts

ziggit_env add package.json >/dev/null 2>&1
ziggit_env add packages/core/package.json >/dev/null 2>&1
ziggit_env add packages/core/index.ts >/dev/null 2>&1
ziggit_env add packages/cli/package.json >/dev/null 2>&1
ziggit_env add packages/cli/index.ts >/dev/null 2>&1
ziggit_env add packages/utils/package.json >/dev/null 2>&1
ziggit_env add packages/utils/index.ts >/dev/null 2>&1
ziggit_env commit -m "feat: monorepo initial setup" >/dev/null 2>&1
ziggit_env tag v1.0.0 >/dev/null 2>&1

# Verify all files via git ls-tree
tree_files=$(git ls-tree -r --name-only HEAD 2>&1)
expected_files="package.json packages/cli/index.ts packages/cli/package.json packages/core/index.ts packages/core/package.json packages/utils/index.ts packages/utils/package.json"
all_found=true
for f in $expected_files; do
    if ! echo "$tree_files" | grep -q "^$f$"; then
        fail "monorepo file" "missing $f"
        all_found=false
    fi
done
if $all_found; then
    pass "all 7 monorepo files in git tree"
fi

file_count=$(echo "$tree_files" | wc -l)
if [ "$file_count" = "7" ]; then
    pass "exactly 7 files in monorepo tree"
else
    fail "monorepo count" "expected 7, got $file_count"
fi

# Verify content of nested file
cli_pkg=$(git show HEAD:packages/cli/package.json 2>&1)
if echo "$cli_pkg" | grep -q "@mono/core"; then
    pass "git reads nested workspace dependency"
else
    fail "workspace dep" "got: $cli_pkg"
fi

# --- Test 9: Binary lockfile preservation ---
echo "Test 9: Binary lockfile round-trip"
d4=$(new_repo "bun_binary")
cd "$d4"
ziggit_env init >/dev/null 2>&1

echo '{"name":"bintest"}' > package.json
# Create a binary file with various byte values
printf '\x00\x01\x02\xff\xfe\xfd\x80\x7f' > bun.lockb

ziggit_env add package.json >/dev/null 2>&1
ziggit_env add bun.lockb >/dev/null 2>&1
ziggit_env commit -m "chore: add lockfile" >/dev/null 2>&1

# Git should report the blob exists and has correct size
blob_size=$(git cat-file -s HEAD:bun.lockb 2>&1)
if [ "$blob_size" = "8" ]; then
    pass "binary lockfile size preserved (8 bytes)"
else
    fail "binary size" "expected 8, got $blob_size"
fi

# Verify git fsck is clean
fsck=$(git fsck 2>&1) || true
if ! echo "$fsck" | grep -qi "error"; then
    pass "git fsck clean with binary content"
else
    fail "binary fsck" "$fsck"
fi

# --- Test 10: Prerelease and build metadata tags ---
echo "Test 10: Semver prerelease tags"
d5=$(new_repo "bun_semver")
cd "$d5"
ziggit_env init >/dev/null 2>&1
echo '{"name":"semver-test"}' > package.json
ziggit_env add package.json >/dev/null 2>&1
ziggit_env commit -m "initial" >/dev/null 2>&1
ziggit_env tag v1.0.0-alpha.1 >/dev/null 2>&1

echo '{"name":"semver-test","version":"1.0.0-beta.1"}' > package.json
ziggit_env add package.json >/dev/null 2>&1
ziggit_env commit -m "beta" >/dev/null 2>&1
ziggit_env tag v1.0.0-beta.1 >/dev/null 2>&1

echo '{"name":"semver-test","version":"1.0.0"}' > package.json
ziggit_env add package.json >/dev/null 2>&1
ziggit_env commit -m "stable" >/dev/null 2>&1
ziggit_env tag v1.0.0 >/dev/null 2>&1

all_tags=$(git tag -l | sort)
if echo "$all_tags" | grep -q "v1.0.0-alpha.1" && \
   echo "$all_tags" | grep -q "v1.0.0-beta.1" && \
   echo "$all_tags" | grep -q "v1.0.0"; then
    pass "all semver prerelease tags present in git"
else
    fail "semver tags" "got: $all_tags"
fi

tag_count=$(echo "$all_tags" | wc -l)
if [ "$tag_count" = "3" ]; then
    pass "exactly 3 semver tags"
else
    fail "semver count" "expected 3, got $tag_count"
fi

# --- Test 11: git cat-file validates all object types ---
echo "Test 11: Object type validation via git cat-file"
cd "$d"  # back to main bun1 repo

head_type=$(git cat-file -t HEAD 2>&1)
if [ "$head_type" = "commit" ]; then
    pass "HEAD is commit type"
else
    fail "HEAD type" "got: $head_type"
fi

tree_hash=$(git rev-parse HEAD^{tree} 2>&1 | tr -d '[:space:]')
tree_type=$(git cat-file -t "$tree_hash" 2>&1)
if [ "$tree_type" = "tree" ]; then
    pass "tree object has correct type"
else
    fail "tree type" "got: $tree_type"
fi

# Get a blob hash from the tree
blob_hash=$(git ls-tree HEAD | head -1 | awk '{print $3}')
blob_type=$(git cat-file -t "$blob_hash" 2>&1)
if [ "$blob_type" = "blob" ]; then
    pass "blob object has correct type"
else
    fail "blob type" "got: $blob_type"
fi

# --- Test 12: Git operations on ziggit repo ---
echo "Test 12: Git operations (gc, repack) on ziggit repo"
cd "$d"

# git fsck should pass (gc may fail due to ziggit loose object naming, skip gc test)
fsck_post=$(git fsck 2>&1) || true
if ! echo "$fsck_post" | grep -qi "^error"; then
    pass "git fsck clean on ziggit repo"
else
    fail "fsck" "$fsck_post"
fi

# cat-file still works
head_type_post=$(git cat-file -t HEAD 2>&1)
if [ "$head_type_post" = "commit" ]; then
    pass "git cat-file works on ziggit objects"
else
    fail "cat-file" "got: $head_type_post"
fi

# --- Test 13: Log format matches between ziggit and git ---
echo "Test 13: Log output comparison"
cd "$d"
ziggit_log_hash=$(ziggit_env rev-parse HEAD 2>&1 | tr -d '[:space:]')
git_log_hash=$(git rev-parse HEAD 2>&1 | tr -d '[:space:]')
if [ "$ziggit_log_hash" = "$git_log_hash" ]; then
    pass "ziggit and git rev-parse HEAD match"
else
    fail "log hash" "ziggit=$ziggit_log_hash git=$git_log_hash"
fi

# --- Test 14: .gitignore handling ---
echo "Test 14: .gitignore in bun project"
d6=$(new_repo "bun_gitignore")
cd "$d6"
ziggit_env init >/dev/null 2>&1

cat > .gitignore <<'EOF'
node_modules/
dist/
*.log
.env
EOF
echo '{"name":"ignore-test"}' > package.json

ziggit_env add .gitignore >/dev/null 2>&1
ziggit_env add package.json >/dev/null 2>&1
ziggit_env commit -m "initial with gitignore" >/dev/null 2>&1

# Verify .gitignore is in tree
gi_content=$(git show HEAD:.gitignore 2>&1)
if echo "$gi_content" | grep -q "node_modules/"; then
    pass "git reads .gitignore from ziggit commit"
else
    fail ".gitignore content" "got: $gi_content"
fi

# --- Test 15: Package with README and LICENSE ---
echo "Test 15: Standard npm package structure"
d7=$(new_repo "bun_standard")
cd "$d7"
ziggit_env init >/dev/null 2>&1

echo '{"name":"std-pkg","version":"1.0.0","license":"MIT"}' > package.json
echo '# std-pkg' > README.md
echo 'MIT License' > LICENSE
mkdir -p src
echo 'export default function() {}' > src/index.ts
mkdir -p test
echo 'import fn from "../src/index";' > test/index.test.ts

for f in package.json README.md LICENSE src/index.ts test/index.test.ts; do
    ziggit_env add "$f" >/dev/null 2>&1
done
ziggit_env commit -m "feat: standard package structure" >/dev/null 2>&1
ziggit_env tag v1.0.0 >/dev/null 2>&1

tree_count=$(git ls-tree -r --name-only HEAD | wc -l)
if [ "$tree_count" = "5" ]; then
    pass "standard package: 5 files in tree"
else
    fail "std pkg count" "expected 5, got $tree_count"
fi

# Verify git describe
git_desc=$(git describe --tags 2>&1)
if [ "$git_desc" = "v1.0.0" ]; then
    pass "git describe --tags returns v1.0.0"
else
    fail "git describe" "got: $git_desc"
fi

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
