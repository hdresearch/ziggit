const std = @import("std");
const testing = std.testing;
const gitignore = @import("../src/git/gitignore.zig");

test "gitignore entry pattern types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test normal ignore pattern
    const entry1 = try gitignore.GitignoreEntry.init("*.log", allocator);
    try testing.expect(entry1.pattern_type == .ignore);
    try testing.expect(!entry1.is_absolute);
    try testing.expect(entry1.has_wildcard);
    
    // Test negation pattern
    const entry2 = try gitignore.GitignoreEntry.init("!important.log", allocator);
    try testing.expect(entry2.pattern_type == .unignore);
    try testing.expectEqualSlices(u8, entry2.pattern, "important.log");
    
    // Test directory pattern
    const entry3 = try gitignore.GitignoreEntry.init("temp/", allocator);
    try testing.expect(entry3.pattern_type == .directory);
    try testing.expectEqualSlices(u8, entry3.pattern, "temp");
    
    // Test absolute pattern
    const entry4 = try gitignore.GitignoreEntry.init("/root.txt", allocator);
    try testing.expect(entry4.is_absolute);
    try testing.expectEqualSlices(u8, entry4.pattern, "root.txt");
}

test "gitignore pattern matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test simple wildcard patterns
    const entry1 = try gitignore.GitignoreEntry.init("*.log", allocator);
    try testing.expect(entry1.matches("error.log", false));
    try testing.expect(entry1.matches("debug.log", false));
    try testing.expect(!entry1.matches("error.txt", false));
    try testing.expect(!entry1.matches("log", false));
    
    // Test directory patterns
    const entry2 = try gitignore.GitignoreEntry.init("temp/", allocator);
    try testing.expect(entry2.matches("temp", true));  // Directory matches
    try testing.expect(!entry2.matches("temp", false)); // File doesn't match
    try testing.expect(!entry2.matches("temporary", true));
    
    // Test absolute patterns
    const entry3 = try gitignore.GitignoreEntry.init("/config.txt", allocator);
    try testing.expect(entry3.matches("config.txt", false));
    try testing.expect(!entry3.matches("src/config.txt", false)); // Should not match in subdirectory
}

test "gitignore pattern container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    try patterns.addPattern("*.log");
    try patterns.addPattern("temp/");
    try patterns.addPattern("!important.log");
    
    // Test that normal log files are ignored
    try testing.expect(patterns.isIgnored("error.log", false));
    try testing.expect(patterns.isIgnored("debug.log", false));
    
    // Test that important.log is not ignored due to negation
    try testing.expect(!patterns.isIgnored("important.log", false));
    
    // Test directory matching
    try testing.expect(patterns.isIgnored("temp", true));
    try testing.expect(!patterns.isIgnored("temp", false));
}

test "gitignore content parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const content = 
        \\# This is a comment
        \\*.log
        \\
        \\temp/
        \\!important.log
        \\   # Another comment
        \\/absolute.txt
        \\
    ;
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    try patterns.parseContent(content);
    
    // Should have 4 patterns (comments and empty lines ignored)
    try testing.expect(patterns.entries.items.len == 4);
    
    // Test each pattern
    try testing.expectEqualSlices(u8, patterns.entries.items[0].pattern, "*.log");
    try testing.expect(patterns.entries.items[0].pattern_type == .ignore);
    
    try testing.expectEqualSlices(u8, patterns.entries.items[1].pattern, "temp");
    try testing.expect(patterns.entries.items[1].pattern_type == .directory);
    
    try testing.expectEqualSlices(u8, patterns.entries.items[2].pattern, "important.log");
    try testing.expect(patterns.entries.items[2].pattern_type == .unignore);
    
    try testing.expectEqualSlices(u8, patterns.entries.items[3].pattern, "absolute.txt");
    try testing.expect(patterns.entries.items[3].is_absolute);
}

test "glob pattern matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test simple wildcards
    const entry1 = try gitignore.GitignoreEntry.init("test*.txt", allocator);
    try testing.expect(entry1.matches("test.txt", false));
    try testing.expect(entry1.matches("test123.txt", false));
    try testing.expect(entry1.matches("testing.txt", false));
    try testing.expect(!entry1.matches("test.log", false));
    try testing.expect(!entry1.matches("mytest.txt", false));
    
    // Test question mark wildcard
    const entry2 = try gitignore.GitignoreEntry.init("file?.txt", allocator);
    try testing.expect(entry2.matches("file1.txt", false));
    try testing.expect(entry2.matches("filea.txt", false));
    try testing.expect(!entry2.matches("file.txt", false));
    try testing.expect(!entry2.matches("file12.txt", false));
    
    // Test double star wildcard
    const entry3 = try gitignore.GitignoreEntry.init("**/temp.txt", allocator);
    try testing.expect(entry3.matches("temp.txt", false));
    try testing.expect(entry3.matches("src/temp.txt", false));
    try testing.expect(entry3.matches("deep/nested/dir/temp.txt", false));
    try testing.expect(!entry3.matches("temp.log", false));
}

