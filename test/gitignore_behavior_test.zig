// test/gitignore_behavior_test.zig - Tests documenting current gitignore behavior
const std = @import("std");
const testing = std.testing;
const gitignore = @import("gitignore");

// ============================================================================
// GitignoreEntry
// ============================================================================

test "GitignoreEntry.init: stores pattern" {
    const entry = try gitignore.GitignoreEntry.init("*.o", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.o", entry.pattern);
}

test "GitignoreEntry.init: trims whitespace" {
    const entry = try gitignore.GitignoreEntry.init("  *.o  ", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.o", entry.pattern);
}

test "GitignoreEntry.init: trims tabs and carriage returns" {
    const entry = try gitignore.GitignoreEntry.init("\t*.o\r", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.o", entry.pattern);
}

test "GitignoreEntry.matches: exact match" {
    const entry = try gitignore.GitignoreEntry.init("build", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(entry.matches("build", false));
}

test "GitignoreEntry.matches: no match for different string" {
    const entry = try gitignore.GitignoreEntry.init("build", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(!entry.matches("src", false));
}

test "GitignoreEntry.matches: exact match required (no glob)" {
    // Current implementation does exact string matching, not glob
    const entry = try gitignore.GitignoreEntry.init("*.o", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(!entry.matches("test.o", false));
    try testing.expect(entry.matches("*.o", false));
}

// ============================================================================
// GitIgnore
// ============================================================================

test "GitIgnore.init and deinit" {
    var gi = gitignore.GitIgnore.init(testing.allocator);
    defer gi.deinit();
    try testing.expectEqual(@as(usize, 0), gi.entries.items.len);
}

test "GitIgnore.isIgnored: always returns false (stub)" {
    var gi = gitignore.GitIgnore.init(testing.allocator);
    defer gi.deinit();

    // Current implementation is a stub that always returns false
    try testing.expect(!gi.isIgnored("anything"));
    try testing.expect(!gi.isIgnored("*.o"));
    try testing.expect(!gi.isIgnored("build/"));
    try testing.expect(!gi.isIgnored(""));
}

test "GitIgnore: add entries manually" {
    var gi = gitignore.GitIgnore.init(testing.allocator);
    defer gi.deinit();

    const entry1 = try gitignore.GitignoreEntry.init("build", testing.allocator);
    try gi.entries.append(entry1);

    const entry2 = try gitignore.GitignoreEntry.init("*.o", testing.allocator);
    try gi.entries.append(entry2);

    try testing.expectEqual(@as(usize, 2), gi.entries.items.len);
    try testing.expectEqualStrings("build", gi.entries.items[0].pattern);
    try testing.expectEqualStrings("*.o", gi.entries.items[1].pattern);
}

// ============================================================================
// PatternType enum
// ============================================================================

test "PatternType: all variants exist" {
    const types = [_]gitignore.PatternType{ .ignore, .unignore, .directory };
    try testing.expectEqual(@as(usize, 3), types.len);
}

test "GitignoreEntry: default pattern_type is ignore" {
    const entry = try gitignore.GitignoreEntry.init("test", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqual(gitignore.PatternType.ignore, entry.pattern_type);
}

test "GitignoreEntry: default is_absolute is false" {
    const entry = try gitignore.GitignoreEntry.init("test", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(!entry.is_absolute);
}

test "GitignoreEntry: default has_wildcard is false" {
    const entry = try gitignore.GitignoreEntry.init("test", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(!entry.has_wildcard);
}
