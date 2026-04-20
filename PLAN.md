# Ziggit Feature Plan: WASM Server Exports, Partial Clone, include-tag, and ArtifactFS Integration

This plan covers three areas of work:

1. **WASM server host-callback interface** — the missing bridge that lets the WASM module serve git operations against host-provided storage (the 11 host imports + streaming output + server exports described in the Cloudflare Artifacts architecture)
2. **`filter` capability** — partial/blobless clone support (`blob:none`, `tree:0`, `blob:limit=N`) for both client and server, required by ArtifactFS
3. **`include-tag` capability** — automatic tag object inclusion in fetch responses
4. **ArtifactFS integration testing** — validate ziggit as the git backend for Cloudflare's ArtifactFS FUSE driver

**Do NOT cut any releases during this work. Releases will be done manually.**

---

## Phase 1: WASM Server Host-Callback Storage Interface

**Goal:** The WASM build can function as a complete git server backed by any JS-provided storage, matching the architecture described in the Cloudflare Artifacts blog: *"11 host-imported functions for storage operations and one for streaming output"*.

**Current state:** `wasm_exports.zig` has filesystem-based host imports (`host_read_file`, `host_write_file`, `host_http_get`, etc.) and client-side exports (clone, rev-parse, ls-remote, etc.). The native server works (`git_serve.zig` + `git_storage.zig`), but there are zero WASM server exports and zero object-level host imports.

### 1.1 Add object-level host imports to `wasm_exports.zig`

**File:** `src/wasm_exports.zig`

Add these 11 host-imported functions alongside the existing `host_read_file` / `host_write_file` imports:

```zig
// ========== Git object storage host imports ==========
// These let the JS host provide any backing store (SQLite, KV, memory, etc.)

/// Retrieve a git object by its SHA-1 hash.
/// hash_ptr: pointer to 20 raw bytes (binary SHA-1)
/// data_ptr: out — host sets this to point at object data
/// data_len: out — host sets this to the data length
/// type_out: out — host sets this to object type (1=commit, 2=tree, 3=blob, 4=tag)
/// Returns true if object exists, false otherwise.
extern fn host_get_object(hash_ptr: [*]const u8, hash_len: u32, data_ptr: *[*]u8, data_len: *u32, type_out: *u32) bool;

/// Store a git object.
/// hash_ptr: 20 raw bytes (binary SHA-1)
/// data_ptr: object content
/// data_len: content length
/// obj_type: 1=commit, 2=tree, 3=blob, 4=tag
extern fn host_put_object(hash_ptr: [*]const u8, hash_len: u32, data_ptr: [*]const u8, data_len: u32, obj_type: u32) bool;

/// Check if an object exists without retrieving it.
extern fn host_object_exists(hash_ptr: [*]const u8, hash_len: u32) bool;

/// Get a ref's target hash.
/// name_ptr/name_len: ref name (e.g. "refs/heads/main")
/// hash_out: 20-byte buffer for the binary hash
/// Returns true if ref exists.
extern fn host_get_ref(name_ptr: [*]const u8, name_len: u32, hash_out: [*]u8) bool;

/// Set a ref to point at a hash.
extern fn host_put_ref(name_ptr: [*]const u8, name_len: u32, hash_ptr: [*]const u8) bool;

/// Delete a ref.
extern fn host_delete_ref(name_ptr: [*]const u8, name_len: u32) bool;

/// List all refs. Host writes a buffer of packed entries:
///   each entry: 20-byte hash + u16 name_len (big-endian) + name bytes
/// out_ptr/out_len: host sets these to point at the packed buffer.
extern fn host_list_refs(out_ptr: *[*]u8, out_len: *u32) bool;

/// Retrieve a stored delta for an object (optional optimization).
/// If the object was received via push with a delta, the raw delta bytes
/// and base hash are persisted alongside the resolved object.
/// base_out: 20-byte buffer for base object hash
/// delta_ptr/delta_len: out — host sets these to point at delta data
/// Returns true if a stored delta exists for this object.
extern fn host_get_object_delta(hash_ptr: [*]const u8, hash_len: u32, base_out: [*]u8, delta_ptr: *[*]u8, delta_len: *u32) bool;

/// Store a delta alongside an object (called during push/receive-pack).
extern fn host_put_object_delta(hash_ptr: [*]const u8, hash_len: u32, base_ptr: [*]const u8, delta_ptr: [*]const u8, delta_len: u32) bool;

/// List objects matching a fanout prefix byte. Used for object enumeration.
/// prefix: first byte of SHA-1 (0x00–0xff)
/// out_ptr/out_len: packed buffer of 20-byte hashes
extern fn host_list_objects(prefix: u8, out_ptr: *[*]u8, out_len: *u32) bool;

/// Stream output bytes back to the JS host (for server responses).
/// Called incrementally as pack data is generated — the host should
/// forward these bytes to the HTTP response stream.
extern fn host_emit_bytes(data_ptr: [*]const u8, data_len: u32) void;
```

