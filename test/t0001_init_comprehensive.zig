const std = @import("std");
const GitTestFramework = @import("git_test_framework.zig").GitTestFramework;
const compareGitZiggitOutput = @import("git_test_framework.zig").compareGitZiggitOutput;

// Test: Plain init (equivalent to git's t0001 "plain" test)
fn testPlainInit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("plain-init");
    defer framework.allocator.free(test_dir);

    // Test ziggit init
    var ziggit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer ziggit_result.deinit(framework.allocator);
    
    try framework.expectExitCode(0, ziggit_result);
    
    // Check that .git directory was created with proper structure
    const git_dir = try std.fs.path.join(framework.allocator, &[_][]const u8{ test_dir, ".git" });
    defer framework.allocator.free(git_dir);
    
    // Verify .git directory exists
    const git_stat = std.fs.cwd().statFile(git_dir) catch |err| {
        std.debug.print("Failed to stat .git directory: {}\n", .{err});
        return error.GitDirNotFound;
    };
    if (git_stat.kind != .directory) {
        return error.GitDirNotDirectory;
    }

    // Verify key files/directories exist
    const config_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ git_dir, "config" });
    defer framework.allocator.free(config_path);
    _ = std.fs.cwd().statFile(config_path) catch return error.ConfigFileNotFound;

    const refs_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ git_dir, "refs" });
    defer framework.allocator.free(refs_path);
    const refs_stat = std.fs.cwd().statFile(refs_path) catch return error.RefsDirNotFound;
    if (refs_stat.kind != .directory) {
        return error.RefsDirNotDirectory;
    }

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("plain-init-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_result = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_result.deinit(framework.allocator);
    
    // Both should succeed
    try framework.expectExitCode(0, git_result);
}

// Test: Bare repository init (equivalent to git's "plain bare" test)
fn testBareInit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("bare-init");
    defer framework.allocator.free(test_dir);

    // Test ziggit init --bare
    var ziggit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "init", "--bare" });
    defer ziggit_result.deinit(framework.allocator);
    
    try framework.expectExitCode(0, ziggit_result);

    // For bare repos, the test_dir itself should be the git directory
    // Verify key files/directories exist directly in test_dir
    const config_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ test_dir, "config" });
    defer framework.allocator.free(config_path);
    _ = std.fs.cwd().statFile(config_path) catch return error.ConfigFileNotFound;

    const refs_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ test_dir, "refs" });
    defer framework.allocator.free(refs_path);
    const refs_stat = std.fs.cwd().statFile(refs_path) catch return error.RefsDirNotFound;
    if (refs_stat.kind != .directory) {
        return error.RefsDirNotDirectory;
    }

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("bare-init-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_result = try framework.runGitCommand(git_test_dir, &[_][]const u8{ "init", "--bare" });
    defer git_result.deinit(framework.allocator);
    
    try framework.expectExitCode(0, git_result);
}

// Test: Re-initialization of existing repository
fn testReinitExisting(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("reinit");
    defer framework.allocator.free(test_dir);

    // First init
    var first_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer first_result.deinit(framework.allocator);
    try framework.expectExitCode(0, first_result);

    // Second init (should not fail)
    var second_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer second_result.deinit(framework.allocator);
    try framework.expectExitCode(0, second_result);

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("reinit-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_first = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_first.deinit(framework.allocator);
    try framework.expectExitCode(0, git_first);

    var git_second = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_second.deinit(framework.allocator);
    try framework.expectExitCode(0, git_second);
}

// Test: Init with specific directory name
fn testInitWithDirectory(framework: *GitTestFramework) !void {
    const base_dir = try framework.createTestRepo("init-with-dir-base");
    defer framework.allocator.free(base_dir);

    const target_repo = "my-new-repo";
    
    // Test ziggit init <directory>
    var ziggit_result = try framework.runZiggitCommand(base_dir, &[_][]const u8{ "init", target_repo });
    defer ziggit_result.deinit(framework.allocator);
    
    try framework.expectExitCode(0, ziggit_result);

    // Verify the new directory was created with .git
    const repo_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ base_dir, target_repo });
    defer framework.allocator.free(repo_path);
    
    const git_dir = try std.fs.path.join(framework.allocator, &[_][]const u8{ repo_path, ".git" });
    defer framework.allocator.free(git_dir);
    
    const git_stat = std.fs.cwd().statFile(git_dir) catch return error.GitDirNotFound;
    if (git_stat.kind != .directory) {
        return error.GitDirNotDirectory;
    }

    // Compare with git behavior
    const git_base_dir = try framework.createTestRepo("init-with-dir-git");
    defer framework.allocator.free(git_base_dir);
    
    var git_result = try framework.runGitCommand(git_base_dir, &[_][]const u8{ "init", target_repo });
    defer git_result.deinit(framework.allocator);
    
    try framework.expectExitCode(0, git_result);
}

// Test: Error cases - init in invalid locations
fn testInitErrorCases(framework: *GitTestFramework) !void {
    // Test init with non-existent parent directory
    var result = try framework.runZiggitCommand("/tmp", &[_][]const u8{ "init", "/nonexistent/path/repo" });
    defer result.deinit(framework.allocator);
    
    // Should fail with non-zero exit code (like git does)
    if (result.exit_code == 0) {
        return error.ExpectedInitToFail;
    }
}

pub fn runInitTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = try GitTestFramework.init(allocator);
    defer framework.deinit();

    std.debug.print("Running t0001 Init Tests (Comprehensive)...\n", .{});

    try framework.testExpectSuccess("plain init", testPlainInit);
    try framework.testExpectSuccess("bare init", testBareInit);
    try framework.testExpectSuccess("reinit existing repository", testReinitExisting);
    try framework.testExpectSuccess("init with directory name", testInitWithDirectory);
    try framework.testExpectSuccess("init error cases", testInitErrorCases);

    framework.summary();
    
    if (framework.failed_counter > 0) {
        std.process.exit(1);
    }
}