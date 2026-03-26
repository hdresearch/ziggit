const std = @import("std");
const index = @import("../src/git/index.zig");
const print = std.debug.print;

// Simple platform implementation for testing
const TestPlatform = struct {
    const Self = @This();

    const TestFs = struct {
        fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        }

        fn writeFile(file_path: []const u8, content: []const u8) !void {
            try std.fs.cwd().writeFile(file_path, content);
        }

        fn makeDir(dir_path: []const u8) !void {
            try std.fs.cwd().makePath(dir_path);
        }

        fn exists(file_path: []const u8) !bool {
            std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
    };

    const fs = TestFs{};
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🧪 Testing comprehensive git index functionality...\n");
    
    const platform = TestPlatform{};
    
    // Test index format support
    print("📋 Testing index format support...\n");
    try testIndexFormats(platform, allocator);
    
    // Test extension handling
    print("🔧 Testing extension handling...\n");
    try testExtensionHandling(allocator);
    
    // Test checksum verification
    print("🔒 Testing checksum verification...\n");
    try testChecksumVerification(allocator);
    
    // Test index validation and analysis
    print("📊 Testing index validation and analysis...\n");
    try testIndexAnalysis(platform, allocator);
    
    print("✅ All index tests completed successfully!\n");
}

fn testIndexFormats(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test directory structure
    try std.fs.cwd().makePath("test_index/.git");
    defer std.fs.cwd().deleteTree("test_index") catch {};
    
    // Test creating and reading a basic index
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    // Create a fake file stat for testing
    const fake_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 26,
        .mode = 33188, // 100644 in octal
        .kind = .file,
        .atime = 1640995200000000000, // 2022-01-01 00:00:00 UTC in nanoseconds
        .mtime = 1640995200000000000,
        .ctime = 1640995200000000000,
    };
    
    // Create test SHA-1 hash
    var test_sha1: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&test_sha1, "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    
    // Create test entry
    const test_entry = index.IndexEntry.init(
        try allocator.dupe(u8, "test_file.txt"), 
        fake_stat, 
        test_sha1
    );
    try test_index.entries.append(test_entry);
    
    // Save index
    try test_index.save("test_index/.git", platform);
    
    // Load index back
    var loaded_index = index.Index.load("test_index/.git", platform, allocator) catch |err| {
        print("Failed to load index: {}\n", .{err});
        return err;
    };
    defer loaded_index.deinit();
    
    // Verify loaded index
    if (loaded_index.entries.items.len != 1) return error.WrongEntryCount;
    
    const loaded_entry = loaded_index.entries.items[0];
    if (!std.mem.eql(u8, loaded_entry.path, "test_file.txt")) return error.PathMismatch;
    if (loaded_entry.size != 26) return error.SizeMismatch;
    if (!std.mem.eql(u8, &loaded_entry.sha1, &test_sha1)) return error.HashMismatch;
    
    print("✅ Basic index format test successful\n");
}

fn testExtensionHandling(allocator: std.mem.Allocator) !void {
    // Create an index with mock extensions to test parsing
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const writer = buffer.writer();
    
    // Index header
    try writer.writeAll("DIRC"); // Signature
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 0, .big); // No entries for this test
    
    // Add a mock TREE extension
    try writer.writeAll("TREE"); // Extension signature
    try writer.writeInt(u32, 8, .big); // Extension size
    try writer.writeAll("mockdata"); // 8 bytes of mock data
    
    // Add a mock REUC extension  
    try writer.writeAll("REUC"); // Extension signature
    try writer.writeInt(u32, 12, .big); // Extension size
    try writer.writeAll("resolveundo!"); // 12 bytes of mock data
    
    // Calculate and write SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Parse the index with extensions
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    test_index.parseIndexData(buffer.items) catch |err| {
        print("Extension parsing failed: {}\n", .{err});
        return err;
    };
    
    print("✅ Extension handling test successful (extensions skipped without crashing)\n");
}

