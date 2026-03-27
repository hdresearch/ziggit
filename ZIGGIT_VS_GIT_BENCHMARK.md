# Ziggit vs Git CLI Benchmark Results

## Test Environment
- Date: 2026-03-27
- Platform: Linux x86_64
- Git version: 2.43.0
- Ziggit: built with ReleaseFast optimization
- Test repo: 100 files, 51 commits (local)

## Local Operations (average of 3 runs)

| Operation | Ziggit (ms) | Git (ms) | Ratio | Winner |
|-----------|------------|---------|-------|--------|
| `rev-parse HEAD` | 1 | 1 | 1.0x | **Tie** |
| `log --oneline -20` | 3 | 2 | 1.5x | Git |
| `cat-file -p HEAD` | 1 | 1 | 1.0x | **Tie** |
| `ls-tree HEAD` | 3 | 1 | 3.0x | Git |
| `show-ref` | 1 | 1 | 1.0x | **Tie** |
| `for-each-ref` | 1 | 1 | 1.0x | **Tie** |
| `status` | 37 | 2 | 18.5x | Git |
| `diff-tree HEAD~1 HEAD` | 4 | 1 | 4.0x | Git |
| `init` | <1 | <1 | 1.0x | **Tie** |
| `commit -m "test"` | 2 | 3 | 0.7x | **Ziggit** |

## Analysis

### Areas where ziggit is competitive or faster:
- **rev-parse, cat-file, show-ref, for-each-ref, init**: At parity (1ms each)
- **commit**: Ziggit is slightly faster (2ms vs 3ms) - no fork/exec overhead

### Areas where ziggit is slower:
1. **status (37ms vs 2ms)**: Main bottleneck is directory traversal and index diffing. Git uses stat caching, fsmonitor, and untracked cache.
2. **ls-tree (3ms vs 1ms)**: Object lookup through loose objects is slower; git uses pack indexes more efficiently.
3. **diff-tree (4ms vs 1ms)**: Tree parsing and comparison allocates too many small buffers.
4. **log (3ms vs 2ms)**: Each commit object is loaded individually; git batches pack file reads.

### Root Causes:
- **Allocation overhead**: Zig's allocator calls for each string/buffer add up
- **No mmap for pack files**: Each read goes through read() syscalls
- **No stat cache**: status rescans all files every time
- **No untracked cache**: Walking directory tree is O(n) every time
- **Object decompression**: Each loose object requires zlib inflate

## Optimization Opportunities:
1. Arena allocator for command-scoped memory (avoid individual free calls)
2. Memory-map pack files for zero-copy reads  
3. Batch object lookups from pack index
4. Implement stat cache for status command
5. Use libdeflate (already linked) more efficiently
