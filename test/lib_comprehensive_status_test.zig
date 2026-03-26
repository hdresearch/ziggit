const std = @import("std");
const testing = std.testing;
const ziggit = @import("ziggit");
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

// Test the specific case mentioned in the task: repo with HEAD+index
test "repo with HEAD+index shows correct status" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create a temporary directory for the test repo
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const repo_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo_path);
    
    const git_ops = GitOps.init(allocator, repo_path);
    
    std.debug.print("Testing repo with HEAD+index scenario in: {s}\n", .{repo_path});
    
    // Initialize git repo
    try git_ops.init_repo();
    
    // Set git config to avoid warnings
    _ = try git_ops.runGitCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" });
    _ = try git_ops.runGitCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" });
    
    // Create initial files and commit (this creates HEAD)
    const file1_path = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{repo_path});
    defer allocator.free(file1_path);
    const file2_path = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{repo_path});
    defer allocator.free(file2_path);
    
    try writeFile(file1_path, "Initial content 1", allocator);
    try writeFile(file2_path, "Initial content 2", allocator);
    
    try git_ops.add_file("file1.txt");
    try git_ops.add_file("file2.txt");
    try git_ops.commit("Initial commit");
    
    std.debug.print("✓ Created repo with HEAD commit and index\n", .{});
    
    // Scenario 1: Clean repository (should return empty status)
    {
        std.debug.print("\n--- Test 1: Clean repository ---\n", .{});
        
        var repo = try ziggit.repo_open(allocator, repo_path);
        
        const lib_status_raw = try ziggit.repo_status(&repo, allocator);
        defer allocator.free(lib_status_raw);
        const lib_status = std.mem.trim(u8, lib_status_raw, " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        std.debug.print("Git status: '{s}'\n", .{git_status});
        std.debug.print("Lib status: '{s}'\n", .{lib_status});
        
        try testing.expectEqualStrings(git_status, lib_status);
        std.debug.print("✓ Clean repository status matches\n", .{});
    }
    
    // Scenario 2: Modified file (unstaged change)
    {
        std.debug.print("\n--- Test 2: Modified file ---\n", .{});
        
        try writeFile(file1_path, "Modified content 1", allocator);
        
        var repo = try ziggit.repo_open(allocator, repo_path);
        
        const lib_status_raw = try ziggit.repo_status(&repo, allocator);
        defer allocator.free(lib_status_raw);
        const lib_status = std.mem.trim(u8, lib_status_raw, " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        std.debug.print("Git status: '{s}'\n", .{git_status});
        std.debug.print("Lib status: '{s}'\n", .{lib_status});
        
        try testing.expectEqualStrings(git_status, lib_status);
        std.debug.print("✓ Modified file status matches\n", .{});
    }
    
    // Scenario 3: New untracked file
    {
        std.debug.print("\n--- Test 3: New untracked file ---\n", .{});
        
        const file3_path = try std.fmt.allocPrint(allocator, "{s}/file3.txt", .{repo_path});
        defer allocator.free(file3_path);
        try writeFile(file3_path, "New untracked content", allocator);
        
        var repo = try ziggit.repo_open(allocator, repo_path);
        
        const lib_status_raw = try ziggit.repo_status(&repo, allocator);
        defer allocator.free(lib_status_raw);
        const lib_status = std.mem.trim(u8, lib_status_raw, " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        std.debug.print("Git status: '{s}'\n", .{git_status});
        std.debug.print("Lib status: '{s}'\n", .{lib_status});
        
        try testing.expectEqualStrings(git_status, lib_status);
        std.debug.print("✓ New untracked file status matches\n", .{});
    }
    
    // Scenario 4: Deleted file 
    {
        std.debug.print("\n--- Test 4: Deleted file ---\n", .{});
        
        // First restore file1 to clean state
        try writeFile(file1_path, "Initial content 1", allocator);
        
        // Now delete file2 (which was committed)
        try deleteFile(file2_path);
        
        var repo = try ziggit.repo_open(allocator, repo_path);
        
        const lib_status_raw = try ziggit.repo_status(&repo, allocator);
        defer allocator.free(lib_status_raw);
        const lib_status = std.mem.trim(u8, lib_status_raw, " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        std.debug.print("Git status: '{s}'\n", .{git_status});
        std.debug.print("Lib status: '{s}'\n", .{lib_status});
        
        try testing.expectEqualStrings(git_status, lib_status);
        std.debug.print("✓ Deleted file status matches\n", .{});
    }
    
    // Scenario 5: Staged new file (should show "A  ")
    {
        std.debug.print("\n--- Test 5: Staged new file ---\n", .{});
        
        // First restore deleted file to clean state
        try writeFile(file2_path, "Initial content 2", allocator);
        
        // Create and stage a new file
        const file4_path = try std.fmt.allocPrint(allocator, "{s}/file4.txt", .{repo_path});
        defer allocator.free(file4_path);
        try writeFile(file4_path, "New staged file content", allocator);
        
        try git_ops.add_file("file4.txt");
        
        var repo = try ziggit.repo_open(allocator, repo_path);
        
        const lib_status_raw = try ziggit.repo_status(&repo, allocator);
        defer allocator.free(lib_status_raw);
        const lib_status = std.mem.trim(u8, lib_status_raw, " \n\r\t");
        
        const git_status_raw = try git_ops.get_status_porcelain();
        defer allocator.free(git_status_raw);
        const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");
        
        std.debug.print("Git status: '{s}'\n", .{git_status});
        std.debug.print("Lib status: '{s}'\n", .{lib_status});
        
        try testing.expectEqualStrings(git_status, lib_status);
        std.debug.print("✓ Staged new file status matches\n", .{});
    }
}

pub fn main() !void {
    // Run the test
    std.testing.refAllDecls(@This());
}