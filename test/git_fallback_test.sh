#!/bin/bash
# Test script for git fallback functionality

set -e

echo "Testing git fallback functionality..."

# Build ziggit
ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build

# Test native commands work
echo "Testing native commands..."
echo -n "status: "
./zig-out/bin/ziggit status > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "rev-parse HEAD: "
./zig-out/bin/ziggit rev-parse HEAD > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "log --oneline -1: "
./zig-out/bin/ziggit log --oneline -1 > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "branch: "
./zig-out/bin/ziggit branch > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "tag --list: "
./zig-out/bin/ziggit tag --list > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "describe --always: "
./zig-out/bin/ziggit describe --always > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "diff --cached: "
./zig-out/bin/ziggit diff --cached > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "show HEAD: "
./zig-out/bin/ziggit show HEAD --name-only > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "ls-files: "
./zig-out/bin/ziggit ls-files > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "cat-file -t HEAD: "
./zig-out/bin/ziggit cat-file -t HEAD > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "rev-list --count HEAD: "
./zig-out/bin/ziggit rev-list --count HEAD > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "remote -v: "
./zig-out/bin/ziggit remote -v > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "reset --help (should fail natively): "
./zig-out/bin/ziggit reset --help > /dev/null 2>&1 && echo "FAIL" || echo "OK"

echo -n "rm --help (should fail natively): "
./zig-out/bin/ziggit rm --help > /dev/null 2>&1 && echo "FAIL" || echo "OK"

# Test git fallback commands work (commands not yet implemented natively)
echo "Testing git fallback commands..."
echo -n "stash list: "
./zig-out/bin/ziggit stash list > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "log --graph --oneline -5: "
./zig-out/bin/ziggit log --graph --oneline -5 > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "shortlog -sn -1: "
./zig-out/bin/ziggit shortlog -sn -1 > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "rebase --help: "
./zig-out/bin/ziggit rebase --help > /dev/null 2>&1 && echo "OK" || echo "FAIL"

echo -n "cherry-pick --help: "
./zig-out/bin/ziggit cherry-pick --help > /dev/null 2>&1 && echo "OK" || echo "FAIL"

# Test error handling when git is not in PATH
echo "Testing error handling when git is not found..."
echo -n "stash list (no git): "
OUTPUT=$(PATH=/tmp ./zig-out/bin/ziggit stash list 2>&1) && echo "FAIL (should have failed)" || {
    if echo "$OUTPUT" | grep -q "is not a ziggit command and git is not installed"; then
        echo "OK"
    else
        echo "FAIL (wrong error message: $OUTPUT)"
    fi
}

# Test global flags forwarding
echo "Testing global flags forwarding..."
echo -n "-C flag forwarding: "
./zig-out/bin/ziggit -C /tmp stash list > /dev/null 2>&1 && echo "FAIL (should fail in /tmp)" || echo "OK"

echo "All tests completed!"