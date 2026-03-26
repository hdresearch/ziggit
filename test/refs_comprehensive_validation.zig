const std = @import("std");
const refs = @import("../src/git/refs.zig");
const print = std.debug.print;

// Simple platform implementation for testing
const TestPlatform = struct {
    const Self = @This();

    const TestFs = struct {
        fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        }

        fn writeFile(file_path: []const u8, content: []const u8) !void {
            try std.fs.cwd().writeFile(file_path, content);
        }

        fn makeDir(dir_path: []const u8) !void {
            try std.fs.cwd().makePath(dir_path);
        }

        fn exists(file_path: []const u8) !bool {
            std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }

        fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
            var list = std.ArrayList([]u8).init(allocator);
            defer list.deinit();

            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
                return try allocator.alloc([]u8, 0);
            };
            defer dir.close();

            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try list.append(try allocator.dupe(u8, entry.name));
                }
            }

            return try list.toOwnedSlice();
        }

        fn deleteFile(file_path: []const u8) !void {
            try std.fs.cwd().deleteFile(file_path);
        }
    };

    const fs = TestFs{};
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🧪 Testing comprehensive git refs functionality...\n");
    
    const platform = TestPlatform{};
    
    // Test basic ref operations
    print("📁 Testing basic ref operations...\n");
    try testBasicRefs(platform, allocator);
    
    // Test symbolic ref resolution
    print("🔗 Testing symbolic ref resolution...\n");
    try testSymbolicRefs(platform, allocator);
    
    // Test packed-refs support
    print("📦 Testing packed-refs support...\n");
    try testPackedRefs(platform, allocator);
    
    // Test remote refs and tracking branches
    print("🌐 Testing remote refs and tracking branches...\n");
    try testRemoteRefs(platform, allocator);
    
    // Test tag resolution including annotated tags
    print("🏷️  Testing tag resolution...\n");
    try testTagResolution(platform, allocator);
    
    print("✅ All refs tests completed successfully!\n");
}

fn testBasicRefs(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test repository structure
    try std.fs.cwd().makePath("test_refs/.git/refs/heads");
    defer std.fs.cwd().deleteTree("test_refs") catch {};
    
    const test_commit = "1234567890abcdef1234567890abcdef12345678";
    
    // Create HEAD pointing to main branch
    try std.fs.cwd().writeFile("test_refs/.git/HEAD", "ref: refs/heads/main\n");
    
    // Create main branch
    const main_content = try std.fmt.allocPrint(allocator, "{s}\n", .{test_commit});
    defer allocator.free(main_content);
    try std.fs.cwd().writeFile("test_refs/.git/refs/heads/main", main_content);
    
    // Test getting current branch
    const current_branch = refs.getCurrentBranch("test_refs/.git", platform, allocator) catch |err| {
        print("Failed to get current branch: {}\n", .{err});
        return err;
    };
    defer allocator.free(current_branch);
    
    if (!std.mem.eql(u8, current_branch, "main")) {
        print("Expected 'main', got '{s}'\n", .{current_branch});
        return error.CurrentBranchMismatch;
    }
    
    // Test getting current commit
    const current_commit = refs.getCurrentCommit("test_refs/.git", platform, allocator) catch |err| {
        print("Failed to get current commit: {}\n", .{err});
        return err;
    };
    defer if (current_commit) |commit| allocator.free(commit);
    
    if (current_commit == null) return error.NoCurrentCommit;
    if (!std.mem.eql(u8, current_commit.?, test_commit)) {
        return error.CurrentCommitMismatch;
    }
    
    // Test resolving ref
    const resolved_main = refs.resolveRef("test_refs/.git", "refs/heads/main", platform, allocator) catch |err| {
        print("Failed to resolve main ref: {}\n", .{err});
        return err;
    };
    defer if (resolved_main) |commit| allocator.free(commit);
    
    if (resolved_main == null) return error.NoResolvedMain;
    if (!std.mem.eql(u8, resolved_main.?, test_commit)) {
        return error.ResolvedMainMismatch;
    }
    
    print("✅ Basic ref operations successful\n");
}

