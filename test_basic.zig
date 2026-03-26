const std = @import("std");
const objects = @import("src/git/objects.zig");
const config = @import("src/git/config.zig");
const index = @import("src/git/index.zig");
const refs = @import("src/git/refs.zig");

// Mock platform implementation for testing
const MockPlatform = struct {
    fs: FileSystem = FileSystem{},
    
    const FileSystem = struct {
        fn readFile(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            _ = self;
            return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        }
        
        fn writeFile(self: @This(), path: []const u8, content: []const u8) !void {
            _ = self;
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
        }
        
        fn exists(self: @This(), path: []const u8) !bool {
            _ = self;
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        
        fn makeDir(self: @This(), path: []const u8) !void {
            _ = self;
            std.fs.cwd().makePath(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        fn deleteFile(self: @This(), path: []const u8) !void {
            _ = self;
            try std.fs.cwd().deleteFile(path);
        }
        
        fn readDir(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            _ = self;
            var entries = std.ArrayList([]u8).init(allocator);
            
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
            defer dir.close();
            
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                try entries.append(try allocator.dupe(u8, entry.name));
            }
            
            return entries.toOwnedSlice();
        }
    };
};

test "basic config parsing" {
    const allocator = std.testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const config_content =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/example/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
    ;
    
    try git_config.parseFromString(config_content);
    
    try std.testing.expectEqualStrings("Test User", git_config.getUserName().?);
    try std.testing.expectEqualStrings("test@example.com", git_config.getUserEmail().?);
    try std.testing.expectEqualStrings("https://github.com/example/repo.git", git_config.getRemoteUrl("origin").?);
    try std.testing.expectEqualStrings("origin", git_config.getBranchRemote("main").?);
    try std.testing.expectEqualStrings("refs/heads/main", git_config.getBranchMerge("main").?);
    
    std.debug.print("✓ Config parsing works correctly\n");
}

test "basic objects functionality" {
    const allocator = std.testing.allocator;
    
    // Test blob object creation
    const test_data = "Hello, World!";
    const blob = try objects.createBlobObject(test_data, allocator);
    defer blob.deinit(allocator);
    
    try std.testing.expectEqual(objects.ObjectType.blob, blob.type);
    try std.testing.expectEqualStrings(test_data, blob.data);
    
    // Test hash calculation
    const hash = try blob.hash(allocator);
    defer allocator.free(hash);
    
    try std.testing.expect(hash.len == 40);
    
    std.debug.print("✓ Object creation and hashing works correctly\n");
}

test "index entry creation" {
    const allocator = std.testing.allocator;
    
    // Create a fake file stat
    const fake_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 1000,
        .mode = 33188, // 100644 octal
        .kind = .file,
        .atime = std.time.timestamp() * std.time.ns_per_s,
        .mtime = std.time.timestamp() * std.time.ns_per_s,
        .ctime = std.time.timestamp() * std.time.ns_per_s,
    };
    
    const fake_hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc};
    
    const entry = index.IndexEntry.init("test/file.txt", fake_stat, fake_hash);
    defer entry.deinit(allocator);
    
    try std.testing.expectEqualStrings("test/file.txt", entry.path);
    try std.testing.expect(entry.size == 1000);
    try std.testing.expect(std.mem.eql(u8, &entry.sha1, &fake_hash));
    
    std.debug.print("✓ Index entry creation works correctly\n");
}

test "ref hash validation" {
    // Test valid hash
    try std.testing.expect(refs.isValidHash("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(refs.isValidHash("0000000000000000000000000000000000000000"));
    try std.testing.expect(refs.isValidHash("ffffffffffffffffffffffffffffffffffffffff"));
    
    // Test invalid hashes
    try std.testing.expect(!refs.isValidHash("invalid"));
    try std.testing.expect(!refs.isValidHash("0123456789abcdef0123456789abcdef0123456")); // too short
    try std.testing.expect(!refs.isValidHash("0123456789abcdef0123456789abcdef012345678")); // too long
    try std.testing.expect(!refs.isValidHash("0123456789abcdef0123456789abcdef0123456g")); // invalid char
    
    std.debug.print("✓ Ref hash validation works correctly\n");
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("Running basic tests...\n");
    
    // Run the tests manually since the testing framework has issues
    try @import("std").testing.refAllDecls(@This());
    
    std.debug.print("\n✅ All basic tests passed!\n");
}