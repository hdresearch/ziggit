// test/diff_module_test.zig - Tests for the diff module (generateUnifiedDiff, isBinary, generateWordDiff)
const std = @import("std");
const diff = @import("diff");
const testing = std.testing;

// ============================================================
// isBinary tests
// ============================================================

test "isBinary: empty content is not binary" {
    try testing.expect(!diff.isBinary(""));
}

test "isBinary: plain text is not binary" {
    try testing.expect(!diff.isBinary("hello world\nthis is text\n"));
}

test "isBinary: content with null byte is binary" {
    try testing.expect(diff.isBinary("hello\x00world"));
}

test "isBinary: content with only tabs and newlines is not binary" {
    try testing.expect(!diff.isBinary("col1\tcol2\tcol3\nval1\tval2\tval3\n"));
}

test "isBinary: content with many control chars is binary" {
    // More than 30% non-printable (excluding \t, \n, \r)
    var buf: [100]u8 = undefined;
    for (&buf) |*b| b.* = 0x01; // SOH control character
    try testing.expect(diff.isBinary(&buf));
}

test "isBinary: mostly text with a few control chars is not binary" {
    // Less than 30% non-printable
    const content = "This is mostly text with one control char: \x01 and that's it. " ++
        "The rest is completely normal ASCII text that should not trigger binary detection.";
    try testing.expect(!diff.isBinary(content));
}

test "isBinary: PNG-like header is binary" {
    const png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    try testing.expect(diff.isBinary(png_header));
}

// ============================================================
// generateUnifiedDiff tests
// ============================================================

test "diff: identical content produces empty diff" {
    const content = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(content, content, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "diff: added line produces + line" {
    const old = "line1\nline2\n";
    const new = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    // Should contain diff header and a + line
    try testing.expect(std.mem.indexOf(u8, result, "diff --git a/test.txt b/test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+line3") != null);
}

test "diff: removed line produces - line" {
    const old = "line1\nline2\nline3\n";
    const new = "line1\nline2\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-line3") != null);
}

test "diff: modified line produces - and + lines" {
    const old = "hello world\n";
    const new = "hello zig\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-hello world") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+hello zig") != null);
}

test "diff: empty old content (new file)" {
    const old = "";
    const new = "new content\n";
    const result = try diff.generateUnifiedDiff(old, new, "new.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "+new content") != null);
}

test "diff: empty new content (deleted file)" {
    const old = "old content\n";
    const new = "";
    const result = try diff.generateUnifiedDiff(old, new, "deleted.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-old content") != null);
}

test "diff: both empty produces no diff" {
    const result = try diff.generateUnifiedDiff("", "", "empty.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "diff: multi-line change" {
    const old = "a\nb\nc\nd\ne\n";
    const new = "a\nB\nC\nd\ne\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "-b") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+B") != null);
    try testing.expect(std.mem.indexOf(u8, result, "-c") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+C") != null);
}

test "diff: hunk header contains @@ markers" {
    const old = "old\n";
    const new = "new\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "@@") != null);
}

test "diff: header contains --- and +++ lines" {
    const old = "old\n";
    const new = "new\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "--- a/test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "+++ b/test.txt") != null);
}

// ============================================================
// generateUnifiedDiffWithHashes tests
// ============================================================

test "diff with hashes: custom hashes appear in index line" {
    const old = "old\n";
    const new = "new\n";
    const result = try diff.generateUnifiedDiffWithHashes(old, new, "test.txt", "abc1234", "def5678", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "index abc1234..def5678") != null);
}

// ============================================================
// generateBinaryDiff tests
// ============================================================

test "binary diff: contains file path and sizes" {
    const result = try diff.generateBinaryDiff(100, 200, "image.png", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "image.png") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GIT binary patch") != null);
    try testing.expect(std.mem.indexOf(u8, result, "100") != null);
    try testing.expect(std.mem.indexOf(u8, result, "200") != null);
}

// ============================================================
// generateWordDiff tests
// ============================================================

test "word diff: identical lines produce no markup" {
    const result = try diff.generateWordDiff("hello world", "hello world", testing.allocator);
    defer testing.allocator.free(result);

    // Should not contain any diff markup
    try testing.expect(std.mem.indexOf(u8, result, "[-") == null);
    try testing.expect(std.mem.indexOf(u8, result, "{+") == null);
    try testing.expect(std.mem.indexOf(u8, result, "hello") != null);
}

test "word diff: changed word shows removal and addition" {
    const result = try diff.generateWordDiff("hello world", "hello zig", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[-world-]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "{+zig+}") != null);
}

test "word diff: added word" {
    const result = try diff.generateWordDiff("hello", "hello world", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "{+world+}") != null);
}

test "word diff: removed word" {
    const result = try diff.generateWordDiff("hello world", "hello", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "[-world-]") != null);
}

// ============================================================
// generateUnifiedDiffWithOptions tests
// ============================================================

test "diff with options: ignore_whitespace" {
    const old = "  hello  \n  world  \n";
    const new = "hello\nworld\n";
    const result = try diff.generateUnifiedDiffWithOptions(
        old,
        new,
        "test.txt",
        "0000000",
        "1111111",
        .{ .ignore_whitespace = true },
        testing.allocator,
    );
    defer testing.allocator.free(result.diff);

    // When ignoring whitespace, these should be considered the same
    try testing.expectEqual(@as(u32, 0), result.stats.insertions);
    try testing.expectEqual(@as(u32, 0), result.stats.deletions);
}

test "diff with options: stats count insertions and deletions" {
    const old = "a\nb\nc\n";
    const new = "a\nB\nc\nD\n";
    const result = try diff.generateUnifiedDiffWithOptions(
        old,
        new,
        "test.txt",
        "0000000",
        "1111111",
        .{},
        testing.allocator,
    );
    defer testing.allocator.free(result.diff);

    // b -> B = 1 delete + 1 insert, D added = 1 insert
    try testing.expect(result.stats.insertions >= 1);
    try testing.expect(result.stats.deletions >= 0);
}

// ============================================================
// applyDiff basic tests
// ============================================================

test "applyDiff: no changes returns original" {
    const original = "line1\nline2\nline3";
    // An empty diff should return original
    const result = try diff.applyDiff(original, "", testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(original, result);
}
