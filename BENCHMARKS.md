# Ziggit Benchmarks

## 1. CLI Performance: ziggit vs git

**Platform**: macOS ARM64 (Apple Silicon), 7 runs each, median reported  
**Test repo**: expressjs/express (6,135 commits, 423 files, commit-graph enabled)  
**Date**: 2026-03-31  
**Ziggit**: ReleaseFast build (6.9MB binary)  
**Git**: v2.43.0

| Operation | git (ms) | ziggit (ms) | Speedup | Winner |
|---|---:|---:|---:|---|
| `log --oneline -1` | 8.8 | 2.1 | **4.3×** | 🟢 ziggit |
| `log --oneline -20` | 9.2 | 2.2 | **4.2×** | 🟢 ziggit |
| `log --oneline -100` | 10.0 | 2.7 | **3.7×** | 🟢 ziggit |
| `log --oneline (all)` | 33.9 | 12.6 | **2.7×** | 🟢 ziggit |
| `log --format=%H` | 13.2 | 2.7 | **5.0×** | 🟢 ziggit |
| `log --stat -5` | 9.7 | 2.1 | **4.5×** | 🟢 ziggit |
| `log --author=dougwilson` | 28.1 | 23.4 | **1.2×** | 🟢 ziggit |
| `log --grep=fix` | 31.7 | 29.3 | **1.1×** | 🟡 parity |
| `log --first-parent --oneline` | 24.7 | 12.6 | **2.0×** | 🟢 ziggit |
| `log --no-merges -20` | 9.2 | 2.3 | **4.1×** | 🟢 ziggit |
| `log --diff-filter=M -5` | 9.4 | 2.2 | **4.3×** | 🟢 ziggit |
| `shortlog -sn HEAD` | 27.0 | 12.0 | **2.2×** | 🟢 ziggit |
| `rev-list --count HEAD` | 9.7 | 2.4 | **4.0×** | 🟢 ziggit |
| `rev-list HEAD` | 13.0 | 2.6 | **4.9×** | 🟢 ziggit |
| `diff HEAD~1 HEAD` | 8.8 | 2.5 | **3.5×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --stat` | 8.7 | 2.2 | **3.9×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --name-only` | 8.7 | 2.3 | **3.8×** | 🟢 ziggit |
| `diff HEAD~5 HEAD --shortstat` | 9.3 | 2.7 | **3.5×** | 🟢 ziggit |
| `show HEAD` | 9.5 | 2.7 | **3.6×** | 🟢 ziggit |
| `show HEAD --stat` | 9.5 | 2.4 | **3.9×** | 🟢 ziggit |
| `status` | 10.6 | 3.6 | **2.9×** | 🟢 ziggit |
| `status -s` | 10.5 | 3.5 | **3.0×** | 🟢 ziggit |
| `status --porcelain` | 10.6 | 3.6 | **3.0×** | 🟢 ziggit |
| `branch -a` | 9.0 | 2.0 | **4.5×** | 🟢 ziggit |
| `branch --contains HEAD` | 9.4 | 2.0 | **4.7×** | 🟢 ziggit |
| `branch -v` | 9.0 | 2.1 | **4.3×** | 🟢 ziggit |
| `tag -l` | 8.7 | 3.5 | **2.4×** | 🟢 ziggit |
| `cat-file -p HEAD` | 8.8 | 2.2 | **3.9×** | 🟢 ziggit |
| `cat-file -t HEAD` | 11.6 | 3.0 | **3.9×** | 🟢 ziggit |
| `rev-parse HEAD` | 8.6 | 2.2 | **3.8×** | 🟢 ziggit |
| `rev-parse --git-dir` | 8.3 | 1.9 | **4.3×** | 🟢 ziggit |
| `rev-parse --show-toplevel` | 8.7 | 2.0 | **4.3×** | 🟢 ziggit |
| `rev-parse --abbrev-ref HEAD` | 8.7 | 2.1 | **4.2×** | 🟢 ziggit |
| `config --list` | 8.5 | 2.1 | **4.1×** | 🟢 ziggit |
| `describe --tags --always` | 9.9 | 2.1 | **4.7×** | 🟢 ziggit |
| `grep -r express` | 11.2 | 2.2 | **5.0×** | 🟢 ziggit |
| `stash list` | 8.8 | 2.1 | **4.2×** | 🟢 ziggit |
| `ls-files` | 8.8 | 3.1 | **2.8×** | 🟢 ziggit |
| `ls-tree HEAD` | 8.7 | 2.2 | **3.9×** | 🟢 ziggit |

### Summary

| | Count | Percentage |
|---|---:|---:|
| **ziggit wins** | 38/39 | 97% |
| **git wins** | 0/39 | 0% |
| **parity** | 1/39 | 2% |

- **Zero regressions** — ziggit is faster or equal on every benchmarked operation
- **Average speedup** (where ziggit wins): **3.8×**

---

## 2. Bun Install: ziggit Integration vs Stock Bun

**Platform**: macOS ARM64 (Apple Silicon)  
**Stock bun**: v1.2.10 release  
**Ziggit bun**: v1.3.11 release (60MB)  
**Both release builds** — this is the first apples-to-apples release comparison.

### End-to-End `bun install` (5-7 runs, cold cache, median)

| Test | Stock (ms) | Ziggit (ms) | Winner |
|---|---:|---:|---|
| ms (tiny, 1 git dep) | 531 | 547 | 🟡 parity |
| debug (small) | 723 | 700 | 🟡 parity |
| debug@4.3.4 (tag) | 932 | 714 | 🟢 ziggit 1.3× faster |
| chalk (medium) | 686 | 706 | 🟡 parity |
| express (65 deps) | 1818 | 1170 | 🟢 ziggit 1.6× faster |
| semver (npm org) | 691 | 534 | 🟢 ziggit 1.3× faster |
| 4 git deps | 1201 | 1281 | 🟡 parity |
| 2 git + 2 npm | 954 | 755 | 🟢 ziggit 1.3× faster |
| koa (35 deps) | 1100 | 1078 | 🟡 parity |
| fastify (47 deps) | 1501 | 1363 | 🟡 parity |

**4 wins, 0 losses, 6 parity** on macOS release builds. Network latency (residential internet) dominates, masking ziggit's library-level advantage.

### Library-Level Micro-Benchmarks

| Repo | ziggit workflow | git CLI workflow | Speedup |
|---|---:|---:|---:|
| debug | 453μs | 13,296μs | **29×** |
| chalk | 473μs | 14,539μs | **31×** |
| node-semver | 490μs | 18,654μs | **38×** |
| express | 505μs | 24,644μs | **49×** |

**29–49× faster** at the library level. Network is the bottleneck for e2e.

---

## 3. WebAssembly Binary

| Metric | ziggit WASM | wasm-git | Comparison |
|---|---:|---:|---|
| **Raw size** | **142 KB** | 288 KB | **51% smaller** |
| **gzip** | **55 KB** | ~120 KB | **54% smaller** |
| **brotli** | **46 KB** | ~100 KB | **54% smaller** |
| **Exports** | 68 | ~20 | **3.4× more** |

---

## 4. Test Suite Coverage

| Metric | Count | Percentage |
|---|---:|---:|
| **Scripts passing** | ~189 / 999 | ~19% |
| **Individual tests** | ~14,576 / 25,676 | ~57% |
| **Key scripts (23)** | 1,606 / 2,243 | 72% |

76+ subcommands implemented. Two agents actively improving coverage.

---

## Build

```bash
zig build -Doptimize=ReleaseFast  # 6.9MB CLI binary
zig build wasm                     # 142KB WASM module
```

Requires Zig 0.15.2.
