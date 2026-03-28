// rebase_cmd.zig - Git rebase command implementation helpers
// This module provides additional rebase utilities and fixes.
// The main rebase dispatch remains in main_common.zig but uses helpers from here.

const std = @import("std");

/// Validate a whitespace option value for rebase --apply
pub fn validateWhitespaceOption(value: []const u8) bool {
    const valid = [_][]const u8{ "nowarn", "warn", "fix", "error", "error-all" };
    for (valid) |v| {
        if (std.mem.eql(u8, value, v)) return true;
    }
    return false;
}

/// Validate an exec command for rebase -x/--exec
pub fn validateExecCommand(cmd: []const u8) enum { ok, empty, has_newline } {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    if (trimmed.len == 0) return .empty;
    if (std.mem.indexOfScalar(u8, cmd, '\n') != null) return .has_newline;
    return .ok;
}

/// Determine the reflog action label for a rebase continue step
/// In apply mode, continue becomes "pick"; in merge mode it stays "continue"
pub fn getContinueReflogAction(is_apply_mode: bool) []const u8 {
    return if (is_apply_mode) "pick" else "continue";
}

/// Parse a rebase todo line and extract the command and hash
pub fn parseTodoLine(line: []const u8) ?struct { command: []const u8, hash: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    // Format: <command> <hash> [optional message]
    const space1 = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const command = trimmed[0..space1];
    const rest = std.mem.trimLeft(u8, trimmed[space1 + 1 ..], " ");
    // Hash may be followed by a space and message
    const hash_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const hash = rest[0..hash_end];

    return .{ .command = command, .hash = hash };
}

test "validateExecCommand" {
    const testing = std.testing;
    try testing.expectEqual(validateExecCommand("echo hello"), .ok);
    try testing.expectEqual(validateExecCommand(""), .empty);
    try testing.expectEqual(validateExecCommand("  "), .empty);
    try testing.expectEqual(validateExecCommand("a\nb"), .has_newline);
}

test "parseTodoLine" {
    const testing = std.testing;
    const result = parseTodoLine("pick abc123 Some message").?;
    try testing.expectEqualStrings("pick", result.command);
    try testing.expectEqualStrings("abc123", result.hash);

    try testing.expect(parseTodoLine("# comment") == null);
    try testing.expect(parseTodoLine("") == null);
}
