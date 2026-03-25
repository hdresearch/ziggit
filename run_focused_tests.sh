#!/bin/bash

# Ziggit Compatibility Test Runner
# Focused on core git functionality and git source test adaptations

set -e

echo "=== Ziggit Compatibility Test Runner ==="
echo "Building ziggit..."

# Set up environment
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

# Build ziggit
zig build

echo "✓ Build complete"
echo ""

echo "Running focused compatibility tests..."

# Compile and run focused tests
zig run test/focused_main.zig --name focused_tests

echo ""
echo "Running Zig unit tests..."

# Run individual test files
echo "Testing core_git_compatibility_tests.zig:"
zig test test/core_git_compatibility_tests.zig

echo "Testing git_source_adapted_tests.zig:"
zig test test/git_source_adapted_tests.zig

echo ""
echo "=== All Tests Complete ==="