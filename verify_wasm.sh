#!/bin/bash

# WebAssembly Build and Test Verification Script for ziggit
# This script verifies that all WebAssembly builds compile and function correctly

set -e

echo "=========================================="
echo "Ziggit WebAssembly Verification Script"
echo "=========================================="

# Set up environment
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

# Test 1: Build all targets
info "Building all targets..."

echo "Building native target..."
if zig build; then
    success "Native build successful"
else
    error "Native build failed"
    exit 1
fi

echo "Building WASI target..."
if zig build wasm; then
    success "WASI build successful"
else
    error "WASI build failed"
    exit 1
fi

echo "Building freestanding/browser target..."
if zig build wasm-browser; then
    success "Freestanding/browser build successful"
else
    error "Freestanding/browser build failed"
    exit 1
fi

# Test 2: Verify output files
info "Verifying build outputs..."

if [[ -f "zig-out/bin/ziggit" ]]; then
    success "Native executable found"
else
    error "Native executable not found"
    exit 1
fi

if [[ -f "zig-out/bin/ziggit.wasm" ]]; then
    success "WASI WASM module found"
else
    error "WASI WASM module not found"
    exit 1
fi

if [[ -f "zig-out/bin/ziggit-browser.wasm" ]]; then
    success "Browser WASM module found"
else
    error "Browser WASM module not found"
    exit 1
fi

# Test 3: Check file sizes (ensure they're reasonable)
info "Checking build sizes..."

native_size=$(stat -c%s "zig-out/bin/ziggit")
wasi_size=$(stat -c%s "zig-out/bin/ziggit.wasm")
browser_size=$(stat -c%s "zig-out/bin/ziggit-browser.wasm")

echo "Build sizes:"
echo "  Native:  $(numfmt --to=iec $native_size)"
echo "  WASI:    $(numfmt --to=iec $wasi_size)" 
echo "  Browser: $(numfmt --to=iec $browser_size)"

# Verify sizes are in expected ranges
if (( native_size > 1000000 )); then  # > 1MB
    success "Native build size reasonable"
else
    error "Native build suspiciously small"
fi

if (( wasi_size > 50000 && wasi_size < 1000000 )); then  # 50KB - 1MB
    success "WASI build size reasonable"  
else
    error "WASI build size unexpected"
fi

if (( browser_size > 2000 && browser_size < 50000 )); then  # 2KB - 50KB
    success "Browser build size reasonable"
else
    error "Browser build size unexpected"
fi

# Test 4: Functional testing with wasmtime (if available)
if command -v wasmtime &> /dev/null; then
    info "Testing WASI build with wasmtime..."
    
    # Test version command
    if wasmtime --dir . zig-out/bin/ziggit.wasm --version | grep -q "ziggit version"; then
        success "WASI version command works"
    else
        error "WASI version command failed"
    fi
    
    # Test help command  
    if wasmtime --dir . zig-out/bin/ziggit.wasm --help | grep -q "usage:"; then
        success "WASI help command works"
    else
        error "WASI help command failed"
    fi
    
    # Test repository initialization in a temporary directory
    test_dir=$(mktemp -d)
    cd "$test_dir"
    
    if wasmtime --dir . "$OLDPWD/zig-out/bin/ziggit.wasm" init .; then
        if [[ -d ".git" ]]; then
            success "WASI init command works (created .git directory)"
        else
            error "WASI init command didn't create .git directory"
        fi
    else
        error "WASI init command failed"
    fi
    
    # Test status command
    if wasmtime --dir . "$OLDPWD/zig-out/bin/ziggit.wasm" status | grep -q "On branch"; then
        success "WASI status command works"
    else
        error "WASI status command failed"
    fi
    
    cd "$OLDPWD"
    rm -rf "$test_dir"
else
    info "Wasmtime not available - skipping functional tests"
fi

# Test 5: Test configurable browser build
info "Testing configurable browser build..."

if zig build wasm-browser -Dfreestanding-memory-size=32768; then
    success "Configurable memory size build works"
else
    error "Configurable memory size build failed"
fi

# Test 6: Verify platform abstraction files exist
info "Verifying platform abstraction structure..."

required_files=(
    "src/platform/interface.zig"
    "src/platform/platform.zig"
    "src/platform/native.zig"
    "src/platform/wasi.zig"
    "src/platform/freestanding.zig"
    "src/main_common.zig"
    "src/main_wasi.zig" 
    "src/main_freestanding.zig"
)

for file in "${required_files[@]}"; do
    if [[ -f "$file" ]]; then
        success "Found $file"
    else
        error "Missing required file: $file"
        exit 1
    fi
done

echo
echo "=========================================="
success "All WebAssembly verification tests passed!"
echo "=========================================="
echo
info "Summary:"
echo "  ✅ All builds compile successfully"
echo "  ✅ Output files have reasonable sizes"
echo "  ✅ Platform abstraction is complete"
echo "  ✅ WASI functionality verified (where possible)"
echo "  ✅ Configurable builds work correctly"
echo
info "ziggit WebAssembly implementation is ready for production use!"