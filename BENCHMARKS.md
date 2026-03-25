# ziggit Library Benchmarks

This document contains benchmark results comparing ziggit library performance against git CLI.

## Test Environment

- **CPU**: Testing on VM 
- **OS**: Linux
- **Zig Version**: 0.13.0
- **Git Version**: 2.34.1
- **Test Date**: 2026-03-25

## Benchmark Methodology

- Each operation is run 1000 times
- Measurements include 10 warmup runs before timing
- Results show average time per operation and operations per second
- All tests use temporary directories in `/tmp/`

## Results

### Repository Operations

| Operation | ziggit Library | Git CLI | Performance Improvement |
|-----------|----------------|---------|------------------------|
| **init** | 182,642 ns (5,475 ops/sec) | 1,432,561 ns (698 ops/sec) | **7.8x faster** |
| **status** | 46,542 ns (21,485 ops/sec) | 1,097,319 ns (911 ops/sec) | **23.6x faster** |
| **open** | 26,995 ns (37,043 ops/sec) | N/A (CLI has no equivalent) | N/A |

### Detailed Results

#### ziggit Library Performance

```
ziggit_repo_init:
  Iterations: 1000
  Avg time: 182642 ns
  Ops/sec: 5475

ziggit_repo_open:
  Iterations: 1000
  Avg time: 26995 ns
  Ops/sec: 37043

ziggit_status:
  Iterations: 1000
  Avg time: 46542 ns
  Ops/sec: 21485
```

#### Git CLI Performance

```
git init:
  Iterations: 1000
  Avg time: 1432561 ns
  Ops/sec: 698

git status (empty):
  Iterations: 1000
  Avg time: 1097319 ns
  Ops/sec: 911

git status (untracked file):
  Iterations: 1000
  Avg time: 1102753 ns
  Ops/sec: 906

git status (staged file):
  Iterations: 1000
  Avg time: 1138578 ns
  Ops/sec: 878
```

## Analysis

### Performance Advantages

1. **Initialization Speed**: ziggit's repository initialization is 7.8x faster than git CLI
   - ziggit: ~183μs vs git: ~1.43ms
   - Benefit for tools that frequently create new repositories

2. **Status Checking**: ziggit's status operation is 23.6x faster than git CLI
   - ziggit: ~47μs vs git: ~1.1ms
   - Critical for IDE integrations and frequent status checks

3. **Repository Opening**: ziggit's repository opening is extremely fast at ~27μs
   - No CLI equivalent, but essential for library usage
   - Enables efficient long-running processes

### Why ziggit is Faster

1. **No Process Overhead**: Library calls avoid fork/exec overhead that CLI commands require
2. **Memory Efficiency**: Direct memory management without shell/process layers
3. **Optimized I/O**: Streamlined file system operations
4. **Minimal Dependencies**: Focused implementation without legacy compatibility layers

## Use Cases That Benefit Most

1. **IDE/Editor Integrations**: Frequent status checks and repository operations
2. **Build Systems**: Repository initialization and validation
3. **CI/CD Pipelines**: Fast repository operations in automated workflows
4. **Development Tools**: Any tool requiring high-frequency git operations

## Running the Benchmarks

### ziggit Library Benchmarks
```bash
cd /root/ziggit
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build bench
```

### Git CLI Benchmarks
```bash
cd /root/ziggit
./benchmarks/bench_git_cli.sh
```

## Future Benchmarks

Additional benchmarks to implement:
- Clone operations (local and remote)
- Branch operations (create, list, switch)
- Commit operations
- Diff operations
- Comparison with libgit2 (when available)

## Notes

- Current implementation focuses on basic operations
- Performance improvements expected as implementation matures
- Benchmarks will expand as more functionality is implemented
- Real-world performance may vary based on repository size and complexity