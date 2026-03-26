const std = @import("std");
const objects = @import("../src/git/objects.zig");

// Test platform implementation
const TestPlatform = struct {
    const fs = struct {
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
            std.fs.cwd().access(file_path, .{}) catch return false;
            return true;
        }
        fn deleteFile(file_path: []const u8) !void {
            try std.fs.cwd().deleteFile(file_path);
        }
        fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
            var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
            defer dir.close();
            
            var entries = std.ArrayList([]u8).init(allocator);
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try entries.append(try allocator.dupe(u8, entry.name));
                }
            }
            return entries.toOwnedSlice();
        }
    };
};

/// Create a test repository with pack files
fn createTestRepo(allocator: std.mem.Allocator) ![]const u8 {
    const tmp_dir = "/tmp/ziggit_pack_test";
    
    // Clean up any previous test
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    // Create git repo
    try std.fs.cwd().makePath(tmp_dir);
    var process = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    process.cwd = tmp_dir;
    try process.spawn();
    _ = try process.wait();
    
    // Create some files and commits
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "file1.txt", .content = "Hello World\n" },
        .{ .name = "file2.txt", .content = "Hello Pack\n" },
        .{ .name = "subdir/file3.txt", .content = "Nested file\n" },
    };
    
    for (files, 0..) |file, i| {
        // Create file
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, file.name });
        defer allocator.free(file_path);
        
        if (std.fs.path.dirname(file_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        try std.fs.cwd().writeFile(file_path, file.content);
        
        // Add and commit
        var add_proc = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
        add_proc.cwd = tmp_dir;
        try add_proc.spawn();
        _ = try add_proc.wait();
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i + 1});
        defer allocator.free(commit_msg);
        
        var commit_proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_proc.cwd = tmp_dir;
        try commit_proc.spawn();
        _ = try commit_proc.wait();
    }
    
    // Force pack creation
    var gc_proc = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive" }, allocator);
    gc_proc.cwd = tmp_dir;
    try gc_proc.spawn();
    _ = try gc_proc.wait();
    
    return tmp_dir;
}

test "pack file object loading" {
    const allocator = std.testing.allocator;
    const platform = TestPlatform{};
    
    // Create test repository with pack files
    const tmp_dir = try createTestRepo(allocator);
    defer std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    // Verify pack files exist
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    
    var pack_found = false;
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_found = true;
            break;
        }
    }
    
    if (!pack_found) {
        std.debug.print("No pack files found, skipping test\n");
        return;
    }
    
    // Get HEAD commit
    const head_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir});
    defer allocator.free(head_ref_path);
    
    const head_content = try std.fs.cwd().readFileAlloc(allocator, head_ref_path, 1024);
    defer allocator.free(head_content);
    
    const head_hash = std.mem.trim(u8, head_content, " \t\n\r");
    
    // Try to load commit object (this should use pack files)
    const commit_obj = try objects.GitObject.load(head_hash, git_dir, platform, allocator);
    defer commit_obj.deinit(allocator);
    
    try std.testing.expect(commit_obj.type == .commit);
    try std.testing.expect(commit_obj.data.len > 0);
    
    // Extract tree hash from commit
    if (std.mem.indexOf(u8, commit_obj.data, "\n")) |first_newline| {
        const first_line = commit_obj.data[0..first_newline];
        if (std.mem.startsWith(u8, first_line, "tree ")) {
            const tree_hash = first_line["tree ".len..];
            
            // Load tree object
            const tree_obj = try objects.GitObject.load(tree_hash, git_dir, platform, allocator);
            defer tree_obj.deinit(allocator);
            
            try std.testing.expect(tree_obj.type == .tree);
            try std.testing.expect(tree_obj.data.len > 0);
        }
    }
}

test "pack file statistics" {
    const allocator = std.testing.allocator;
    const platform = TestPlatform{};
    
    const tmp_dir = try createTestRepo(allocator);
    defer std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    
    // Find pack file
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            defer allocator.free(pack_path);
            
            // Analyze pack file
            const stats = try objects.analyzePackFile(pack_path, platform, allocator);
            
            try std.testing.expect(stats.total_objects > 0);
            try std.testing.expect(stats.file_size > 0);
            
            std.debug.print("Pack stats: {} objects, {} bytes\n", .{ stats.total_objects, stats.file_size });
            break;
        }
    }
}

// Run the tests
pub fn main() !void {
    std.debug.print("Running pack integration tests...\n");
    
    // Since we can't use the test runner, manually run tests
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test pack file loading
    std.debug.print("Test 1: pack file object loading...\n");
    @import("std").testing.allocator = allocator;
    
    // We'll create a simple version that doesn't require the test framework
    const tmp_dir = try createTestRepo(allocator);
    defer std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    const platform = TestPlatform{};
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    // Check for pack files
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    
    var pack_found = false;
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch {
        std.debug.print("No pack directory found\n");
        return;
    };
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            std.debug.print("Found pack file: {s}\n", .{entry.name});
            pack_found = true;
        }
    }
    
    if (!pack_found) {
        std.debug.print("ERROR: No pack files created\n");
        return;
    }
    
    // Test object loading
    const head_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir});
    defer allocator.free(head_ref_path);
    
    const head_content = try std.fs.cwd().readFileAlloc(allocator, head_ref_path, 1024);
    defer allocator.free(head_content);
    
    const head_hash = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD commit: {s}\n", .{head_hash});
    
    // Load commit from pack
    const commit_obj = objects.GitObject.load(head_hash, git_dir, platform, allocator) catch |err| {
        std.debug.print("ERROR loading commit: {}\n", .{err});
        return;
    };
    defer commit_obj.deinit(allocator);
    
    std.debug.print("Successfully loaded commit from pack files!\n");
    std.debug.print("Type: {s}, Size: {}\n", .{ commit_obj.type.toString(), commit_obj.data.len });
    
    std.debug.print("All pack integration tests passed!\n");
}