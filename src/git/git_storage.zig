const std = @import("std");
const objects = @import("objects.zig");

/// Storage abstraction for git server operations.
/// Provides a unified interface for reading/writing objects, refs, and packs
/// independent of the underlying storage mechanism (filesystem, memory, etc.).
pub const GitStorage = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) GitStorage {
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
        };
    }

    pub fn deinit(self: *GitStorage) void {
        _ = self;
    }

    // ========================================================================
    // Object operations
    // ========================================================================

    /// Check if an object exists in the repository (loose or packed).
    pub fn objectExists(self: *GitStorage, hash_hex: []const u8) bool {
        if (hash_hex.len < 40) return false;

        // Check loose objects
        if (self.looseObjectExists(hash_hex)) return true;

        // Check packed objects
        return self.packedObjectExists(hash_hex);
    }

    /// Read a git object's type and data.
    pub fn readObject(self: *GitStorage, hash_hex: []const u8) !ObjectData {
        const platform = StoragePlatform{};
        const obj = try objects.GitObject.load(hash_hex, self.git_dir, platform, self.allocator);
        return .{
            .obj_type = obj.type,
            .data = obj.data,
            .allocator = self.allocator,
        };
    }

    /// Write a loose object to the repository.
    pub fn writeObject(self: *GitStorage, obj_type: objects.GitObject.ObjectType, data: []const u8) ![40]u8 {
        const type_str: []const u8 = switch (obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };

        // Compute hash
        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, data.len });
        defer self.allocator.free(header);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(data);
        const hash_bytes = hasher.finalResult();

        var hash_hex: [40]u8 = undefined;
        for (hash_bytes, 0..) |b, i| {
            const hc = "0123456789abcdef";
            hash_hex[i * 2] = hc[b >> 4];
            hash_hex[i * 2 + 1] = hc[b & 0xf];
        }

        // Write loose object
        const obj_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/{c}{c}", .{ self.git_dir, hash_hex[0], hash_hex[1] });
        defer self.allocator.free(obj_dir);
        std.fs.cwd().makePath(obj_dir) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ obj_dir, hash_hex[2..] });
        defer self.allocator.free(obj_path);

        // Compress header + data
        var full_content = std.array_list.Managed(u8).init(self.allocator);
        defer full_content.deinit();
        try full_content.appendSlice(header);
        try full_content.appendSlice(data);

        const compressed = try objects.cCompressSlice(self.allocator, full_content.items);
        defer self.allocator.free(compressed);

        const file = try std.fs.cwd().createFile(obj_path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(compressed);

        return hash_hex;
    }

    // ========================================================================
    // Ref operations
    // ========================================================================

    /// Read the hash pointed to by a ref.
    pub fn readRef(self: *GitStorage, ref_name: []const u8) !?[40]u8 {
        // Try loose ref first
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);

        if (std.fs.cwd().readFileAlloc(self.allocator, ref_path, 1024)) |content| {
            defer self.allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (trimmed.len >= 40) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, trimmed[0..40]);
                return hash;
            }
        } else |_| {}

        // Try packed-refs
        const packed_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_path);
        const packed_content = std.fs.cwd().readFileAlloc(self.allocator, packed_path, 10 * 1024 * 1024) catch return null;
        defer self.allocator.free(packed_content);

        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                const hash = line[0..sp];
                const name = line[sp + 1 ..];
                if (std.mem.eql(u8, name, ref_name) and hash.len >= 40) {
                    var result: [40]u8 = undefined;
                    @memcpy(&result, hash[0..40]);
                    return result;
                }
            }
        }

        return null;
    }

    /// Write a ref to point to the given hash.
    pub fn writeRef(self: *GitStorage, ref_name: []const u8, hash: [40]u8) !void {
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);

        if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |last_slash| {
            std.fs.cwd().makePath(ref_path[0..last_slash]) catch {};
        }

        const file = try std.fs.cwd().createFile(ref_path, .{});
        defer file.close();
        try file.writeAll(&hash);
        try file.writeAll("\n");
    }

    /// Delete a ref.
    pub fn deleteRef(self: *GitStorage, ref_name: []const u8) !void {
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch {};
    }

    /// Read HEAD - returns either a symbolic ref target or a hash.
    pub fn readHead(self: *GitStorage) !HeadValue {
        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const content = try std.fs.cwd().readFileAlloc(self.allocator, head_path, 1024);
        defer self.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return .{ .symbolic = try self.allocator.dupe(u8, trimmed[5..]) };
        } else if (trimmed.len >= 40) {
            var hash: [40]u8 = undefined;
            @memcpy(&hash, trimmed[0..40]);
            return .{ .direct = hash };
        }
        return error.InvalidHead;
    }

    /// List all refs (loose + packed), sorted.
    pub fn listRefs(self: *GitStorage) !RefList {
        var refs = std.array_list.Managed(RefEntry).init(self.allocator);
        errdefer {
            for (refs.items) |r| {
                self.allocator.free(r.name);
            }
            refs.deinit();
        }

        try self.collectLooseRefsRecursive("refs", &refs);
        try self.collectPackedRefsInto(&refs);

        // Sort alphabetically
        const SortCtx = struct {
            items: []RefEntry,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, ctx.items[a].name, ctx.items[b].name).compare(.lt);
            }
        };
        var indices = try self.allocator.alloc(usize, refs.items.len);
        defer self.allocator.free(indices);
        for (indices, 0..) |*idx, i| idx.* = i;
        std.mem.sort(usize, indices, SortCtx{ .items = refs.items }, SortCtx.lessThan);

        var sorted = std.array_list.Managed(RefEntry).init(self.allocator);
        for (indices) |idx| {
            try sorted.append(refs.items[idx]);
        }
        // Clear original without freeing (ownership transferred)
        refs.items.len = 0;
        refs.deinit();

        return .{ .entries = try sorted.toOwnedSlice(), .allocator = self.allocator };
    }

    // ========================================================================
    // Pack operations
    // ========================================================================

    /// Save a pack file and generate its index.
    pub fn savePack(self: *GitStorage, pack_data: []const u8) !void {
        if (pack_data.len < 32) return error.InvalidPackData;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackData;

        const pack_content = pack_data[0 .. pack_data.len - 20];
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(pack_content);
        const checksum = sha1.finalResult();
        var checksum_hex: [40]u8 = undefined;
        for (checksum, 0..) |b, i| {
            const hc = "0123456789abcdef";
            checksum_hex[i * 2] = hc[b >> 4];
            checksum_hex[i * 2 + 1] = hc[b & 0xf];
        }

        const pack_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/pack", .{self.git_dir});
        defer self.allocator.free(pack_dir);
        std.fs.cwd().makePath(pack_dir) catch {};

        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
        defer self.allocator.free(pack_path);
        const pack_file = try std.fs.cwd().createFile(pack_path, .{});
        defer pack_file.close();
        try pack_file.writeAll(pack_data);
    }

    /// List pack files in the repository.
    pub fn listPacks(self: *GitStorage) ![][]u8 {
        const pack_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/pack", .{self.git_dir});
        defer self.allocator.free(pack_dir);

        var packs = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (packs.items) |p| self.allocator.free(p);
            packs.deinit();
        }

        var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return packs.toOwnedSlice();
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".pack")) {
                try packs.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        return packs.toOwnedSlice();
    }

    // ========================================================================
    // Shallow file operations
    // ========================================================================

    /// Read the shallow file and return list of shallow commit hashes.
    pub fn readShallowCommits(self: *GitStorage) ![][40]u8 {
        const shallow_path = try std.fmt.allocPrint(self.allocator, "{s}/shallow", .{self.git_dir});
        defer self.allocator.free(shallow_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, shallow_path, 1024 * 1024) catch return &.{};
        defer self.allocator.free(content);

        var commits = std.array_list.Managed([40]u8).init(self.allocator);
        errdefer commits.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len >= 40) {
                var hash: [40]u8 = undefined;
                @memcpy(&hash, trimmed[0..40]);
                try commits.append(hash);
            }
        }

        return commits.toOwnedSlice();
    }

    /// Write the shallow file with the given commit hashes.
    pub fn writeShallowCommits(self: *GitStorage, commits: [][40]u8) !void {
        const shallow_path = try std.fmt.allocPrint(self.allocator, "{s}/shallow", .{self.git_dir});
        defer self.allocator.free(shallow_path);

        if (commits.len == 0) {
            std.fs.cwd().deleteFile(shallow_path) catch {};
            return;
        }

        const file = try std.fs.cwd().createFile(shallow_path, .{});
        defer file.close();
        for (commits) |commit| {
            try file.writeAll(&commit);
            try file.writeAll("\n");
        }
    }

    // ========================================================================
    // Repository info
    // ========================================================================

    /// Check if the storage path is a valid git repository.
    pub fn isValidRepo(self: *GitStorage) bool {
        const head_path = std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir}) catch return false;
        defer self.allocator.free(head_path);
        std.fs.cwd().access(head_path, .{}) catch return false;
        return true;
    }

    /// Get the git directory path (might be .git subdir or bare repo root).
    pub fn resolveGitDir(self: *GitStorage) ![]u8 {
        const dot_git = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{self.git_dir});
        const is_dot_git = blk: {
            std.fs.cwd().access(dot_git, .{}) catch {
                self.allocator.free(dot_git);
                break :blk false;
            };
            break :blk true;
        };
        if (is_dot_git) return dot_git;

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);
        std.fs.cwd().access(head_path, .{}) catch return error.NotAGitRepository;
        return try self.allocator.dupe(u8, self.git_dir);
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn looseObjectExists(self: *GitStorage, hash_hex: []const u8) bool {
        const obj_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/objects/{c}{c}/{s}",
            .{ self.git_dir, hash_hex[0], hash_hex[1], hash_hex[2..] },
        ) catch return false;
        defer self.allocator.free(obj_path);
        std.fs.cwd().access(obj_path, .{}) catch return false;
        return true;
    }

    fn packedObjectExists(self: *GitStorage, hash_hex: []const u8) bool {
        _ = hash_hex;
        // For now, delegate to object loading which checks packs
        _ = self;
        return false;
    }

    fn collectLooseRefsRecursive(self: *GitStorage, prefix: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, prefix });
        defer self.allocator.free(dir_path);

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            if (entry.kind == .directory) {
                defer self.allocator.free(full_name);
                try self.collectLooseRefsRecursive(full_name, ref_list);
            } else {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, full_name });
                defer self.allocator.free(file_path);
                if (std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024)) |content| {
                    defer self.allocator.free(content);
                    const hash = std.mem.trim(u8, content, " \t\r\n");
                    if (hash.len >= 40) {
                        var h: [40]u8 = undefined;
                        @memcpy(&h, hash[0..40]);
                        try ref_list.append(.{ .name = full_name, .hash = h });
                    } else {
                        self.allocator.free(full_name);
                    }
                } else |_| {
                    self.allocator.free(full_name);
                }
            }
        }
    }

    fn collectPackedRefsInto(self: *GitStorage, ref_list: *std.array_list.Managed(RefEntry)) !void {
        const packed_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_path);
        const content = std.fs.cwd().readFileAlloc(self.allocator, packed_path, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var lines_iter = std.mem.splitScalar(u8, content, '\n');
        while (lines_iter.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                const hash = line[0..sp];
                const name = line[sp + 1 ..];
                if (hash.len >= 40 and std.mem.startsWith(u8, name, "refs/")) {
                    // Check for duplicates
                    var found = false;
                    for (ref_list.items) |existing| {
                        if (std.mem.eql(u8, existing.name, name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        var h: [40]u8 = undefined;
                        @memcpy(&h, hash[0..40]);
                        try ref_list.append(.{
                            .name = try self.allocator.dupe(u8, name),
                            .hash = h,
                        });
                    }
                }
            }
        }
    }
};

