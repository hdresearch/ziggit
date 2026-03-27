const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");
const smart_http = @import("smart_http");

/// Result of a clone operation
pub const CloneResult = struct {
    git_dir: []u8,
    pack_checksum: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CloneResult) void {
        self.allocator.free(self.git_dir);
        self.allocator.free(self.pack_checksum);
    }
};

/// Clone a remote repository using smart HTTP protocol (bare).
/// Creates the repo structure, downloads pack, generates idx, and updates refs.
pub fn cloneBareSmart(allocator: std.mem.Allocator, url: []const u8, target_dir: []const u8) !CloneResult {
    // 1. Create bare repo structure
    try std.fs.cwd().makePath(target_dir);
    const git_dir = try allocator.dupe(u8, target_dir);
    errdefer allocator.free(git_dir);

    try createBareStructure(git_dir);

    // 2. Discover refs and download pack
    var clone_result = try smart_http.clonePack(allocator, url);
    defer clone_result.deinit();

    // 3. Save pack to disk (skip if empty/too small - e.g., empty repo)
    var checksum: []u8 = undefined;
    if (clone_result.pack_data.len >= 32) {
        checksum = try pack_writer.savePackFast(allocator, git_dir, clone_result.pack_data);
        errdefer allocator.free(checksum);

        // 4. Generate idx
        const pp = try pack_writer.packPath(allocator, git_dir, checksum);
        defer allocator.free(pp);
        try idx_writer.generateIdx(allocator, pp);
    } else {
        checksum = try allocator.dupe(u8, "0000000000000000000000000000000000000000");
    }
    errdefer allocator.free(checksum);

    // 5. Update refs (bare mode)
    var ref_updates = std.array_list.Managed(pack_writer.RefUpdate).init(allocator);
    defer ref_updates.deinit();
    for (clone_result.refs) |ref| {
        try ref_updates.append(.{
            .name = ref.name,
            .hash = &ref.hash,
        });
    }
    try pack_writer.updateRefsAfterClone(allocator, git_dir, ref_updates.items, true);

    return .{
        .git_dir = git_dir,
        .pack_checksum = checksum,
        .allocator = allocator,
    };
}

/// Clone a remote repository using smart HTTP protocol (non-bare).
/// Creates .git inside target_dir.
pub fn cloneSmart(allocator: std.mem.Allocator, url: []const u8, target_dir: []const u8) !CloneResult {
    // 1. Create repo structure
    try std.fs.cwd().makePath(target_dir);
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{target_dir});
    errdefer allocator.free(git_dir);

    try createBareStructure(git_dir);

    // Write config with remote origin
    try writeRemoteConfig(allocator, git_dir, url);

    // 2. Discover refs and download pack
    var clone_result = try smart_http.clonePack(allocator, url);
    defer clone_result.deinit();

    // 3. Save pack (skip if empty/too small - e.g., empty repo)
    var checksum: []u8 = undefined;
    if (clone_result.pack_data.len >= 32) {
        checksum = try pack_writer.savePackFast(allocator, git_dir, clone_result.pack_data);
        errdefer allocator.free(checksum);

        // 4. Generate idx
        const pp = try pack_writer.packPath(allocator, git_dir, checksum);
        defer allocator.free(pp);
        try idx_writer.generateIdx(allocator, pp);
    } else {
        checksum = try allocator.dupe(u8, "0000000000000000000000000000000000000000");
    }
    errdefer allocator.free(checksum);

    // 5. Update refs (non-bare: branches go to remotes/origin/)
    var ref_updates = std.array_list.Managed(pack_writer.RefUpdate).init(allocator);
    defer ref_updates.deinit();
    for (clone_result.refs) |ref| {
        try ref_updates.append(.{
            .name = ref.name,
            .hash = &ref.hash,
        });
    }
    try pack_writer.updateRefsAfterClone(allocator, git_dir, ref_updates.items, false);

    return .{
        .git_dir = git_dir,
        .pack_checksum = checksum,
        .allocator = allocator,
    };
}

/// Fetch new objects from a remote repository using smart HTTP protocol.
/// Updates refs/remotes/origin/* and writes FETCH_HEAD.
pub fn fetchSmart(allocator: std.mem.Allocator, url: []const u8, git_dir: []const u8) !?[]u8 {
    // 1. Build list of local refs
    var local_refs = std.array_list.Managed(smart_http.LocalRef).init(allocator);
    defer local_refs.deinit();

    // Read refs/remotes/origin/* to get local state
    const remote_refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
    defer allocator.free(remote_refs_dir);

    if (std.fs.cwd().openDir(remote_refs_dir, .{ .iterate = true })) |*dir| {
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_refs_dir, entry.name });
                defer allocator.free(ref_path);
                const content = try std.fs.cwd().readFileAlloc(allocator, ref_path, 256);
                defer allocator.free(content);
                const hash_str = std.mem.trimRight(u8, content, "\n\r ");
                if (hash_str.len == 40) {
                    var oid: smart_http.Oid = undefined;
                    @memcpy(&oid, hash_str[0..40]);
                    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                    defer allocator.free(ref_name);
                    try local_refs.append(.{
                        .hash = oid,
                        .name = ref_name,
                    });
                }
            }
        }
    } else |_| {
        // No remote refs yet - that's fine, we'll fetch everything
    }

    // 2. Negotiate and fetch pack
    var fetch_result = try smart_http.fetchNewPack(allocator, url, local_refs.items) orelse return null;
    defer fetch_result.deinit();

    // 3. Save pack (skip if too small)
    if (fetch_result.pack_data.len < 32) return null;

    const checksum = try pack_writer.savePackFast(allocator, git_dir, fetch_result.pack_data);
    errdefer allocator.free(checksum);

    // 4. Generate idx
    const pp = try pack_writer.packPath(allocator, git_dir, checksum);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // 5. Update remote refs
    var ref_updates = std.array_list.Managed(pack_writer.RefUpdate).init(allocator);
    defer ref_updates.deinit();
    for (fetch_result.refs) |ref| {
        try ref_updates.append(.{
            .name = ref.name,
            .hash = &ref.hash,
        });
    }
    try pack_writer.updateRefsAfterFetch(allocator, git_dir, ref_updates.items);

    return checksum;
}

// ============================================================================
// Helpers
// ============================================================================

pub fn createBareStructure(git_dir: []const u8) !void {
    const allocator = std.heap.page_allocator;

    const dirs = [_][]const u8{
        "",
        "/objects",
        "/objects/pack",
        "/refs",
        "/refs/heads",
        "/refs/tags",
        "/refs/remotes",
        "/refs/remotes/origin",
    };

    for (dirs) |suffix| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ git_dir, suffix });
        defer allocator.free(path);
        std.fs.cwd().makePath(path) catch {};
    }

    // Write default HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const file = try std.fs.cwd().createFile(head_path, .{});
    defer file.close();
    try file.writeAll("ref: refs/heads/main\n");
}

pub fn writeRemoteConfig(allocator: std.mem.Allocator, git_dir: []const u8, url: []const u8) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);

    const config_content = try std.fmt.allocPrint(allocator,
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\[remote "origin"]
        \\    url = {s}
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    , .{url});
    defer allocator.free(config_content);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(config_content);
}
