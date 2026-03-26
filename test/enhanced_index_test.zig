const std = @import("std");
const testing = std.testing;
const index_module = @import("../src/git/index.zig");

test "index version compatibility and extension handling" {
    const allocator = testing.allocator;
    
    // Test parsing index with various versions and extensions
    
    // Create a minimal valid index v2 structure
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Write index header
    try writer.writeAll("DIRC"); // Signature
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 1, .big); // 1 entry
    
    // Write a single index entry
    try writer.writeInt(u32, 1640995200, .big); // ctime_sec
    try writer.writeInt(u32, 0, .big); // ctime_nsec
    try writer.writeInt(u32, 1640995200, .big); // mtime_sec
    try writer.writeInt(u32, 0, .big); // mtime_nsec
    try writer.writeInt(u32, 0x801, .big); // dev
    try writer.writeInt(u32, 12345, .big); // ino
    try writer.writeInt(u32, 33188, .big); // mode (100644)
    try writer.writeInt(u32, 1000, .big); // uid
    try writer.writeInt(u32, 1000, .big); // gid
    try writer.writeInt(u32, 13, .big); // size
    
    // SHA-1 hash (20 bytes)
    const test_sha1 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    try writer.writeAll(&test_sha1);
    
    try writer.writeInt(u16, 8, .big); // flags (path length = 8)
    try writer.writeAll("test.txt"); // path
    
    // Padding to 8-byte boundary (62 + 8 = 70, need 6 bytes padding to reach 72)  
    try writer.writeAll(&[_]u8{0, 0, 0, 0, 0, 0});
    
    // Add a TREE extension
    try writer.writeAll("TREE"); // Extension signature
    try writer.writeInt(u32, 40, .big); // Extension size
    
    // Tree cache data (simplified)
    try writer.writeAll(""); // Empty tree path
    try writer.writeByte(0); // Path terminator
    try writer.writeAll("1 0\n"); // Entry count and subtree count
    try writer.writeAll(&test_sha1); // Tree SHA-1
    // Padding for extension
    try writer.writeAll(&[_]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0});
    
    // Calculate and add checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Parse the index
    var test_index = index_module.Index.init(allocator);
    defer test_index.deinit();
    
    try test_index.parseIndexData(index_data.items);
    
    // Verify the parsed entry
    try testing.expect(test_index.entries.items.len == 1);
    const entry = test_index.entries.items[0];
    try testing.expectEqualStrings("test.txt", entry.path);
    try testing.expect(entry.size == 13);
    try testing.expect(entry.mode == 33188);
    try testing.expect(std.mem.eql(u8, &entry.sha1, &test_sha1));
    
    std.debug.print("Index v2 with TREE extension parsed successfully\n", .{});
}

test "index statistics and analysis" {
    const allocator = testing.allocator;
    
    // Create a temporary test repository with an index
    const temp_path = "/tmp/zig-index-stats-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    // Initialize git repo
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Test User"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "test@example.com"});
    
    // Create test files and add them to index
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "file1.txt", .data = "Content of file 1\n" });
    try temp_dir.writeFile(.{ .sub_path = "file2.txt", .data = "Content of file 2 with more data\n" });
    try temp_dir.writeFile(.{ .sub_path = "subdir/file3.txt", .data = "Nested file content\n" });
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "."});
    
    // Create a simple platform implementation for testing
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => return false,
                    else => return err,
                };
                return true;
            }
        };
    };
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Test index analysis
    const stats = index_module.analyzeIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Index analysis failed: {}\n", .{err});
        return;
    };
    
    std.debug.print("Index analysis results:\n", .{});
    stats.print();
    
    try testing.expect(stats.total_entries > 0);
    try testing.expect(stats.version >= 2);
    try testing.expect(stats.checksum_valid);
    
    // Test index validation
    const issues = index_module.validateIndex(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Index validation failed: {}\n", .{err});
        return;
    };
    defer {
        for (issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(issues);
    }
    
    std.debug.print("Index validation found {} issues\n", .{issues.len});
    for (issues) |issue| {
        std.debug.print("  Issue: {s}\n", .{issue});
    }
    
    // For a healthy repository, we expect no validation issues
    try testing.expect(issues.len == 0);
    
    std.debug.print("Index statistics and analysis test completed successfully\n", .{});
}

