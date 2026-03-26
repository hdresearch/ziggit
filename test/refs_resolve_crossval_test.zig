// test/refs_resolve_crossval_test.zig
// Tests refs module: resolveRef, getCurrentBranch, listBranches, etc.
// Cross-validates with git CLI
const std = @import("std");
const testing = std.testing;
const git = @import("git");

const NativePlatform = struct {
    const fs = struct {
        fn makeDir(path: []const u8) !void {
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        fn writeFile(path: []const u8, content: []const u8) !void {
            const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
        fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        }
        fn fileExists(path: []const u8) bool {
            std.fs.accessAbsolute(path, .{}) catch return false;
            return true;
        }
    };
};
const platform = NativePlatform{};

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_refs_crossval_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn execGit(work_dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(work_dir);
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn execGitNoOutput(work_dir: []const u8, args: []const []const u8) !void {
    const out = try execGit(work_dir, args);
    testing.allocator.free(out);
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    try execGitNoOutput(path, &.{"init"});
    try execGitNoOutput(path, &.{ "config", "user.email", "t@t.com" });
    try execGitNoOutput(path, &.{ "config", "user.name", "Test" });
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const file = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

// ============================================================================
// getCurrentBranch tests
// ============================================================================

test "getCurrentBranch: returns master/main after first commit" {
    const path = tmpPath("branch_default");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    const branch = try git.refs.getCurrentBranch(git_dir, platform, testing.allocator);
    defer testing.allocator.free(branch);

    // Should be refs/heads/master or refs/heads/main
    try testing.expect(
        std.mem.eql(u8, branch, "refs/heads/master") or
            std.mem.eql(u8, branch, "refs/heads/main"),
    );
}

// ============================================================================
// resolveRef tests
// ============================================================================

test "resolveRef: HEAD points to commit hash" {
    const path = tmpPath("resolve_head");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Get expected hash from git
    const git_out = try execGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_out);
    const expected = std.mem.trim(u8, git_out, " \n\r\t");

    // Get current branch
    const branch = try git.refs.getCurrentBranch(git_dir, platform, testing.allocator);
    defer testing.allocator.free(branch);

    // Resolve the branch ref
    const resolved = try git.refs.resolveRef(git_dir, branch, platform, testing.allocator);
    if (resolved) |hash| {
        defer testing.allocator.free(hash);
        try testing.expectEqualStrings(expected, hash);
    } else {
        return error.RefNotResolved;
    }
}

test "resolveRef: tag ref resolves to commit" {
    const path = tmpPath("resolve_tag");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });
    try execGitNoOutput(path, &.{ "tag", "v1.0.0" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    const resolved = try git.refs.resolveRef(git_dir, "refs/tags/v1.0.0", platform, testing.allocator);
    if (resolved) |hash| {
        defer testing.allocator.free(hash);

        // Should match git rev-parse
        const git_out = try execGit(path, &.{ "rev-parse", "v1.0.0" });
        defer testing.allocator.free(git_out);
        const expected = std.mem.trim(u8, git_out, " \n\r\t");
        try testing.expectEqualStrings(expected, hash);
    } else {
        return error.RefNotResolved;
    }
}

// ============================================================================
// listBranches tests
// ============================================================================

test "listBranches: shows all branches" {
    const path = tmpPath("list_branches");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });
    try execGitNoOutput(path, &.{ "branch", "feature-a" });
    try execGitNoOutput(path, &.{ "branch", "feature-b" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    var branches = try git.refs.listBranches(git_dir, platform, testing.allocator);
    defer {
        for (branches.items) |b| testing.allocator.free(b);
        branches.deinit();
    }

    // Should have 3 branches (master/main + feature-a + feature-b)
    try testing.expect(branches.items.len >= 3);

    var found_a = false;
    var found_b = false;
    for (branches.items) |b| {
        if (std.mem.eql(u8, b, "feature-a")) found_a = true;
        if (std.mem.eql(u8, b, "feature-b")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

// ============================================================================
// updateRef tests
// ============================================================================

test "updateRef: creates new ref readable by git" {
    const path = tmpPath("update_ref");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Get HEAD hash
    const git_out = try execGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_out);
    const head_hash = std.mem.trim(u8, git_out, " \n\r\t");

    // Create a new ref using ziggit's refs module
    try git.refs.updateRef(git_dir, "refs/tags/ziggit-tag", head_hash, platform, testing.allocator);

    // git should be able to read it
    const tag_out = try execGit(path, &.{ "rev-parse", "refs/tags/ziggit-tag" });
    defer testing.allocator.free(tag_out);
    const tag_hash = std.mem.trim(u8, tag_out, " \n\r\t");

    try testing.expectEqualStrings(head_hash, tag_hash);
}

// ============================================================================
// branchExists tests
// ============================================================================

test "branchExists: returns true for existing branch" {
    const path = tmpPath("branch_exists");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });
    try execGitNoOutput(path, &.{ "branch", "test-branch" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    try testing.expect(try git.refs.branchExists(git_dir, "test-branch", platform, testing.allocator));
    try testing.expect(!try git.refs.branchExists(git_dir, "nonexistent", platform, testing.allocator));
}

// ============================================================================
// createBranch tests
// ============================================================================

test "createBranch: new branch at HEAD" {
    const path = tmpPath("create_branch");
    defer cleanup(path);
    try initGitRepo(path);
    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });
    try execGitNoOutput(path, &.{ "commit", "-m", "init" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    try git.refs.createBranch(git_dir, "new-branch", null, platform, testing.allocator);

    // git should see it
    const branch_out = try execGit(path, &.{ "branch", "--format=%(refname:short)" });
    defer testing.allocator.free(branch_out);
    try testing.expect(std.mem.indexOf(u8, branch_out, "new-branch") != null);
}
