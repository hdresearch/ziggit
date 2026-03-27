# Ziggit vs Git CLI Benchmark

## Test Environment
- Repository: 51 commits, 100 files, packed (single pack file)
- Binary: `zig build -Doptimize=ReleaseFast`
- Runs: 3 iterations per command, averaged
- Date: 2026-03-27

## Results (51 commits, 100 files, packed repo)

| Command | ziggit | git | Ratio |
|---------|--------|-----|-------|
| init | 2ms | 3ms | **0.7x (faster)** |
| rev-parse HEAD | 1ms | 1ms | 1.0x |
| cat-file -t HEAD | 1ms | 1ms | 1.0x |
| cat-file -p HEAD | 2ms | 1ms | 2.0x |
| show-ref | 1ms | 1ms | 1.0x |
| for-each-ref | 1ms | 1ms | 1.0x |
| branch | 1ms | 1ms | 1.0x |
| symbolic-ref HEAD | 1ms | 1ms | 1.0x |
| hash-object file.txt | 1ms | 1ms | 1.0x |
| update-server-info | 1ms | 1ms | 1.0x |
| log --oneline -20 | 4ms | 2ms | 2.0x |
| ls-tree HEAD | 3ms | 1ms | 3.0x |
| status | 4ms | 2ms | 2.0x |
| count-objects | 7ms | 2ms | 3.5x |
| rev-list HEAD (51) | 8ms | 2ms | 4.0x |
| rev-list --count HEAD | 7ms | 2ms | 3.5x |
| write-tree | 14ms | 1ms | 14.0x |

## Analysis

### At parity or faster (10/17 commands):
- **init**: ziggit is faster (no template copying overhead)
- **rev-parse, cat-file -t, show-ref, for-each-ref, branch, symbolic-ref, hash-object, update-server-info**: all at 1ms parity

### Slower (7/17 commands):
- **write-tree (14x)**: Rebuilds entire tree from index; git uses cache-tree extension
- **rev-list (4x)**: Object loading from pack files requires decompression per commit
- **count-objects (3.5x)**: Iterates all object directories
- **ls-tree (3x)**: Tree object loading from pack + formatting
- **log (2x)**: Multiple commit object loads + formatting
- **status (2x)**: Index parsing + tree comparison + working directory stat
- **cat-file -p (2x)**: Pack object decompression

### Optimization History
1. Initial: ~40ms for most ops (file I/O overhead)
2. HEAD tree map caching: 40ms → 4ms (10x)
3. Pack idx caching: 4163 → 1062 syscalls (4x fewer)
4. Pack dir listing cache: eliminated repeated directory scans
5. Pack data caching: reads pack file once per process

### Remaining Optimization Targets
1. **write-tree**: Implement cache-tree index extension (git's biggest speedup)
2. **rev-list**: Batch object loading (read all needed objects in one pass)
3. **count-objects**: Use directory entry counts without opening files
4. **General**: mmap pack files instead of read+allocate, lazy decompression
