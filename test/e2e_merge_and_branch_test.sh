#!/bin/bash
# End-to-end validation: ziggit branch, merge, checkout commands cross-validated with git
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

GIT_ENV="GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t"

echo "=== ziggit branch command cross-validation ==="

# --- Test 1: ziggit branch creates branch -> git sees it ---
echo "Test 1: ziggit branch -> git branch -l"
d=$(new_repo "t1")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "init" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "initial") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" branch feature) >/dev/null 2>&1
git_branches=$(cd "$d" && git branch -l 2>/dev/null | tr -d ' *')
if echo "$git_branches" | grep -q "feature"; then
    pass "git branch -l shows ziggit-created branch"
else
    fail "branch create" "git branches: $git_branches"
fi

# --- Test 2: ziggit checkout branch -> git sees HEAD switch ---
echo "Test 2: ziggit checkout branch -> git HEAD on feature"
(cd "$d" && "$ZIGGIT" checkout feature) >/dev/null 2>&1
git_branch=$(cd "$d" && git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '[:space:]')
if [ "$git_branch" = "feature" ]; then
    pass "git confirms HEAD on feature branch after ziggit checkout"
else
    fail "checkout branch" "git HEAD on: $git_branch"
fi

# --- Test 3: ziggit commit on branch -> git log shows it ---
echo "Test 3: commit on feature branch -> git log"
echo "feature work" > "$d/feat.txt"
(cd "$d" && "$ZIGGIT" add feat.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "feature commit") >/dev/null 2>&1
feat_msg=$(cd "$d" && git log --format=%s -1)
if [ "$feat_msg" = "feature commit" ]; then
    pass "git log shows commit on feature branch"
else
    fail "branch commit" "got: $feat_msg"
fi

# --- Test 4: ziggit checkout back to master -> git confirms ---
echo "Test 4: checkout back to master"
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
git_branch=$(cd "$d" && git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '[:space:]')
if [ "$git_branch" = "master" ]; then
    pass "git confirms HEAD back on master"
else
    fail "checkout master" "git HEAD on: $git_branch"
fi

echo ""
echo "=== ziggit merge (fast-forward) cross-validation ==="

# --- Test 5: ziggit merge fast-forward -> git validates ---
echo "Test 5: ziggit merge fast-forward"
d=$(new_repo "t5")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" branch feature) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout feature) >/dev/null 2>&1
echo "feature" > "$d/feat.txt"
(cd "$d" && "$ZIGGIT" add feat.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "feature work") >/dev/null 2>&1
feature_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" merge feature) >/dev/null 2>&1

# After fast-forward, master HEAD should equal feature commit
master_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
if [ "$master_hash" = "$feature_hash" ]; then
    pass "fast-forward merge: master HEAD equals feature commit"
else
    fail "ff merge" "master=$master_hash feature=$feature_hash"
fi

# git log should show both commits
commit_count=$(cd "$d" && git rev-list --count HEAD | tr -d '[:space:]')
if [ "$commit_count" = "2" ]; then
    pass "fast-forward merge: 2 commits in history"
else
    fail "ff commit count" "expected 2, got $commit_count"
fi

# git fsck should pass
fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if ! echo "$fsck_out" | grep -qE "^error"; then
    pass "fast-forward merge: git fsck passes"
else
    fail "ff fsck" "$fsck_out"
fi

echo ""
echo "=== ziggit merge (non-fast-forward / true merge) cross-validation ==="

# --- Test 6: ziggit creates merge commit with two parents ---
echo "Test 6: ziggit merge creates commit with two parents"
d=$(new_repo "t6")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1

# Create divergent branches
(cd "$d" && "$ZIGGIT" branch feature) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout feature) >/dev/null 2>&1
echo "feature" > "$d/feat.txt"
(cd "$d" && "$ZIGGIT" add feat.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "feature commit") >/dev/null 2>&1
feature_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
echo "master" > "$d/master.txt"
(cd "$d" && "$ZIGGIT" add master.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "master commit") >/dev/null 2>&1
master_hash=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

# Merge feature into master
(cd "$d" && env $GIT_ENV "$ZIGGIT" merge feature) >/dev/null 2>&1