**Key design point:** The existing filesystem-based imports (`host_read_file`, etc.) remain unchanged for client-side WASM usage. The new imports are only called by the server export functions. The JS host implements whichever set it needs.

### 1.2 Create `HostCallbackStorage` backend

**File:** `src/git/host_callback_storage.zig` (new, ~200-300 lines)

Implement a storage backend that satisfies the same interface as `GitStorage` but delegates every operation to the host imports from 1.1:

```zig
pub const HostCallbackStorage = struct {
    allocator: std.mem.Allocator,

    pub fn objectExists(self: *HostCallbackStorage, hash_hex: []const u8) bool { ... }
    pub fn readObject(self: *HostCallbackStorage, hash_hex: []const u8) !ObjectData { ... }
    pub fn writeObject(self: *HostCallbackStorage, obj_type: ObjectType, data: []const u8) ![40]u8 { ... }
    pub fn getRef(self: *HostCallbackStorage, name: []const u8) ?[20]u8 { ... }
    pub fn putRef(self: *HostCallbackStorage, name: []const u8, hash: [20]u8) !void { ... }
    pub fn deleteRef(self: *HostCallbackStorage, name: []const u8) !void { ... }
    pub fn listRefs(self: *HostCallbackStorage) ![]RefEntry { ... }
    pub fn getStoredDelta(self: *HostCallbackStorage, hash: [20]u8) ?StoredDelta { ... }
    pub fn putStoredDelta(self: *HostCallbackStorage, hash: [20]u8, base: [20]u8, delta: []const u8) !void { ... }
};
```

Helper functions convert between hex/binary hashes and call the extern host functions. Each method is a thin wrapper: convert hash format, call host import, copy returned data into Zig-managed memory.

### 1.3 Create `WasmGitServer` that operates on `HostCallbackStorage`

**File:** `src/git/wasm_git_serve.zig` (new, ~400-600 lines)

This is a WASM-specific version of the server protocol handler that:
- Uses `HostCallbackStorage` instead of filesystem access
- Uses `host_emit_bytes` for streaming output instead of writing to a `std.net.Stream`
- Operates on raw byte buffers (request in, response streamed out via callbacks)

The core logic mirrors `git_serve.zig` but adapted for the WASM constraints:

```zig
pub const WasmGitServer = struct {
    allocator: std.mem.Allocator,
    storage: HostCallbackStorage,

    /// Generate ref advertisement for info/refs endpoint.
    /// service: 0 = git-upload-pack, 1 = git-receive-pack
    /// Streams response via host_emit_bytes.
    pub fn serveRefAdvertisement(self: *WasmGitServer, service: u32) !void { ... }

    /// Process a git-upload-pack request (fetch/clone).
    /// request: raw HTTP request body bytes
    /// Streams pack response via host_emit_bytes.
    pub fn serveUploadPack(self: *WasmGitServer, request: []const u8) !void { ... }

    /// Process a git-receive-pack request (push).
    /// request: raw HTTP request body bytes
    /// Streams status response via host_emit_bytes.
    pub fn serveReceivePack(self: *WasmGitServer, request: []const u8) !void { ... }

    /// Process a protocol v2 command.
    pub fn serveV2Command(self: *WasmGitServer, request: []const u8) !void { ... }
};
```

**Critical implementation details:**

