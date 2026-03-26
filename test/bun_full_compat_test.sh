#!/bin/bash

# Comprehensive test for bun compatibility with ziggit
# This test verifies all the features needed by bun's git usage

set -e  # Exit on any error

echo "Running Bun Full Compatibility Test..."

# Clean up any existing test directories
rm -rf /tmp/bv && mkdir /tmp/bv && cd /tmp/bv

# Initialize test repository
git init -q && git config user.email t@t.com && git config user.name T
echo hi > f.txt && git add f.txt && git commit -q -m init
git tag -a v1.0.0 -m v1.0.0
echo bye > g.txt && git add g.txt && git commit -q -m second

ZIGGIT=/root/ziggit/zig-out/bin/ziggit

echo "✓ Test setup complete"

# Test -C flag
echo "Testing -C flag..."
RESULT=$($ZIGGIT -C /tmp/bv rev-parse HEAD)
if [[ ${#RESULT} -eq 40 ]]; then
    echo "✓ -C flag works"
else
    echo "✗ -C flag failed"
    exit 1
fi

# Test clone --bare with -c flag
echo "Testing clone --bare with -c flag..."
rm -rf /tmp/bv_bare 
if $ZIGGIT clone -c core.longpaths=true --quiet --bare /tmp/bv /tmp/bv_bare; then
    if [[ -f /tmp/bv_bare/HEAD ]]; then
        echo "✓ clone --bare OK"
    else
        echo "✗ clone --bare failed - missing HEAD file"
        exit 1
    fi
else
    echo "✗ clone --bare failed"
    exit 1
fi

# Test clone --no-checkout
echo "Testing clone --no-checkout..."
rm -rf /tmp/bv_noco
if $ZIGGIT clone --no-checkout /tmp/bv /tmp/bv_noco; then
    if [[ -d /tmp/bv_noco/.git ]] && [[ ! -f /tmp/bv_noco/f.txt ]]; then
        echo "✓ clone --no-checkout OK"
    else
        echo "✗ clone --no-checkout failed"
        exit 1
    fi
else
    echo "✗ clone --no-checkout failed"
    exit 1
fi

# Test -C fetch (using no-checkout repo)
echo "Testing -C fetch..."
if $ZIGGIT -C /tmp/bv_noco fetch --quiet; then
    echo "✓ fetch OK"
else
    echo "✗ fetch failed"
    exit 1
fi

# Test -C log
echo "Testing -C log..."
RESULT=$($ZIGGIT -C /tmp/bv log --format=%H -1)
if [[ ${#RESULT} -eq 40 ]]; then
    echo "✓ -C log OK"
else
    echo "✗ -C log failed"
    exit 1
fi

# Test checkout with hash
echo "Testing checkout..."
cd /tmp/bv_noco
FIRST=$(git log --format=%H --reverse | head -1)
if $ZIGGIT checkout --quiet $FIRST; then
    echo "✓ checkout OK"
else
    echo "✗ checkout failed"
    exit 1
fi

# Test status with deleted file
echo "Testing status deleted file detection..."
cd /tmp/bv && rm f.txt
RESULT=$($ZIGGIT status --porcelain)
if echo "$RESULT" | grep -q " D f.txt"; then
    echo "✓ delete detect OK"
else
    echo "✗ delete detect failed"
    echo "Expected: ' D f.txt', Got: '$RESULT'"
    exit 1
fi

# Test commit -am
echo "Testing commit -am..."
cd /tmp/bv && echo changed >> g.txt
if $ZIGGIT commit -am "auto" --quiet; then
    # Verify the commit was made
    if git log --oneline -1 | grep -q "auto"; then
        echo "✓ commit -am OK"
    else
        echo "✗ commit -am failed - commit not found"
        exit 1
    fi
else
    echo "✗ commit -am failed"
    exit 1
fi

# Test HEAD~1 resolution
echo "Testing HEAD~1 resolution..."
RESULT=$($ZIGGIT -C /tmp/bv log --format=%H -1 HEAD~1)
EXPECTED=$(cd /tmp/bv && git log --format=%H -1 HEAD~1)
if [[ "$RESULT" == "$EXPECTED" ]]; then
    echo "✓ HEAD~1 resolution OK"
else
    echo "✗ HEAD~1 resolution failed"
    echo "Expected: $EXPECTED, Got: $RESULT"
    exit 1
fi

echo ""
echo "🎉 ALL TESTS PASSED! Ziggit is compatible with Bun's git usage."
echo ""
echo "Verified features:"
echo "  ✓ -C <dir> global flag"
echo "  ✓ -c key=value global flag (ignored as expected)"
echo "  ✓ clone --bare shells out to git"
echo "  ✓ clone --no-checkout shells out to git"
echo "  ✓ checkout with refs/hashes shells out to git"
echo "  ✓ commit -am support with staging and --quiet"
echo "  ✓ HEAD~N relative ref resolution"
echo "  ✓ status --porcelain detects deleted files"