fn testChecksumVerification(allocator: std.mem.Allocator) !void {
    // Create valid index with correct checksum
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const writer = buffer.writer();
    
    try writer.writeAll("DIRC"); // Signature
    try writer.writeInt(u32, 2, .big); // Version
    try writer.writeInt(u32, 0, .big); // No entries
    
    // Calculate correct checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var correct_checksum: [20]u8 = undefined;
    hasher.final(&correct_checksum);
    try writer.writeAll(&correct_checksum);
    
    // Test with correct checksum
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    try test_index.parseIndexData(buffer.items);
    print("✅ Valid checksum accepted\n");
    
    // Create index with invalid checksum
    var bad_buffer = std.ArrayList(u8).init(allocator);
    defer bad_buffer.deinit();
    
    const bad_writer = bad_buffer.writer();
    
    try bad_writer.writeAll("DIRC");
    try bad_writer.writeInt(u32, 2, .big);
    try bad_writer.writeInt(u32, 0, .big);
    
    // Write invalid checksum (all zeros)
    var invalid_checksum: [20]u8 = undefined;
    @memset(&invalid_checksum, 0);
    try bad_writer.writeAll(&invalid_checksum);
    
    // Test with invalid checksum
    var bad_index = index.Index.init(allocator);
    defer bad_index.deinit();
    
    const result = bad_index.parseIndexData(bad_buffer.items);
    if (result) {
        return error.InvalidChecksumAccepted;
    } else |err| switch (err) {
        error.ChecksumMismatch => print("✅ Invalid checksum rejected correctly\n"),
        else => return err,
    }
}

fn testIndexAnalysis(platform: TestPlatform, allocator: std.mem.Allocator) !void {
    // Create test directory with index
    try std.fs.cwd().makePath("test_analysis/.git");
    defer std.fs.cwd().deleteTree("test_analysis") catch {};
    
    // Create a more complex index for analysis
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    const fake_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 100,
        .mode = 33188,
        .kind = .file,
        .atime = 1640995200000000000,
        .mtime = 1640995200000000000,
        .ctime = 1640995200000000000,
    };
    
    // Add multiple entries
    const file_names = [_][]const u8{ "file1.txt", "file2.txt", "subdir/file3.txt" };
    for (file_names) |file_name| {
        var test_sha1: [20]u8 = undefined;
        // Create different hashes for each file
        @memset(&test_sha1, @intCast(file_name.len));
        
        const entry = index.IndexEntry.init(
            try allocator.dupe(u8, file_name),
            fake_stat,
            test_sha1
        );
        try test_index.entries.append(entry);
    }
    
    // Save the test index
    try test_index.save("test_analysis/.git", platform);
    
    // Analyze the index
    const stats = index.analyzeIndex("test_analysis/.git", platform, allocator) catch |err| {
        print("Index analysis failed: {}\n", .{err});
        return err;
    };
    
    // Verify analysis results
    if (stats.total_entries != 3) return error.AnalysisEntryCountMismatch;
    if (stats.version != 2) return error.AnalysisVersionMismatch;
    if (!stats.checksum_valid) return error.AnalysisChecksumInvalid;
    if (stats.has_conflicts) return error.AnalysisUnexpectedConflicts;
    
    print("📈 Index analysis results:\n");
    print("   Total entries: {}\n", .{stats.total_entries});
    print("   Version: {}\n", .{stats.version});
    print("   File size: {} bytes\n", .{stats.file_size});
    print("   Checksum valid: {}\n", .{stats.checksum_valid});
    
    // Test index validation
    const issues = index.validateIndex("test_analysis/.git", platform, allocator) catch |err| {
        print("Index validation failed: {}\n", .{err});
        return err;
    };
    defer {
        for (issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(issues);
    }
    
    print("🔍 Index validation found {} issues\n", .{issues.len});
    for (issues) |issue| {
        print("   - {s}\n", .{issue});
    }
    
    print("✅ Index analysis and validation successful\n");
}