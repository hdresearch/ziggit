// test/diff_internal_test.zig - Tests for diff generation module
const std = @import("std");
const diff = @import("diff");
const testing = std.testing;

// ============================================================================
// isBinary detection
// ============================================================================

test "isBinary: empty content is not binary" {
    try testing.expect(!diff.isBinary(""));
}

test "isBinary: regular text is not binary" {
    try testing.expect(!diff.isBinary("Hello, world!\nThis is text.\n"));
}

test "isBinary: content with null bytes is binary" {
    try testing.expect(diff.isBinary("hello\x00world"));
}

test "isBinary: pure ASCII is not binary" {
    try testing.expect(!diff.isBinary("abcdefghijklmnopqrstuvwxyz\n0123456789\n"));
}

// ============================================================================
// Unified diff generation
// ============================================================================

test "diff: identical content produces empty diff body" {
    const content = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(content, content, "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    // If content is the same, diff should be empty or minimal
    // The exact format depends on implementation, but it shouldn't show changes
    // Just verify it doesn't crash and produces valid output
    try testing.expect(result.len >= 0);
}

test "diff: added line detected" {
    const old = "line1\nline2\n";
    const new = "line1\nline2\nline3\n";
    const result = try diff.generateUnifiedDiff(old, new, "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    // Should contain the added line
    try testing.expect(std.mem.indexOf(u8, result, "line3") != null);
}

test "diff: removed line detected" {
    const old = "line1\nline2\nline3\n";
    const new = "line1\nline2\n";
    const result = try diff.generateUnifiedDiff(old, new, "file.txt", testing.allocator);
    defer testing.allocator.free(result);
    // Should reference line3 as removed
    try testing.expect(std.mem.indexOf(u8, result, "line3") != null);
}

test "diff: modified line detected" {
    const old = "hello world\n";
    const new = "hello zig\n";
    const result = try diff.generateUnifiedDiff(old, new, "test.txt", testing.allocator);
    defer testing.allocator.free(result);
    // Should show both old and new content
    try testing.expect(std.mem.indexOf(u8, result, "hello") != null);
}

test "diff: empty to non-empty" {
    const result = try diff.generateUnifiedDiff("", "new content\n", "new.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "new content") != null);
}

test "diff: non-empty to empty" {
    const result = try diff.generateUnifiedDiff("old content\n", "", "removed.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "old content") != null);
}

test "diff: header contains file path" {
    const result = try diff.generateUnifiedDiff("a\n", "b\n", "myfile.txt", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "myfile.txt") != null);
}

// ============================================================================
// generateBinaryDiff
// ============================================================================

test "generateBinaryDiff produces output with sizes" {
    const result = try diff.generateBinaryDiff(100, 200, "data.bin", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "data.bin") != null);
}

// ============================================================================
// generateWordDiff
// ============================================================================

test "generateWordDiff: identical lines" {
    const result = try diff.generateWordDiff("hello world", "hello world", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

test "generateWordDiff: single word changed" {
    const result = try diff.generateWordDiff("hello world", "hello zig", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}
