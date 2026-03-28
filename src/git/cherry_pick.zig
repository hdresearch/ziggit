// cherry_pick.zig - Git cherry-pick implementation helpers
// This module provides cherry-pick utilities used by both cherry-pick and rebase.

const std = @import("std");

/// Extract the subject (first line) from a commit message
pub fn extractSubject(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, " \t\n\r");
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
        return trimmed[0..nl];
    }
    return trimmed;
}

/// Parse author info from a commit's author line
/// Returns name, email, and date components
pub fn parseAuthorLine(author_line: []const u8) ?struct {
    name: []const u8,
    email: []const u8,
    date: []const u8,
} {
    // Format: "Name <email> timestamp tz"
    const lt = std.mem.indexOfScalar(u8, author_line, '<') orelse return null;
    const gt = std.mem.indexOfScalar(u8, author_line, '>') orelse return null;
    if (gt <= lt) return null;

    const name = std.mem.trim(u8, author_line[0..lt], " \t");
    const email = author_line[lt + 1 .. gt];
    const date = std.mem.trim(u8, author_line[gt + 1 ..], " \t");

    return .{ .name = name, .email = email, .date = date };
}

test "extractSubject" {
    const testing = std.testing;
    try testing.expectEqualStrings("Hello world", extractSubject("Hello world\n\nBody text"));
    try testing.expectEqualStrings("Single line", extractSubject("Single line"));
    try testing.expectEqualStrings("Trimmed", extractSubject("\n\nTrimmed"));
}

test "parseAuthorLine" {
    const testing = std.testing;
    const result = parseAuthorLine("Test User <test@example.com> 1234567890 +0000").?;
    try testing.expectEqualStrings("Test User", result.name);
    try testing.expectEqualStrings("test@example.com", result.email);
    try testing.expectEqualStrings("1234567890 +0000", result.date);
}
