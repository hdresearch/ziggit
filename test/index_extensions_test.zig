const std = @import("std");
const index = @import("../src/git/index.zig");
const testing = std.testing;

test "index extensions and version support comprehensive test" {
    const allocator = testing.allocator;

    // Create a test repository with various index states
    const temp_path = "/tmp/zig-test-index-ext";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var entries = std.ArrayList([]u8).init(alloc);
                errdefer {
                    for (entries.items) |entry| alloc.free(entry);
                    entries.deinit();
                }
                
                var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
                defer dir.close();
                
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    try entries.append(try alloc.dupe(u8, entry.name));
                }
                
                return entries.toOwnedSlice();
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
            }
        };
    };

    // Create various types of files to generate different index states
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "simple.txt", .content = "Simple file content" },
        .{ .name = "subdirectory/nested.txt", .content = "Nested file content" },
        .{ .name = "binary_like.dat", .content = "\x00\x01\x02\x03Binary-like content" },
        .{ .name = "long_name_file_to_test_path_length_handling_in_index.txt", .content = "Long name test" },
        .{ .name = "unicode_ñame.txt", .content = "Unicode filename test" },
    };

    for (files) |file| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_path, file.name });
        defer allocator.free(file_path);

        // Create directory if needed
        if (std.fs.path.dirname(file_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = file.content });

        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", file.name }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }
    }

    // Commit to update index
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit with various file types" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Test basic index loading
    std.debug.print("Testing basic index loading...\n", .{});
    var git_index = index.Index.init(allocator);
    defer git_index.deinit();

    git_index.loadFromFile(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to load index: {}\n", .{err});
        return err;
    };

    try testing.expect(git_index.entries.items.len == files.len);
    std.debug.print("✓ Loaded {} index entries\n", .{git_index.entries.items.len});

    // Verify some entries
    var found_simple = false;
    var found_nested = false;
    var found_unicode = false;

    for (git_index.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "simple.txt")) {
            found_simple = true;
            try testing.expect(entry.mode & 0o100000 != 0); // Regular file
            try testing.expect(entry.size > 0);
        } else if (std.mem.eql(u8, entry.path, "subdirectory/nested.txt")) {
            found_nested = true;
            try testing.expect(entry.size > 0);
        } else if (std.mem.eql(u8, entry.path, "unicode_ñame.txt")) {
            found_unicode = true;
        }
    }

    try testing.expect(found_simple);
    try testing.expect(found_nested);
    try testing.expect(found_unicode);

    // Test index statistics
    std.debug.print("Testing index analysis...\n", .{});
    const stats = index.analyzeIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to analyze index: {}\n", .{err});
        return err;
    };

    try testing.expect(stats.total_entries == files.len);
    try testing.expect(stats.version >= 2 and stats.version <= 4);
    try testing.expect(stats.file_size > 0);
    try testing.expect(stats.checksum_valid);

    std.debug.print("Index statistics:\n", .{});
    stats.print();

    // Test index operations
    std.debug.print("Testing index operations...\n", .{});
    var ops = index.IndexOperations.init(allocator);
    defer ops.deinit();

    const entry_count = ops.getEntryCount(git_dir, TestPlatform) catch |err| {
        std.debug.print("Failed to get entry count: {}\n", .{err});
        return err;
    };

    try testing.expect(entry_count == files.len);
    std.debug.print("✓ Entry count check: {} entries\n", .{entry_count});

    // Test conflict detection (should be false for clean repo)
    const has_conflicts = ops.hasConflicts(git_dir, TestPlatform) catch false;
    try testing.expect(!has_conflicts);
    std.debug.print("✓ Conflict check: no conflicts found\n", .{});

    // Test validation
    std.debug.print("Testing index validation...\n", .{});
    const validation_issues = index.validateIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to validate index: {}\n", .{err});
        return err;
    };
    defer {
        for (validation_issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(validation_issues);
    }

    if (validation_issues.len > 0) {
        std.debug.print("Index validation issues found:\n", .{});
        for (validation_issues) |issue| {
            std.debug.print("  - {s}\n", .{issue});
        }
    } else {
        std.debug.print("✓ Index validation: no issues found\n", .{});
    }

    std.debug.print("✓ All index tests passed!\n", .{});
}

