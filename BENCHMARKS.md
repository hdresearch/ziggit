# Ziggit Comprehensive Benchmarks

**Date:** 2026-03-31  
**Ziggit:** commit `d4c1e5c` (2,367 commits, 150 source files, 125,878 LOC)

---

## Table of Contents

1. [CLI Performance: ziggit vs git](#1-cli-performance-ziggit-vs-git)
2. [Internal Library Speedups (bun integration)](#2-internal-library-speedups-bun-integration)
3. [E2E bun install Benchmarks](#3-e2e-bun-install-benchmarks)
4. [Binary Size](#4-binary-size)

---

## 1. CLI Performance: ziggit vs git

### macOS arm64 — Small Repo (51 commits, 100 files)

Measured with `hyperfine --warmup 5 --runs 100`.

| Command | git (ms) | ziggit (ms) | Speedup |
|---------|----------|-------------|---------|
| `status` | 8.1 | 1.0 | **8.1×** |
| `log -20` | 8.4 | 1.7 | **5.0×** |
| `diff --stat HEAD~1` | 7.7 | 1.5 | **5.2×** |
| `branch -a` | 7.9 | 1.4 | **5.6×** |
| `rev-parse HEAD` | 7.0 | 1.3 | **5.3×** |
| `tag -l` | 7.4 | 1.3 | **5.5×** |
| `show --stat` | 7.9 | 1.7 | **4.7×** |
| `diff HEAD~1` | 8.0 | 1.6 | **4.9×** |
| `log --oneline` | 8.7 | 2.4 | **3.7×** |
| `blame file_1.txt` | 10.2 | 7.6 | **1.3×** |

**Average: 4.9× faster** (Apple Git 2.50.1 vs ziggit, M-series arm64, macOS 15.6)

### macOS arm64 — Large Repo (ziggit itself: 2,367 commits, 150 files)

Measured with `hyperfine --warmup 5 --runs 50`.

| Command | git (ms) | ziggit (ms) | Speedup |
|---------|----------|-------------|---------|
| `status` | 8.6 | 4.1 | **2.1×** |
| `log -20` | 9.2 | 2.1 | **4.5×** |
| `log --oneline -50` | 8.5 | 1.9 | **4.6×** |
| `diff --stat HEAD~1` | 9.3 | 7.5 | **1.3×** |
| `branch -a` | 7.7 | 1.4 | **5.5×** |
| `rev-parse HEAD` | 7.1 | 1.4 | **5.1×** |
| `tag -l` | 7.7 | 1.3 | **5.8×** |
| `show --stat` | 8.4 | 7.2 | **1.2×** |
| `log --oneline` (all 2367) | 22.5 | 15.7 | **1.4×** |
| `blame src/main.zig` | 36.0 | 2.8 | **12.6×** |

**Average: 4.4× faster** (Apple Git 2.50.1, M-series arm64)

### Linux x86_64 VM — Small Repo (21 commits, 50 files)

Measured with 50 iterations, `date +%s%N` timing. 8GB RAM, vers VM.

| Command | git (ms) | ziggit (ms) | Speedup |
|---------|----------|-------------|---------|
| `status` | 4 | 2 | **2.0×** |
| `log -20` | 3 | 4 | 0.8× |
| `diff --stat HEAD~1` | 4 | 3 | **1.3×** |
| `branch -a` | 3 | 3 | 1.0× |
| `rev-parse HEAD` | 3 | 2 | **1.5×** |
| `tag -l` | 2 | 2 | 1.0× |
| `show --stat` | 3 | 3 | 1.0× |
| `diff HEAD~1` | 4 | 3 | **1.3×** |
| `log --oneline` | 4 | 4 | 1.0× |

**Average: 1.2× faster** (git 2.43.0, x86_64 Linux)

### Linux x86_64 VM — Large Repo (2,367 commits)

| Command | git (μs) | ziggit (μs) | Speedup |
|---------|----------|-------------|---------|
| `status` | 5,975 | 8,939 | 0.7× |
| `log -20` | 4,534 | 4,773 | 0.9× |
| `log --oneline -50` | 7,301 | 7,511 | 1.0× |
| `diff --stat HEAD~1` | 7,557 | 23,173 | 0.3× |
| `branch -a` | 3,883 | 4,103 | 0.9× |
| `rev-parse HEAD` | 3,139 | 3,418 | 0.9× |
| `tag -l` | 3,617 | 3,637 | 1.0× |
| `show --stat` | 6,588 | 21,376 | 0.3× |
| `log --oneline` (all) | 41,865 | 48,037 | 0.9× |
| `blame src/main.zig` | 87,885 | 7,888 | **11.1×** |

**Notes on Linux:** On x86_64 Linux, git is heavily optimized and the process spawn overhead is much lower (~2ms vs ~7ms on macOS). Ziggit's advantage comes from algorithmic wins (blame cache: 11×) rather than startup time. The diff --stat/show --stat regressions on the large repo are being investigated.

---

## 2. Internal Library Speedups (bun integration)

These measure ziggit as a **linked library** vs spawning `git` as a **subprocess** — the exact comparison relevant to bun's package manager.

### macOS arm64 (ReleaseFast, 20 iterations)

#### findCommit (rev-parse HEAD)

| Repo | Size | ziggit (μs) | git CLI (μs) | Speedup |
|------|------|-------------|--------------|---------|
| debug | 596KB | 108 | 8,176 | **75.7×** |
| chalk | 2.2MB | 70 | 7,760 | **110.8×** |
| is | 1.3MB | 74 | 7,913 | **106.9×** |
| node-semver | 2.2MB | 93 | 7,772 | **83.5×** |
| express | 11MB | 116 | 7,661 | **66.0×** |
| **Average** | | **92** | **7,856** | **85.4×** |

#### cloneBare (local bare clone)

| Repo | Size | ziggit (μs) | git CLI (μs) | Speedup |
|------|------|-------------|--------------|---------|
| debug | 596KB | 1,641 | 18,071 | **11.0×** |
| chalk | 2.2MB | 1,528 | 17,628 | **11.5×** |
| is | 1.3MB | 1,504 | 17,994 | **11.9×** |
| node-semver | 2.2MB | 1,799 | 18,605 | **10.3×** |
| express | 11MB | 6,032 | 19,395 | **3.2×** |
| **Average** | | **2,501** | **18,339** | **7.3×** |

#### Full Workflow (cloneBare + findCommit + checkout)

| Repo | Size | ziggit (μs) | git CLI (μs) | Speedup |
|------|------|-------------|--------------|---------|
| debug | 596KB | 3,058 | 45,617 | **14.9×** |
| chalk | 2.2MB | 3,099 | 47,792 | **15.4×** |
| is | 1.3MB | 3,229 | 46,795 | **14.4×** |
| node-semver | 2.2MB | 3,484 | 54,916 | **15.7×** |
| express | 11MB | 13,752 | 59,456 | **4.3×** |
| **Average (small 4)** | | **3,218** | **48,780** | **15.2×** |
| **Average (all 5)** | | **5,324** | **50,915** | **9.6×** |

### Linux x86_64 VM (ReleaseFast, 20 iterations, 8GB RAM)

#### findCommit

| Repo | ziggit (μs) | git CLI (μs) | Speedup |
|------|-------------|--------------|---------|
| debug | 370 | 2,128 | **5.7×** |
| chalk | 132 | 2,215 | **16.7×** |
| is | 131 | 2,110 | **16.1×** |
| node-semver | 375 | 2,008 | **5.3×** |
| express | 649 | 2,042 | **3.1×** |
| **Average** | **331** | **2,101** | **6.3×** |

#### cloneBare

| Repo | ziggit (μs) | git CLI (μs) | Speedup |
|------|-------------|--------------|---------|
| debug | 394 | 9,453 | **23.9×** |
| chalk | 382 | 8,328 | **21.8×** |
| is | 378 | 8,737 | **23.1×** |
| node-semver | 174 | 11,545 | **66.3×** |
| express | 180 | 13,806 | **76.7×** |
| **Average** | **302** | **10,374** | **34.3×** |

#### Full Workflow

| Repo | ziggit (μs) | git CLI (μs) | Speedup |
|------|-------------|--------------|---------|
| debug | 986 | 22,651 | **22.9×** |
| chalk | 845 | 24,382 | **28.8×** |
| is | 1,043 | 26,227 | **25.1×** |
| node-semver | 679 | 33,152 | **48.8×** |
| express | 1,153 | 46,104 | **39.9×** |
| **Average** | **941** | **30,503** | **32.4×** |

### Why macOS shows bigger findCommit speedups (85× vs 6×)

On macOS, `fork()+exec()` to spawn `git` costs ~7.8ms. On Linux, it costs ~2.1ms. The ziggit library call itself is 70-650μs on both platforms. The massive macOS findCommit speedup (66-111×) is almost entirely from eliminating macOS's expensive process spawn.

---

## 3. E2E bun install Benchmarks

### Release Build

- **Stock bun:** 1.2.10 (Homebrew release, macOS arm64)
- **Ziggit bun:** 1.3.11-canary (local cmake+ninja release build from `hdresearch/bun` ziggit-integration branch)

### Single Git Dependency (7 runs, cold cache, median)

| Package | Stock (ms) | Ziggit (ms) | Speedup |
|---------|-----------|------------|---------|
| ms | 1,010 | 728 | **1.39×** |
| chalk | 846 | 739 | **1.14×** |
| debug@4.3.4 | 849 | 843 | 1.01× |
| semver | 800 | 742 | **1.08×** |
| is-type | 840 | 906 | 0.93× |

### Multi Git Dependencies (5 deps at once, 7 runs, cold cache)

| Test | Stock (ms) | Ziggit (ms) | Speedup |
|------|-----------|------------|---------|
| 5 small deps (ms+chalk+debug+semver+is) | 1,177 | 1,115 | **1.06×** |
| 2 large deps (express+koa) | 1,587 | 1,423 | **1.12×** |

### Warm Cache (lockfile present, 20 runs)

| Test | Stock (ms) | Ziggit (ms) | Speedup |
|------|-----------|------------|---------|
| 5 git deps (warm) | 21 | 21 | 1.0× (parity) |

### Why E2E shows modest speedups despite 10-85× library speedups

1. **Network dominates:** Cold `bun install` spends 500-900ms on HTTPS clones from GitHub. The git resolution portion is only ~50-80ms of total time.
2. **npm registry resolution:** Transitive npm deps (not git) add 200-400ms.
3. **File I/O:** Extraction, linking, lockfile generation add constant overhead.
4. **The internal speedup is real** but git dep resolution is only ~10-15% of cold install wall time.

### Projected Impact at Scale

| Git deps in project | Estimated savings | % of cold install |
|--------------------|------------------|-------------------|
| 5 | ~40ms | ~5-8% |
| 10 | ~80ms | ~10-15% |
| 20 | ~160ms | ~20-25% |
| 50 | ~400ms | ~40%+ |

---

## 4. Binary Size

| Build | Platform | Size |
|-------|----------|------|
| ReleaseFast | macOS arm64 | 7.5 MB |
| ReleaseSmall | macOS arm64 | 3.4 MB |
| ReleaseFast (stripped) | Linux x86_64 | 8.4 MB |
| WASM (ReleaseSmall) | wasm32 | 148 KB (57 KB gzipped) |
| WASM (wasm-git) | wasm32 | 288 KB |

---

## Methodology

- **CLI benchmarks (macOS):** `hyperfine --warmup 5 --runs N` with process-level timing
- **CLI benchmarks (Linux):** Shell loop with `date +%s%N` nanosecond timing, 50 iterations
- **Library benchmarks:** Custom `lib_bench.zig` binary linking ziggit directly, `-Doptimize=ReleaseFast`, measures wall-clock time of each library call vs `fork()+exec("git ...")` subprocess
- **E2E bun install:** Wall-clock timing of `bun install --no-progress`, cold cache (remove `~/.bun/install/cache` + `node_modules` + `bun.lockb` between runs), 7 runs, median reported
- **Warm cache:** Remove only `node_modules`, keep lockfile and cache, 20 runs

## Environment

- **macOS:** arm64, macOS 15.6, Apple M-series, Apple Git 2.50.1
- **Linux VM:** x86_64, 8GB RAM, vers VM, git 2.43.0
- **Zig:** 0.15.2 (stock for ziggit CLI, oven-sh fork for bun integration)
- **Bun:** stock 1.2.10 vs ziggit-integration 1.3.11-canary (cmake+ninja release build)
