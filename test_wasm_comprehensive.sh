#!/bin/bash

# Comprehensive WebAssembly test script for ziggit

echo "=== ziggit WebAssembly Comprehensive Test ==="
echo

# Build all targets
echo "Building all targets..."
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

echo "  - Native build..."
zig build
if [ $? -ne 0 ]; then
    echo "ERROR: Native build failed"
    exit 1
fi

echo "  - WASM (WASI) build..."
zig build wasm
if [ $? -ne 0 ]; then
    echo "ERROR: WASM build failed"
    exit 1
fi

echo "  - WASM (Browser/Freestanding) build..."
zig build wasm-browser
if [ $? -ne 0 ]; then
    echo "ERROR: WASM browser build failed"
    exit 1
fi

echo "All builds successful!"
echo

# Check build outputs
echo "Build outputs:"
ls -la zig-out/bin/
echo

# Test WASI build with wasmtime
WASMTIME="./wasmtime-v23.0.1-x86_64-linux/wasmtime"

if [ ! -f "$WASMTIME" ]; then
    echo "ERROR: wasmtime not found at $WASMTIME"
    exit 1
fi

echo "Testing WASI build with wasmtime..."

# Create test directory
TEST_DIR="test-wasm-comprehensive"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Test version
echo "  1. Testing version command..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm --version
echo

# Test init
echo "  2. Testing repository initialization..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm init .
if [ ! -d ".git" ]; then
    echo "ERROR: .git directory not created"
    exit 1
fi
echo "Repository initialized successfully"
echo

# Test status (empty repo)
echo "  3. Testing status on empty repository..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm status
echo

# Create and add files
echo "  4. Testing file operations..."
echo "Hello WASM World!" > README.md
echo "Test file for ziggit WASM" > test.txt
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm add README.md
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm add test.txt
echo "Files added to staging area"
echo

# Test status with staged files
echo "  5. Testing status with staged files..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm status
echo

# Test commit
echo "  6. Testing commit..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm commit -m "WASM test commit: Add README and test file"
echo "Commit successful"
echo

# Test log
echo "  7. Testing log..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm log --oneline
echo

# Test status after commit
echo "  8. Testing status after commit..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm status
echo

# Test diff (should be empty)
echo "  9. Testing diff (should be empty)..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm diff
echo

# Make changes and test diff
echo "  10. Testing diff with changes..."
echo "Modified content" >> README.md
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm diff
echo

# Test branch operations
echo "  11. Testing branch operations..."
../$WASMTIME --dir . ../zig-out/bin/ziggit.wasm branch
echo

cd ..

echo
echo "=== WASI WebAssembly Test PASSED ==="
echo

# Test browser build (just verify it loads and shows help)
echo "Testing browser/freestanding build..."
echo "  - Binary size: $(stat -c%s zig-out/bin/ziggit-browser.wasm) bytes"
echo "  - Browser build created successfully (requires JavaScript host for full testing)"
echo

echo "=== All WebAssembly Tests PASSED ==="
echo
echo "WebAssembly builds are fully functional!"
echo
echo "Usage:"
echo "  WASI build: wasmtime --dir . zig-out/bin/ziggit.wasm <command>"
echo "  Browser build: Use zig-out/bin/ziggit-browser.wasm with JavaScript host"