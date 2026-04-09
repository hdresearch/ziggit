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

# Mock HOME so we don't modify the real agent configs
export HOME="$TMPDIR/fake_home"
mkdir -p "$HOME"

echo "=== CLI init-agent Tests ==="

# ---- Test 1: Help flag ----
echo "Test 1: --help"
HELP_OUT=$($ZIGGIT init-agent --help 2>&1)
if echo "$HELP_OUT" | grep -q "usage: ziggit init-agent"; then
    pass "--help shows usage"
else
    fail "--help shows usage"
fi
if echo "$HELP_OUT" | grep -q "Supported agents"; then
    pass "--help lists supported agents"
else
    fail "--help lists supported agents"
fi

# ---- Test 2: First run with no agent dirs — creates ziggit.md only ----
echo "Test 2: No agent dirs present"
mkdir -p "$TMPDIR/t2"
OUT2=$(cd "$TMPDIR/t2" && $ZIGGIT init-agent 2>&1)

if [ -f "$TMPDIR/t2/ziggit.md" ]; then
    pass "ziggit.md created"
else
    fail "ziggit.md created"
fi
if echo "$OUT2" | grep -q "No agent config directories"; then
    pass "reports no agent dirs found"
else
    fail "reports no agent dirs found"
fi

# ---- Test 3: With ~/.claude present ----
echo "Test 3: Claude agent dir"
mkdir -p "$HOME/.claude"
mkdir -p "$TMPDIR/t3"
OUT3=$(cd "$TMPDIR/t3" && $ZIGGIT init-agent 2>&1)

if [ -f "$HOME/.claude/CLAUDE.md" ] && grep -q "@ziggit.md" "$HOME/.claude/CLAUDE.md"; then
    pass "@ziggit.md appended to CLAUDE.md"
else
    fail "@ziggit.md appended to CLAUDE.md"
fi

# ---- Test 4: Idempotency — second run doesn't duplicate ----
echo "Test 4: Idempotency"
(cd "$TMPDIR/t3" && $ZIGGIT init-agent >/dev/null 2>&1)
COUNT=$(grep -c "@ziggit.md" "$HOME/.claude/CLAUDE.md" || true)
if [ "$COUNT" -eq 1 ]; then
    pass "only one @ziggit.md in CLAUDE.md"
else
    fail "duplicate @ziggit.md in CLAUDE.md (count=$COUNT)"
fi

# ---- Test 5: Multiple agent dirs ----
echo "Test 5: Multiple agents"
mkdir -p "$HOME/.gemini"
mkdir -p "$HOME/.codex"
mkdir -p "$TMPDIR/t5"
(cd "$TMPDIR/t5" && $ZIGGIT init-agent >/dev/null 2>&1)

for pair in ".gemini/GEMINI.md" ".codex/CODEX.md"; do
    if [ -f "$HOME/$pair" ] && grep -q "@ziggit.md" "$HOME/$pair"; then
        pass "@ziggit.md in $pair"
    else
        fail "@ziggit.md in $pair"
    fi
done

# ---- Test 6: Skips agents without existing dir ----
echo "Test 6: Skips non-existent agent dirs"
if [ ! -f "$HOME/.cursor/rules" ]; then
    pass ".cursor/rules not created (dir doesn't exist)"
else
    fail ".cursor/rules should not be created"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
