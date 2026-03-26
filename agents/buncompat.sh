#!/bin/bash
swapon /swapfile 2>/dev/null || true
export NODE_OPTIONS="--max-old-space-size=256"
export PATH="/usr/local/zig:/usr/local/bin:/usr/bin:/bin:$PATH"
cd /root/ziggit || exit 1

GOAL='You are working on ziggit, a version control system in Zig at /root/ziggit (repo: https://github.com/hdresearch/ziggit.git).

THE VISION: Bun (oven-sh/bun) currently shells out to the git CLI for version control operations. We want bun to instead import ziggit as a Zig package and call Zig functions directly — no process spawning, no C FFI, no git CLI dependency. Pure Zig calling pure Zig. The Zig compiler will optimize the whole thing as one compilation unit.

CRITICAL RULES:
- Do NOT write markdown files, reports, or verification docs. Only .zig code and build files.
- Run "zig build" after EVERY change. If it fails, fix it before moving on.
- Commit and push after each completed item.
- If rebase conflicts: git rebase --abort && git reset --hard origin/master, redo work.
- IMPORTANT: Another agent is adding a git CLI fallback to main_common.zig that forwards unknown commands to the git binary. This fallback DOES NOT COUNT as implementing anything. Your job is the LIBRARY API in src/ziggit.zig — pure Zig functions that work WITHOUT git installed. If a function calls std.process.Child, spawns "git", or uses runGitCommand(), it is NOT done. Every function you write must work on a machine with ZERO git installation. Test this by verifying your code never imports std.process.Child or calls any external process.

YOUR TASK LIST (in order):

ITEM 1: Create build.zig.zon for Zig package manager.
Create a build.zig.zon file so ziggit can be imported as a Zig dependency:
```
.{
    .name = "ziggit",
    .version = "0.3.0",
    .paths = .{ "src/", "build.zig", "build.zig.zon" },
}
```

ITEM 2: Create a clean Zig-native API module at src/ziggit.zig.
This is the public API that bun would import. NOT the C export API — a proper Zig API with Zig types.
It should re-export the useful internals:

```zig
// src/ziggit.zig - Public Zig API
const std = @import("std");

pub const Repository = struct {
    path: []const u8,
    git_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Repository { ... }
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Repository { ... }
    pub fn close(self: *Repository) void { ... }

    // Read operations (pure Zig, no git dependency)
    pub fn revParseHead(self: *const Repository) ![40]u8 { ... }
    pub fn statusPorcelain(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 { ... }
    pub fn isClean(self: *const Repository) !bool { ... }
    pub fn describeTags(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 { ... }
    pub fn findCommit(self: *const Repository, committish: []const u8) ![40]u8 { ... }
    pub fn latestTag(self: *const Repository, allocator: std.mem.Allocator) ![]const u8 { ... }
    pub fn branchList(self: *const Repository, allocator: std.mem.Allocator) ![][]const u8 { ... }

    // Write operations (MUST be pure Zig - no shelling out to git)
    pub fn add(self: *Repository, path: []const u8) !void { ... }
    pub fn commit(self: *Repository, message: []const u8, author_name: []const u8, author_email: []const u8) ![40]u8 { ... }
    pub fn createTag(self: *Repository, name: []const u8, message: ?[]const u8) !void { ... }
};
```

The implementations should call the existing code in src/git/objects.zig, src/git/refs.zig, src/git/index.zig, src/lib/index_parser.zig, src/lib/objects_parser.zig.

For the read operations, the existing code in src/lib/ziggit.zig already has working implementations — extract and adapt them to return Zig types instead of writing to C buffers.

ITEM 3: Implement native git add (no shelling out).
In the Repository.add() function, implement:
1. Read the file at the given path
2. Compute SHA-1 of "blob <size>\0<content>" (git blob format)
3. Zlib-compress the full "blob <size>\0<content>" string
4. Write to .git/objects/<first-2-hex>/<remaining-38-hex>
5. Update .git/index: read existing index, add/update entry with new SHA-1 + stat info, write index back

The index writing is the hard part. Look at src/lib/index_parser.zig for the read side — writing is the reverse:
- Write "DIRC" magic + version(2) + entry_count
- For each entry: write ctime, mtime, dev, ino, mode, uid, gid, size, sha1, flags(name_len), name, padding to 8-byte boundary
- Write SHA-1 checksum of everything written

ITEM 4: Implement native git commit (no shelling out).
In Repository.commit():
1. Read the current index (.git/index)
2. Build a tree object from the index entries:
   - Sort entries by name
   - For each entry: "<mode> <name>\0<20-byte-sha1>"
   - Wrap in "tree <size>\0<content>", SHA-1 hash it, zlib compress, write to objects
3. Build the commit object:
   - "tree <tree-hash>\nparent <parent-hash>\nauthor <name> <email> <timestamp> +0000\ncommitter <name> <email> <timestamp> +0000\n\n<message>\n"
   - Wrap in "commit <size>\0<content>", SHA-1 hash, compress, write to objects
