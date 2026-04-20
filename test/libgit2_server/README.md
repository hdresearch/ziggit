# libgit2 Test Server

C program using libgit2 to create and verify bare git repositories for cross-verification testing with ziggit.

## Prerequisites

- `zig` (used as C compiler via `zig cc`)
- `cmake` (for building libgit2 from source)
- `git` (for cloning libgit2 source)

## Building libgit2

If libgit2 is not already built:

```bash
./build_libgit2.sh
```

This clones libgit2 v1.8.4 and builds it as a static library using `zig cc`.

## Building the test server

```bash
make
```

## Running tests

```bash
make check
```

This creates a bare test repository at `/tmp/libgit2_test_repo.git` with:
- 3 commits on `main` branch
- `feature-test` branch
- Annotated tag `v1.0`
- Multiple blobs and trees

## Tests performed

1. **Init bare repo** — creates a bare repository
2. **Blob roundtrip** — creates blob, reads back, verifies content
3. **Tree creation** — creates tree with multiple sorted entries
4. **Commit chain** — creates 3-commit history, verifies revwalk
5. **Ref verification** — checks refs/heads/main exists
6. **Branch creation** — creates feature-test branch
7. **Tag creation** — creates annotated tag v1.0
8. **ODB integrity** — counts objects in database
9. **Object readback** — verifies HEAD commit message and tree

## Cross-verification

After running the server, use the client to clone and verify:

```bash
cd ../libgit2_client && make check
```
