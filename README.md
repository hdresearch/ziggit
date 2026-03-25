# ziggit

A modern version control system written in Zig — a drop-in replacement for git.

## Goals

- Drop-in git replacement: `ziggit checkout`, `ziggit commit`, etc. (no `ziggit git` subcommands)
- Full feature compatibility with git (passes git's own test suite)
- Compiles to WebAssembly
- Performance improvements for oven-sh/bun by replacing libgit2/git CLI with native Zig integration

## Building

```bash
zig build
```

## License

MIT