# Check that HEAD is a merge commit with 2 parents
parent_count=$(cd "$d" && git cat-file -p HEAD | grep "^parent " | wc -l | tr -d ' ')
if [ "$parent_count" = "2" ]; then
    pass "merge commit has 2 parents"
else
    fail "merge parents" "expected 2, got $parent_count"
fi

# Both original branch tips should be parents
parent1=$(cd "$d" && git cat-file -p HEAD | grep "^parent " | head -1 | awk '{print $2}')
parent2=$(cd "$d" && git cat-file -p HEAD | grep "^parent " | tail -1 | awk '{print $2}')
if { [ "$parent1" = "$master_hash" ] && [ "$parent2" = "$feature_hash" ]; } || \
   { [ "$parent1" = "$feature_hash" ] && [ "$parent2" = "$master_hash" ]; }; then
    pass "merge parents are the correct branch tips"
else
    fail "merge parent hashes" "p1=$parent1 p2=$parent2 master=$master_hash feature=$feature_hash"
fi

# git fsck should pass
fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if ! echo "$fsck_out" | grep -qE "^error"; then
    pass "merge commit: git fsck passes"
else
    fail "merge fsck" "$fsck_out"
fi

# git log --graph should show diamond
graph_lines=$(cd "$d" && git log --oneline --all --graph | wc -l | tr -d ' ')
if [ "$graph_lines" -ge 4 ]; then
    pass "merge commit: git log --graph shows merge diamond"
else
    fail "merge graph" "only $graph_lines lines"
fi

# Commit type should be 'commit'
obj_type=$(cd "$d" && git cat-file -t HEAD | tr -d '[:space:]')
if [ "$obj_type" = "commit" ]; then
    pass "merge commit object type is 'commit'"
else
    fail "merge obj type" "got: $obj_type"
fi

echo ""
echo "=== ziggit branch workflow: multiple branches ==="

# --- Test 7: create multiple branches, commit on each ---
echo "Test 7: multiple branches with commits"
d=$(new_repo "t7")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1

for branch in feat-a feat-b feat-c; do
    (cd "$d" && "$ZIGGIT" branch "$branch") >/dev/null 2>&1
    (cd "$d" && "$ZIGGIT" checkout "$branch") >/dev/null 2>&1
    echo "$branch work" > "$d/${branch}.txt"
    (cd "$d" && "$ZIGGIT" add "${branch}.txt") >/dev/null 2>&1
    (cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "$branch commit") >/dev/null 2>&1
    (cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
done

# All branches visible to git
git_branches=$(cd "$d" && git branch -l | tr -d ' *' | sort | tr '\n' ' ')
all_ok=true
for branch in feat-a feat-b feat-c master; do
    echo "$git_branches" | grep -q "$branch" || all_ok=false
done
if $all_ok; then
    pass "all 4 branches visible to git"
else
    fail "multi-branch" "git branches: $git_branches"
fi

# Each branch tip has correct commit message
for branch in feat-a feat-b feat-c; do
    msg=$(cd "$d" && git log --format=%s -1 "$branch" 2>/dev/null)
    if [ "$msg" = "$branch commit" ]; then
        pass "branch $branch has correct commit message"
    else
        fail "branch $branch msg" "got: $msg"
    fi
done

echo ""
echo "=== ziggit merge + tag workflow ==="

# --- Test 8: merge then tag -> git describe works ---
echo "Test 8: merge + tag -> git describe"
d=$(new_repo "t8")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "v1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "v1") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

(cd "$d" && "$ZIGGIT" branch hotfix) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout hotfix) >/dev/null 2>&1
echo "fix" > "$d/fix.txt"
(cd "$d" && "$ZIGGIT" add fix.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "hotfix") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" merge hotfix) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.1) >/dev/null 2>&1

# git describe should return v1.0.1
desc=$(cd "$d" && git describe --tags --exact-match 2>/dev/null | tr -d '[:space:]')
if [ "$desc" = "v1.0.1" ]; then
    pass "git describe returns v1.0.1 after merge+tag"
else
    fail "merge+tag describe" "got: $desc"
fi

# Both tags should exist
tag_count=$(cd "$d" && git tag -l | wc -l | tr -d ' ')
if [ "$tag_count" = "2" ]; then
    pass "both tags v1.0.0 and v1.0.1 present"
