#!/bin/bash

# Test script to demonstrate ziggit WebAssembly functionality

set -e

echo "🚀 Testing ziggit WebAssembly builds..."

# Build all targets
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
echo "Building all targets..."
zig build
zig build wasm  
zig build wasm-browser

echo ""
echo "📊 Build results:"
ls -lh zig-out/bin/

echo ""
echo "🧪 Testing WASI build with wasmtime..."

# Test version
echo "Version check:"
wasmtime zig-out/bin/ziggit.wasm --version

# Test help
echo ""
echo "Help output:"
wasmtime zig-out/bin/ziggit.wasm --help | head -5

# Test init in a temporary directory
echo ""
echo "Testing repository initialization:"
cd /tmp
rm -rf wasm-test-repo 2>/dev/null || true
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm init wasm-test-repo

# Test status
echo ""
echo "Testing status command:"
cd wasm-test-repo
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm status

echo ""
echo "✅ All WebAssembly tests passed!"
echo ""
echo "🌐 Browser build is available at zig-out/bin/ziggit-browser.wasm"
echo "   Size: $(du -h zig-out/bin/ziggit-browser.wasm | cut -f1)"
echo "   See README.md for JavaScript integration examples."