4. Update .git/refs/heads/<branch> with the new commit hash
5. Return the new commit hash

ITEM 5: Expose the module in build.zig.
Add to build.zig so external projects can use ziggit as a module:
```zig
// Add this after the existing build targets
const ziggit_module = b.addModule("ziggit", .{
    .root_source_file = b.path("src/ziggit.zig"),
});
// Also expose it for the library
lib_static.root_module.addImport("ziggit", ziggit_module);
```

ITEM 6: Write a Zig test that simulates bun'"'"'s exact workflow using the Zig API.
Create test/bun_zig_api_test.zig:
```zig
const ziggit = @import("../src/ziggit.zig");

test "bun workflow - pure Zig, no git CLI" {
    // 1. init repo
    var repo = try ziggit.Repository.init(allocator, "/tmp/zig_api_test");
    defer repo.close();

    // 2. create a file, add it, commit
    // write file to disk
    try repo.add("package.json");
    const hash = try repo.commit("Initial commit", "test", "test@test.com");

    // 3. read operations bun uses
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(&hash, &head);

    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", status); // clean

    // 4. create tag
    try repo.createTag("v1.0.0", "v1.0.0");
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
    try std.testing.expectEqualStrings("v1.0.0", tag);

    // 5. verify git can read what we wrote
    // (run git log --oneline in the test dir and check output)
}
```

Register this test in build.zig under the test step.

ITEM 7: Write a benchmark comparing direct Zig calls vs git CLI spawning.
Create benchmarks/zig_api_bench.zig that:
1. Creates a repo with 100 files using the Zig API (no git CLI)
2. Times 1000 iterations of each operation:
   - repo.revParseHead() vs spawning "git rev-parse HEAD"
   - repo.statusPorcelain() vs spawning "git status --porcelain"
   - repo.describeTags() vs spawning "git describe --tags --abbrev=0"
   - repo.isClean() vs spawning "git status --porcelain" and checking empty
3. Reports actual measured times. Do NOT fabricate numbers.
This benchmark proves the point: direct Zig function calls eliminate process spawn overhead entirely.

ITEM 8: Implement native checkout (no shelling out).
Repository.checkout(ref: []const u8) should:
1. Resolve ref to commit hash (handle branch names, tag names, raw hashes)
2. Read the commit object to get tree hash
3. Read the tree object recursively
4. For each blob in the tree: decompress object, write file content to working directory
5. Update .git/HEAD (for detached HEAD) or the branch ref
6. Update .git/index to match the checked-out tree
This is bun'"'"'s "git -C <dir> checkout --quiet <ref>" call.

ITEM 9: Implement native fetch for local repos (no shelling out).
Repository.fetch(remote_path: []const u8) should handle LOCAL repositories:
1. Read the remote'"'"'s refs (refs/heads/*, refs/tags/*)
2. Copy any objects from the remote'"'"'s .git/objects/ that we don'"'"'t have
3. Update our .git/refs/remotes/origin/* to match
For network URLs (http://, git://, ssh://), it is OK to return an error or fall back for now.
Bun clones bare repos locally then fetches from them — so local fetch covers the main use case.

ITEM 10: Implement native clone for local repos (no shelling out).
Repository.cloneBare(source: []const u8, target: []const u8) and
Repository.cloneNoCheckout(source: []const u8, target: []const u8) should:
1. Create the target .git directory structure
2. Copy all objects from source (or hardlink them)
3. Copy all refs
4. Set up remote config pointing back to source
For cloneBare: the target IS the git dir (no working tree).
For cloneNoCheckout: create .git/ inside target, copy objects+refs, don'"'"'t populate working tree.

THESE ITEMS (8-10) MAKE BUN FULLY GIT-CLI-FREE FOR LOCAL OPERATIONS.
For network clone/fetch (https:// URLs), bun already caches bare repos locally, so local clone+fetch covers the critical path.

After all 10 items, commit and push everything. Then continue optimizing — there is always more performance to extract.

IMPORTANT: The key insight is that bun is written in Zig. If ziggit is a Zig package, bun can @import it and call functions directly. No CLI parsing, no process spawning, no C FFI boundary, no git dependency. The Zig compiler optimizes it all as one binary. This is fundamentally faster than both libgit2 (C library with FFI overhead) and git CLI (process spawn + pipe + parse overhead).'

while true; do
    echo "$(date): Starting pi agent run..." >> /root/agent.log
    pi -p "$GOAL" --model anthropic/claude-sonnet-4-20250514 --no-session >> /root/agent.log 2>&1
    EXIT=$?
    echo "$(date): Agent run completed (exit=$EXIT)" >> /root/agent.log
    cd /root/ziggit
    git pull --rebase origin master 2>> /root/agent.log || { git rebase --abort 2>/dev/null; git reset --hard origin/master; }
    if [ -n "$(git status --porcelain)" ]; then
        git add -A && git commit -m "agent: auto-commit zig package API work" 2>> /root/agent.log || true
        git push origin master 2>> /root/agent.log || true
    fi
    sleep 10
done
