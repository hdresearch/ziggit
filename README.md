<p align="center">
  <img src="ziggit-logo.png" alt="ziggit" width="400">
</p>

A modern git implementation written in pure Zig. Drop-in replacement for `git` — use `ziggit` wherever you'd use `git`.

**4–10× faster** than git on macOS arm64, compiles to a **142KB WebAssembly** binary, and includes a **succinct mode** that cuts LLM token usage by 70–95%. Supports push/pull over HTTPS to GitHub and other git hosts.

## Install

### Download a release (easiest)

Grab the latest binary for your platform from [GitHub Releases](https://github.com/hdresearch/ziggit/releases/latest):

**macOS (Apple Silicon):**
```bash
curl -fsSL https://github.com/hdresearch/ziggit/releases/latest/download/ziggit-macos-aarch64 -o ziggit
chmod +x ziggit
sudo mv ziggit /usr/local/bin/
```

**macOS (Intel):**
```bash
curl -fsSL https://github.com/hdresearch/ziggit/releases/latest/download/ziggit-macos-x86_64 -o ziggit
chmod +x ziggit
sudo mv ziggit /usr/local/bin/
```

**Linux (x86_64):**
```bash
curl -fsSL https://github.com/hdresearch/ziggit/releases/latest/download/ziggit-linux-x86_64 -o ziggit
chmod +x ziggit
sudo mv ziggit /usr/local/bin/
```

**Linux (arm64):**
```bash
curl -fsSL https://github.com/hdresearch/ziggit/releases/latest/download/ziggit-linux-aarch64 -o ziggit
chmod +x ziggit
sudo mv ziggit /usr/local/bin/
```

### Build from source

Requires [Zig 0.15.2+](https://ziglang.org/download/).

```bash
git clone https://github.com/hdresearch/ziggit.git
cd ziggit
zig build -Doptimize=ReleaseFast
cp zig-out/bin/ziggit ~/.local/bin/
```

### Alias as `git`

If you want to use ziggit as your default `git`:

```bash
alias git=ziggit
```

Add that to your `~/.bashrc`, `~/.zshrc`, or equivalent to make it permanent.

## Usage

ziggit works exactly like git. Every command, flag, and argument you know works the same way:

```bash
ziggit init
ziggit clone https://github.com/user/repo.git
ziggit add .
ziggit commit -m "initial commit"
ziggit push origin main
ziggit log --oneline -10
ziggit status
ziggit diff
ziggit branch -a
ziggit checkout -b feature
ziggit stash
ziggit merge feature
ziggit rebase main
ziggit tag v1.0.0
ziggit blame README.md
```

It reads and writes the same `.git` directory format, so you can switch between `git` and `ziggit` freely on any repository.

## Succinct mode

Succinct mode compresses CLI output to save tokens when used by LLM coding agents. It's **on by default**.

| Command | Normal output | Succinct output |
|---------|--------------|-----------------|
| `status` | 12 lines with hints | `* main` `+ Staged: 2 files` `~ Modified: 1 files` |
| `log` | 6 lines per commit | `a1b2c3d fix: bug (2 min ago) Alice` |
| `commit` | `[main a1b2c3d] msg` + stats | `ok main a1b2c3d "msg"` |
| `checkout` | `Switched to branch 'foo'` | `ok switched to foo` |
| `push` | Progress + refs | `ok push main a1b2c3d` |
| `fetch` | Progress + ref updates | `ok fetch origin 3 refs` |
| `merge` | Verbose merge info | `ok merge feature` |
| `clone` | Counting, compressing, etc. | `ok clone URL` |
| `diff` | Full diff | First 500 lines, then `[full diff: git diff --no-succinct]` |

To disable succinct mode and get standard git output:

```bash
ziggit --no-succinct status
```

Or set the environment variable:

```bash
export GIT_SUCCINCT=0
```

Succinct mode automatically disables when running under git's test suite (`GIT_TEST_INSTALLED`), so it never interferes with compatibility testing.

## Workflow commands

Three convenience commands for development loops:

```bash
ziggit restart              # fetch + rebase onto origin/main
ziggit start                # stash + restart + pop (safe restart with dirty tree)
ziggit progress "did stuff" # add -A + commit + push + restart
```

## WebAssembly

ziggit compiles to a 142KB WASM binary (55KB gzipped) with 68 named exports — clone a repo in your browser.

Build it:

```bash
zig build wasm
```

The output is at `zig-out/wasm/ziggit.wasm`. A ready-to-use demo is in the `wasm/` directory — serve it with any static file server:

```bash
cd wasm
python3 -m http.server 8080
```

Then open `http://localhost:8080/demo.html`.

## Performance

Measured with [hyperfine](https://github.com/sharkdp/hyperfine) (100 runs, 5 warmup). Full details in [BENCHMARKS.md](BENCHMARKS.md).

### CLI (macOS arm64)

| Command | git | ziggit | Speedup |
|---------|-----|--------|---------|
| `status` | 8.1ms | 1.0ms | **8.1×** |
| `log -20` | 8.4ms | 1.7ms | **5.0×** |
| `branch -a` | 7.9ms | 1.4ms | **5.6×** |
| `blame` (large repo) | 36ms | 2.8ms | **12.6×** |

### As a library (bun integration)

When used as a Zig library instead of spawning `git` as a subprocess:

| Operation | macOS arm64 | Linux x86_64 |
|-----------|-------------|--------------|
| `findCommit` (rev-parse) | **85×** | **6×** |
| `cloneBare` | **7×** | **34×** |
| Full workflow | **10×** | **32×** |

### Binary size

| Target | Size |
|--------|------|
| macOS arm64 (ReleaseFast) | 7.5MB |
| macOS arm64 (ReleaseSmall) | 3.4MB |
| Linux x86_64 (stripped) | 8.4MB |
| WASM (ReleaseSmall) | 142KB |
| WASM (gzipped) | 55KB |

## Project structure

```
src/
  main.zig              # native entry point
  main_common.zig       # command dispatch (104 commands)
  main_freestanding.zig  # WASM entry point
  succinct.zig          # succinct output mode
  cmd_workflow.zig      # workflow commands (restart, start, progress)
  cmd_*.zig             # command implementations
  git/                  # core git internals (objects, refs, pack, index, etc.)
  platform/             # platform abstraction (native, WASM)
wasm/
  demo.html             # browser demo
  demo.js               # WASM host bindings
  ziggit.wasm           # prebuilt WASM binary
build.zig
```

## License

GPLv2