- **Streaming pack generation:** When building the pack in `serveUploadPack`, call `host_emit_bytes` incrementally (pack header first, then each compressed object, then checksum) rather than buffering the entire pack in WASM memory. This is essential for the 128MB Durable Objects memory limit.
- **Delta replay optimization:** In `serveUploadPack`, before compressing an object for the pack, check `host_get_object_delta` — if a stored delta exists and the base object is in the client's `have` set, emit the delta directly instead of the full object. This avoids expensive delta computation and reduces memory usage.
- **Sideband framing:** Wrap pack chunks in sideband-64k framing before calling `host_emit_bytes`, so the output is ready to forward directly to the HTTP response.

### 1.4 Add WASM server exports

**File:** `src/wasm_exports.zig` (additions at bottom)

```zig
/// Process a git-upload-pack request (fetch/clone).
/// request_ptr/len: raw HTTP request body
/// Response is streamed via host_emit_bytes callbacks.
/// Returns 0 on success, negative on error.
export fn ziggit_serve_upload_pack(request_ptr: [*]const u8, request_len: u32) i32 { ... }

/// Process a git-receive-pack request (push).
export fn ziggit_serve_receive_pack(request_ptr: [*]const u8, request_len: u32) i32 { ... }

/// Generate ref advertisement for info/refs endpoint.
/// service: 0 = git-upload-pack, 1 = git-receive-pack
export fn ziggit_serve_ref_advertisement(service: u32) i32 { ... }

/// Process a protocol v2 command.
export fn ziggit_serve_v2_command(request_ptr: [*]const u8, request_len: u32) i32 { ... }
```

Each export instantiates a `WasmGitServer` with `HostCallbackStorage`, calls the corresponding method, and returns a status code. All response data flows through `host_emit_bytes`.

### 1.5 Register new exports in `build.zig`

**File:** `build.zig`

Add to the `export_symbol_names` array:

```zig
"ziggit_serve_upload_pack",
"ziggit_serve_receive_pack",
"ziggit_serve_ref_advertisement",
"ziggit_serve_v2_command",
```

### 1.6 Tests

**File:** `test/wasm_server_test.js` (new)

Node.js test that:
1. Loads `ziggit.wasm`
2. Implements the 11 host storage functions backed by an in-memory `Map`
3. Implements `host_emit_bytes` to collect output into a buffer
4. Seeds the storage with a commit, tree, and blob (manually constructed git objects)
5. Calls `ziggit_serve_ref_advertisement(0)` — verifies valid pkt-line output listing the seeded refs
6. Calls `ziggit_serve_upload_pack` with a crafted want request — verifies the emitted bytes contain a valid PACK header and the correct number of objects
7. Calls `ziggit_serve_receive_pack` with a pack containing a new commit — verifies objects were stored via `host_get_object`
8. Calls `ziggit_serve_v2_command` with an `ls-refs` command — verifies filtered ref output

**File:** `test/wasm_server_test.zig` (new)

Zig-level unit tests for `WasmGitServer` and `HostCallbackStorage` that mock the host imports at compile time (using `@import("builtin").is_test` to swap real extern calls with test stubs).

---

## Phase 2: `filter` Capability (Partial / Blobless Clone)

**Goal:** Support `--filter=blob:none`, `--filter=tree:0`, and `--filter=blob:limit=<n>` for both client (fetch/clone) and server (upload-pack). This is the key capability that ArtifactFS depends on — it runs `git clone --filter=blob:none` to get the tree structure without downloading blob content.

**Current state:** Neither the client (`smart_http.zig`) nor the server (`git_serve.zig`) support the `filter` capability. The server advertises `include-tag` in capabilities but doesn't parse or handle `filter` lines from clients.

### 2.1 Client-side filter support

**File:** `src/git/smart_http.zig`

Add filter spec parsing and transmission:

- Add a `filter` field to `ShallowCloneOptions` (or create a new `FetchOptions` struct):
  ```zig
  filter: ?[]const u8 = null, // e.g. "blob:none", "tree:0", "blob:limit=1024"
  ```

- In `buildUploadPackRequestWithOptions` (v1), after the `want` lines and before `done`, emit:
  ```
  filter blob:none\n
  ```
  Only when the server's capability advertisement includes `filter`.

- In `buildV2FetchRequestWithDeepenOptions` (v2), add `filter <spec>\n` as an argument in the `command=fetch` section.