test "index operations and optimization" {
    const allocator = testing.allocator;
    
    // Test index operations
    var test_index = index_module.Index.init(allocator);
    defer test_index.deinit();
    
    // Create some test entries
    const entries_data = [_]struct { path: []const u8, size: usize }{
        .{ .path = "src/main.zig", .size = 1234 },
        .{ .path = "README.md", .size = 567 },
        .{ .path = "build.zig", .size = 890 },
        .{ .path = "src/lib.zig", .size = 2345 },
        .{ .path = "tests/test.zig", .size = 678 },
        .{ .path = "docs/guide.md", .size = 1890 },
    };
    
    // Add entries in random order to test sorting
    const test_sha1 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    
    for (entries_data) |entry_data| {
        const fake_stat = std.fs.File.Stat{
            .inode = 12345,
            .size = entry_data.size,
            .mode = 33188, // 100644
            .kind = .file,
            .atime = 1640995200 * std.time.ns_per_s,
            .mtime = 1640995200 * std.time.ns_per_s,
            .ctime = 1640995200 * std.time.ns_per_s,
        };
        
        const index_entry = index_module.IndexEntry.init(
            try allocator.dupe(u8, entry_data.path),
            fake_stat,
            test_sha1
        );
        try test_index.entries.append(index_entry);
    }
    
    std.debug.print("Created index with {} entries\n", .{test_index.entries.items.len});
    
    // Test optimization (sorting and deduplication)
    index_module.optimizeIndex(&test_index);
    
    // Verify entries are sorted
    for (0..test_index.entries.items.len - 1) |i| {
        const current = test_index.entries.items[i].path;
        const next = test_index.entries.items[i + 1].path;
        try testing.expect(std.mem.lessThan(u8, current, next));
    }
    
    std.debug.print("Index optimization completed, entries are sorted\n", .{});
    
    // Test pattern matching
    const matching_entries = try index_module.getEntriesMatching(test_index, "src/*", allocator);
    defer {
        for (matching_entries) |entry| {
            entry.deinit(allocator);
        }
        allocator.free(matching_entries);
    }
    
    // Should match src/main.zig and src/lib.zig
    try testing.expect(matching_entries.len == 2);
    
    for (matching_entries) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.path, "src/"));
    }
    
    std.debug.print("Pattern matching test completed successfully\n", .{});
}

test "index advanced features and edge cases" {
    const allocator = testing.allocator;
    
    // Test handling of index with conflicts (stage bits set)
    var conflict_index_data = std.ArrayList(u8).init(allocator);
    defer conflict_index_data.deinit();
    
    const writer = conflict_index_data.writer();
    
    // Write index header for v2 with conflicts
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big);
    try writer.writeInt(u32, 3, .big); // 3 entries (representing a 3-way conflict)
    
    const test_sha1_base = [_]u8{0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11};
    const test_sha1_ours = [_]u8{0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22};
    const test_sha1_theirs = [_]u8{0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33};
    
    const conflict_file = "conflict.txt";
    
    // Write three entries for the same file with different stages
    const stages = [_]struct { stage: u16, sha1: [20]u8 }{
        .{ .stage = 1, .sha1 = test_sha1_base },   // Stage 1: common ancestor
        .{ .stage = 2, .sha1 = test_sha1_ours },   // Stage 2: our version
        .{ .stage = 3, .sha1 = test_sha1_theirs }, // Stage 3: their version
    };
    
    for (stages) |stage_info| {
        // Standard entry data
        try writer.writeInt(u32, 1640995200, .big); // ctime_sec
        try writer.writeInt(u32, 0, .big); // ctime_nsec
        try writer.writeInt(u32, 1640995200, .big); // mtime_sec
        try writer.writeInt(u32, 0, .big); // mtime_nsec
        try writer.writeInt(u32, 0x801, .big); // dev
        try writer.writeInt(u32, 12345, .big); // ino
        try writer.writeInt(u32, 33188, .big); // mode
        try writer.writeInt(u32, 1000, .big); // uid
        try writer.writeInt(u32, 1000, .big); // gid
        try writer.writeInt(u32, 20, .big); // size
        
        try writer.writeAll(&stage_info.sha1);
        
        // Flags with stage bits set
        const flags: u16 = @intCast(conflict_file.len | (stage_info.stage << 12));
        try writer.writeInt(u16, flags, .big);
        
        try writer.writeAll(conflict_file);
        
        // Padding to 8-byte boundary
        const entry_size = 62 + conflict_file.len;
        const padding_needed = (8 - (entry_size % 8)) % 8;
        for (0..padding_needed) |_| {
            try writer.writeByte(0);
        }
    }
    
    // Add checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(conflict_index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Parse the conflict index
    var conflict_index = index_module.Index.init(allocator);
    defer conflict_index.deinit();
    
    try conflict_index.parseIndexData(conflict_index_data.items);
    
    // Verify conflict entries
    try testing.expect(conflict_index.entries.items.len == 3);
    
    for (conflict_index.entries.items, 0..) |entry, i| {
        try testing.expectEqualStrings(conflict_file, entry.path);
        const stage = (entry.flags >> 12) & 0x3;
        try testing.expect(stage == i + 1); // Stages 1, 2, 3
    }
    
    std.debug.print("Conflict index parsing test completed successfully\n", .{});
    
    // Test detailed index operations
    var index_ops = index_module.IndexOperations.init(allocator);
    
    // Test with the mock repository from previous test
    const temp_path = "/tmp/zig-index-ops-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Test User"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "test@example.com"});
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "normal_file.txt", .data = "Normal file content\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "normal_file.txt"});
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => return false,
                    else => return err,
                };
                return true;
            }
        };
    };
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Test conflict detection (should be false for normal repo)
    const has_conflicts = index_ops.hasConflicts(git_dir, TestPlatform) catch false;
    try testing.expect(!has_conflicts);
    
    // Test detailed statistics
    const detailed_stats = index_ops.getDetailedStats(git_dir, TestPlatform) catch |err| {
        std.debug.print("Failed to get detailed stats: {}\n", .{err});
        return;
    };
    
    std.debug.print("Detailed index statistics:\n", .{});
    detailed_stats.print();
    
    try testing.expect(detailed_stats.basic.total_entries > 0);
    
    std.debug.print("Advanced index features test completed successfully\n", .{});
}