test "gitignore precedence with negation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    // Add patterns in specific order to test precedence
    try patterns.addPattern("*.log");        // Ignore all .log files
    try patterns.addPattern("!debug.log");   // Except debug.log
    try patterns.addPattern("debug.log");    // But ignore debug.log again
    
    // The last pattern should win
    try testing.expect(patterns.isIgnored("error.log", false));   // Ignored by first pattern
    try testing.expect(patterns.isIgnored("debug.log", false));   // Ignored by last pattern
    try testing.expect(patterns.isIgnored("warning.log", false)); // Ignored by first pattern
}

test "complex gitignore scenarios" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    // Set up realistic patterns
    try patterns.addPattern("node_modules/");
    try patterns.addPattern("*.log");
    try patterns.addPattern("dist/");
    try patterns.addPattern("!dist/README.md");
    try patterns.addPattern("*.tmp");
    try patterns.addPattern("/config.json");
    try patterns.addPattern("**/cache/**");
    
    // Test various paths
    try testing.expect(patterns.isIgnored("node_modules", true));
    try testing.expect(patterns.isIgnored("node_modules/package.json", false));
    try testing.expect(patterns.isIgnored("error.log", false));
    try testing.expect(patterns.isIgnored("dist", true));
    try testing.expect(!patterns.isIgnored("dist/README.md", false)); // Negated
    try testing.expect(patterns.isIgnored("temp.tmp", false));
    try testing.expect(patterns.isIgnored("config.json", false)); // Absolute pattern
    try testing.expect(!patterns.isIgnored("src/config.json", false)); // Not absolute
    try testing.expect(patterns.isIgnored("deep/cache/nested/file.txt", false));
}

test "default patterns creation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test Zig project patterns
    var zig_patterns = try gitignore.createDefaultPatterns(allocator, "zig");
    defer zig_patterns.deinit();
    
    try testing.expect(zig_patterns.isIgnored("zig-cache", true));
    try testing.expect(zig_patterns.isIgnored("zig-out", true));
    try testing.expect(zig_patterns.isIgnored("test.tmp", false));
    try testing.expect(zig_patterns.isIgnored("lib.o", false));
    
    // Test Node.js project patterns
    var node_patterns = try gitignore.createDefaultPatterns(allocator, "node");
    defer node_patterns.deinit();
    
    try testing.expect(node_patterns.isIgnored("node_modules", true));
    try testing.expect(node_patterns.isIgnored("dist", true));
    try testing.expect(node_patterns.isIgnored("npm-debug.log", false));
    
    // Test Python project patterns
    var python_patterns = try gitignore.createDefaultPatterns(allocator, "python");
    defer python_patterns.deinit();
    
    try testing.expect(python_patterns.isIgnored("__pycache__", true));
    try testing.expect(python_patterns.isIgnored("test.pyc", false));
    try testing.expect(python_patterns.isIgnored("venv", true));
}

test "pattern string extraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    try patterns.addPattern("*.log");
    try patterns.addPattern("temp/");
    try patterns.addPattern("!important.log");
    
    const pattern_strings = try patterns.getPatternStrings(allocator);
    defer allocator.free(pattern_strings);
    
    try testing.expect(pattern_strings.len == 3);
    try testing.expectEqualSlices(u8, pattern_strings[0], "*.log");
    try testing.expectEqualSlices(u8, pattern_strings[1], "temp");
    try testing.expectEqualSlices(u8, pattern_strings[2], "important.log");
}

test "edge cases and malformed patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var patterns = gitignore.GitignorePattern.init(allocator);
    defer patterns.deinit();
    
    // Test empty and whitespace patterns
    try patterns.addPattern("");     // Empty pattern
    try patterns.addPattern("   ");  // Whitespace only
    try patterns.addPattern("!!");   // Double negation
    try patterns.addPattern("//");   // Double slash
    
    // Should handle gracefully without crashing
    try testing.expect(!patterns.isIgnored("test.txt", false));
    
    // Test very long pattern
    var long_pattern = try allocator.alloc(u8, 1000);
    defer allocator.free(long_pattern);
    @memset(long_pattern, 'a');
    
    try patterns.addPattern(long_pattern);
    try testing.expect(!patterns.isIgnored("test.txt", false));
}