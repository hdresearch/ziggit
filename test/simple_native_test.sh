#!/bin/bash

echo "=== Native vs Fallback Command Analysis ==="
echo "Testing which ziggit commands work vs call git"

cd /root/ziggit
XDG_CACHE_HOME=/tmp/.cache zig build
ZIGGIT="./zig-out/bin/ziggit"

# Temporarily rename git to detect fallback calls
if command -v git > /dev/null; then
    echo "Temporarily renaming git to test native vs fallback..."
    sudo mv /usr/bin/git /usr/bin/git.backup 2>/dev/null || true
fi

echo ""
echo "=== Testing Commands Without Git Available ==="

echo "status:"
$ZIGGIT status 2>&1 | head -1

echo "show HEAD:"
$ZIGGIT show HEAD --name-only 2>&1 | head -1

echo "ls-files:"
$ZIGGIT ls-files | head -1 2>&1

echo "cat-file:"
$ZIGGIT cat-file -t HEAD 2>&1

echo "rev-list:"
$ZIGGIT rev-list --count HEAD 2>&1

echo "log:"
$ZIGGIT log --oneline -1 2>&1

echo "branch:"
$ZIGGIT branch 2>&1 | head -1

echo "stash list (should fail):"
$ZIGGIT stash list 2>&1 | head -1

echo "remote -v (should fail):"
$ZIGGIT remote -v 2>&1 | head -1

# Restore git
if [ -f /usr/bin/git.backup ]; then
    echo ""
    echo "Restoring git..."
    sudo mv /usr/bin/git.backup /usr/bin/git 2>/dev/null || true
fi

echo ""
echo "=== Analysis Complete ==="
echo "Commands that worked above are NATIVE (Zig implementation)"
echo "Commands that failed with 'git is not installed' are FALLBACK"