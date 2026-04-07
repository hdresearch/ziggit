#!/bin/bash
# test/cli_init_agent_test.sh - Test init-agent subcommand
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIGGIT="${ZIGGIT:-$SCRIPT_DIR/../zig-out/bin/ziggit}"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ FAIL: $1"; FAIL=$((FAIL+1)); }

if [ ! -x "$ZIGGIT" ]; then
    echo "Building ziggit..."
    (cd "$SCRIPT_DIR/.." && zig build 2>/dev/null) || { echo "Build failed"; exit 1; }
fi

TMPDIR=$(mktemp -d /tmp/ziggit_cli_init_agent_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# Mock HOME so we don't modify the real ~/.claude/CLAUDE.md
export HOME="$TMPDIR/fake_home"
mkdir -p "$HOME"

echo "=== CLI init-agent Tests ==="

# ---- Test 1: First run creates ziggit.md and appends to CLAUDE.md ----
echo "Test 1: First run"
mkdir -p "$TMPDIR/t1"
(cd "$TMPDIR/t1" && $ZIGGIT init-agent)

if [ -f "$TMPDIR/t1/ziggit.md" ]; then
    pass "ziggit.md created"
else
    fail "ziggit.md created"
fi

if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    pass "CLAUDE.md created"
else
    fail "CLAUDE.md created"
fi

if grep -q "@ziggit.md" "$HOME/.claude/CLAUDE.md"; then
    pass "@ziggit.md appended to CLAUDE.md"
else
    fail "@ziggit.md appended to CLAUDE.md"
fi

# ---- Test 2: Second run does not append duplicate @ziggit.md ----
echo "Test 2: Second run (idempotency)"
# Run it again in the same directory
(cd "$TMPDIR/t1" && $ZIGGIT init-agent)

COUNT=$(grep -c "@ziggit.md" "$HOME/.claude/CLAUDE.md" || true)
if [ "$COUNT" -eq 1 ]; then
    pass "Only one @ziggit.md in CLAUDE.md"
else
    fail "Duplicate @ziggit.md found in CLAUDE.md (count=$COUNT)"
fi

echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
