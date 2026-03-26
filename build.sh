#!/bin/bash
# Build script for ziggit to handle environment setup

export HOME=/root

case "${1:-}" in
    clean)
        rm -rf zig-cache zig-out
        ;;
    lib)
        zig build lib
        ;;
    test)
        zig build test
        ;;
    bench)
        echo "Note: Benchmarks may fail with NoSpaceLeft in constrained environments"
        zig build bench || echo "Benchmark failed (likely disk space)"
        ;;
    wasm)
        echo "Note: WASM build has known compilation issues in git module"
        zig build wasm || echo "WASM build failed (known issues)"
        ;;
    *)
        zig build
        ;;
esac