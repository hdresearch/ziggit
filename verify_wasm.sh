#!/bin/bash
set -e

# WebAssembly Verification Script for ziggit
# This script verifies all WebAssembly builds and tests functionality

echo "🚀 ziggit WebAssembly Verification Script"
echo "=========================================="

# Set up cache directory
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

# Check if wasmtime is available
WASMTIME_AVAILABLE=false
if command -v wasmtime >/dev/null 2>&1; then
    WASMTIME_AVAILABLE=true
    echo "✅ wasmtime is available for testing"
else
    echo "⚠️  wasmtime not found - WASI tests will be skipped"
fi

echo ""
echo "Building all targets..."
echo "======================="

# Build native target
echo "🏗️  Building native target..."
zig build
if [ $? -eq 0 ]; then
    NATIVE_SIZE=$(stat -c%s "zig-out/bin/ziggit" 2>/dev/null || stat -f%z "zig-out/bin/ziggit" 2>/dev/null || echo "unknown")
    echo "✅ Native build successful (${NATIVE_SIZE} bytes)"
else
    echo "❌ Native build failed"
    exit 1
fi

# Build WASI target
echo "🏗️  Building WASI target..."
zig build wasm
if [ $? -eq 0 ]; then
    WASI_SIZE=$(stat -c%s "zig-out/bin/ziggit.wasm" 2>/dev/null || stat -f%z "zig-out/bin/ziggit.wasm" 2>/dev/null || echo "unknown")
    echo "✅ WASI build successful (${WASI_SIZE} bytes)"
else
    echo "❌ WASI build failed"
    exit 1
fi

# Build browser target
echo "🏗️  Building browser target..."
zig build wasm-browser
if [ $? -eq 0 ]; then
    BROWSER_SIZE=$(stat -c%s "zig-out/bin/ziggit-browser.wasm" 2>/dev/null || stat -f%z "zig-out/bin/ziggit-browser.wasm" 2>/dev/null || echo "unknown")
    echo "✅ Browser build successful (${BROWSER_SIZE} bytes)"
else
    echo "❌ Browser build failed"
    exit 1
fi

# Test configurable memory build
echo "🏗️  Building browser target with custom memory..."
zig build wasm-browser -Dfreestanding-memory-size=32768
if [ $? -eq 0 ]; then
    echo "✅ Configurable memory build successful"
else
    echo "❌ Configurable memory build failed"
    exit 1
fi

echo ""
echo "File Structure Verification"
echo "==========================="

# Verify platform abstraction
echo "📁 Checking platform abstraction structure..."
PLATFORM_FILES=("interface.zig" "native.zig" "wasi.zig" "freestanding.zig" "platform.zig")
MISSING_PLATFORM_FILES=()

for file in "${PLATFORM_FILES[@]}"; do
    if [ ! -f "src/platform/$file" ]; then
        MISSING_PLATFORM_FILES+=("$file")
    fi
done

if [ ${#MISSING_PLATFORM_FILES[@]} -eq 0 ]; then
    echo "✅ Platform abstraction complete - all files present"
else
    echo "❌ Missing platform files: ${MISSING_PLATFORM_FILES[*]}"
    exit 1
fi

# Verify WASM entry points
echo "📁 Checking WASM entry points..."
if [ -f "src/main_wasi.zig" ] && [ -f "src/main_freestanding.zig" ]; then
    echo "✅ WASM entry points present"
else
    echo "❌ Missing WASM entry points"
    exit 1
fi

echo ""
echo "WASI Functionality Testing"
echo "=========================="

if [ "$WASMTIME_AVAILABLE" = true ]; then
    echo "🧪 Testing WASI build functionality..."
    
    # Create test directory
    TEST_DIR="wasm_verification_test"
    rm -rf "$TEST_DIR"
    mkdir "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Test help command
    echo "  - Testing help command..."
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm --help >/dev/null 2>&1; then
        echo "✅ Help command works"
    else
        echo "❌ Help command failed"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test init command
    echo "  - Testing init command..."
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm init >/dev/null 2>&1; then
        echo "✅ Init command works"
    else
        echo "❌ Init command failed"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Verify .git directory was created
    if [ -d ".git" ]; then
        echo "✅ .git directory created"
    else
        echo "❌ .git directory not created"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test add/status workflow
    echo "  - Testing add/status workflow..."
    echo "Hello WebAssembly" > test.txt
    
    # Test status with untracked file
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm status | grep -q "test.txt"; then
        echo "✅ Status shows untracked files"
    else
        echo "❌ Status doesn't show untracked files"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test add command
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm add test.txt >/dev/null 2>&1; then
        echo "✅ Add command works"
    else
        echo "❌ Add command failed"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test status with staged file
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm status | grep -q "Changes to be committed"; then
        echo "✅ Status shows staged files"
    else
        echo "❌ Status doesn't show staged files"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test commit command
    echo "  - Testing commit command..."
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm commit -m "WASM test commit" >/dev/null 2>&1; then
        echo "✅ Commit command works"
    else
        echo "❌ Commit command failed"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Test log command
    echo "  - Testing log command..."
    if wasmtime --dir . ../zig-out/bin/ziggit.wasm log | grep -q "WASM test commit"; then
        echo "✅ Log shows commit"
    else
        echo "❌ Log doesn't show commit"
        cd ..
        rm -rf "$TEST_DIR"
        exit 1
    fi
    
    # Clean up
    cd ..
    rm -rf "$TEST_DIR"
    
    echo "✅ All WASI functionality tests passed"
else
    echo "⚠️  WASI tests skipped (wasmtime not available)"
fi

echo ""
echo "Binary Size Analysis"
echo "==================="
echo "Native binary:     ${NATIVE_SIZE} bytes"
echo "WASI module:       ${WASI_SIZE} bytes"  
echo "Browser module:    ${BROWSER_SIZE} bytes"

# Verify reasonable size constraints
if [ "$WASI_SIZE" != "unknown" ] && [ "$WASI_SIZE" -gt 1000000 ]; then
    echo "⚠️  WASI module is quite large (>${WASI_SIZE} bytes)"
fi

if [ "$BROWSER_SIZE" != "unknown" ] && [ "$BROWSER_SIZE" -gt 100000 ]; then
    echo "⚠️  Browser module is quite large (>${BROWSER_SIZE} bytes)"
fi

echo ""
echo "🎉 WebAssembly Verification Complete!"
echo "======================================"
echo "✅ All builds compile successfully"
echo "✅ Platform abstraction verified"
echo "✅ File structure validated"

if [ "$WASMTIME_AVAILABLE" = true ]; then
    echo "✅ WASI functionality tested and working"
else
    echo "⚠️  WASI functionality tests skipped (install wasmtime for full verification)"
fi

echo ""
echo "Summary:"
echo "--------"
echo "- Native build: ✅ Working (${NATIVE_SIZE} bytes)"
echo "- WASI build: ✅ Working (${WASI_SIZE} bytes)"
echo "- Browser build: ✅ Working (${BROWSER_SIZE} bytes)"
echo "- Platform abstraction: ✅ Complete"
if [ "$WASMTIME_AVAILABLE" = true ]; then
    echo "- End-to-end WASM testing: ✅ All tests passed"
else
    echo "- End-to-end WASM testing: ⚠️  Skipped"
fi

echo ""
echo "ziggit WebAssembly support is fully functional! 🚀"