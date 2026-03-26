#!/bin/bash
# validate_improvements.sh - Validation script for ziggit improvements

echo "=== ZIGGIT IMPROVEMENTS VALIDATION ==="
echo

echo "1. Benchmarks cleanup:"
echo "   Checking benchmark directory contains only 3 files..."
benchmark_count=$(ls -1 benchmarks/*.zig | wc -l)
if [ "$benchmark_count" -eq 3 ]; then
    echo "   ✅ Benchmarks consolidated to 3 files:"
    ls benchmarks/*.zig | sed 's/^/      - /'
else
    echo "   ❌ Expected 3 benchmark files, found $benchmark_count"
fi
echo

echo "2. Build system cleanup:"
echo "   Checking build.zig has clean targets..."
if grep -q "bench.*Run all benchmarks" build.zig; then
    echo "   ✅ Clean bench target found"
else
    echo "   ❌ Bench target not found or malformed"
fi

if grep -q "lib.*Build libziggit" build.zig; then
    echo "   ✅ Clean lib target found"
else
    echo "   ❌ Lib target not found or malformed"
fi

if grep -q "wasm.*WebAssembly" build.zig; then
    echo "   ✅ Clean wasm target found" 
else
    echo "   ❌ WASM target not found or malformed"
fi
echo

echo "3. BrokenPipe error handling:"
echo "   Checking native.zig has BrokenPipe handling..."
if grep -A 3 "writeStdoutImpl" src/platform/native.zig | grep -q "BrokenPipe => return"; then
    echo "   ✅ BrokenPipe handling found in writeStdoutImpl"
else
    echo "   ❌ BrokenPipe handling missing in writeStdoutImpl"
fi

if grep -A 3 "writeStderrImpl" src/platform/native.zig | grep -q "BrokenPipe => return"; then
    echo "   ✅ BrokenPipe handling found in writeStderrImpl"
else 
    echo "   ❌ BrokenPipe handling missing in writeStderrImpl"
fi
echo

echo "4. Integration tests enhancement:"
echo "   Checking git_interop_test.zig has BrokenPipe test..."
if grep -q "testBrokenPipeHandling" test/git_interop_test.zig; then
    echo "   ✅ BrokenPipe test added to git_interop_test.zig"
else
    echo "   ❌ BrokenPipe test missing from git_interop_test.zig"
fi

# Count test functions in git_interop_test.zig
test_count=$(grep -c "^fn test" test/git_interop_test.zig)
echo "   📊 Git interop test contains $test_count test functions"
echo

echo "5. File cleanup:"
echo "   Checking root directory is clean..."
root_zig_count=$(ls -1 *.zig 2>/dev/null | grep -v build.zig | wc -l)
if [ "$root_zig_count" -eq 0 ]; then
    echo "   ✅ Root directory cleaned (no extra .zig files except build.zig)"
else
    echo "   ⚠️  Root directory has $root_zig_count extra .zig files:"
    ls -1 *.zig 2>/dev/null | grep -v build.zig | sed 's/^/      - /'
fi

if [ -d test_compat ]; then
    echo "   ❌ test_compat directory should have been removed"
else
    echo "   ✅ Redundant test_compat directory removed"
fi
echo

echo "6. Build target verification:"
echo "   Required build targets should be:"
echo "      - zig build          (builds ziggit CLI)"
echo "      - zig build lib      (builds libziggit.a + ziggit.h)"
echo "      - zig build test     (runs unit tests)" 
echo "      - zig build bench    (runs benchmarks)"
echo "      - zig build wasm     (WASM target)"
echo

echo "=== VALIDATION COMPLETE ==="
echo
echo "NOTE: Due to Zig environment issues (AppDataDirUnavailable error),"
echo "      actual compilation tests cannot be run in this environment."
echo "      However, all static validations have been performed."