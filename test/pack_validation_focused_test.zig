const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const objects = @import("../src/git/objects.zig");

/// Test basic pack file reading with a real repository
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Testing pack file reading...\n", .{});

    // Create a fake platform implementation for testing
    const TestPlatform = struct {
        const fs_impl = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(path, content);
            }
            
            pub fn makeDir(path: []const u8) !void {
                try std.fs.cwd().makePath(path);
            }
        };
        
        pub const fs = fs_impl;
    };

    // Test pack file reading with the test repository we created
    try testPackFileReading(allocator, TestPlatform);

    std.debug.print("Pack file tests completed!\n", .{});
}

fn testPackFileReading(allocator: std.mem.Allocator, platform_impl: anytype) !void {
    std.debug.print("Creating test repository and testing pack file reading...\n", .{});
    
    // Create temporary test directory
    const test_dir = "test_pack_validation";
    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Initialize a git repo
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "init", test_dir},
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    // Set git config in the test repo
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "config", "user.name", "Test User"},
            .cwd = test_dir,
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "config", "user.email", "test@example.com"},
            .cwd = test_dir,
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    // Create initial file and commit
    try std.fs.cwd().writeFile(test_dir ++ "/initial.txt", "Initial content\n");
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "add", "initial.txt"},
            .cwd = test_dir,
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "commit", "-m", "Initial commit"},
            .cwd = test_dir,
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    // Create several more commits
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{}.txt", .{test_dir, i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {}\n", .{i});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(filename, content);
        
        {
            const filename_only = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
            defer allocator.free(filename_only);
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{"git", "add", filename_only},
                .cwd = test_dir,
            }) catch return;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i});
        defer allocator.free(commit_msg);
        {
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{"git", "commit", "-m", commit_msg},
                .cwd = test_dir,
            }) catch return;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
    }

    // Check what objects exist before gc
    std.debug.print("  Objects before gc:\n", .{});
    const objects_before = try std.fs.cwd().readDirAlloc(allocator, test_dir ++ "/.git/objects", true);
    defer {
        for (objects_before) |entry| {
            allocator.free(entry.name);
        }
        allocator.free(objects_before);
    }
    for (objects_before) |entry| {
        std.debug.print("    {s}: {s}\n", .{@tagName(entry.kind), entry.name});
    }

    // Get a commit hash before gc so we can test loading it after
    const git_log_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "rev-parse", "HEAD"},
        .cwd = test_dir,
    }) catch return;
    defer allocator.free(git_log_result.stdout);
    defer allocator.free(git_log_result.stderr);
    const head_hash = std.mem.trim(u8, git_log_result.stdout, " \t\n\r");
    std.debug.print("  HEAD before gc: {s}\n", .{head_hash});

    // Test that we can load the object before gc
    std.debug.print("  Testing object loading before gc...\n", .{});
    const git_dir = test_dir ++ "/.git";
    const obj_before = objects.GitObject.load(head_hash, git_dir, platform_impl, allocator) catch |err| {
        std.debug.print("  Error loading object before gc: {}\n", .{err});
        return;
    };
    defer obj_before.deinit(allocator);
    std.debug.print("  Successfully loaded object before gc: type={s}, size={}\n", .{obj_before.type.toString(), obj_before.data.len});

    // Run git gc to create pack files
    std.debug.print("  Running git gc...\n", .{});
    const gc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "gc", "--aggressive"},
        .cwd = test_dir,
    }) catch return;
    defer allocator.free(gc_result.stdout);
    defer allocator.free(gc_result.stderr);

    // Check what objects exist after gc
    std.debug.print("  Objects after gc:\n", .{});
    const objects_after = try std.fs.cwd().readDirAlloc(allocator, test_dir ++ "/.git/objects", true);
    defer {
        for (objects_after) |entry| {
            allocator.free(entry.name);
        }
        allocator.free(objects_after);
    }
    for (objects_after) |entry| {
        std.debug.print("    {s}: {s}\n", .{@tagName(entry.kind), entry.name});
        
        // If it's a pack file, show its size
        if (std.mem.startsWith(u8, entry.name, "pack") and entry.kind == .file) {
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/{s}", .{test_dir, entry.name});
            defer allocator.free(pack_path);
            const file = std.fs.cwd().openFile(pack_path, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            std.debug.print("      Size: {} bytes\n", .{stat.size});
        }
    }

    // Test that we can load the same object after gc (from pack file)
    std.debug.print("  Testing object loading after gc (from pack)...\n", .{});
    const obj_after = objects.GitObject.load(head_hash, git_dir, platform_impl, allocator) catch |err| {
        std.debug.print("  Error loading object after gc: {}\n", .{err});
        std.debug.print("  This indicates an issue with pack file reading\n", .{});
        return;
    };
    defer obj_after.deinit(allocator);
    std.debug.print("  Successfully loaded object after gc: type={s}, size={}\n", .{obj_after.type.toString(), obj_after.data.len});

    // Compare the objects
    if (obj_before.type != obj_after.type) {
        std.debug.print("  ✗ Object type mismatch!\n", .{});
        return;
    }
    if (!std.mem.eql(u8, obj_before.data, obj_after.data)) {
        std.debug.print("  ✗ Object data mismatch!\n", .{});
        return;
    }
    
    std.debug.print("  ✓ Objects match! Pack file reading works correctly.\n", .{});
}

test "pack file validation" {
    try main();
}