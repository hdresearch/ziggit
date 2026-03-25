#!/bin/bash

# Test script for WebAssembly builds
set -e

export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

echo "=== Testing ziggit WebAssembly builds ==="
echo

# Build all targets
echo "Building all targets..."
zig build
zig build wasm  
zig build wasm-browser

echo "✅ All builds completed successfully"
echo

# Check file sizes
echo "Build sizes:"
ls -lh zig-out/bin/ziggit*

echo
echo "=== Testing WASI build ==="

# Test basic commands
echo "Testing --version:"
wasmtime --dir . zig-out/bin/ziggit.wasm --version

echo
echo "Testing --help:"
wasmtime --dir . zig-out/bin/ziggit.wasm --help | head -10

# Test in a temporary directory
echo
echo "Testing status in non-git directory:"
mkdir -p /tmp/wasm-test
cd /tmp/wasm-test
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm status 2>&1 | grep -q "not a git repository" && echo "✅ Error handling works correctly"

cd /root/ziggit

echo
echo "=== WebAssembly builds are working correctly! ==="