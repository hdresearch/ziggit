const std = @import("std");
const testing = std.testing;
const ziggit = @import("../src/lib/ziggit.zig");
const Allocator = std.mem.Allocator;

const GitOps = struct {
    allocator: Allocator,
    repo_path: []const u8,
    
    const Self = @This();
    
    fn init(allocator: Allocator, repo_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .repo_path = repo_path,
        };
    }
    
    fn runGitCommand(self: Self, args: []const []const u8) ![]u8 {
        var child = std.process.Child.init(args, self.allocator);
        child.cwd = self.repo_path;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);
        
        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.log.err("Git command failed with code {}: {s}", .{ code, stderr });
                    return error.GitCommandFailed;
                }
            },
            else => return error.GitCommandFailed,
        }
        
        return stdout;
    }
    
    fn init_repo(self: Self) !void {
        const output = try self.runGitCommand(&[_][]const u8{ "git", "init" });
        defer self.allocator.free(output);
    }
    
    fn add_file(self: Self, filename: []const u8) !void {
        const output = try self.runGitCommand(&[_][]const u8{ "git", "add", filename });
        defer self.allocator.free(output);
    }
    
    fn commit(self: Self, message: []const u8) !void {
        const output = try self.runGitCommand(&[_][]const u8{ "git", "commit", "-m", message });
        defer self.allocator.free(output);
    }
    
    fn get_status_porcelain(self: Self) ![]u8 {
        return try self.runGitCommand(&[_][]const u8{ "git", "status", "--porcelain" });
    }
};

// Helper function to write content to a file
fn writeFile(path: []const u8, content: []const u8, allocator: Allocator) !void {
    _ = allocator;
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// Helper function to delete a file
fn deleteFile(path: []const u8) !void {
    try std.fs.deleteFileAbsolute(path);
}

// Test the library status function against git status --porcelain
test "lib status vs git status --porcelain" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create a temporary directory for the test repo
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const repo_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo_path);
    
    const git_ops = GitOps.init(allocator, repo_path);
    
    // Initialize git repo
    try git_ops.init_repo();
    
    // Set git config to avoid warnings
    _ = try git_ops.runGitCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" });
    _ = try git_ops.runGitCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" });
    
    // Create initial file and commit
    const file1_path = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{repo_path});
    defer allocator.free(file1_path);
    try writeFile(file1_path, "Initial content", allocator);
    
    try git_ops.add_file("file1.txt");
    try git_ops.commit("Initial commit");
    
    // Test 1: Clean repository (should be empty)
    {
        var repo = try ziggit.openRepository(repo_path);
        defer ziggit.closeRepository(&repo);
        
        var buffer: [4096]u8 = undefined;
        try ziggit.getStatusPorcelain(&repo, &buffer);
        const lib_status = std.mem.trim(u8, std.mem.sliceTo(&buffer, 0), " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        try testing.expectEqualStrings(git_status, lib_status);
    }
    
    // Test 2: Modified file
    {
        try writeFile(file1_path, "Modified content", allocator);
        
        var repo = try ziggit.openRepository(repo_path);
        defer ziggit.closeRepository(&repo);
        
        var buffer: [4096]u8 = undefined;
        try ziggit.getStatusPorcelain(&repo, &buffer);
        const lib_status = std.mem.trim(u8, std.mem.sliceTo(&buffer, 0), " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        try testing.expectEqualStrings(git_status, lib_status);
    }
    
    // Test 3: New untracked file
    {
        const file2_path = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{repo_path});
        defer allocator.free(file2_path);
        try writeFile(file2_path, "New file content", allocator);
        
        var repo = try ziggit.openRepository(repo_path);
        defer ziggit.closeRepository(&repo);
        
        var buffer: [4096]u8 = undefined;
        try ziggit.getStatusPorcelain(&repo, &buffer);
        const lib_status = std.mem.trim(u8, std.mem.sliceTo(&buffer, 0), " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        try testing.expectEqualStrings(git_status, lib_status);
    }
    
    // Test 4: Deleted file
    {
        // First restore file1 to clean state
        try writeFile(file1_path, "Initial content", allocator);
        try git_ops.add_file("file1.txt");
        try git_ops.commit("Reset file1");
        
        // Now delete the file
        try deleteFile(file1_path);
        
        var repo = try ziggit.openRepository(repo_path);
        defer ziggit.closeRepository(&repo);
        
        var buffer: [4096]u8 = undefined;
        try ziggit.getStatusPorcelain(&repo, &buffer);
        const lib_status = std.mem.trim(u8, std.mem.sliceTo(&buffer, 0), " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        try testing.expectEqualStrings(git_status, lib_status);
    }
}