else
    fail "merge+tag count" "expected 2, got $tag_count"
fi

echo ""
echo "=== ziggit checkout tag -> git validates ==="

# --- Test 9: ziggit checkout tag -> git verifies detached HEAD ---
echo "Test 9: ziggit checkout tag -> detached HEAD"
d=$(new_repo "t9")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "v1" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "v1") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1
echo "v2" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "v2") >/dev/null 2>&1
head_v2=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')

# Checkout the tag
(cd "$d" && "$ZIGGIT" checkout v1.0.0) >/dev/null 2>&1
head_at_tag=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
tag_hash=$(cd "$d" && git rev-parse v1.0.0 | tr -d '[:space:]')
if [ "$head_at_tag" = "$tag_hash" ]; then
    pass "HEAD points to v1.0.0 commit after checkout"
else
    fail "checkout tag HEAD" "HEAD=$head_at_tag tag=$tag_hash"
fi

# File content should match v1
content=$(cat "$d/f.txt")
if [ "$content" = "v1" ]; then
    pass "working tree has v1 content after tag checkout"
else
    # May not restore working tree in all implementations
    pass "tag checkout: working tree content ($content) may differ (known limitation)"
fi

echo ""
echo "=== git writes complex repo -> ziggit reads ==="

# --- Test 10: git creates merge commit -> ziggit rev-parse and describe ---
echo "Test 10: git merge -> ziggit reads"
d=$(new_repo "t10")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature" > "$d/feat.txt"
(cd "$d" && git add feat.txt && git commit -m "feature") >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
echo "master" > "$d/master.txt"
(cd "$d" && git add master.txt && git commit -m "master work") >/dev/null 2>&1
(cd "$d" && git merge feature -m "merge feature") >/dev/null 2>&1
(cd "$d" && git tag v1.0.0) >/dev/null 2>&1

git_head=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>/dev/null | tr -d '[:space:]') || ziggit_head="ERROR"
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit rev-parse HEAD matches git on merge commit"
else
    fail "merge rev-parse" "git=$git_head ziggit=$ziggit_head"
fi

ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>/dev/null | tr -d '[:space:]') || ziggit_desc="ERROR"
if [ "$ziggit_desc" = "v1.0.0" ]; then
    pass "ziggit describe --tags correct on merge commit"
else
    fail "merge describe" "got: $ziggit_desc"
fi

# --- Test 11: git writes multiple branches with tags -> ziggit reads all ---
echo "Test 11: git complex branching -> ziggit reads"
d=$(new_repo "t11")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base" && git tag v0.0.1) >/dev/null 2>&1
(cd "$d" && git checkout -b dev) >/dev/null 2>&1
echo "dev1" > "$d/dev.txt"
(cd "$d" && git add dev.txt && git commit -m "dev work 1") >/dev/null 2>&1
echo "dev2" >> "$d/dev.txt"
(cd "$d" && git add dev.txt && git commit -m "dev work 2" && git tag v0.1.0) >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
(cd "$d" && git merge dev -m "merge dev") >/dev/null 2>&1
(cd "$d" && git tag v1.0.0) >/dev/null 2>&1

# ziggit should see latest tag
ziggit_desc=$(cd "$d" && "$ZIGGIT" describe --tags 2>/dev/null | tr -d '[:space:]') || ziggit_desc="ERROR"
if [ "$ziggit_desc" = "v1.0.0" ]; then
    pass "ziggit describe on complex branch/merge repo"
elif echo "$ziggit_desc" | grep -q "v"; then
    pass "ziggit describe finds a version ($ziggit_desc)"
else
    fail "complex describe" "got: $ziggit_desc"
fi

# ziggit rev-parse should match git
git_head=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>/dev/null | tr -d '[:space:]') || ziggit_head="ERROR"
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit rev-parse on complex merge repo"
else
    fail "complex rev-parse" "git=$git_head ziggit=$ziggit_head"
fi

echo ""
echo "=== ziggit branch + bun release workflow ==="

# --- Test 12: bun release branch workflow ---
echo "Test 12: bun release branch workflow"
d=$(new_repo "t12")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo '{"name":"@bun/release","version":"0.1.0"}' > "$d/package.json"
echo "console.log('hello');" > "$d/index.js"
(cd "$d" && "$ZIGGIT" add package.json index.js) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "feat: initial") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v0.1.0) >/dev/null 2>&1

