# Ziggit Benchmarks

## 1. CLI Performance: ziggit vs git

**Platform**: macOS ARM64 (Apple Silicon), 10 runs each, median reported  
**Test repo**: expressjs/express (6,135 commits, 423 files, commit-graph enabled)  
**Date**: 2026-03-31  
**Ziggit**: ReleaseFast build (6.9MB binary)  
**Git**: v2.43.0

| Operation | git (ms) | ziggit (ms) | Speedup | Winner |
|---|---:|---:|---:|---|
| `log --oneline -20` | 9.9 | 2.3 | **4.2×** | 🟢 ziggit |
| `log --oneline -100` | 10.3 | 2.7 | **3.8×** | 🟢 ziggit |
| `log --oneline` (all 6135) | 35.9 | 13.5 | **2.7×** | 🟢 ziggit |
| `log --format=%H` | 13.9 | 3.0 | **4.7×** | 🟢 ziggit |
| `shortlog -sn HEAD` | 29.8 | 13.4 | **2.2×** | 🟢 ziggit |
| `rev-list --count HEAD` | 10.2 | 2.5 | **4.0×** | 🟢 ziggit |
| `rev-list HEAD` | 13.9 | 3.0 | **4.6×** | 🟢 ziggit |
| `diff HEAD~1 HEAD` | 9.7 | 2.7 | **3.6×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --stat` | 8.7 | 2.3 | **3.8×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --name-only` | 9.0 | 2.3 | **3.9×** | 🟢 ziggit |
| `show HEAD --stat` | 9.7 | 2.5 | **3.8×** | 🟢 ziggit |
| `show HEAD` | 10.0 | 2.8 | **3.6×** | 🟢 ziggit |
| `status` | 10.9 | 3.7 | **3.0×** | 🟢 ziggit |
| `status -s` | 10.8 | 3.7 | **2.9×** | 🟢 ziggit |
| `status --porcelain` | 10.7 | 3.7 | **2.9×** | 🟢 ziggit |
| `branch -a` | 8.7 | 2.0 | **4.3×** | 🟢 ziggit |
| `branch --contains HEAD` | 8.4 | 1.9 | **4.4×** | 🟢 ziggit |
| `tag -l` | 8.8 | 3.4 | **2.6×** | 🟢 ziggit |
| `cat-file -p HEAD` | 9.0 | 2.1 | **4.3×** | 🟢 ziggit |
| `cat-file -t HEAD` | 8.8 | 2.1 | **4.1×** | 🟢 ziggit |
| `rev-parse HEAD` | 8.6 | 2.2 | **4.0×** | 🟢 ziggit |
| `rev-parse --git-dir` | 8.5 | 1.9 | **4.4×** | 🟢 ziggit |
| `rev-parse --show-toplevel` | 8.7 | 2.1 | **4.1×** | 🟢 ziggit |
| `config --list` | 9.8 | 2.4 | **4.0×** | 🟢 ziggit |
| `describe --tags --always` | 11.6 | 2.6 | **4.4×** | 🟢 ziggit |
| `grep -r express` | 12.4 | 2.5 | **5.0×** | 🟢 ziggit |
| `log --author=dougwilson` | 31.2 | 25.7 | **1.2×** | 🟢 ziggit |
| `log --grep=fix` | 33.2 | 30.3 | 1.1× | 🟡 parity |
| `stash list` | 9.2 | 2.1 | **4.4×** | 🟢 ziggit |

### Summary

| | Count | Percentage |
|---|---:|---:|
| **ziggit wins** | 28/29 | 97% |
| **git wins** | 0/29 | 0% |
| **parity** | 1/29 | 3% |

- **Zero regressions** — ziggit is faster or equal on every benchmarked operation
- **Average speedup** (where ziggit wins): **3.7×**
- **Best**: `grep -r` at **5.0×**, `log --format=%H` at **4.7×**, `rev-list HEAD` at **4.6×**

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

| Repo | ziggit full workflow | git CLI full workflow | Speedup |
|---|---:|---:|---:|
| debug | 453μs | 13,296μs | **29×** |
| chalk | 473μs | 14,539μs | **31×** |
| node-semver | 490μs | 18,654μs | **38×** |
| express | 505μs | 24,644μs | **49×** |

**Library calls are 29–49× faster** than spawning git CLI for the full bun-install workflow.

---

## 3. WebAssembly Binary

| Metric | ziggit WASM | wasm-git | Comparison |
|---|---:|---:|---|
| **Raw size** | **142 KB** | 288 KB | **51% smaller** |
| **gzip** | **55 KB** | ~120 KB | **54% smaller** |
| **brotli** | **46 KB** | ~100 KB | **54% smaller** |
| **Exports** | 68 | ~20 | **3.4× more** |

68 exported functions: init, clone, add, commit, status, log, diff, show, branch, tag, checkout, stash, merge, grep, blame, config, refs, tree parsing, pack loading, object reading, memory management.

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
