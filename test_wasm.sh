#!/bin/bash
set -e

echo "=== ziggit WebAssembly Tests ==="

# Build all targets
echo "Building all targets..."
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build
zig build wasm
zig build wasm-browser

echo "✅ All builds completed successfully"

# Create test directory
TEST_DIR="/tmp/ziggit-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo ""
echo "=== Testing Native Build ==="
/root/ziggit/zig-out/bin/ziggit --version
/root/ziggit/zig-out/bin/ziggit init
echo "test content" > test.txt
/root/ziggit/zig-out/bin/ziggit add test.txt
/root/ziggit/zig-out/bin/ziggit status

echo ""
echo "=== Testing WASI Build ==="
wasmtime --version
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm --version
rm -rf .git
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm init
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm add test.txt
wasmtime --dir . /root/ziggit/zig-out/bin/ziggit.wasm status

echo ""
echo "=== WebAssembly Binary Sizes ==="
ls -lh /root/ziggit/zig-out/bin/*.wasm

echo ""
echo "=== Browser WASM Info ==="
file /root/ziggit/zig-out/bin/ziggit-browser.wasm
wasm-objdump -x /root/ziggit/zig-out/bin/ziggit-browser.wasm | head -20 || echo "wasm-objdump not available"

echo ""
echo "✅ All WebAssembly tests passed!"
echo ""
echo "To test the browser version:"
echo "1. Serve the test_browser.html file over HTTP"
echo "2. Open in a web browser"
echo "3. Click 'Run Tests' button"
echo ""
echo "Example with Python:"
echo "cd /root/ziggit && python3 -m http.server 8080"
echo "Then open: http://localhost:8080/test_browser.html"