- Advertise `filter` in the client's requested capabilities.

**File:** `src/cmd_clone.zig`

Wire `--filter=<spec>` CLI argument through to the fetch options:
```
ziggit clone --filter=blob:none https://github.com/user/repo.git
```

Parse the filter spec and pass it to the smart HTTP fetch functions.

**File:** `src/git/fetch_cmd.zig`

Wire `--filter=<spec>` for `ziggit fetch --filter=blob:none`.

### 2.2 Server-side filter support

**File:** `src/git/git_serve.zig`

In `handleUploadPack`, after parsing `want`/`have`/`deepen` lines, also parse:
```
filter blob:none
filter tree:<depth>
filter blob:limit=<bytes>
```

Store the parsed filter spec. Then in `generatePackData` / `walkReachable`, apply the filter:

- **`blob:none`**: When walking the commit graph and collecting objects, include commits and trees but **skip all blobs**. This means in `walkReachable`, when processing a tree entry, still recurse into subtrees but don't add blob entries to the object set. The pack will contain only commits, trees, and tags.

- **`blob:limit=<n>`**: Same as above but only skip blobs larger than `<n>` bytes. When encountering a blob in tree traversal, check its size before adding it. Objects with `size <= n` are included.

- **`tree:<depth>`**: Skip tree objects below the specified depth. At depth 0, only the root tree of each commit is included. At depth 1, one level of subtrees, etc.

**Implementation in `walkReachable`:**

Add a `FilterSpec` parameter:
```zig
const FilterSpec = union(enum) {
    none,
    blob_none,
    blob_limit: usize,
    tree_depth: u32,
};
```

In the tree-entry processing loop:
```zig
// Current code unconditionally adds all tree entries to worklist.
// With filter, conditionally skip:
const entry_mode = parseMode(mode_str);
if (filter == .blob_none and entry_mode.is_blob) continue; // skip blob
if (filter == .blob_limit) |limit| {
    if (entry_mode.is_blob) {
        const blob_size = self.getObjectSize(git_dir, &entry_hex) catch continue;
        if (blob_size > limit) continue; // skip large blob
    }
}
if (filter == .tree_depth) |max_depth| {
    if (entry_mode.is_tree and current_depth >= max_depth) continue;
}
```

Add `filter` to the capability advertisement string. Currently the server advertises:
```
multi_ack thin-pack side-band side-band-64k ofs-delta shallow ...
```
Add `filter` to this list.

### 2.3 WASM server filter support

**File:** `src/git/wasm_git_serve.zig`

Mirror the same filter handling from 2.2 in the WASM server. When `host_get_object` is called during pack generation, the filter spec determines whether to include or skip the object.

### 2.4 Tests

**File:** `test/filter_clone_test.sh` (new)

```bash
# Start ziggit server with a repo containing commits, trees, and blobs
ziggit serve --port=9999 --repo=/tmp/test-filter-repo &

# Standard git client: blobless clone
git clone --filter=blob:none http://localhost:9999/test-filter-repo /tmp/blobless
# Verify: tree structure is present, blobs are missing
test -d /tmp/blobless/.git
git -C /tmp/blobless ls-tree -r HEAD  # should list files
git -C /tmp/blobless cat-file -t HEAD  # should work (commit present)
# Blobs should be fetchable on demand (git will fault them in)

# ziggit client: blobless clone
ziggit clone --filter=blob:none http://localhost:9999/test-filter-repo /tmp/blobless-ziggit
```

**File:** `test/filter_test.zig` (new)

Unit tests for `FilterSpec` parsing and the filtered `walkReachable`:
- `blob:none` on a repo with 10 blobs, 3 trees, 2 commits → pack contains 5 objects (no blobs)
- `blob:limit=100` with blobs of varying sizes → only small blobs included
- `tree:0` → only root trees + commits + tags
- No filter → all objects included (regression test)

---

## Phase 3: `include-tag` Capability

**Goal:** When the server sends a pack during fetch, automatically include tag objects that point to objects being sent, without the client needing to explicitly request them.

**Current state:** The server advertises `include-tag` in its capability string but does **not implement it** — tag objects are only sent if the client explicitly `want`s them or they're reachable from a wanted ref. This means a `git clone` may not receive tag objects even though the tags were advertised.

