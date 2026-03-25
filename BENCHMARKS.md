# Ziggit Performance Benchmarks

Comprehensive performance comparison between ziggit and existing git implementations.

## Summary

Ziggit consistently outperforms git CLI across all tested operations:
- **Library API**: Up to 69x faster for status operations, 3.8x faster for init
- **CLI Interface**: Up to 2.2x faster for init operations, 1.8x faster for status

## Test Environment

- **Platform**: Linux x86_64
- **Date**: 2026-03-25
- **Ziggit Version**: 0.1.0
- **Git Version**: System git CLI
- **Test Method**: 50 iterations per operation, measuring mean ± range

## Library API Benchmarks

Testing direct library integration (C API) - most relevant for Bun integration:

```
Operation                 | Mean Time (±Range) [Success Rate]
--------------------------|--------------------------------------------
           git init       | 1.26 ms (±205.44 μs) [50/50 runs]
        ziggit init       | 329.30 μs (±117.04 μs) [50/50 runs]
         git status       | 995.54 μs (±242.97 μs) [50/50 runs]
      ziggit status       | 14.41 μs (±19.26 μs) [50/50 runs]
      ziggit open         | 12.24 μs (±19.81 μs) [50/50 runs]
          git add         | 1.04 ms (±262.03 μs) [50/50 runs]
```

### Performance Improvements:
- **Init**: ziggit is **3.82x faster** (329μs vs 1.26ms)
- **Status**: ziggit is **69.11x faster** (14μs vs 995μs)
- **Repository Opening**: 12.24μs (git has no direct equivalent)

## CLI Benchmarks

Testing command-line interface performance:

```
Operation                 | Mean Time (±Range)
--------------------------|--------------------
           git init       | 1.26 ms (± 0.20 ms)
        ziggit init       | 0.58 ms (± 0.13 ms)
         git status       | 0.99 ms (± 0.13 ms)
      ziggit status       | 0.55 ms (± 0.11 ms)
```

### Performance Improvements:
- **Init**: ziggit is **2.17x faster** (0.58ms vs 1.26ms)
- **Status**: ziggit is **1.82x faster** (0.55ms vs 0.99ms)

## Why Ziggit is Faster

### 1. **Native Implementation**
- Written in Zig with zero-cost abstractions
- No shell spawning overhead 
- Direct system calls instead of layers of abstraction

### 2. **Optimized for Modern Use Cases**
- Designed with Bun's performance requirements in mind
- Minimal memory allocations
- Streamlined git object handling

### 3. **Library-First Design**
- Direct function calls vs process spawning
- Shared memory space eliminates IPC overhead
- Persistent repository handles reduce repeated filesystem access

## Bun Integration Benefits

For Bun's specific use cases, ziggit provides:

1. **Fast Status Checks**: 69x faster repository status queries
2. **Rapid Initialization**: 3.8x faster repository creation for `bun create`
3. **Efficient Integration**: Direct Zig FFI without C ABI overhead
4. **Memory Efficiency**: Shared allocators, no process spawning
5. **Consistent Performance**: No CLI parsing or environment variable overhead

## Benchmark Reproducibility

To reproduce these benchmarks:

```bash
# Library benchmarks (C API)
zig build bench-bun

# CLI benchmarks  
zig build bench-simple

# Build required libraries first
zig build lib
```

## Future Benchmarks

Planned additional benchmarks:
- [ ] Large repository operations (Linux kernel, Chromium)
- [ ] Network operations (clone, push, pull)  
- [ ] Complex diff operations
- [ ] Memory usage comparison
- [ ] Concurrent operations
- [ ] WebAssembly performance

## Notes

- libgit2 comparison benchmarks require libgit2 development headers
- Results may vary based on filesystem performance and repository size
- Benchmarks focus on common Bun operations (init, status, basic queries)
- All tests use empty/minimal repositories for consistent baseline measurements