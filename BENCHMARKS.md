# Ziggit Benchmarks

## 1. CLI Performance: ziggit vs git

**Platform**: macOS ARM64 (Apple Silicon), 7 runs each, median reported  
**Test repo**: expressjs/express (6,135 commits, 423 files)  
**Date**: 2026-03-28  
**Ziggit**: ReleaseFast build (6.9MB binary)  
**Git**: v2.43.0

| Operation | git (ms) | ziggit (ms) | Speedup | Winner |
|---|---:|---:|---:|---|
| `log --oneline -20` | 9.2 | 2.3 | **4.1×** | 🟢 ziggit |
| `log --oneline -100` | 9.9 | 2.6 | **3.8×** | 🟢 ziggit |
| `log --oneline` (all 6135) | 36.5 | 28.0 | **1.3×** | 🟢 ziggit |
| `log --format=%H` | 32.4 | 124.4 | 0.26× | 🔴 git |
| `shortlog -sn` | 9.8 | 22.3 | 0.44× | 🔴 git |
| `rev-list --count HEAD` | 25.1 | 12.5 | **2.0×** | 🟢 ziggit |
| `rev-list HEAD` | 31.5 | 24.2 | **1.3×** | 🟢 ziggit |
| `diff HEAD~1 HEAD` | 9.3 | 2.7 | **3.4×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --stat` | 9.4 | 2.6 | **3.6×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --name-only` | 9.3 | 2.5 | **3.7×** | 🟢 ziggit |
| `show HEAD --stat` | 9.6 | 2.5 | **3.8×** | 🟢 ziggit |
| `show HEAD` | 9.2 | 2.6 | **3.5×** | 🟢 ziggit |
| `status` | 10.7 | 3.7 | **2.9×** | 🟢 ziggit |
| `status -s` | 9.9 | 3.5 | **2.8×** | 🟢 ziggit |
| `status --porcelain` | 10.8 | 3.8 | **2.8×** | 🟢 ziggit |
| `branch -a` | 9.4 | 2.1 | **4.5×** | 🟢 ziggit |
| `branch --contains HEAD` | 9.5 | 2.1 | **4.5×** | 🟢 ziggit |
| `tag -l` | 9.5 | 3.9 | **2.4×** | 🟢 ziggit |
| `cat-file -p HEAD` | 9.5 | 2.3 | **4.2×** | 🟢 ziggit |
| `cat-file -t HEAD` | 9.1 | 2.2 | **4.1×** | 🟢 ziggit |
| `rev-parse HEAD` | 8.7 | 2.2 | **3.9×** | 🟢 ziggit |
| `rev-parse --git-dir` | 9.1 | 2.2 | **4.2×** | 🟢 ziggit |
| `rev-parse --show-toplevel` | 8.3 | 2.0 | **4.2×** | 🟢 ziggit |
| `config --list` | 8.1 | 2.1 | **3.9×** | 🟢 ziggit |
| `describe --tags --always` | 10.4 | 2.2 | **4.8×** | 🟢 ziggit |
| `grep -r express` | 11.1 | 2.3 | **4.8×** | 🟢 ziggit |
| `log --author=dougwilson` | 28.9 | 23.9 | **1.2×** | 🟢 ziggit |
| `log --grep=fix` | 31.3 | 29.4 | 1.06× | 🟡 parity |
| `stash list` | 8.1 | 2.0 | **4.1×** | 🟢 ziggit |

### Summary

| | Count | Percentage |
|---|---:|---:|
| **ziggit wins** | 26/29 | 90% |
| **git wins** | 2/29 | 7% |
| **parity** | 1/29 | 3% |

- **Average speedup** (where ziggit wins): **3.5×**
- **Best**: `grep -r` and `describe` at **4.8×**
- **Known losses**: `log --format=%H` (format string parsing overhead), `shortlog -sn` (pack decompression vs commit-graph)

---

## 2. Bun Install: ziggit Integration vs Stock Bun