### 3.1 Server-side implementation

**File:** `src/git/git_serve.zig`

In `handleUploadPack`, after computing the set of objects to include in the pack and before calling `buildPackFromObjects`:

1. Check if the client's capability request includes `include-tag` (parse from the first `want` line's trailing capabilities).
2. If yes, scan all tag refs (`refs/tags/*`):
   - For each tag ref, load the tag object.
   - If it's an annotated tag (object type `tag`), check if the tag's target object is in the pack's object set.
   - If the target is being sent, add the tag object itself to the pack as well.
3. This ensures annotated tags "piggyback" on fetches without the client needing to know about them.

```zig
// After building want_list in generatePackData:
if (client_wants_include_tag) {
    const tag_refs = try self.collectTagRefs(git_dir);
    defer { /* free tag_refs */ }
    for (tag_refs) |tag_ref| {
        const tag_obj = objects.GitObject.load(tag_ref.hash, git_dir, ...) catch continue;
        if (tag_obj.type == .tag) {
            // Parse "object <hex>\n" from tag data to get target
            const target_hash = parseTagTarget(tag_obj.data) orelse continue;
            if (want_set.contains(target_hash)) {
                // Target is being sent — include the tag object too
                if (!want_set.contains(tag_ref.hash)) {
                    try want_set.put(try self.allocator.dupe(u8, tag_ref.hash), {});
                    try want_list.append(try self.allocator.dupe(u8, tag_ref.hash));
                }
            }
        }
    }
}
```

### 3.2 Client-side handling

**File:** `src/git/smart_http.zig`

- Add `include-tag` to the client's requested capabilities when sending `want` lines (it's already in the server advertisement — the client needs to echo it back to opt in).
- After receiving the pack, check for any tag objects that arrived. For each, if it points to a commit that corresponds to a ref, update `refs/tags/<name>` to point at the tag object.

### 3.3 WASM server implementation

**File:** `src/git/wasm_git_serve.zig`

Mirror the same `include-tag` logic from 3.1. When building the pack for a WASM-served fetch, scan tag refs in `HostCallbackStorage` and include relevant tag objects.

### 3.4 Tests

**File:** `test/include_tag_test.sh` (new)

```bash
# Create a repo with annotated tags
cd /tmp/test-include-tag
git init && git commit --allow-empty -m "first"
git tag -a v1.0 -m "release 1.0"
git commit --allow-empty -m "second"

# Serve with ziggit
ziggit serve --port=9998 --repo=/tmp/test-include-tag &

# Clone with standard git (should receive the tag automatically)
git clone http://localhost:9998/test-include-tag /tmp/clone-tags
git -C /tmp/clone-tags tag -l  # should list v1.0
git -C /tmp/clone-tags cat-file -t v1.0  # should be "tag" (annotated)

# Fetch into existing clone after new tag
cd /tmp/test-include-tag && git tag -a v2.0 -m "release 2.0"
git -C /tmp/clone-tags fetch
git -C /tmp/clone-tags tag -l  # should list v1.0 and v2.0
```

---

## Phase 4: ArtifactFS Integration Testing

