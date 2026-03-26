// test/refs_validation_test.zig - Tests for ref validation, parsing, and utility functions
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// validateRefName
// ============================================================================

test "validateRefName: valid simple name" {
    try git.refs.validateRefName("main");
    try git.refs.validateRefName("master");
    try git.refs.validateRefName("feature-branch");
    try git.refs.validateRefName("release/1.0");
    try git.refs.validateRefName("refs/heads/main");
    try git.refs.validateRefName("refs/tags/v1.0");
}

test "validateRefName: empty name rejected" {
    try testing.expectError(error.EmptyRefName, git.refs.validateRefName(""));
}

test "validateRefName: rejects double dots" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("main..branch"));
}

test "validateRefName: rejects space" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("my branch"));
}

test "validateRefName: rejects tilde" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch~1"));
}

test "validateRefName: rejects caret" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch^2"));
}

test "validateRefName: rejects colon" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch:name"));
}

test "validateRefName: rejects question mark" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch?name"));
}

test "validateRefName: rejects asterisk" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch*name"));
}

test "validateRefName: rejects bracket" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch[0]"));
}

test "validateRefName: rejects backslash" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch\\name"));
}

test "validateRefName: rejects leading dot" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName(".hidden"));
}

test "validateRefName: rejects trailing dot" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch."));
}

test "validateRefName: rejects leading slash" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("/branch"));
}

test "validateRefName: rejects trailing slash" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch/"));
}

test "validateRefName: rejects control characters" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch\x01name"));
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch\x7fname"));
}

test "validateRefName: rejects at-brace" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("branch@{0}"));
}

test "validateRefName: rejects slash-dot" {
    try testing.expectError(error.InvalidRefName, git.refs.validateRefName("refs/.hidden"));
}

test "validateRefName: rejects too-long name" {
    var buf: [1025]u8 = undefined;
    @memset(&buf, 'a');
    try testing.expectError(error.RefNameTooLong, git.refs.validateRefName(&buf));
}

test "validateRefName: accepts max-length name" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 'a');
    try git.refs.validateRefName(&buf);
}

// ============================================================================
// getRefType
// ============================================================================

test "getRefType: HEAD" {
    try testing.expect(git.refs.getRefType("HEAD") == .head);
}

test "getRefType: branch ref" {
    try testing.expect(git.refs.getRefType("refs/heads/main") == .branch);
    try testing.expect(git.refs.getRefType("refs/heads/feature") == .branch);
}

test "getRefType: tag ref" {
    try testing.expect(git.refs.getRefType("refs/tags/v1.0") == .tag);
}

test "getRefType: remote ref" {
    try testing.expect(git.refs.getRefType("refs/remotes/origin/main") == .remote);
}

test "getRefType: other ref" {
    try testing.expect(git.refs.getRefType("refs/stash") == .other);
    try testing.expect(git.refs.getRefType("something") == .other);
}

// ============================================================================
// getShortRefName
// ============================================================================

test "getShortRefName: strips refs/heads/" {
    const short = try git.refs.getShortRefName("refs/heads/main", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("main", short);
}

test "getShortRefName: strips refs/tags/" {
    const short = try git.refs.getShortRefName("refs/tags/v1.0", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("v1.0", short);
}

test "getShortRefName: strips refs/remotes/" {
    const short = try git.refs.getShortRefName("refs/remotes/origin/main", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("origin/main", short);
}

test "getShortRefName: preserves HEAD" {
    const short = try git.refs.getShortRefName("HEAD", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("HEAD", short);
}

test "getShortRefName: strips refs/ from other refs" {
    const short = try git.refs.getShortRefName("refs/stash", testing.allocator);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("stash", short);
}

// ============================================================================
// parsePackedRefs
// ============================================================================

test "parsePackedRefs: empty content" {
    var result = try git.refs.parsePackedRefs("", testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 0);
}

test "parsePackedRefs: comment lines ignored" {
    const content = "# pack-refs with: peeled fully-peeled sorted\n";
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 0);
}

test "parsePackedRefs: single ref" {
    const content = "abcdef1234567890abcdef1234567890abcdef12 refs/heads/main\n";
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 1);
    try testing.expectEqualStrings("refs/heads/main", result.items[0].name);
    try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", result.items[0].hash);
}

test "parsePackedRefs: multiple refs with comments" {
    const content =
        \\# pack-refs with: peeled fully-peeled sorted
        \\1111111111111111111111111111111111111111 refs/heads/main
        \\2222222222222222222222222222222222222222 refs/tags/v1.0
        \\3333333333333333333333333333333333333333 refs/remotes/origin/main
        \\
    ;
    var result = try git.refs.parsePackedRefs(content, testing.allocator);
    defer {
        for (result.items) |r| r.deinit(testing.allocator);
        result.deinit();
    }
    try testing.expect(result.items.len == 3);
}

// ============================================================================
// Ref struct
// ============================================================================

test "Ref.init creates ref with name and hash" {
    const r = git.refs.Ref.init("refs/heads/main", "abc123");
    try testing.expectEqualStrings("refs/heads/main", r.name);
    try testing.expectEqualStrings("abc123", r.hash);
}

// ============================================================================
// isValidRefName (module-level helper)
// ============================================================================

test "isValidRefName rejects empty" {
    // The module-level isValidRefName is private, but validateRefName tests the same logic
    try testing.expectError(error.EmptyRefName, git.refs.validateRefName(""));
}
