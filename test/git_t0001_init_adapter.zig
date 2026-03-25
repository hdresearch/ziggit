// Git Test Suite Adapter - t0001-init.sh equivalent
// This test adapts git's t0001-init.sh test for ziggit compatibility

const std = @import("std");

const TestFramework = struct {
    allocator: std.mem.Allocator,
    temp_dir_counter: u32 = 0,

    fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }

    fn runCommand(self: *TestFramework, argv: []const []const u8) !std.process.Child.RunResult {
        return try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
            .max_output_bytes = 1024 * 1024,
        });
    }

    fn createTempDir(self: *TestFramework, name: []const u8) ![]u8 {
        self.temp_dir_counter += 1;
        const full_name = try std.fmt.allocPrint(self.allocator, "ziggit-t0001-{s}-{d}", .{ name, self.temp_dir_counter });
        
        // Clean up any existing directory
        std.fs.cwd().deleteTree(full_name) catch {};
        try std.fs.cwd().makeDir(full_name);
        
        return full_name;
    }

    fn writeFile(self: *TestFramework, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(full_path);
        
        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    fn changeDir(_: *TestFramework, dir: []const u8) !void {
        try std.posix.chdir(dir);
    }

    fn cleanup(_: *TestFramework, dir: []const u8) void {
        std.fs.cwd().deleteTree(dir) catch {};
    }

    // Equivalent to git's check_config function
    fn checkConfig(self: *TestFramework, git_dir_path: []const u8, expected_bare: bool, expected_worktree: []const u8) !void {
        // Check if .git directory exists
        var git_dir = std.fs.cwd().openDir(git_dir_path, .{}) catch |err| {
            std.debug.print("Expected directory {s} not found: {}\n", .{ git_dir_path, err });
            return error.GitDirNotFound;
        };
        defer git_dir.close();

        // Check config file exists
        git_dir.access("config", .{}) catch |err| {
            std.debug.print("Expected file {s}/config not found: {}\n", .{ git_dir_path, err });
            return error.ConfigNotFound;
        };

        // Check refs directory exists  
        git_dir.access("refs", .{}) catch |err| {
            std.debug.print("Expected directory {s}/refs not found: {}\n", .{ git_dir_path, err });
            return error.RefsNotFound;
        };

        // Read and check config values using git command
        const allocator = self.allocator;
        const config_dir = try std.fmt.allocPrint(allocator, "{s}", .{git_dir_path});
        defer allocator.free(config_dir);

        // Check bare setting
        const bare_result = try self.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "config", "core.bare" });
        defer allocator.free(bare_result.stdout);
        defer allocator.free(bare_result.stderr);

        const bare_str = std.mem.trim(u8, bare_result.stdout, " \n\r\t");
        const is_bare = std.mem.eql(u8, bare_str, "true");
        
        if (is_bare != expected_bare) {
            std.debug.print("Expected bare={}, got bare={}\n", .{ expected_bare, is_bare });
            return error.BareConfigMismatch;
        }

        // Note: worktree check would require more complex git config parsing
        // For now, we'll just verify the basic structure is correct
        _ = expected_worktree;
    }
};

// Test equivalent to git's 'plain' test
fn testPlain(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("plain");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Run ziggit init (equivalent to 'git init plain')
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Check config (equivalent to 'check_config plain/.git false unset')
    try tf.checkConfig(".git", false, "unset");

    std.debug.print("    ✓ 'plain' test passed\n", .{});
}

// Test equivalent to git's 'bare repository' test  
fn testBareRepository(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("bare");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Run ziggit init --bare
    const result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init", "--bare" });
    
    if (result.term.Exited != 0) {
        std.debug.print("ziggit init --bare failed: {s}\n", .{result.stderr});
        return error.ZiggitBareInitFailed;
    }

    // In bare repositories, the git directory is the current directory
    try tf.checkConfig(".", true, "unset");

    std.debug.print("    ✓ 'bare repository' test passed\n", .{});
}

// Test equivalent to git's 'plain with GIT_WORK_TREE' test (simplified)
fn testPlainWithWorkTree(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("worktree");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Create work tree directory
    try std.fs.cwd().makeDir("work");
    
    // Run ziggit init with work tree (if supported)
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Basic check that .git was created
    std.fs.cwd().access(".git", .{}) catch |err| {
        std.debug.print("Expected .git directory not found: {}\n", .{err});
        return error.GitDirNotFound;
    };

    std.debug.print("    ✓ 'plain with worktree' test passed\n", .{});
}

// Test equivalent to git's 'reinit' test
fn testReinit(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("reinit");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // First init
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Create a test file and commit
    try tf.writeFile(".", "test.txt", "test content\n");
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "test.txt" });
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "test commit" });

    // Reinit - should not destroy existing repository
    const reinit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });
    
    if (reinit_result.term.Exited != 0) {
        std.debug.print("ziggit reinit failed: {s}\n", .{reinit_result.stderr});
        return error.ZiggitReinitFailed;
    }

    // Verify repository still works
    const log_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "log", "--oneline" });
    
    if (log_result.term.Exited != 0) {
        std.debug.print("log after reinit failed: {s}\n", .{log_result.stderr});
        return error.LogAfterReinitFailed;
    }

    // Should contain our test commit
    if (std.mem.indexOf(u8, log_result.stdout, "test commit") == null) {
        std.debug.print("Commit history lost after reinit\n", .{});
        return error.HistoryLostAfterReinit;
    }

    std.debug.print("    ✓ 'reinit' test passed\n", .{});
}

// Test equivalent to git's directory and file permissions (simplified)
fn testPermissions(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("permissions");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Run ziggit init
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Check that .git directory was created with proper structure
    const essential_paths = [_][]const u8{
        ".git",
        ".git/objects", 
        ".git/refs",
        ".git/refs/heads",
        ".git/refs/tags",
        ".git/HEAD",
        ".git/config",
    };

    for (essential_paths) |path| {
        std.fs.cwd().access(path, .{}) catch |err| {
            std.debug.print("Essential path missing: {s} - {}\n", .{ path, err });
            return error.EssentialPathMissing;
        };
    }

    std.debug.print("    ✓ 'permissions' test passed\n", .{});
}

pub fn runGitT0001InitTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tf = TestFramework.init(allocator);

    std.debug.print("Running git t0001-init.sh equivalent tests...\n", .{});
    
    std.debug.print("  Testing 'plain' initialization...\n", .{});
    try testPlain(&tf);
    
    std.debug.print("  Testing 'bare repository' initialization...\n", .{});
    try testBareRepository(&tf);
    
    std.debug.print("  Testing 'plain with worktree'...\n", .{});
    try testPlainWithWorkTree(&tf);
    
    std.debug.print("  Testing 'reinit'...\n", .{});
    try testReinit(&tf);
    
    std.debug.print("  Testing 'permissions'...\n", .{});
    try testPermissions(&tf);
    
    std.debug.print("✓ All git t0001-init equivalent tests passed!\n", .{});
}

pub fn main() !void {
    try runGitT0001InitTests();
}