const std = @import("std");
const objects = @import("src/git/objects.zig");
const config = @import("src/git/config.zig");
const index = @import("src/git/index.zig");
const refs = @import("src/git/refs.zig");

/// Simple platform implementation for manual testing
const SimplePlatform = struct {
    pub const FS = struct {
        pub fn readFile(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            _ = self;
            return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 10);
        }
        
        pub fn writeFile(self: @This(), path: []const u8, data: []const u8) !void {
            _ = self;
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
        }
        
        pub fn makeDir(self: @This(), path: []const u8) !void {
            _ = self;
            try std.fs.cwd().makeDir(path);
        }
        
        pub fn exists(self: @This(), path: []const u8) !bool {
            _ = self;
            std.fs.cwd().access(path, .{}) catch return false;
            return true;
        }
        
        pub fn deleteFile(self: @This(), path: []const u8) !void {
            _ = self;
            try std.fs.cwd().deleteFile(path);
        }
        
        pub fn readDir(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            _ = self;
            var entries = std.ArrayList([]u8).init(allocator);
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
            defer dir.close();
            
            var iterator = dir.iterate();
            while (iterator.next() catch null) |entry| {
                if (entry.kind == .file) {
                    try entries.append(try allocator.dupe(u8, entry.name));
                }
            }
            return entries.toOwnedSlice();
        }
    };
    
    pub const fs = FS{};
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Manual ziggit core functionality test ===\n", .{});
    
    // Test 1: Object creation and hashing
    std.debug.print("\n1. Testing object creation...\n", .{});
    const blob_data = "Hello, ziggit world!";
    const blob = try objects.createBlobObject(blob_data, allocator);
    defer blob.deinit(allocator);
    
    const hash = try blob.hash(allocator);
    defer allocator.free(hash);
    std.debug.print("   Created blob with hash: {s}\n", .{hash});
    
    // Test 2: Config parsing
    std.debug.print("\n2. Testing config parsing...\n", .{});
    const sample_config =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\[remote "origin"]
        \\    url = https://github.com/example/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;
    
    var config_parser = config.GitConfig.init(allocator);
    defer config_parser.deinit();
    try config_parser.parseFromString(sample_config);
    
    if (config_parser.getUserName()) |name| {
        std.debug.print("   User name: {s}\n", .{name});
    }
    if (config_parser.getRemoteUrl("origin")) |url| {
        std.debug.print("   Remote URL: {s}\n", .{url});
    }
    
    // Test 3: Simple git repository check
    std.debug.print("\n3. Testing repository detection...\n", .{});
    const git_exists = SimplePlatform.fs.exists(".git") catch false;
    if (git_exists) {
        std.debug.print("   ✓ Found .git directory\n", .{});
        
        // Try to read HEAD
        if (refs.getCurrentBranch(".git", SimplePlatform.fs, allocator)) |current_branch| {
            defer allocator.free(current_branch);
            std.debug.print("   Current branch: {s}\n", .{current_branch});
            
            // Try to get the commit hash for this branch
            if (refs.getCurrentCommit(".git", SimplePlatform.fs, allocator)) |current_commit| {
                defer allocator.free(current_commit.?);
                std.debug.print("   Current commit: {s}\n", .{current_commit.?[0..8]});
            } else |err| {
                std.debug.print("   Could not get current commit: {}\n", .{err});
            }
        } else |err| {
            std.debug.print("   Could not get current branch: {}\n", .{err});
        }
    } else {
        std.debug.print("   No .git directory found (not a git repository)\n", .{});
    }
    
    std.debug.print("\n=== Manual test completed ===\n", .{});
}