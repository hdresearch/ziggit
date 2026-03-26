# Ziggit Benchmark Results

## Environment
- Date: 2026-03-26
- Machine: Linux (root@ziggit)
- Git version: `git version 2.39.5`
- Ziggit: built from `master` branch (commit `b035a98`)

## Bare Clone Benchmarks

### sindresorhus/is (small repo, ~900 objects)

| Tool    | Run 1  | Run 2  | Run 3  | Avg    |
|---------|--------|--------|--------|--------|
| ziggit  | 0.382s | 0.365s | 0.379s | 0.375s |
| git CLI | 0.192s | 0.227s | 0.185s | 0.201s |

**Ratio: ~1.9x slower than git CLI**

### chalk/chalk (medium repo, ~1500 objects)

| Tool    | Time   |
|---------|--------|
| ziggit  | 0.297s |
| git CLI | 0.160s |

**Ratio: ~1.9x slower than git CLI**

### Pack/Index Validation
- ✅ `git verify-pack` passes on ziggit-produced .idx files
- ✅ Identical .idx file sizes between ziggit and git CLI (35708 bytes for sindresorhus/is)
- ✅ Identical pack SHA checksums (`65019c9a45459b2c2fea9d34adb2190bf317066d`)

## Progress History
- **Initial**: 21x slower than git CLI
- **After perf optimizations** (commit `20915d3`): ~4x slower
- **Previous** (commit `1a68b74`): ~1.9x slower
- **Current** (commit `b035a98`): ~1.9x slower (no idx_writer changes yet)

## Bun Fork Integration Status
- Branch: `hdresearch/bun:ziggit-integration`
- Commit: `f91422b` — defer repo.close() on all paths + expanded error categorization
- `repository.zig`: ziggit used for clone, fetch, findCommit, checkout
- Fallback: automatic to git CLI on any ziggit failure
- Debug logging: `BUN_DEBUG_GitRepository=1` to see ziggit vs CLI decisions
- Error categorization: SSH auth, network, protocol errors get distinct log messages
- Partial clone cleanup: failed ziggit clones are cleaned up before git CLI fallback

## Pending
- [ ] idx_writer.zig rewrite (NET-SMART agent) — expected to improve pack indexing speed
- [ ] Re-benchmark after idx_writer lands
- [x] Add debug logging to bun fork (commit `f8c37f0`)
- [x] Fix build.zig.zon branch reference