fn testSymbolicRefs(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test repository with nested symbolic refs
    try std.fs.cwd().makePath("test_symbolic/.git/refs/heads");
    defer std.fs.cwd().deleteTree("test_symbolic") catch {};
    
    const final_commit = "abcdef1234567890abcdef1234567890abcdef12";
    
    // Create chain: HEAD -> refs/heads/current -> refs/heads/main -> commit
    try std.fs.cwd().writeFile("test_symbolic/.git/HEAD", "ref: refs/heads/current\n");
    try std.fs.cwd().writeFile("test_symbolic/.git/refs/heads/current", "ref: refs/heads/main\n");
    
    const main_content = try std.fmt.allocPrint(allocator, "{s}\n", .{final_commit});
    defer allocator.free(main_content);
    try std.fs.cwd().writeFile("test_symbolic/.git/refs/heads/main", main_content);
    
    // Test resolving nested symbolic refs
    const resolved_head = refs.resolveRef("test_symbolic/.git", "HEAD", platform, allocator) catch |err| {
        print("Failed to resolve nested symbolic HEAD: {}\n", .{err});
        return err;
    };
    defer if (resolved_head) |commit| allocator.free(commit);
    
    if (resolved_head == null) return error.NoResolvedHead;
    if (!std.mem.eql(u8, resolved_head.?, final_commit)) {
        print("Expected '{s}', got '{s}'\n", .{ final_commit, resolved_head.? });
        return error.NestedSymbolicRefMismatch;
    }
    
    // Test circular reference detection
    try std.fs.cwd().writeFile("test_symbolic/.git/refs/heads/circular1", "ref: refs/heads/circular2\n");
    try std.fs.cwd().writeFile("test_symbolic/.git/refs/heads/circular2", "ref: refs/heads/circular1\n");
    
    const circular_result = refs.resolveRef("test_symbolic/.git", "refs/heads/circular1", platform, allocator);
    if (circular_result) |_| {
        return error.CircularRefNotDetected;
    } else |err| switch (err) {
        error.CircularRef => print("✅ Circular reference detected correctly\n"),
        error.TooManySymbolicRefs => print("✅ Too many symbolic refs detected correctly\n"),
        else => return err,
    }
    
    print("✅ Symbolic ref resolution successful\n");
}

fn testPackedRefs(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test repository with packed-refs
    try std.fs.cwd().makePath("test_packed/.git");
    defer std.fs.cwd().deleteTree("test_packed") catch {};
    
    // Create packed-refs file
    const packed_refs_content =
        \\# pack-refs with: peeled fully-peeled sorted 
        \\1234567890abcdef1234567890abcdef12345678 refs/heads/main
        \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/develop
        \\2468ace024681357924681357924681357924681 refs/remotes/origin/main
        \\1357924680ace135792468ace1357924681357924 refs/tags/v1.0.0
        \\^fedcba0987654321fedcba0987654321fedcba09 
        \\9876543210fedcba9876543210fedcba9876543210 refs/tags/v2.0.0
    ;
    
    try std.fs.cwd().writeFile("test_packed/.git/packed-refs", packed_refs_content);
    
    // Test resolving refs from packed-refs
    const main_commit = refs.resolveRef("test_packed/.git", "refs/heads/main", platform, allocator) catch |err| {
        print("Failed to resolve main from packed-refs: {}\n", .{err});
        return err;
    };
    defer if (main_commit) |commit| allocator.free(commit);
    
    if (main_commit == null) return error.NoPackedMain;
    if (!std.mem.eql(u8, main_commit.?, "1234567890abcdef1234567890abcdef12345678")) {
        return error.PackedMainMismatch;
    }
    
    // Test resolving annotated tag (should get peeled ref)
    const tag_commit = refs.resolveRef("test_packed/.git", "refs/tags/v1.0.0", platform, allocator) catch |err| {
        print("Failed to resolve tag from packed-refs: {}\n", .{err});
        return err;
    };
    defer if (tag_commit) |commit| allocator.free(commit);
    
    if (tag_commit == null) return error.NoPackedTag;
    // For this test, we'll accept either the tag object hash or peeled hash
    // since our implementation may not have the tag object to parse
    if (!std.mem.eql(u8, tag_commit.?, "1357924680ace135792468ace1357924681357924") and
        !std.mem.eql(u8, tag_commit.?, "fedcba0987654321fedcba0987654321fedcba09")) {
        return error.PackedTagMismatch;
    }
    
    // Test short ref name resolution
    const develop_commit = refs.resolveRef("test_packed/.git", "develop", platform, allocator) catch |err| {
        print("Failed to resolve develop from packed-refs: {}\n", .{err});
        return err;
    };
    defer if (develop_commit) |commit| allocator.free(commit);
    
    if (develop_commit == null) return error.NoPackedDevelop;
    if (!std.mem.eql(u8, develop_commit.?, "abcdef1234567890abcdef1234567890abcdef12")) {
        return error.PackedDevelopMismatch;
    }
    
    print("✅ Packed-refs support successful\n");
}

