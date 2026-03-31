# Ziggit Benchmarks

## 1. CLI Performance: ziggit vs git (37 operations)

**Platform**: macOS ARM64 (Apple Silicon), 7 runs each, median reported  
**Test repo**: expressjs/express (6,135 commits, 423 files, commit-graph enabled)  
**Date**: 2026-03-31  
**Ziggit**: ReleaseFast build (6.9MB)  
**Git**: v2.43.0

| Operation | git (ms) | ziggit (ms) | Speedup | Winner |
|---|---:|---:|---:|---|
| `log --oneline -1` | 8.7 | 1.9 | **4.6×** | 🟢 ziggit |
| `log --oneline -20` | 9.0 | 2.2 | **4.0×** | 🟢 ziggit |
| `log --oneline -100` | 9.8 | 2.7 | **3.7×** | 🟢 ziggit |
| `log --oneline (all)` | 35.2 | 12.8 | **2.7×** | 🟢 ziggit |
| `log --format=%H` | 13.6 | 2.5 | **5.4×** | 🟢 ziggit |
| `log --stat -5` | 9.7 | 2.3 | **4.3×** | 🟢 ziggit |
| `log --author=dougwilson` | 28.1 | 23.7 | **1.2×** | 🟢 ziggit |
| `log --grep=fix` | 32.5 | 30.0 | **1.1×** | 🟡 parity |
| `log --first-parent --oneline` | 26.1 | 13.0 | **2.0×** | 🟢 ziggit |
| `log --no-merges -20` | 9.4 | 2.3 | **4.0×** | 🟢 ziggit |
| `log --diff-filter=M -5` | 9.6 | 2.2 | **4.5×** | 🟢 ziggit |
| `shortlog -sn HEAD` | 26.3 | 11.7 | **2.2×** | 🟢 ziggit |
| `rev-list --count HEAD` | 9.7 | 2.3 | **4.3×** | 🟢 ziggit |
| `rev-list HEAD` | 12.8 | 2.4 | **5.2×** | 🟢 ziggit |
| `diff HEAD~1 HEAD` | 9.0 | 2.1 | **4.2×** | 🟢 ziggit |
| `diff --stat` | 8.9 | 2.1 | **4.3×** | 🟢 ziggit |
| `diff --name-only` | 8.8 | 2.1 | **4.3×** | 🟢 ziggit |
| `diff --shortstat` | 9.0 | 2.4 | **3.8×** | 🟢 ziggit |
| `show HEAD` | 9.1 | 2.2 | **4.1×** | 🟢 ziggit |
| `show --stat` | 9.2 | 2.3 | **4.0×** | 🟢 ziggit |
| `status` | 10.8 | 7.7 | **1.4×** | 🟢 ziggit |
| `status -s` | 10.2 | 3.8 | **2.7×** | 🟢 ziggit |
| `status --porcelain` | 10.2 | 3.8 | **2.7×** | 🟢 ziggit |
| `branch -a` | 8.8 | 2.0 | **4.4×** | 🟢 ziggit |
| `branch --contains` | 9.0 | 1.9 | **4.7×** | 🟢 ziggit |
| `tag -l` | 9.2 | 3.6 | **2.6×** | 🟢 ziggit |
| `cat-file -p HEAD` | 8.9 | 2.1 | **4.3×** | 🟢 ziggit |
| `cat-file -t HEAD` | 8.9 | 2.0 | **4.4×** | 🟢 ziggit |
| `rev-parse HEAD` | 8.2 | 1.9 | **4.3×** | 🟢 ziggit |
| `rev-parse --git-dir` | 8.0 | 1.9 | **4.2×** | 🟢 ziggit |
| `rev-parse --show-toplevel` | 7.9 | 1.9 | **4.2×** | 🟢 ziggit |
| `config --list` | 8.6 | 2.1 | **4.1×** | 🟢 ziggit |
| `describe --tags --always` | 9.8 | 2.0 | **5.0×** | 🟢 ziggit |
| `grep -r express` | 10.6 | 2.1 | **5.1×** | 🟢 ziggit |
| `stash list` | 8.1 | 1.9 | **4.3×** | 🟢 ziggit |
| `ls-files` | 8.4 | 2.8 | **3.0×** | 🟢 ziggit |
| `ls-tree HEAD` | 8.7 | 2.1 | **4.1×** | 🟢 ziggit |

