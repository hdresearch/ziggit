# ziggit

A modern version control system written in Zig — a drop-in replacement for git.

## Goals

- Drop-in git replacement: `ziggit checkout`, `ziggit commit`, etc. (no `ziggit git` subcommands)
- Full feature compatibility with git (passes git's own test suite)
- Compiles to WebAssembly
- Performance improvements for oven-sh/bun by replacing libgit2/git CLI with native Zig integration

## Building

### Native build
```bash
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build
```

### WebAssembly (WASI)
```bash
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
zig build wasm
```

This produces `zig-out/bin/ziggit.wasm` that can be run with WASI runtimes like:
- [wasmtime](https://wasmtime.dev/): `wasmtime --dir . zig-out/bin/ziggit.wasm init my-repo`
- [wasmer](https://wasmer.io/): `wasmer zig-out/bin/ziggit.wasm`

Example:
```bash
# Install wasmtime
curl -sSf https://wasmtime.dev/install.sh | bash
export PATH="$HOME/.wasmtime/bin:$PATH"

# Run ziggit in WASM
wasmtime --dir . zig-out/bin/ziggit.wasm init my-repo
cd my-repo && wasmtime --dir . ../zig-out/bin/ziggit.wasm status  # Some commands may have limitations
```

### WebAssembly (Browser/Freestanding)
```bash
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache  
zig build wasm-browser  # Currently disabled due to stdlib compatibility issues
```

## WebAssembly Limitations

### WASI Build
- Filesystem operations work through WASI APIs
- Network operations are stubbed/limited by WASI capabilities
- Working directory changes may not be supported
- Some system-level git operations may be limited

### Browser/Freestanding Build
- Currently disabled due to Zig stdlib POSIX dependencies in freestanding target
- Would require virtual filesystem implementation
- All I/O operations need JavaScript host functions
- No direct filesystem access
- Network operations require JavaScript implementation

## Platform Abstraction

The codebase uses a platform abstraction layer in `src/platform/` that allows ziggit to run on different targets:
- `native.zig`: Standard POSIX/Windows platforms
- `wasi.zig`: WebAssembly System Interface
- `freestanding.zig`: Browser/embedded (in development)

This ensures the core git logic remains platform-agnostic while supporting different runtime environments.

## License

MIT
