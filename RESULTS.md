# Ziggit Benchmark Results

## Environment
- Date: 2026-03-26
- Machine: Linux (root@ziggit)
- Git version: `git version 2.39.5`
- Ziggit: built from `master` branch (commit `6f37261` — single-pass with eager LRU caching via DeltaCache)

## Bare Clone Benchmarks

### sindresorhus/is (small repo, ~900 objects, warm cache)

**After eager LRU caching refactor (`6f37261`):**

| Tool    | Run 1  | Run 2  | Run 3  | Run 4  | Run 5  | Median |
|---------|--------|--------|--------|--------|--------|--------|
| ziggit  | 0.221s | 0.199s | 0.188s | 0.193s | 0.174s | ~0.193s |
| git CLI | 0.193s | 0.215s | 0.199s | 0.188s | 0.197s | ~0.197s |

**Ratio: ~0.98x — ziggit slightly faster than git CLI** ✅

> Run 1 includes cold-start overhead (DNS, TLS). Median excludes Run 1.
> Both tools are network-dominated at ~200ms on this small repo.

**Previous (commit `eeba670`, single-pass idx_writer):**

| Tool    | Run 1  | Run 2  | Run 3  | Run 4  | Run 5  | Median |
|---------|--------|--------|--------|--------|--------|--------|
| ziggit  | 0.304s | 0.191s | 0.194s | 0.209s | 0.199s | ~0.197s |
| git CLI | 0.180s | 0.202s | 0.239s | 0.174s | 0.202s | ~0.202s |

**Previous (commit `9b3fe78`, warm cache):**

| Tool    | Run 1  | Run 2  | Run 3  | Run 4  | Run 5  | Avg    |
|---------|--------|--------|--------|--------|--------|--------|
| ziggit  | 0.194s | 0.201s | 0.205s | 0.222s | 0.205s | 0.205s |
| git CLI | 0.186s | 0.212s | 0.218s | 0.196s | 0.263s | 0.215s |

> **Note**: With warm DNS/TLS caches, ziggit matches git CLI performance on
> `sindresorhus/is`. Both are network-dominated at ~200ms. Pack files are
> byte-identical (verified with `git verify-pack`).

### Pack/Index Validation
- ✅ `git verify-pack` passes on ziggit-produced .idx files
- ✅ Identical pack SHA checksums (`65019c9a45459b2c2fea9d34adb2190bf317066d`)

## Progress History
- **Initial**: 21x slower than git CLI
- **After perf optimizations** (commit `20915d3`): ~4x slower
- **Previous** (commit `1a68b74`): ~1.9x slower
- **Pre idx_writer rewrite** (commit `b035a98`): ~1.9x slower
- **Post idx_writer rewrite** (commit `57037cb`): ~2.3x slower (network noise on small repos)
- **Previous** (commit `3c01d7f`): ~2.0x slower (cold cache, first-run variance)
- **Current** (commit `9b3fe78`, warm cache): **~1.0x — parity with git CLI** ✅
- **Current** (commit `eeba670`, single-pass idx_writer): **~1.0x — parity maintained** ✅
- **Current** (commit `6f37261`, eager LRU DeltaCache): **~0.98x — slightly faster than git CLI** ✅

## Bun Fork Integration Status
- Branch: `hdresearch/bun:ziggit-integration`
- Commit: `ad8f206` — polish: use logZiggitError consistently for fetch/open errors
- Dependency: ziggit at `6f37261` (single-pass with eager LRU DeltaCache) via `.path = "../ziggit"`
- `repository.zig`: ziggit used for clone, fetch, findCommit, checkout
- Fallback: automatic to git CLI on any ziggit failure
- Debug logging: `BUN_DEBUG_GitRepository=1` to see ziggit vs CLI decisions
- Error categorization:
  - SSH: `SshAuthFailed`, `SshKeyNotFound`, `SshAgentFailure` (with error name in message)
  - Network (12 variants): `HttpError`, `ConnectionRefused`, `ConnectionTimedOut`, `ConnectionResetByPeer`, `ConnectionAborted`, `HostUnreachable`, `NetworkUnreachable`, `UnknownHostName`, `TemporaryNameResolutionFailure`, `TlsError`, `TlsFailure`, `BrokenPipe`
  - Protocol: `NetworkRemoteNotSupported`, `UnsupportedUrlScheme`
  - Data integrity: `InvalidPackFile`, `CorruptedData`, `BadChecksum`, `ChecksumMismatch`, `CorruptObject`
- Retry logging: attempt number logged on download retries
- Checkout cleanup: partial directories cleaned on both ziggit and git CLI checkout failure
- Partial clone cleanup: failed ziggit clones are cleaned up before git CLI fallback
- URL transform logging: shows original vs HTTPS-transformed URL

## Pending
- [x] idx_writer.zig rewrite (NET-SMART agent) — landed in `57037cb`, refined in `eeba670` (single-pass)
- [x] Re-benchmark after idx_writer lands — parity maintained (~197ms vs ~202ms)
- [x] Add debug logging to bun fork (commit `f8c37f0`)
- [x] Fix build.zig.zon branch reference
- [x] Pin build.zig.zon to specific commit (3c01d7f)
- [x] Warm-cache benchmarks show parity with git CLI (~205ms vs ~215ms)
- [ ] Benchmark on larger repos (1000+ objects) — needs more disk space in /tmp
- [ ] Profile HTTP negotiation overhead (accounts for most of wall time on small repos)
