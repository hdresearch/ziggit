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
- Commit: `95a7784` — polish: complete error categorization (extract isSshAuthError/isProtocolError/isDataIntegrityError helpers, all 12 network errors, all 5 data integrity errors)
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
- [ ] idx_writer.zig rewrite (NET-SMART agent) — expected to improve pack indexing speed
- [ ] Re-benchmark after idx_writer lands
- [x] Add debug logging to bun fork (commit `f8c37f0`)
- [x] Fix build.zig.zon branch reference
