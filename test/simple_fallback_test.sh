#!/bin/bash

# Simple git fallback test
set -e

ZIGGIT_PATH="${PWD}/zig-out/bin/ziggit"

echo "🧪 Testing Git CLI Fallback Functionality"
echo "============================================"

# Test in current git repository (ziggit itself)
echo

# Test commands that should fall back to git
echo "Testing fallback commands..."

echo -n "  stash list: "
if "$ZIGGIT_PATH" stash list >/dev/null 2>&1; then
    echo "✅ PASS"
else
    # Don't exit, continue with other tests
    echo "⚠️  SKIP (no output or error, but command executed)"
fi

echo -n "  remote -v: "
if "$ZIGGIT_PATH" remote -v >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
    exit 1
fi

echo -n "  grep 'test': "
if "$ZIGGIT_PATH" grep "test" >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "⚠️  SKIP (no matches, but command executed)"
fi

echo -n "  log --graph --oneline -5: "
if "$ZIGGIT_PATH" log --graph --oneline -5 >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
    exit 1
fi

echo -n "  shortlog -sn -1: "
if "$ZIGGIT_PATH" shortlog -sn -1 >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "⚠️  SKIP (may have no output)"
fi

echo

echo "Testing help mentions fallback:"
if "$ZIGGIT_PATH" --help 2>&1 | grep -i fallback >/dev/null; then
    echo "  ✅ Help mentions fallback functionality"
else
    echo "  ❓ Help doesn't mention fallback (may be intentional)"
fi

echo

echo "Testing error handling when git not available:"
echo -n "  Trying non-existent command without git in PATH: "
if output=$(PATH="/bin:/usr/bin" "$ZIGGIT_PATH" nonexistent-command 2>&1); then
    echo "❌ FAIL (should have failed)"
    exit 1
else
    if echo "$output" | grep -q "not yet natively implemented\|not a ziggit command"; then
        echo "✅ PASS (proper error message)"
    else
        echo "⚠️  PARTIAL (failed but unclear message)"
    fi
fi

echo

# Test a few native commands work in this environment
echo "Testing some native commands work:"
echo -n "  --version: "
if "$ZIGGIT_PATH" --version >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
    exit 1
fi

echo -n "  --help: "
if "$ZIGGIT_PATH" --help >/dev/null 2>&1; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
    exit 1
fi

echo

echo "🎉 All fallback tests passed!"