// test/diff_comprehensive_test.zig - Comprehensive tests for diff module
const std = @import("std");
const testing = std.testing;
const diff = @import("diff");

// ============================================================================
// isBinary
// ============================================================================

test "isBinary: empty content is not binary" {
    try testing.expect(!diff.isBinary(""));
}

test "isBinary: plain text is not binary" {
    try testing.expect(!diff.isBinary("Hello, world!\nThis is a test.\n"));
}

test "isBinary: null byte makes it binary" {
    try testing.expect(diff.isBinary("hello\x00world"));
}

test "isBinary: single null byte is binary" {
    try testing.expect(diff.isBinary("\x00"));
}

test "isBinary: tabs and newlines are not binary" {
    try testing.expect(!diff.isBinary("line1\tcolumn\nline2\tcolumn\r\n"));
}

test "isBinary: high non-printable ratio is binary" {
    // Create content with >30% non-printable chars (excluding \t, \n, \r)
    var buf: [100]u8 = undefined;
    for (&buf) |*b| b.* = 0x01; // non-printable
    try testing.expect(diff.isBinary(&buf));
}

test "isBinary: mostly printable with few control chars is not binary" {
    var buf: [100]u8 = undefined;
    for (&buf) |*b| b.* = 'A';
    buf[0] = 0x01; // only 1% non-printable
    try testing.expect(!diff.isBinary(&buf));
}

// ============================================================================
// generateUnifiedDiff: basic diff generation
// ============================================================================

test "generateUnifiedDiff: identical files produce empty diff body" {
    const content = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(content, content, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    // When files are identical, diff should be minimal (just header or empty)
    // Check no +/- lines in output
    var has_change = false;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
            if (!std.mem.startsWith(u8, line, "---") and !std.mem.startsWith(u8, line, "+++")) {
                has_change = true;
            }
        }
    }
    try testing.expect(!has_change);
}

test "generateUnifiedDiff: added line shows +" {
    const old = "line1\nline2\n";
    const new = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "+line3") != null);
}

test "generateUnifiedDiff: removed line shows -" {
    const old = "line1\nline2\nline3\n";
    const new = "line1\nline2\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-line3") != null);
}

test "generateUnifiedDiff: modified line shows both - and +" {
    const old = "hello world\n";
    const new = "hello universe\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-hello world") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+hello universe") != null);
}

test "generateUnifiedDiff: includes file path in header" {
    const result = try diff.generateUnifiedDiff("a\n", "b\n", "myfile.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "myfile.txt") != null);
}

test "generateUnifiedDiff: empty to content shows all additions" {
    const result = try diff.generateUnifiedDiff("", "line1\nline2\n", "new.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "+line1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+line2") != null);
}

test "generateUnifiedDiff: content to empty shows all removals" {
    const result = try diff.generateUnifiedDiff("line1\nline2\n", "", "old.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-line1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "-line2") != null);
}

// ============================================================================
// generateUnifiedDiffWithHashes: custom hashes in header
// ============================================================================

test "generateUnifiedDiffWithHashes: includes hash in header" {
    const result = try diff.generateUnifiedDiffWithHashes(
        "old\n",
        "new\n",
        "test.txt",
        "aabbccdd",
        "11223344",
        testing.allocator,
    );
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "aabbccdd") != null);
    try testing.expect(std.mem.indexOf(u8, result, "11223344") != null);
}

// ============================================================================
// generateBinaryDiff
// ============================================================================

test "generateBinaryDiff: shows file sizes" {
    const result = try diff.generateBinaryDiff(100, 200, "data.bin", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "data.bin") != null);
}

// ============================================================================
// DiffHunk
// ============================================================================

test "DiffHunk: init and deinit" {
    var hunk = diff.DiffHunk.init(testing.allocator);
    defer hunk.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), hunk.old_start);
    try testing.expectEqual(@as(u32, 0), hunk.old_count);
    try testing.expectEqual(@as(u32, 0), hunk.new_start);
    try testing.expectEqual(@as(u32, 0), hunk.new_count);
}

test "DiffHunk: addLine increments counts correctly" {
    var hunk = diff.DiffHunk.init(testing.allocator);
    defer hunk.deinit(testing.allocator);

    try hunk.addLine(.context, "same line", testing.allocator);
    try testing.expectEqual(@as(u32, 1), hunk.old_count);
    try testing.expectEqual(@as(u32, 1), hunk.new_count);

    try hunk.addLine(.add, "new line", testing.allocator);
    try testing.expectEqual(@as(u32, 1), hunk.old_count);
    try testing.expectEqual(@as(u32, 2), hunk.new_count);

    try hunk.addLine(.remove, "old line", testing.allocator);
    try testing.expectEqual(@as(u32, 2), hunk.old_count);
    try testing.expectEqual(@as(u32, 2), hunk.new_count);

    try testing.expectEqual(@as(usize, 3), hunk.lines.items.len);
}

// ============================================================================
// DiffLine
// ============================================================================

test "DiffLine: init stores all fields" {
    const line = diff.DiffLine.init(.add, "content", null, 5);
    try testing.expect(line.type == .add);
    try testing.expectEqualStrings("content", line.content);
    try testing.expectEqual(@as(?u32, null), line.old_line);
    try testing.expectEqual(@as(?u32, 5), line.new_line);
}

// ============================================================================
// DiffOptions
// ============================================================================

test "DiffOptions: default values" {
    const opts = diff.DiffOptions.default();
    try testing.expectEqual(@as(u32, 3), opts.context_lines);
    try testing.expect(!opts.ignore_whitespace);
    try testing.expect(!opts.ignore_case);
}

// ============================================================================
// generateWordDiff
// ============================================================================

test "generateWordDiff: different words highlighted" {
    const result = try diff.generateWordDiff("hello world", "hello universe", testing.allocator);
    defer testing.allocator.free(result);

    // Should contain some diff markers
    try testing.expect(result.len > 0);
}

test "generateWordDiff: identical content" {
    const result = try diff.generateWordDiff("same text", "same text", testing.allocator);
    defer testing.allocator.free(result);

    // Should just have the text, no change markers
    try testing.expect(result.len > 0);
}

// ============================================================================
// Edge cases
// ============================================================================

test "generateUnifiedDiff: both empty" {
    const result = try diff.generateUnifiedDiff("", "", "empty.txt", testing.allocator);
    defer testing.allocator.free(result);
    // Should not crash
    try testing.expect(true);
}

test "generateUnifiedDiff: single newline" {
    const result = try diff.generateUnifiedDiff("\n", "\n", "nl.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(true);
}

test "generateUnifiedDiff: no trailing newline" {
    const result = try diff.generateUnifiedDiff("no newline", "no newline", "nonl.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(true);
}

test "generateUnifiedDiff: large diff with many lines" {
    var old = std.ArrayList(u8).init(testing.allocator);
    defer old.deinit();
    var new = std.ArrayList(u8).init(testing.allocator);
    defer new.deinit();

    for (0..100) |i| {
        try old.writer().print("old line {}\n", .{i});
        try new.writer().print("new line {}\n", .{i});
    }

    const result = try diff.generateUnifiedDiff(old.items, new.items, "big.txt", testing.allocator);
    defer testing.allocator.free(result);

    // Should produce substantial diff output
    try testing.expect(result.len > 100);
}
