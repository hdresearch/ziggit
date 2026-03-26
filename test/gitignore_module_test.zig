// test/gitignore_module_test.zig - Tests for gitignore pattern matching
const std = @import("std");
const gitignore = @import("gitignore");
const testing = std.testing;

// ============================================================
// GitignoreEntry tests
// ============================================================

test "GitignoreEntry.init: creates entry with pattern" {
    var entry = try gitignore.GitignoreEntry.init("*.log", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.log", entry.pattern);
}

test "GitignoreEntry.init: trims whitespace" {
    var entry = try gitignore.GitignoreEntry.init("  *.log  ", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.log", entry.pattern);
}

test "GitignoreEntry.init: trims tabs" {
    var entry = try gitignore.GitignoreEntry.init("\t*.log\t", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("*.log", entry.pattern);
}

test "GitignoreEntry.matches: exact match" {
    var entry = try gitignore.GitignoreEntry.init("file.txt", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(entry.matches("file.txt", false));
}

test "GitignoreEntry.matches: no match on different name" {
    var entry = try gitignore.GitignoreEntry.init("file.txt", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(!entry.matches("other.txt", false));
}

test "GitignoreEntry.matches: exact match for directory pattern" {
    var entry = try gitignore.GitignoreEntry.init("node_modules", testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expect(entry.matches("node_modules", true));
}

// ============================================================
// GitIgnore collection tests
// ============================================================

test "GitIgnore.init: creates empty ignore list" {
    var ignore = gitignore.GitIgnore.init(testing.allocator);
    defer ignore.deinit();
    try testing.expectEqual(@as(usize, 0), ignore.entries.items.len);
}

test "GitIgnore.isIgnored: returns false on empty list" {
    var ignore = gitignore.GitIgnore.init(testing.allocator);
    defer ignore.deinit();
    try testing.expect(!ignore.isIgnored("anything.txt"));
}

test "GitIgnore.isIgnored: stub always returns false (not yet implemented)" {
    // NOTE: isIgnored is currently a stub that always returns false.
    // These tests verify the current behavior. When implemented, update tests.
    var ignore = gitignore.GitIgnore.init(testing.allocator);
    defer ignore.deinit();

    const entry = try gitignore.GitignoreEntry.init("build", testing.allocator);
    try ignore.entries.append(entry);

    // Current stub behavior: always returns false
    try testing.expect(!ignore.isIgnored("build"));
    try testing.expect(!ignore.isIgnored("src"));
}

test "GitIgnore: entries are stored correctly" {
    var ignore = gitignore.GitIgnore.init(testing.allocator);
    defer ignore.deinit();

    const e1 = try gitignore.GitignoreEntry.init("build", testing.allocator);
    try ignore.entries.append(e1);
    const e2 = try gitignore.GitignoreEntry.init("dist", testing.allocator);
    try ignore.entries.append(e2);
    const e3 = try gitignore.GitignoreEntry.init(".env", testing.allocator);
    try ignore.entries.append(e3);

    try testing.expectEqual(@as(usize, 3), ignore.entries.items.len);
    try testing.expectEqualStrings("build", ignore.entries.items[0].pattern);
    try testing.expectEqualStrings("dist", ignore.entries.items[1].pattern);
    try testing.expectEqualStrings(".env", ignore.entries.items[2].pattern);
}

test "GitIgnoreEntry.matches: uses exact string comparison" {
    var entry = try gitignore.GitignoreEntry.init("Build", testing.allocator);
    defer entry.deinit(testing.allocator);

    // Matches is exact string comparison
    try testing.expect(entry.matches("Build", false));
    try testing.expect(!entry.matches("build", false));
    try testing.expect(!entry.matches("BUILD", false));
}
