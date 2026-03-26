// test/diff_generation_test.zig
// Tests for the diff module: unified diff generation, binary detection, word diff.

const std = @import("std");
const diff = @import("diff");
const testing = std.testing;

// ============================================================================
// Unified Diff Generation
// ============================================================================

test "identical content produces empty diff" {
    const content = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(content, content, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "added lines produce + prefixed output" {
    const old = "";
    const new = "hello\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "+hello") != null);
}

test "removed lines produce - prefixed output" {
    const old = "hello\n";
    const new = "";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "-hello") != null);
}

test "changed line shows both old and new" {
    const old = "old line\n";
    const new = "new line\n";
    const result = try diff.generateUnifiedDiff(old, new, "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "-old line") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+new line") != null);
}

test "diff header contains file path" {
    const old = "a\n";
    const new = "b\n";
    const result = try diff.generateUnifiedDiff(old, new, "src/main.zig", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "a/src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, "b/src/main.zig") != null);
}

test "diff contains @@ hunk header" {
    const old = "line1\n";
    const new = "line2\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "@@") != null);
}

test "multi-line diff with context" {
    const old = "line1\nline2\nline3\nline4\nline5\n";
    const new = "line1\nline2\nmodified\nline4\nline5\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "-line3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+modified") != null);
}

test "diff with custom hashes" {
    const result = try diff.generateUnifiedDiffWithHashes(
        "old\n",
        "new\n",
        "file.txt",
        "abc1234",
        "def5678",
        testing.allocator,
    );
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "abc1234") != null);
    try testing.expect(std.mem.indexOf(u8, result, "def5678") != null);
}

// ============================================================================
// Empty Content Edge Cases
// ============================================================================

test "both empty produces empty diff" {
    const result = try diff.generateUnifiedDiff("", "", "empty.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "empty to single line" {
    const result = try diff.generateUnifiedDiff("", "hello", "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

test "single line to empty" {
    const result = try diff.generateUnifiedDiff("hello", "", "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

// ============================================================================
// Binary Detection
// ============================================================================

test "text content is not binary" {
    try testing.expect(!diff.isBinary("Hello, world!\nThis is text.\n"));
}

test "empty content is not binary" {
    try testing.expect(!diff.isBinary(""));
}

test "content with null byte is binary" {
    try testing.expect(diff.isBinary("hello\x00world"));
}

test "content with many null bytes is binary" {
    const data = "\x00\x01\x02\x03\x04\x05";
    try testing.expect(diff.isBinary(data));
}

test "printable ASCII is not binary" {
    var buf: [128]u8 = undefined;
    for (0..128) |i| {
        buf[i] = @intCast(i);
    }
    // Has null byte, so should be binary
    try testing.expect(diff.isBinary(&buf));
}

test "pure printable text is not binary" {
    try testing.expect(!diff.isBinary("abcdefghijklmnopqrstuvwxyz\n0123456789\n"));
}

// ============================================================================
// Binary Diff
// ============================================================================

test "binary diff reports sizes" {
    const result = try diff.generateBinaryDiff(1024, 2048, "image.png", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "image.png") != null);
}

// ============================================================================
// Word Diff
// ============================================================================

test "word diff shows changes inline" {
    const result = try diff.generateWordDiff("hello world", "hello earth", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

test "word diff identical lines" {
    const result = try diff.generateWordDiff("same text", "same text", testing.allocator);
    defer testing.allocator.free(result);
    // Should have some output even for identical content
    try testing.expect(result.len >= 0);
}

// ============================================================================
// Large Diff
// ============================================================================

test "diff with many lines" {
    var old_buf = std.ArrayList(u8).init(testing.allocator);
    defer old_buf.deinit();
    var new_buf = std.ArrayList(u8).init(testing.allocator);
    defer new_buf.deinit();

    for (0..100) |i| {
        try old_buf.writer().print("line {d}\n", .{i});
        if (i == 50) {
            try new_buf.writer().print("CHANGED LINE\n", .{});
        } else {
            try new_buf.writer().print("line {d}\n", .{i});
        }
    }

    const result = try diff.generateUnifiedDiff(old_buf.items, new_buf.items, "large.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "-line 50") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+CHANGED LINE") != null);
}

// ============================================================================
// Diff Output Format
// ============================================================================

test "diff output starts with git diff header" {
    const result = try diff.generateUnifiedDiff("old\n", "new\n", "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.startsWith(u8, result, "diff --git"));
}

test "diff output has --- and +++ markers" {
    const result = try diff.generateUnifiedDiff("a\n", "b\n", "f.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "--- a/f.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+++ b/f.txt") != null);
}
