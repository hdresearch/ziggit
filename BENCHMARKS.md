# Ziggit vs Git CLI Benchmarks

**Platform**: macOS ARM64 (Apple Silicon), 5 runs each, median values reported
**Test repo**: expressjs/express (6,135 commits, 423 files)
**Date**: 2026-03-28
**Ziggit**: ReleaseFast build (6.8MB binary)
**Git**: v2.43.0

## Results

| Operation | git (ms) | ziggit (ms) | Speedup | Winner |
|---|---:|---:|---:|---|
| `log --oneline -20` | 10.1 | 2.7 | **3.7×** | 🟢 ziggit |
| `log --oneline -100` | 11.1 | 3.2 | **3.5×** | 🟢 ziggit |
| `log --oneline` (all 6135) | 35.9 | 26.7 | **1.3×** | 🟢 ziggit |
| `log --format=%H` | 33.2 | 126.5 | 0.26× | 🔴 git |
| `shortlog -sn` | 9.4 | 22.5 | 0.42× | 🔴 git |
| `rev-list --count HEAD` | 25.9 | 12.7 | **2.0×** | 🟢 ziggit |
| `rev-list HEAD` | 31.2 | 24.8 | **1.3×** | 🟢 ziggit |
| `diff HEAD~1 HEAD` | 10.0 | 2.9 | **3.4×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --stat` | 10.3 | 2.9 | **3.6×** | 🟢 ziggit |
| `diff HEAD~1 HEAD --name-only` | 9.7 | 2.6 | **3.7×** | 🟢 ziggit |
| `show HEAD --stat` | 9.9 | 2.6 | **3.8×** | 🟢 ziggit |
| `show HEAD` | 10.1 | 2.9 | **3.5×** | 🟢 ziggit |
| `status` | 11.1 | 4.0 | **2.8×** | 🟢 ziggit |
| `status -s` | 10.9 | 3.7 | **2.9×** | 🟢 ziggit |
| `branch -a` | 9.5 | 2.0 | **4.8×** | 🟢 ziggit |
| `branch --contains HEAD` | 9.6 | 2.0 | **4.8×** | 🟢 ziggit |
| `tag -l` | 9.6 | 3.8 | **2.5×** | 🟢 ziggit |
| `cat-file -p HEAD` | 9.3 | 2.2 | **4.2×** | 🟢 ziggit |
| `cat-file -t HEAD` | 9.3 | 2.2 | **4.2×** | 🟢 ziggit |
| `rev-parse HEAD` | 9.1 | 2.4 | **3.8×** | 🟢 ziggit |
| `rev-parse --git-dir` | 9.7 | 2.1 | **4.6×** | 🟢 ziggit |
| `rev-parse --show-toplevel` | 9.2 | 2.0 | **4.6×** | 🟢 ziggit |
| `config --list` | 9.1 | 2.2 | **4.1×** | 🟢 ziggit |
| `describe --tags --always` | 11.3 | 2.4 | **4.7×** | 🟢 ziggit |
| `grep -r express` | 11.9 | 2.2 | **5.4×** | 🟢 ziggit |
| `log --author=dougwilson` | 28.6 | 24.4 | **1.2×** | 🟢 ziggit |
| `log --grep=fix` | 30.9 | 29.5 | **1.0×** | 🟡 parity |
| `stash list` | 9.4 | 2.3 | **4.1×** | 🟢 ziggit |

## Summary

- **ziggit wins**: 25/28 operations (89%)
- **git wins**: 2/28 operations (7%) — `log --format=%H`, `shortlog -sn`
- **parity**: 1/28 operations (4%) — `log --grep=fix`
- **Average speedup** (excluding losses): **3.5×**
- **Best speedup**: `grep -r express` at **5.4×**

## Known Regressions

| Operation | Issue | Root Cause |
|---|---|---|
| `log --format=%H` | 3.8× slower | Custom format string parsing overhead — needs optimization |
| `shortlog -sn` | 2.4× slower | Full pack decompression for author extraction vs git's commit-graph shortcut |

## Test Suite Coverage

- **189/999** test scripts passing (18.9%)
- **14,576/25,676** individual tests passing (56.8%)
- Last full run: 2026-03-27

## Build

```bash
zig build -Doptimize=ReleaseFast  # produces 6.8MB binary
```