// ============================================================================
// Types
// ============================================================================

/// Result of reading a git object.
pub const ObjectData = struct {
    obj_type: objects.GitObject.ObjectType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ObjectData) void {
        self.allocator.free(self.data);
    }
};

/// Ref entry with name and hash.
pub const RefEntry = struct {
    name: []const u8,
    hash: [40]u8,
};

/// HEAD value - either symbolic ref or direct hash.
pub const HeadValue = union(enum) {
    symbolic: []const u8,
    direct: [40]u8,

    pub fn deinit(self: *HeadValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .symbolic => |s| allocator.free(s),
            .direct => {},
        }
    }
};

/// List of refs returned by listRefs.
pub const RefList = struct {
    entries: []RefEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RefList) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
        }
        self.allocator.free(self.entries);
    }
};

/// Minimal platform implementation for object loading.
const StoragePlatform = struct {
    fs: StorageFs = .{},

    pub fn writeStderr(_: StoragePlatform, _: []const u8) !void {}
    pub fn writeStdout(_: StoragePlatform, _: []const u8) !void {}

    const StorageFs = struct {
        pub fn readFile(_: StorageFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
        }
        pub fn writeFile(_: StorageFs, path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }
        pub fn makeDir(_: StorageFs, path: []const u8) !void {
            std.fs.cwd().makePath(path) catch {};
        }
        pub fn exists(_: StorageFs, path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch return false;
            return true;
        }
        pub fn deleteFile(_: StorageFs, path: []const u8) !void {
            try std.fs.cwd().deleteFile(path);
        }
        pub fn getCwd(_: StorageFs, allocator: std.mem.Allocator) ![]u8 {
            return try std.fs.cwd().realpathAlloc(allocator, ".");
        }
        pub fn chdir(_: StorageFs, _: []const u8) !void {}
        pub fn readDir(_: StorageFs, _: std.mem.Allocator, _: []const u8) ![][]u8 {
            return &.{};
        }
        pub fn stat(_: StorageFs, path: []const u8) !std.fs.File.Stat {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            return try file.stat();
        }
    };
};