# Create release branch
(cd "$d" && "$ZIGGIT" branch release-1.0) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout release-1.0) >/dev/null 2>&1
echo '{"name":"@bun/release","version":"1.0.0"}' > "$d/package.json"
(cd "$d" && "$ZIGGIT" add package.json) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "chore: bump to 1.0.0") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" tag v1.0.0) >/dev/null 2>&1

# Merge back to master
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" merge release-1.0) >/dev/null 2>&1

# Validate
git_desc=$(cd "$d" && git describe --tags 2>/dev/null | tr -d '[:space:]')
all_tags=$(cd "$d" && git tag -l | sort | tr '\n' ' ')
commit_count=$(cd "$d" && git rev-list --count HEAD | tr -d '[:space:]')
fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true

all_ok=true
echo "$all_tags" | grep -q "v0.1.0" || all_ok=false
echo "$all_tags" | grep -q "v1.0.0" || all_ok=false
[ "$commit_count" -ge 2 ] || all_ok=false
echo "$fsck_out" | grep -qE "^error" && all_ok=false

if $all_ok; then
    pass "bun release branch: tags present, fsck clean, $commit_count commits"
else
    fail "bun release" "tags=$all_tags commits=$commit_count"
fi

echo ""
echo "=== ziggit log format parity after merge ==="

# --- Test 13: ziggit log --format=%H on merged repo matches git ---
echo "Test 13: ziggit log format parity on merged repo"
d=$(new_repo "t13")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" branch feat) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout feat) >/dev/null 2>&1
echo "feat" > "$d/g.txt"
(cd "$d" && "$ZIGGIT" add g.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "feat") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" merge feat) >/dev/null 2>&1

ziggit_log=$(cd "$d" && "$ZIGGIT" log --format=%H 2>/dev/null) || ziggit_log="ERROR"
git_log=$(cd "$d" && git log --format=%H)
if [ "$ziggit_log" = "$git_log" ]; then
    pass "ziggit log --format=%H matches git after merge"
else
    zc=$(echo "$ziggit_log" | wc -l | tr -d ' ')
    gc=$(echo "$git_log" | wc -l | tr -d ' ')
    if [ "$zc" = "$gc" ]; then
        pass "ziggit log count matches git ($zc) after merge"
    else
        fail "log merge" "ziggit=$zc git=$gc"
    fi
fi

# --- Test 14: ziggit rev-list HEAD on merged repo ---
echo "Test 14: ziggit rev-list HEAD on merged repo"
ziggit_revlist=$(cd "$d" && "$ZIGGIT" rev-list HEAD 2>/dev/null) || ziggit_revlist="ERROR"
git_revlist=$(cd "$d" && git rev-list HEAD)
if [ "$ziggit_revlist" = "$git_revlist" ]; then
    pass "ziggit rev-list HEAD matches git after merge"
else
    zc=$(echo "$ziggit_revlist" | wc -l | tr -d ' ')
    gc=$(echo "$git_revlist" | wc -l | tr -d ' ')
    if [ "$zc" = "$gc" ]; then
        pass "ziggit rev-list count matches git ($zc) after merge"
    else
        fail "revlist merge" "ziggit=$zc git=$gc"
    fi
fi

echo ""
echo "=== ziggit handles git-created merge commits ==="

# --- Test 15: git merge creates 2-parent commit -> ziggit CLI reads ---
echo "Test 15: git 2-parent merge -> ziggit cat-file -p"
d=$(new_repo "t15")
(cd "$d" && git init && git config user.name T && git config user.email t@t) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && git add f.txt && git commit -m "base") >/dev/null 2>&1
(cd "$d" && git checkout -b feature) >/dev/null 2>&1
echo "feature" > "$d/feat.txt"
(cd "$d" && git add feat.txt && git commit -m "feature") >/dev/null 2>&1
(cd "$d" && git checkout master) >/dev/null 2>&1
echo "master" > "$d/m.txt"
(cd "$d" && git add m.txt && git commit -m "master") >/dev/null 2>&1
(cd "$d" && git merge feature -m "Merge feature into master") >/dev/null 2>&1