### Summary

- **36/37 wins (97%), 0 losses, 1 parity**
- **Average speedup: 3.8×** (where ziggit wins)
- **Best: 5.4×** (`log --format=%H`), **5.2×** (`rev-list HEAD`), **5.1×** (`grep -r`)
- Only parity: `log --grep=fix` (1.1×) — full commit message text scan

---

## 2. Bun Install: ziggit vs Stock Bun (macOS release builds)

**Stock bun**: v1.2.10 release  
**Ziggit bun**: v1.3.11 release (60MB, built with latest ziggit optimizations)

### End-to-End `bun install` (5 runs, cold cache, median)

| Test | Stock (ms) | Ziggit (ms) | Winner |
|---|---:|---:|---|
| ms (tiny, 1 git dep) | 586 | 570 | 🟡 parity |
| debug (small) | 865 | 780 | 🟡 parity |
| debug@4.3.4 (tag) | 795 | 698 | 🟢 ziggit 1.1× |
| chalk (medium) | 718 | 738 | 🟡 parity |
| express (65 deps) | 1428 | 1170 | 🟢 ziggit 1.2× |
| semver (npm org) | 598 | 569 | 🟡 parity |
| 4 git deps | 1272 | 1259 | 🟡 parity |
| 2 git + 2 npm | 791 | 792 | 🟡 parity |
| koa (35 deps) | 1198 | 1078 | 🟢 ziggit 1.1× |
| fastify (47 deps) | 1331 | 1327 | 🟡 parity |

**3 wins, 0 losses, 7 parity** — network latency dominates on residential internet.

### Library-Level (eliminates network noise)

| Repo | ziggit | git CLI | Speedup |
|---|---:|---:|---:|
| debug | 453μs | 13,296μs | **29×** |
| chalk | 473μs | 14,539μs | **31×** |
| semver | 490μs | 18,654μs | **38×** |
| express | 505μs | 24,644μs | **49×** |

---

## 3. WebAssembly Binary

| Metric | ziggit | wasm-git | Δ |
|---|---:|---:|---|
| Raw | **142 KB** | 288 KB | **51% smaller** |
| gzip | **55 KB** | ~120 KB | **54% smaller** |
| brotli | **46 KB** | ~100 KB | **54% smaller** |
| Exports | 68 | ~20 | **3.4× more** |

---

## 4. Test Suite Coverage

Tested against git v2.43.0 test suite on macOS ARM64.

| Script | Pass | Total | Rate |
|---|---:|---:|---:|
| t1006-cat-file.sh | 165 | 179 | **92%** |
| t1300-config.sh | 200 | 219 | **91%** |
| t7004-tag.sh | 195 | 218 | **89%** |
| t1500-rev-parse.sh | 67 | 76 | **88%** |
| t6300-for-each-ref.sh | 361 | 418 | **86%** |
| t3903-stash.sh | 94 | 122 | **77%** |
| t7508-status.sh | 77 | 121 | **64%** |
| t3200-branch.sh | 102 | 164 | **62%** |
| t7502-commit-porcelain.sh | 20 | 47 | **43%** |
| t4202-log.sh | 62 | 146 | **42%** |

76+ subcommands implemented. Two agents actively improving coverage.

---

## Build

```bash
zig build -Doptimize=ReleaseFast  # 6.9MB CLI binary
zig build wasm                     # 142KB WASM module
```

Requires Zig 0.15.2.