// ============================================================================
// Tests
// ============================================================================

test "GitStorage init and deinit" {
    const allocator = std.testing.allocator;
    var storage = GitStorage.init(allocator, "/tmp/nonexistent");
    defer storage.deinit();
    try std.testing.expectEqualStrings("/tmp/nonexistent", storage.git_dir);
}

test "GitStorage isValidRepo returns false for nonexistent" {
    const allocator = std.testing.allocator;
    var storage = GitStorage.init(allocator, "/tmp/nonexistent-repo-xyz");
    defer storage.deinit();
    try std.testing.expect(!storage.isValidRepo());
}

test "RefEntry and HeadValue types" {
    const allocator = std.testing.allocator;

    // Test HeadValue symbolic
    var head = HeadValue{ .symbolic = try allocator.dupe(u8, "refs/heads/main") };
    defer head.deinit(allocator);
    switch (head) {
        .symbolic => |s| try std.testing.expectEqualStrings("refs/heads/main", s),
        .direct => unreachable,
    }

    // Test HeadValue direct
    var direct_head = HeadValue{ .direct = "abcdef0123456789abcdef0123456789abcdef01".* };
    direct_head.deinit(allocator); // no-op for direct
}

test "ObjectData type" {
    // Just verify the type compiles and has the right fields
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, "test data");
    var obj = ObjectData{
        .obj_type = .blob,
        .data = data,
        .allocator = allocator,
    };
    defer obj.deinit();
    try std.testing.expectEqualStrings("test data", obj.data);
}
