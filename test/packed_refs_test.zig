// test/packed_refs_test.zig - Tests for packed-refs reading and ref utilities
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// parsePackedRefs
// ============================================================================

test "parsePackedRefs: empty file" {
    var result = try git.refs.parsePackedRefs("", testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 0);
}

test "parsePackedRefs: comment-only file" {
    const content = "# pack-refs with: peeled fully-peeled sorted\n";
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 0);
}

test "parsePackedRefs: single ref" {
    const content = "abc123def456abc123def456abc123def456abcd refs/heads/master\n";
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 1);
    try testing.expectEqualStrings("refs/heads/master", result.items[0].name);
    try testing.expectEqualStrings("abc123def456abc123def456abc123def456abcd", result.items[0].hash);
}

test "parsePackedRefs: multiple refs with header comment" {
    const content =
        \\# pack-refs with: peeled fully-peeled sorted
        \\aaaa234567890abcdef1234567890abcdef12345 refs/heads/master
        \\bbbb234567890abcdef1234567890abcdef12345 refs/heads/develop
        \\cccc234567890abcdef1234567890abcdef12345 refs/tags/v1.0.0
        \\
    ;
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 3);
}

test "parsePackedRefs: peeled tag lines (^) handled" {
    const content =
        \\aaaa234567890abcdef1234567890abcdef12345 refs/tags/v1.0.0
        \\^bbbb234567890abcdef1234567890abcdef12345
        \\cccc234567890abcdef1234567890abcdef12345 refs/heads/master
        \\
    ;
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    // Should have 2 refs (the peeled line attaches to the tag)
    try testing.expect(result.items.len == 2);

    // The tag should have the peeled hash
    var found_tag = false;
    for (result.items) |r| {
        if (std.mem.eql(u8, r.name, "refs/tags/v1.0.0")) {
            found_tag = true;
            try testing.expect(r.peeled_hash != null);
            try testing.expectEqualStrings("bbbb234567890abcdef1234567890abcdef12345", r.peeled_hash.?);
        }
    }
    try testing.expect(found_tag);
}

// ============================================================================
// validateRefName
// ============================================================================

test "validateRefName: accepts valid names" {
    const valid_names = [_][]const u8{
        "master",
        "feature/login",
        "fix-123",
        "refs/heads/main",
        "v1.0.0",
        "a",
    };
    for (valid_names) |name| {
        git.refs.validateRefName(name) catch |err| {
            std.debug.print("unexpected error for '{s}': {}\n", .{ name, err });
            return error.TestUnexpectedResult;
        };
    }
}

test "validateRefName: rejects empty" {
    try testing.expectError(error.EmptyRefName, git.refs.validateRefName(""));
}

test "validateRefName: rejects double dots" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("a..b"));
}

test "validateRefName: rejects space" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has space"));
}

test "validateRefName: rejects tilde" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has~tilde"));
}

test "validateRefName: rejects caret" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has^caret"));
}

test "validateRefName: rejects colon" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has:colon"));
}

test "validateRefName: rejects question" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has?q"));
}

test "validateRefName: rejects asterisk" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has*star"));
}

test "validateRefName: rejects bracket" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has[bracket"));
}

test "validateRefName: rejects backslash" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("has\\bs"));
}

test "validateRefName: rejects too long" {
    const long_name = "a" ** 1025;
    try testing.expectError(error.RefNameTooLong, git.refs.validateRefName(long_name));
}

// ============================================================================
// getRefType
// ============================================================================

test "getRefType: HEAD" {
    try testing.expect(git.refs.getRefType("HEAD") == .head);
}

test "getRefType: branch" {
    try testing.expect(git.refs.getRefType("refs/heads/master") == .branch);
}

test "getRefType: tag" {
    try testing.expect(git.refs.getRefType("refs/tags/v1.0.0") == .tag);
}

test "getRefType: remote" {
    try testing.expect(git.refs.getRefType("refs/remotes/origin/main") == .remote);
}

test "getRefType: other" {
    try testing.expect(git.refs.getRefType("refs/stash") == .other);
}

// ============================================================================
// getShortRefName
// ============================================================================

test "getShortRefName: strips refs/heads/" {
    const short = try git.refs.getShortRefName("refs/heads/master", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("master", short);
}

test "getShortRefName: strips refs/tags/" {
    const short = try git.refs.getShortRefName("refs/tags/v1.0.0", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("v1.0.0", short);
}

test "getShortRefName: strips refs/remotes/" {
    const short = try git.refs.getShortRefName("refs/remotes/origin/main", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("origin/main", short);
}

// ============================================================================
// Integration: packed refs with git
// ============================================================================

test "packed refs: parse git pack-refs output" {
    const tmp = "/tmp/ziggit_packed_refs_int";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("content\n");
    }
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "f.txt" });
    _ = try runCmd(&.{ "git", "-C", tmp, "commit", "-q", "-m", "init" });
    _ = try runCmd(&.{ "git", "-C", tmp, "tag", "v1.0.0" });
    _ = try runCmd(&.{ "git", "-C", tmp, "tag", "v2.0.0" });

    // Get HEAD before packing
    const head_output = try runCmd(&.{ "git", "-C", tmp, "rev-parse", "HEAD" });
    defer testing.allocator.free(head_output);
    const head_hash = std.mem.trim(u8, head_output, " \t\n\r");

    // Pack refs
    _ = try runCmd(&.{ "git", "-C", tmp, "pack-refs", "--all" });

    // Verify packed-refs exists
    std.fs.accessAbsolute(tmp ++ "/.git/packed-refs", .{}) catch return;

    const packed_data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/packed-refs", 1024 * 1024);
    defer testing.allocator.free(packed_data);

    var refs = try git.refs.parsePackedRefs(packed_data, testing.allocator);
    defer {
        for (refs.items) |r| r.deinit(testing.allocator);
        refs.deinit();
    }

    // Should find master, v1.0.0, v2.0.0
    var found_master = false;
    var found_v1 = false;
    var found_v2 = false;
    for (refs.items) |r| {
        if (std.mem.eql(u8, r.name, "refs/heads/master")) {
            try testing.expectEqualStrings(head_hash, r.hash);
            found_master = true;
        }
        if (std.mem.eql(u8, r.name, "refs/tags/v1.0.0")) found_v1 = true;
        if (std.mem.eql(u8, r.name, "refs/tags/v2.0.0")) found_v2 = true;
    }
    try testing.expect(found_master);
    try testing.expect(found_v1);
    try testing.expect(found_v2);
}

// ============================================================================
// Helpers
// ============================================================================

fn runCmd(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    return stdout;
}