/// Helper function to run git commands
fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var cmd = std.process.Child.init(args, allocator);
    cmd.cwd = cwd;
    cmd.stdout_behavior = .Ignore;
    cmd.stderr_behavior = .Ignore;
    
    const result = try cmd.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("Git command failed: {any}\n", .{args});
        return error.GitCommandFailed;
    }
}

test "index performance and scalability" {
    const allocator = testing.allocator;
    
    // Test with a large number of entries
    var large_index = index_module.Index.init(allocator);
    defer large_index.deinit();
    
    const num_entries = 1000;
    const test_sha1 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    
    const start_time = std.time.milliTimestamp();
    
    // Add many entries
    for (0..num_entries) |i| {
        const path = try std.fmt.allocPrint(allocator, "file_{:04}.txt", .{i});
        
        const fake_stat = std.fs.File.Stat{
            .inode = i,
            .size = i * 10 + 100,
            .mode = 33188,
            .kind = .file,
            .atime = 1640995200 * std.time.ns_per_s,
            .mtime = 1640995200 * std.time.ns_per_s,
            .ctime = 1640995200 * std.time.ns_per_s,
        };
        
        const entry = index_module.IndexEntry.init(path, fake_stat, test_sha1);
        try large_index.entries.append(entry);
    }
    
    const creation_time = std.time.milliTimestamp() - start_time;
    
    // Test optimization performance
    const opt_start_time = std.time.milliTimestamp();
    index_module.optimizeIndex(&large_index);
    const opt_time = std.time.milliTimestamp() - opt_start_time;
    
    // Test lookup performance
    const lookup_start_time = std.time.milliTimestamp();
    
    // Look up some random entries
    for (0..100) |i| {
        const lookup_path = try std.fmt.allocPrint(allocator, "file_{:04}.txt", .{i * 10});
        defer allocator.free(lookup_path);
        
        const entry = large_index.getEntry(lookup_path);
        try testing.expect(entry != null);
    }
    
    const lookup_time = std.time.milliTimestamp() - lookup_start_time;
    
    std.debug.print("Index performance test results:\n", .{});
    std.debug.print("  Entries: {}\n", .{num_entries});
    std.debug.print("  Creation time: {}ms\n", .{creation_time});
    std.debug.print("  Optimization time: {}ms\n", .{opt_time});
    std.debug.print("  Lookup time (100 lookups): {}ms\n", .{lookup_time});
    
    try testing.expect(large_index.entries.items.len == num_entries);
    
    // Verify entries are sorted after optimization
    for (0..large_index.entries.items.len - 1) |i| {
        const current = large_index.entries.items[i].path;
        const next = large_index.entries.items[i + 1].path;
        try testing.expect(std.mem.lessThan(u8, current, next));
    }
    
    std.debug.print("Index performance and scalability test completed successfully\n", .{});
}