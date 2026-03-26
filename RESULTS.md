# Ziggit Benchmark Results

## Environment
- Date: 2026-03-26
- Machine: Linux (root@ziggit)
- Git version: `git --version`
- Ziggit: built from `master` branch

## Bare Clone Benchmarks

### sindresorhus/is (small repo, ~900 objects)

| Tool    | Run 1  | Run 2  | Run 3  | Avg    |
|---------|--------|--------|--------|--------|
| ziggit  | 0.408s | 0.329s | 0.352s | 0.363s |
| git CLI | 0.204s | 0.188s | 0.186s | 0.193s |

**Ratio: ~1.9x slower than git CLI**

### chalk/chalk (medium repo, ~1500 objects)

| Tool    | Time   |
|---------|--------|
| ziggit  | 0.332s |
| git CLI | 0.176s |

**Ratio: ~1.9x slower than git CLI**

### Pack/Index Validation
- ✅ `git verify-pack` passes on ziggit-produced .idx files
- ✅ Identical .idx file sizes between ziggit and git CLI
- ✅ Identical pack SHA checksums

## Progress History
- **Initial**: 21x slower than git CLI
- **After perf optimizations** (commit `20915d3`): ~4x slower
- **Current** (commit `1a68b74`): ~1.9x slower

## Bun Fork Integration Status
- Branch: `hdresearch/bun:ziggit-integration`
- `repository.zig`: ziggit used for clone, fetch, findCommit, checkout
- Fallback: automatic to git CLI on any ziggit failure
- Debug logging: `BUN_DEBUG_GitRepository=1` to see ziggit vs CLI decisions

## Pending
- [ ] idx_writer.zig rewrite (NET-SMART agent) — expected to improve pack indexing speed
- [ ] Re-benchmark after idx_writer lands