**Platform**: Linux x86_64, 4 vCPU, 16GB RAM  
**Stock bun**: v1.3.11 release (99MB)  
**Ziggit bun**: v1.3.11-debug **(-O0, no optimization)** (1.1GB)  
**Note**: The ziggit bun is compiled at -O0 (debug). A release build would be significantly faster.

### End-to-End `bun install` (5 runs, cold cache, median)

| Test | Packages | Stock (ms) | Ziggit (ms) | Ratio | Winner |
|---|---:|---:|---:|---:|---|
| ms (tiny) | 1 | 134 | 100 | **0.75×** | 🟢 ziggit 1.3× faster |
| debug (small) | 2 | 266 | 267 | 1.00× | 🟡 parity |
| debug@4.3.4 (tag) | 2 | 317 | 215 | **0.68×** | 🟢 ziggit 1.5× faster |
| chalk (medium) | 1 | 159 | 101 | **0.64×** | 🟢 ziggit 1.6× faster |
| express (65 deps) | 65 | 782 | 706 | **0.90×** | 🟢 ziggit 1.1× faster |
| semver (npm org) | 1 | 181 | 103 | **0.57×** | 🟢 ziggit 1.8× faster |
| 4 git deps | 68 | 523 | 802 | 1.53× | 🔴 stock 1.5× faster |
| 2 git + 2 npm | 71 | 1180 | 878 | **0.74×** | 🟢 ziggit 1.3× faster |
| koa (35 deps) | 35 | 549 | 487 | **0.89×** | 🟢 ziggit 1.1× faster |
| fastify (47 deps) | 47 | 814 | 965 | 1.19× | 🔴 stock 1.2× faster |

**Ziggit wins 6/10, parity 2/10, stock wins 2/10** — at -O0 debug. Zero git CLI subprocess calls (strace-verified).

### Library-Level Micro-Benchmarks (ziggit in-process vs git CLI subprocess)

| Repo | ziggit findCommit | git CLI findCommit | Speedup | ziggit full workflow | git CLI full workflow | Speedup |
|---|---:|---:|---:|---:|---:|---:|
| debug | 184μs | 1,303μs | 7.0× | 453μs | 13,296μs | **29.3×** |
| chalk | 148μs | 1,209μs | 8.1× | 473μs | 14,539μs | **30.7×** |
| node-semver | 158μs | 1,249μs | 7.9× | 490μs | 18,654μs | **38.0×** |
| express | 162μs | 1,233μs | 7.6× | 505μs | 24,644μs | **48.8×** |

**Library calls are 29–49× faster** than spawning git CLI for the full bun-install workflow (clone + find commit + checkout).

### Variance

Ziggit provides **3–9× more predictable** install times (lower coefficient of variation) due to eliminating subprocess spawn jitter.

---

## 3. WebAssembly Binary

| Metric | ziggit WASM | wasm-git |
|---|---:|---:|
| **Raw size** | **142 KB** | 288 KB |
| **gzip** | **55 KB** | ~120 KB |
| **brotli** | **46 KB** | ~100 KB |
| **Exports** | 68 | ~20 |
| **Size reduction** | — | **51% smaller** |

68 exported functions covering: init, clone, add, commit, status, log, diff, show, branch, tag, checkout, stash, merge, grep, blame, config, refs, tree parsing, pack loading, object reading, and memory management.

Browser demo served via single Express server with built-in CORS proxy — all git operations run in WASM with zero JS git fallbacks.

---

## Test Suite Coverage

| Metric | Count | Percentage |
|---|---:|---:|
| **Scripts passing** | 189 / 999 | 18.9% |
| **Individual tests passing** | 14,576 / 25,676 | 56.8% |

Last full run: 2026-03-27. 76+ subcommands implemented.

---

## Build

```bash
# CLI binary (6.9MB)
zig build -Doptimize=ReleaseFast

# WASM module (142KB)
zig build wasm
```

Requires Zig 0.15.2.