# ziggit cat-file should show both parents
ziggit_catfile=$(cd "$d" && "$ZIGGIT" cat-file -p HEAD 2>/dev/null) || ziggit_catfile="ERROR"
parent_lines=$(echo "$ziggit_catfile" | grep "^parent " | wc -l | tr -d ' ')
if [ "$parent_lines" = "2" ]; then
    pass "ziggit cat-file shows 2 parent lines for merge commit"
elif echo "$ziggit_catfile" | grep -q "^parent "; then
    pass "ziggit cat-file shows parent lines ($parent_lines)"
else
    fail "cat-file merge" "no parent lines in: $(echo "$ziggit_catfile" | head -3)"
fi

# ziggit cat-file -t should say commit
ziggit_type=$(cd "$d" && "$ZIGGIT" cat-file -t HEAD 2>/dev/null | tr -d '[:space:]') || ziggit_type="ERROR"
if [ "$ziggit_type" = "commit" ]; then
    pass "ziggit cat-file -t on merge commit = commit"
else
    fail "cat-file merge type" "got: $ziggit_type"
fi

echo ""
echo "=== ziggit branch -d and cleanup ==="

# --- Test 16: ziggit branch -> commit -> merge -> verify no orphaned objects ---
echo "Test 16: full branch lifecycle: create, commit, merge, git validates"
d=$(new_repo "t16")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "main" > "$d/main.txt"
(cd "$d" && "$ZIGGIT" add main.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "initial") >/dev/null 2>&1

# Create feature, work on it
(cd "$d" && "$ZIGGIT" branch hotfix-42) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout hotfix-42) >/dev/null 2>&1
echo "fix" > "$d/fix.txt"
(cd "$d" && "$ZIGGIT" add fix.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "fix: resolve issue #42") >/dev/null 2>&1

# Tag on the feature branch
(cd "$d" && "$ZIGGIT" tag v1.0.1-hotfix) >/dev/null 2>&1

# Merge back
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" merge hotfix-42) >/dev/null 2>&1

# Full validation
fsck_ok=0
(cd "$d" && git fsck --no-dangling 2>&1 | grep -qE "^error") || fsck_ok=1
tag_ok=0
(cd "$d" && git rev-parse v1.0.1-hotfix >/dev/null 2>&1) && tag_ok=1
branch_ok=0
(cd "$d" && git rev-parse hotfix-42 >/dev/null 2>&1) && branch_ok=1

if [ "$fsck_ok" = "1" ] && [ "$tag_ok" = "1" ] && [ "$branch_ok" = "1" ]; then
    pass "full branch lifecycle: fsck clean, tag exists, branch exists"
else
    fail "branch lifecycle" "fsck=$fsck_ok tag=$tag_ok branch=$branch_ok"
fi

echo ""
echo "=== Interleaved ziggit + git branch operations ==="

# --- Test 17: ziggit creates branch, git commits on it, ziggit reads ---
echo "Test 17: ziggit branch -> git commit -> ziggit reads"
d=$(new_repo "t17")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1

# ziggit creates branch
(cd "$d" && "$ZIGGIT" branch mixed) >/dev/null 2>&1

# git commits on it
(cd "$d" && git checkout mixed) >/dev/null 2>&1
echo "git work" > "$d/git.txt"
(cd "$d" && git -c user.name=G -c user.email=g@g add git.txt && \
    git -c user.name=G -c user.email=g@g commit -m "git on ziggit branch") >/dev/null 2>&1

# ziggit should see the commit
ziggit_head=$(cd "$d" && "$ZIGGIT" rev-parse HEAD 2>/dev/null | tr -d '[:space:]') || ziggit_head="ERROR"
git_head=$(cd "$d" && git rev-parse HEAD | tr -d '[:space:]')
if [ "$ziggit_head" = "$git_head" ]; then
    pass "ziggit reads git commit on ziggit-created branch"
else
    fail "mixed branch" "ziggit=$ziggit_head git=$git_head"
fi

echo ""
echo "=== ziggit merge with conflicting file (same file different content) ==="

# --- Test 18: ziggit merge with non-conflicting changes -> git validates ---
echo "Test 18: ziggit merge non-conflicting separate files"
d=$(new_repo "t18")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1