fn testRemoteRefs(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test repository with remote tracking branches
    try std.fs.cwd().makePath("test_remote/.git/refs/remotes/origin");
    try std.fs.cwd().makePath("test_remote/.git/refs/remotes/upstream");
    defer std.fs.cwd().deleteTree("test_remote") catch {};
    
    const origin_main_commit = "aaaa567890abcdef1234567890abcdef12345678";
    const origin_dev_commit = "bbbb567890abcdef1234567890abcdef12345678";
    const upstream_main_commit = "cccc567890abcdef1234567890abcdef12345678";
    
    // Create remote tracking branches
    const origin_main_content = try std.fmt.allocPrint(allocator, "{s}\n", .{origin_main_commit});
    defer allocator.free(origin_main_content);
    try std.fs.cwd().writeFile("test_remote/.git/refs/remotes/origin/main", origin_main_content);
    
    const origin_dev_content = try std.fmt.allocPrint(allocator, "{s}\n", .{origin_dev_commit});
    defer allocator.free(origin_dev_content);
    try std.fs.cwd().writeFile("test_remote/.git/refs/remotes/origin/develop", origin_dev_content);
    
    const upstream_main_content = try std.fmt.allocPrint(allocator, "{s}\n", .{upstream_main_commit});
    defer allocator.free(upstream_main_content);
    try std.fs.cwd().writeFile("test_remote/.git/refs/remotes/upstream/main", upstream_main_content);
    
    // Test resolving remote refs
    const resolved_origin_main = refs.resolveRef("test_remote/.git", "refs/remotes/origin/main", platform, allocator) catch |err| {
        print("Failed to resolve origin/main: {}\n", .{err});
        return err;
    };
    defer if (resolved_origin_main) |commit| allocator.free(commit);
    
    if (resolved_origin_main == null) return error.NoOriginMain;
    if (!std.mem.eql(u8, resolved_origin_main.?, origin_main_commit)) {
        return error.OriginMainMismatch;
    }
    
    // Test listing remotes
    const remotes_list = refs.listRemotes("test_remote/.git", platform, allocator) catch |err| {
        print("Failed to list remotes: {}\n", .{err});
        return err;
    };
    defer {
        for (remotes_list.items) |remote| {
            allocator.free(remote);
        }
        remotes_list.deinit();
    }
    
    // Should find both 'origin' and 'upstream'
    var found_origin = false;
    var found_upstream = false;
    for (remotes_list.items) |remote| {
        if (std.mem.eql(u8, remote, "origin")) found_origin = true;
        if (std.mem.eql(u8, remote, "upstream")) found_upstream = true;
    }
    
    if (!found_origin or !found_upstream) {
        return error.RemotesListIncomplete;
    }
    
    // Test listing remote branches
    const origin_branches = refs.listRemoteBranches("test_remote/.git", "origin", platform, allocator) catch |err| {
        print("Failed to list origin branches: {}\n", .{err});
        return err;
    };
    defer {
        for (origin_branches.items) |branch| {
            allocator.free(branch);
        }
        origin_branches.deinit();
    }
    
    if (origin_branches.items.len != 2) {
        return error.OriginBranchesCountMismatch;
    }
    
    print("✅ Remote refs and tracking branches successful\n");
}

fn testTagResolution(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test repository with tags
    try std.fs.cwd().makePath("test_tags/.git/refs/tags");
    defer std.fs.cwd().deleteTree("test_tags") catch {};
    
    const lightweight_tag_commit = "1111567890abcdef1234567890abcdef12345678";
    
    // Create lightweight tag (just points to commit)
    const tag_content = try std.fmt.allocPrint(allocator, "{s}\n", .{lightweight_tag_commit});
    defer allocator.free(tag_content);
    try std.fs.cwd().writeFile("test_tags/.git/refs/tags/v1.0", tag_content);
    
    // Test resolving lightweight tag
    const resolved_tag = refs.resolveRef("test_tags/.git", "refs/tags/v1.0", platform, allocator) catch |err| {
        print("Failed to resolve lightweight tag: {}\n", .{err});
        return err;
    };
    defer if (resolved_tag) |commit| allocator.free(commit);
    
    if (resolved_tag == null) return error.NoResolvedTag;
    if (!std.mem.eql(u8, resolved_tag.?, lightweight_tag_commit)) {
        return error.LightweightTagMismatch;
    }
    
    // Test short tag name resolution
    const resolved_short_tag = refs.resolveRef("test_tags/.git", "v1.0", platform, allocator) catch |err| {
        print("Failed to resolve short tag name: {}\n", .{err});
        return err;
    };
    defer if (resolved_short_tag) |commit| allocator.free(commit);
    
    if (resolved_short_tag == null) return error.NoResolvedShortTag;
    if (!std.mem.eql(u8, resolved_short_tag.?, lightweight_tag_commit)) {
        return error.ShortTagMismatch;
    }
    
    // Test listing tags
    const tags_list = refs.listTags("test_tags/.git", platform, allocator) catch |err| {
        print("Failed to list tags: {}\n", .{err});
        return err;
    };
    defer {
        for (tags_list.items) |tag| {
            allocator.free(tag);
        }
        tags_list.deinit();
    }
    
    if (tags_list.items.len != 1) return error.TagsListCountMismatch;
    if (!std.mem.eql(u8, tags_list.items[0], "v1.0")) return error.TagsListContentMismatch;
    
    print("✅ Tag resolution successful\n");
}