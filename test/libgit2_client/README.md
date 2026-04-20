# libgit2 Test Client

C program using libgit2 to clone, fetch, push, and verify repositories for cross-verification testing with ziggit.

## Prerequisites

- `zig` (used as C compiler via `zig cc`)
- libgit2 built from source (see `../libgit2_server/build_libgit2.sh`)
- Test repository created by `../libgit2_server/server`

## Building

```bash
make
```

## Running tests

First create the test repository:
```bash
cd ../libgit2_server && make check
```

Then run the client:
```bash
make check
```

## Tests performed

1. **Clone** — clones local bare repo to working directory
2. **Verify refs** — checks HEAD, main branch, remote tracking refs
3. **Commit walk** — walks full history, verifies 3 commits
4. **Blob content** — reads file.txt blob, verifies content
5. **Tag verification** — checks annotated tag v1.0 and message
6. **Create commit** — adds new file, creates commit in clone
7. **Push** — pushes new commit back to origin
8. **Fetch** — fetches from origin
9. **ODB integrity** — counts all objects
10. **git fsck** — runs `git fsck` to verify repository integrity
