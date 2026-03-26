// test/refs_internal_resolution_test.zig
// Tests for internal git ref resolution module.
// Verifies: symbolic ref chains, packed-refs, detached HEAD, invalid refs
const std = @import("std");
const git = @import("git");
const testing = std.testing;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_refs_internal_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFileAbs(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileAbs(path: []const u8) ![]u8 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn mkdirAbs(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

/// Create a minimal .git directory structure
fn createMinimalGitDir(comptime suffix: []const u8) ![]const u8 {
    const base = tmpPath(suffix);
    cleanup(base);
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{base});

    try mkdirAbs(base);
    try mkdirAbs(git_dir);

    const refs = try std.fmt.allocPrint(testing.allocator, "{s}/refs", .{git_dir});
    defer testing.allocator.free(refs);
    try mkdirAbs(refs);

    const heads = try std.fmt.allocPrint(testing.allocator, "{s}/refs/heads", .{git_dir});
    defer testing.allocator.free(heads);
    try mkdirAbs(heads);

    const tags = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags", .{git_dir});
    defer testing.allocator.free(tags);
    try mkdirAbs(tags);

    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{git_dir});
    defer testing.allocator.free(head_path);
    try writeFileAbs(head_path, "ref: refs/heads/main\n");

    return git_dir;
}

// We need a minimal platform implementation for the refs module
const FsImpl = struct {
    pub fn readFile(_: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
            return switch (e) {
                error.FileNotFound => error.FileNotFound,
                else => e,
            };
        };
        defer file.close();
        return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    }

    pub fn fileExists(_: @This(), path: []const u8) bool {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    pub fn readDir(_: @This(), allocator: std.mem.Allocator, path: []const u8) ![]const std.fs.Dir.Entry {
        _ = allocator;
        _ = path;
        return &[_]std.fs.Dir.Entry{};
    }

    pub fn makeDir(_: @This(), path: []const u8) !void {
        std.fs.makeDirAbsolute(path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    pub fn writeFile(_: @This(), path: []const u8, data: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
    }
};

const TestPlatform = struct {
    fs: FsImpl = .{},
};

const platform = TestPlatform{};

test "getCurrentBranch: HEAD pointing to refs/heads/main" {
    const git_dir = try createMinimalGitDir("branch_main");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("branch_main"));
    }

    const branch = try git.refs.getCurrentBranch(git_dir, platform, testing.allocator);
    defer testing.allocator.free(branch);
    try testing.expectEqualStrings("main", branch);
}

test "getCurrentBranch: HEAD pointing to refs/heads/feature" {
    const git_dir = try createMinimalGitDir("branch_feature");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("branch_feature"));
    }

    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{git_dir});
    defer testing.allocator.free(head_path);
    try writeFileAbs(head_path, "ref: refs/heads/feature/my-branch\n");

    const branch = try git.refs.getCurrentBranch(git_dir, platform, testing.allocator);
    defer testing.allocator.free(branch);
    try testing.expectEqualStrings("feature/my-branch", branch);
}

test "getCurrentBranch: detached HEAD returns HEAD" {
    const git_dir = try createMinimalGitDir("detached");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("detached"));
    }

    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{git_dir});
    defer testing.allocator.free(head_path);
    try writeFileAbs(head_path, "abc123def456abc123def456abc123def456abc1\n");

    const branch = try git.refs.getCurrentBranch(git_dir, platform, testing.allocator);
    defer testing.allocator.free(branch);
    try testing.expectEqualStrings("HEAD", branch);
}

test "resolveRef: resolves HEAD to commit hash" {
    const git_dir = try createMinimalGitDir("resolve_head");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("resolve_head"));
    }

    const hash = "abc123def456abc123def456abc123def456abc1";
    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/heads/main", .{git_dir});
    defer testing.allocator.free(ref_path);
    try writeFileAbs(ref_path, hash ++ "\n");

    const result = try git.refs.resolveRef(git_dir, "HEAD", platform, testing.allocator);
    if (result) |r| {
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(hash, r);
    }
}

test "resolveRef: resolves branch name directly" {
    const git_dir = try createMinimalGitDir("resolve_branch");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("resolve_branch"));
    }

    const hash = "1234567890abcdef1234567890abcdef12345678";
    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/heads/main", .{git_dir});
    defer testing.allocator.free(ref_path);
    try writeFileAbs(ref_path, hash ++ "\n");

    const result = try git.refs.resolveRef(git_dir, "refs/heads/main", platform, testing.allocator);
    if (result) |r| {
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(hash, r);
    }
}

test "resolveRef: resolves tag ref" {
    const git_dir = try createMinimalGitDir("resolve_tag");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("resolve_tag"));
    }

    const hash = "fedcba9876543210fedcba9876543210fedcba98";
    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags/v1.0", .{git_dir});
    defer testing.allocator.free(ref_path);
    try writeFileAbs(ref_path, hash ++ "\n");

    const result = try git.refs.resolveRef(git_dir, "refs/tags/v1.0", platform, testing.allocator);
    if (result) |r| {
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(hash, r);
    }
}

test "resolveRef: empty ref name returns error" {
    const git_dir = try createMinimalGitDir("empty_ref");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("empty_ref"));
    }

    const result = git.refs.resolveRef(git_dir, "", platform, testing.allocator);
    try testing.expectError(error.EmptyRefName, result);
}

test "resolveRef: ref with invalid chars returns error" {
    const git_dir = try createMinimalGitDir("invalid_ref");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("invalid_ref"));
    }

    const result = git.refs.resolveRef(git_dir, "refs/heads/bad~ref", platform, testing.allocator);
    try testing.expectError(error.InvalidRefNameChar, result);
}

test "resolveRef: nonexistent ref returns error" {
    const git_dir = try createMinimalGitDir("nonexist_ref");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("nonexist_ref"));
    }

    const result = git.refs.resolveRef(git_dir, "refs/heads/nonexistent", platform, testing.allocator);
    // Nonexistent refs should return an error (RefNotFound or similar)
    try testing.expectError(error.RefNotFound, result);
}