**Goal:** Validate that ziggit's git server (both native and WASM) works correctly as the backend for Cloudflare's [ArtifactFS](https://github.com/cloudflare/artifact-fs) FUSE driver. ArtifactFS uses `git clone --filter=blob:none` (blobless clone) and then hydrates blobs on demand via `git cat-file --batch`, so the filter capability from Phase 2 is a prerequisite.

**Current state:** ArtifactFS is a Go program that uses standard git CLI commands (`git clone`, `git ls-tree`, `git cat-file --batch`, `git fetch`) against any git remote. It does **not** require a specific server implementation, but it does require:
- `--filter=blob:none` support (Phase 2)
- Standard smart HTTP protocol
- `git cat-file --batch` to work on the resulting repo (this is a client-side operation, not server-side)

### 4.1 Clone ArtifactFS and set up test environment

```bash
git clone https://github.com/cloudflare/artifact-fs.git test/artifact-fs
cd test/artifact-fs
go build -o artifact-fs github.com/cloudflare/artifact-fs/cmd/artifact-fs
```

### 4.2 End-to-end test: ziggit serve + ArtifactFS

**File:** `test/artifactfs_integration_test.sh` (new)

This test validates the full pipeline: ziggit serves a repo, ArtifactFS mounts it via FUSE with blobless clone, and file reads trigger on-demand blob hydration.

```bash
#!/bin/bash
set -euo pipefail

# Prerequisites: ziggit built, artifact-fs built, FUSE available

# Step 1: Create a test repo with known content
TEST_REPO=/tmp/artifactfs-test-repo
rm -rf "$TEST_REPO"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init --bare

# Populate via a temp working copy
WORK=/tmp/artifactfs-test-work
rm -rf "$WORK"
git clone "$TEST_REPO" "$WORK"
cd "$WORK"
echo "hello world" > README.md
echo '{"name": "test", "version": "1.0.0"}' > package.json
mkdir -p src
echo 'console.log("hello")' > src/index.js
dd if=/dev/urandom of=large-binary.bin bs=1024 count=512  # 512KB binary
git add -A
git commit -m "initial commit"
git push origin main

# Step 2: Start ziggit server
ziggit serve --port=9997 --repo="$TEST_REPO" &
ZIGGIT_PID=$!
sleep 1

# Step 3: Register repo with ArtifactFS
export ARTIFACT_FS_ROOT=/tmp/artifactfs-root
rm -rf "$ARTIFACT_FS_ROOT"

MOUNT_DIR=/tmp/artifactfs-mount
rm -rf "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"

./test/artifact-fs/artifact-fs add-repo \
  --name test-repo \
  --remote http://localhost:9997/artifactfs-test-repo \
  --branch main \
  --mount-root "$MOUNT_DIR"

# Step 4: Start ArtifactFS daemon
./test/artifact-fs/artifact-fs daemon --root "$MOUNT_DIR" &
AFS_PID=$!
sleep 3  # wait for mount + initial tree indexing

# Step 5: Validate
# Tree should be visible immediately (blobless clone fetched tree structure)
ls "$MOUNT_DIR/test-repo/"
test -f "$MOUNT_DIR/test-repo/README.md"
test -f "$MOUNT_DIR/test-repo/package.json"
test -f "$MOUNT_DIR/test-repo/src/index.js"

# Reading a file triggers on-demand hydration
CONTENT=$(cat "$MOUNT_DIR/test-repo/README.md")
test "$CONTENT" = "hello world"

# package.json should be prioritized for hydration
PACKAGE=$(cat "$MOUNT_DIR/test-repo/package.json")
echo "$PACKAGE" | grep '"name"'

# Git operations should work inside the mount
git -C "$MOUNT_DIR/test-repo" log --oneline
git -C "$MOUNT_DIR/test-repo" rev-parse HEAD
git -C "$MOUNT_DIR/test-repo" status

# Step 6: Test push from mount (if ArtifactFS supports writes)
cd "$MOUNT_DIR/test-repo"
echo "new file" > new.txt
git add new.txt
git commit -m "add new file"
git push origin main

# Verify push arrived at the server
cd "$WORK"
git pull
test -f new.txt

# Cleanup
kill $AFS_PID 2>/dev/null || true
kill $ZIGGIT_PID 2>/dev/null || true
fusermount -u "$MOUNT_DIR/test-repo" 2>/dev/null || umount "$MOUNT_DIR/test-repo" 2>/dev/null || true
```

### 4.3 Test: ziggit as both client and server with ArtifactFS

**File:** `test/artifactfs_ziggit_client_test.sh` (new)

Test using `ziggit` instead of `git` as the client for ArtifactFS operations. This validates that ziggit's `--filter=blob:none` client-side implementation produces a repo structure that ArtifactFS can work with.

```bash
# Use ziggit for the blobless clone step
ziggit clone --filter=blob:none http://localhost:9997/repo /tmp/blobless-repo

# Verify repo structure: trees present, blobs missing
ziggit -C /tmp/blobless-repo ls-tree -r HEAD  # should list entries
# Individual blob reads should fault in from the server
ziggit -C /tmp/blobless-repo cat-file blob <hash>  # triggers fetch from server
```

### 4.4 ArtifactFS compatibility test matrix

Run ArtifactFS's own end-to-end tests against a ziggit-served repo:

```bash
cd test/artifact-fs

# Run ArtifactFS e2e tests against ziggit server
AFS_RUN_E2E_TESTS=1 \
  AFS_E2E_REPO=http://localhost:9997/test-repo \
  go test -v -run TestE2E -count=1 -timeout 10m .
```

This validates that ziggit's smart HTTP server + filter support is compatible with ArtifactFS's expectations for:
- Blobless clone (`--filter=blob:none`)
- `git ls-tree -r -t -z HEAD` on the resulting repo
- `git cat-file --batch` for on-demand blob hydration
- `git fetch` for background refresh
- `git push` for writes

### 4.5 CI integration

**File:** `.github/workflows/test-artifactfs.yml` (new)

```yaml
name: ArtifactFS Integration
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.2
      - uses: actions/setup-go@v5
        with:
          go-version: '1.24'
      - name: Install FUSE
        run: sudo apt-get install -y fuse3 libfuse3-dev
      - name: Build ziggit
        run: zig build -Doptimize=ReleaseFast
      - name: Build ArtifactFS
        run: |
          git clone https://github.com/cloudflare/artifact-fs.git /tmp/artifact-fs
          cd /tmp/artifact-fs
          go build -o /usr/local/bin/artifact-fs ./cmd/artifact-fs
      - name: Run integration tests
        run: bash test/artifactfs_integration_test.sh
```

---

## Dependency Graph

```
Phase 1 (WASM Server Exports)
    ↓
Phase 2 (filter capability) ← can partially parallel with Phase 1
    ↓
Phase 3 (include-tag) ← can parallel with Phase 2
    ↓
Phase 4 (ArtifactFS Integration) ← requires Phase 2 (filter), benefits from Phase 1
```

Phase 1 and Phase 2 can be developed in parallel since they touch different parts of the codebase. Phase 4 requires Phase 2's filter support to be complete. Phase 3 is independent and can be done at any time.

## Estimated Work

| Phase | New Zig code | New test code | Files created | Files modified |
|-------|-------------|--------------|---------------|----------------|
| 1 (WASM Server) | ~800-1000 lines | ~300 lines JS + ~200 lines Zig | 3 new (`host_callback_storage.zig`, `wasm_git_serve.zig`, `wasm_server_test.js`) | 2 modified (`wasm_exports.zig`, `build.zig`) |
| 2 (filter) | ~200-300 lines | ~200 lines | 2 new (`filter_clone_test.sh`, `filter_test.zig`) | 3 modified (`smart_http.zig`, `git_serve.zig`, `cmd_clone.zig`) |
| 3 (include-tag) | ~100-150 lines | ~100 lines | 1 new (`include_tag_test.sh`) | 2 modified (`git_serve.zig`, `smart_http.zig`) |
| 4 (ArtifactFS) | ~0 lines | ~200 lines shell | 3 new (test scripts + CI) | 0 |

**Total: ~1100-1450 lines of Zig, ~300 lines JS, ~500 lines shell tests**

## Files Summary

### New files:
- `src/git/host_callback_storage.zig` — WASM host-callback storage backend
- `src/git/wasm_git_serve.zig` — WASM-specific git server protocol handler
- `test/wasm_server_test.js` — Node.js WASM server integration tests
- `test/wasm_server_test.zig` — Zig WASM server unit tests
- `test/filter_clone_test.sh` — partial clone integration tests
- `test/filter_test.zig` — filter capability unit tests
- `test/include_tag_test.sh` — include-tag integration tests
- `test/artifactfs_integration_test.sh` — ArtifactFS end-to-end tests
- `test/artifactfs_ziggit_client_test.sh` — ziggit + ArtifactFS client tests
- `.github/workflows/test-artifactfs.yml` — CI for ArtifactFS integration

### Modified files:
- `src/wasm_exports.zig` — add host imports + server exports
- `build.zig` — register new WASM export symbols
- `src/git/smart_http.zig` — client-side `filter` + `include-tag` capability
- `src/git/git_serve.zig` — server-side `filter` + `include-tag` implementation
- `src/cmd_clone.zig` — `--filter=<spec>` CLI argument
- `src/git/fetch_cmd.zig` — `--filter=<spec>` for fetch
