#!/bin/bash
set -e

echo "=== Native vs Fallback Command Analysis ==="
echo "Testing which ziggit commands are native vs git fallback"

cd /root/ziggit
XDG_CACHE_HOME=/tmp/.cache zig build
ZIGGIT="./zig-out/bin/ziggit"

# Create a test function that detects if git was called
test_command() {
    local cmd="$1"
    echo "Testing: ziggit $cmd"
    
    # Use strace to see if git binary is executed
    if command -v strace > /dev/null 2>&1; then
        strace -f -e execve "$ZIGGIT" $cmd > /tmp/test_output 2>&1 
        if grep -q "execve.*git" /tmp/test_output 2>/dev/null; then
            echo "  → FALLBACK (calls git)"
        else
            echo "  → NATIVE (Zig implementation)"
        fi
    else
        # Fallback method: just run the command and assume it works
        if "$ZIGGIT" $cmd > /tmp/test_output 2>&1; then
            echo "  → WORKS (likely native)"
        else
            echo "  → FAILED (may be fallback with error)"
        fi
    fi
}

echo ""
echo "=== Testing Core Commands ==="
test_command "status"
test_command "log --oneline -3"
test_command "branch"
test_command "tag"
test_command "rev-parse HEAD"
test_command "describe --always"
test_command "diff --name-only"

echo ""
echo "=== Testing Object Commands ==="
test_command "show HEAD --name-only"
test_command "ls-files | head -5"
test_command "cat-file -t HEAD"
test_command "rev-list --count HEAD"

echo ""
echo "=== Testing Fallback Commands ==="
test_command "stash list"
test_command "remote -v"
test_command "shortlog -sn -1"
test_command "blame README.md | head -5"
test_command "fsck"

echo ""
echo "=== Summary ==="
echo "This shows which commands are implemented natively in Zig vs forwarded to git."
echo "Native commands are faster and work in all environments (including WASM)."
echo "Fallback commands require git to be installed but provide 100% compatibility."