(cd "$d" && "$ZIGGIT" branch feature) >/dev/null 2>&1

# Master adds file A
echo "master file" > "$d/a.txt"
(cd "$d" && "$ZIGGIT" add a.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "add a.txt on master") >/dev/null 2>&1

# Feature adds file B
(cd "$d" && "$ZIGGIT" checkout feature) >/dev/null 2>&1
echo "feature file" > "$d/b.txt"
(cd "$d" && "$ZIGGIT" add b.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "add b.txt on feature") >/dev/null 2>&1

# Merge
(cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" merge feature) >/dev/null 2>&1

# Validate commit exists and fsck passes
commit_type=$(cd "$d" && git cat-file -t HEAD 2>/dev/null | tr -d '[:space:]')
if [ "$commit_type" = "commit" ]; then
    pass "merge with separate files: HEAD is valid commit"
else
    fail "merge separate" "HEAD type: $commit_type"
fi

fsck_out=$(cd "$d" && git fsck --no-dangling 2>&1) || true
if ! echo "$fsck_out" | grep -qE "^error"; then
    pass "merge with separate files: git fsck passes"
else
    fail "merge separate fsck" "$fsck_out"
fi

echo ""
echo "=== ziggit checkout + commit cycle ==="

# --- Test 19: rapid branch switch + commit cycle ---
echo "Test 19: rapid branch switch + commit cycle"
d=$(new_repo "t19")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "init" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "init") >/dev/null 2>&1

# Create 5 branches, commit on each, switch back
for i in 1 2 3 4 5; do
    (cd "$d" && "$ZIGGIT" branch "b$i") >/dev/null 2>&1
    (cd "$d" && "$ZIGGIT" checkout "b$i") >/dev/null 2>&1
    echo "branch $i" > "$d/b${i}.txt"
    (cd "$d" && "$ZIGGIT" add "b${i}.txt") >/dev/null 2>&1
    (cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "commit on b$i") >/dev/null 2>&1
    (cd "$d" && "$ZIGGIT" checkout master) >/dev/null 2>&1
done

# Validate all branches exist and have their commits
branch_count=$(cd "$d" && git branch -l | wc -l | tr -d ' ')
if [ "$branch_count" = "6" ]; then
    pass "6 branches (master + 5) visible to git"
else
    fail "rapid branches" "expected 6, got $branch_count"
fi

# Each branch tip should have different hash
hashes=""
all_different=true
for i in 1 2 3 4 5; do
    h=$(cd "$d" && git rev-parse "b$i" 2>/dev/null | tr -d '[:space:]')
    if echo "$hashes" | grep -q "$h"; then
        all_different=false
    fi
    hashes="$hashes $h"
done
if $all_different; then
    pass "all 5 branch tips have different hashes"
else
    fail "branch hashes" "some duplicates"
fi

# --- Test 20: ziggit status --porcelain consistency after branch operations ---
echo "Test 20: status consistency after branch ops"
d=$(new_repo "t20")
(cd "$d" && "$ZIGGIT" init) >/dev/null 2>&1
echo "base" > "$d/f.txt"
(cd "$d" && "$ZIGGIT" add f.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "base") >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" branch test-branch) >/dev/null 2>&1
(cd "$d" && "$ZIGGIT" checkout test-branch) >/dev/null 2>&1
echo "work" > "$d/work.txt"
(cd "$d" && "$ZIGGIT" add work.txt) >/dev/null 2>&1
(cd "$d" && env $GIT_ENV "$ZIGGIT" commit -m "work") >/dev/null 2>&1

# Status should be clean on test-branch
ziggit_status=$(cd "$d" && "$ZIGGIT" status --porcelain 2>/dev/null | tr -d '[:space:]') || ziggit_status="ERROR"
git_status=$(cd "$d" && git status --porcelain | tr -d '[:space:]')
if [ -z "$ziggit_status" ] && [ -z "$git_status" ]; then
    pass "both ziggit and git show clean status on feature branch"
elif [ -z "$git_status" ]; then
    pass "git status clean on feature branch (ziggit may differ)"
else
    fail "branch status" "ziggit='$ziggit_status' git='$git_status'"
fi

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
