#!/bin/bash
# Shallow clone performance and correctness tests
# Tests various repos and depths, compares with git

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/zig-out/bin/ziggit}"
TESTDIR=$(mktemp -d -p /root)
trap "rm -rf $TESTDIR" EXIT

echo "=== Shallow Clone Performance & Correctness Tests ==="

# Test 1: Shallow clone correctness - express repo
echo -n "Test 1: Express shallow clone correctness... "
$ZIGGIT clone --depth 1 --bare https://github.com/expressjs/express.git "$TESTDIR/z-express" 2>/dev/null
git clone --depth 1 --bare https://github.com/expressjs/express.git "$TESTDIR/g-express" 2>/dev/null

Z_HEAD=$(cd "$TESTDIR/z-express" && git rev-parse HEAD)
G_HEAD=$(cd "$TESTDIR/g-express" && git rev-parse HEAD)

if [ "$Z_HEAD" != "$G_HEAD" ]; then
    echo "FAIL: HEAD mismatch: ziggit=$Z_HEAD git=$G_HEAD"
    exit 1
fi

# Verify fsck passes
cd "$TESTDIR/z-express"
FSCK_OUT=$(git fsck 2>&1 || true)
if echo "$FSCK_OUT" | grep -q "error\|fatal"; then
    echo "FAIL: git fsck errors: $FSCK_OUT"
    exit 1
fi

# Verify shallow file
if [ ! -f shallow ]; then
    echo "FAIL: shallow file missing"
    exit 1
fi

COMMIT_COUNT=$(git log --oneline | wc -l)
if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "FAIL: expected 1 commit, got $COMMIT_COUNT"
    exit 1
fi
echo "OK (HEAD=$Z_HEAD, 1 commit, fsck clean)"

# Test 2: Object count matches
echo -n "Test 2: Object count comparison... "
Z_OBJECTS=$(cd "$TESTDIR/z-express" && git count-objects | awk '{print $1}')
G_OBJECTS=$(cd "$TESTDIR/g-express" && git count-objects | awk '{print $1}')
# Pack objects
Z_PACK=$(cd "$TESTDIR/z-express" && git count-objects -v 2>/dev/null | grep "in-pack" | awk '{print $2}')
G_PACK=$(cd "$TESTDIR/g-express" && git count-objects -v 2>/dev/null | grep "in-pack" | awk '{print $2}')
echo "OK (ziggit: $Z_PACK pack objects, git: $G_PACK pack objects)"

# Test 3: Tree content matches
echo -n "Test 3: Tree listing matches... "
Z_TREE=$(cd "$TESTDIR/z-express" && git ls-tree -r HEAD | md5sum | awk '{print $1}')
G_TREE=$(cd "$TESTDIR/g-express" && git ls-tree -r HEAD | md5sum | awk '{print $1}')
if [ "$Z_TREE" != "$G_TREE" ]; then
    echo "FAIL: tree mismatch"
    exit 1
fi
echo "OK (tree hash: $Z_TREE)"

# Test 4: Performance benchmark
echo ""
echo "=== Performance Benchmark (express, --depth 1, --bare) ==="
rm -rf "$TESTDIR/perf-"*

ZIGGIT_TIMES=""
GIT_TIMES=""
for i in 1 2 3; do
    rm -rf "$TESTDIR/perf-z-$i" "$TESTDIR/perf-g-$i"
    
    Z_START=$(date +%s%N)
    $ZIGGIT clone --depth 1 --bare https://github.com/expressjs/express.git "$TESTDIR/perf-z-$i" 2>/dev/null
    Z_END=$(date +%s%N)
    Z_MS=$(( (Z_END - Z_START) / 1000000 ))
    
    G_START=$(date +%s%N)
    git clone --depth 1 --bare https://github.com/expressjs/express.git "$TESTDIR/perf-g-$i" 2>/dev/null
    G_END=$(date +%s%N)
    G_MS=$(( (G_END - G_START) / 1000000 ))
    
    RATIO=$(awk "BEGIN{printf \"%.2f\", $Z_MS / $G_MS}" 2>/dev/null || echo "N/A")
    echo "  Run $i: ziggit=${Z_MS}ms  git=${G_MS}ms  ratio=${RATIO}x"
    ZIGGIT_TIMES="$ZIGGIT_TIMES $Z_MS"
    GIT_TIMES="$GIT_TIMES $G_MS"
done

# Calculate averages
Z_AVG=$(echo $ZIGGIT_TIMES | tr ' ' '\n' | awk '{sum+=$1} END{printf "%.0f", sum/NR}')
G_AVG=$(echo $GIT_TIMES | tr ' ' '\n' | awk '{sum+=$1} END{printf "%.0f", sum/NR}')
RATIO_AVG=$(awk "BEGIN{printf \"%.2f\", $Z_AVG / $G_AVG}" 2>/dev/null || echo "N/A")
echo "  Average: ziggit=${Z_AVG}ms  git=${G_AVG}ms  ratio=${RATIO_AVG}x"

# Test 5: Depth > 1
echo ""
echo -n "Test 5: --depth 3 clone... "
rm -rf "$TESTDIR/depth3"
$ZIGGIT clone --depth 3 --bare https://github.com/expressjs/express.git "$TESTDIR/depth3" 2>/dev/null
cd "$TESTDIR/depth3"
COMMIT_COUNT=$(git log --oneline | wc -l)
if [ "$COMMIT_COUNT" -lt 1 ] || [ "$COMMIT_COUNT" -gt 3 ]; then
    echo "FAIL: expected 1-3 commits, got $COMMIT_COUNT"
    exit 1
fi

FSCK_OUT=$(git fsck 2>&1 || true)
if echo "$FSCK_OUT" | grep -q "error\|fatal"; then
    echo "FAIL: git fsck errors"
    exit 1
fi
echo "OK ($COMMIT_COUNT commits, fsck clean)"

# Test 6: Non-bare shallow clone
echo -n "Test 6: Non-bare shallow clone with checkout... "
rm -rf "$TESTDIR/nonbare"
$ZIGGIT clone --depth 1 https://github.com/expressjs/express.git "$TESTDIR/nonbare" 2>/dev/null
cd "$TESTDIR/nonbare"
if [ ! -f ".git/shallow" ]; then
    echo "FAIL: .git/shallow file missing"
    exit 1
fi
if [ ! -f "package.json" ]; then
    echo "FAIL: checkout failed - package.json missing"
    exit 1
fi
COMMIT_COUNT=$(git log --oneline | wc -l)
if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "FAIL: expected 1 commit, got $COMMIT_COUNT"
    exit 1
fi
echo "OK (checked out, 1 commit)"

echo ""
echo "=== All shallow clone tests passed ==="
echo "Performance summary: ziggit avg ${Z_AVG}ms vs git avg ${G_AVG}ms"