test "index checksum and corruption handling" {
    const allocator = testing.allocator;

    // Create a test repository
    const temp_path = "/tmp/zig-test-index-checksum";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create a file and add it to index
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_path});
    defer allocator.free(test_file);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Test content" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
        };
    };

    // First, verify the index is valid
    std.debug.print("Testing valid index checksum...\n", .{});
    const stats = index.analyzeIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to analyze index: {}\n", .{err});
        return err;
    };

    try testing.expect(stats.checksum_valid);
    std.debug.print("✓ Valid index checksum verified\n", .{});

    // Test with a truncated index file (simulate corruption)
    std.debug.print("Testing truncated index handling...\n", .{});
    const original_index = try std.fs.cwd().readFileAlloc(allocator, index_path, 10 * 1024 * 1024);
    defer allocator.free(original_index);

    // Create truncated version (remove checksum)
    if (original_index.len > 20) {
        const truncated_index = original_index[0..original_index.len - 20];
        try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = truncated_index });

        const truncated_stats = index.analyzeIndex(git_dir, TestPlatform, allocator) catch {
            std.debug.print("✓ Correctly detected truncated index as invalid\n", .{});
            
            // Restore original
            try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = original_index });
            return;
        };

        // If we get here, the truncated index was somehow parsed
        try testing.expect(!truncated_stats.checksum_valid);
        std.debug.print("✓ Truncated index marked as invalid checksum\n", .{});
    }

    // Restore original index
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = original_index });

    // Test with corrupted data (flip some bytes in the middle)
    std.debug.print("Testing corrupted index data handling...\n", .{});
    if (original_index.len > 100) {
        var corrupted_index = try allocator.dupe(u8, original_index);
        defer allocator.free(corrupted_index);

        // Flip some bytes in the middle (not affecting header or checksum position)
        corrupted_index[50] ^= 0xFF;
        corrupted_index[60] ^= 0xFF;
        corrupted_index[70] ^= 0xFF;

        try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = corrupted_index });

        const corrupted_stats = index.analyzeIndex(git_dir, TestPlatform, allocator) catch {
            std.debug.print("✓ Correctly detected corrupted index\n", .{});
            
            // Restore original
            try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = original_index });
            return;
        };

        // The checksum should detect corruption
        try testing.expect(!corrupted_stats.checksum_valid);
        std.debug.print("✓ Corrupted index detected via checksum\n", .{});
    }

    // Restore original index
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = original_index });

    std.debug.print("✓ All index corruption tests passed!\n", .{});
}

test "index large file and performance" {
    const allocator = testing.allocator;

    // Create a test repository with many files
    const temp_path = "/tmp/zig-test-index-large";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create multiple files (but not too many for CI performance)
    const num_files = 20;
    std.debug.print("Creating {} test files...\n", .{num_files});

    for (0..num_files) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d:0>3}.txt", .{ temp_path, i });
        defer allocator.free(filename);

        const content = try std.fmt.allocPrint(allocator, "Content for file number {d}\nSecond line\nThird line\n", .{i});
        defer allocator.free(content);

        try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = content });

        const short_name = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(short_name);

        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", short_name }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }
    }

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 50 * 1024 * 1024);
            }
        };
    };

    // Measure index loading performance
    std.debug.print("Testing index loading performance...\n", .{});
    
    const start_time = std.time.nanoTimestamp();
    
    var git_index = index.Index.init(allocator);
    defer git_index.deinit();

    git_index.loadFromFile(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to load large index: {}\n", .{err});
        return err;
    };

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @divTrunc(end_time - start_time, 1_000_000);

    std.debug.print("✓ Loaded {} entries in {}ms\n", .{ git_index.entries.items.len, duration_ms });
    try testing.expect(git_index.entries.items.len == num_files);

    // Test index analysis performance
    const analyze_start = std.time.nanoTimestamp();
    
    const stats = index.analyzeIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to analyze large index: {}\n", .{err});
        return err;
    };

    const analyze_end = std.time.nanoTimestamp();
    const analyze_duration_ms = @divTrunc(analyze_end - analyze_start, 1_000_000);

    std.debug.print("✓ Analyzed index in {}ms\n", .{analyze_duration_ms});
    try testing.expect(stats.total_entries == num_files);
    try testing.expect(stats.checksum_valid);

    // Performance should be reasonable (under 100ms for 20 files)
    try testing.expect(duration_ms < 100);
    try testing.expect(analyze_duration_ms < 100);

    std.debug.print("✓ All index performance tests passed!\n", .{});
}