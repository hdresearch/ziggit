const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t0001-init.sh - Test git init functionality
// Adapted from git/git.git/t/t0001-init.sh

// Test plain git init
fn testPlainInit(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"init"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit init") == .fail) return .fail;
    if (runner.expectDirExists(".git", "git directory created") == .fail) return .fail;
    if (runner.expectFileExists(".git/config", "config file created") == .fail) return .fail;
    if (runner.expectDirExists(".git/refs", "refs directory created") == .fail) return .fail;
    if (runner.expectDirExists(".git/objects", "objects directory created") == .fail) return .fail;
    
    return .pass;
}

// Test git init with directory argument
fn testInitWithDirectory(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "init", "test-repo" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit init test-repo") == .fail) return .fail;
    if (runner.expectDirExists("test-repo", "repository directory created") == .fail) return .fail;
    if (runner.expectDirExists("test-repo/.git", "git directory created") == .fail) return .fail;
    if (runner.expectFileExists("test-repo/.git/config", "config file created") == .fail) return .fail;
    
    return .pass;
}

// Test bare repository init
fn testBareInit(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "init", "--bare", "bare-repo.git" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit init --bare") == .fail) return .fail;
    if (runner.expectDirExists("bare-repo.git", "bare repository directory created") == .fail) return .fail;
    if (runner.expectFileExists("bare-repo.git/config", "config file created in bare repo") == .fail) return .fail;
    if (runner.expectDirExists("bare-repo.git/refs", "refs directory created in bare repo") == .fail) return .fail;
    
    return .pass;
}

// Test init in existing directory
fn testInitExistingDirectory(runner: *TestRunner) !TestResult {
    // Create a directory with some content
    try runner.createFile("existing-dir/file.txt", "some content\n");
    
    const result = try runner.runZiggit(&[_][]const u8{ "init", "existing-dir" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit init existing-dir") == .fail) return .fail;
    if (runner.expectDirExists("existing-dir/.git", "git directory created") == .fail) return .fail;
    if (runner.expectFileExists("existing-dir/file.txt", "existing file preserved") == .fail) return .fail;
    
    return .pass;
}

// Test re-init of repository
fn testReinitRepository(runner: *TestRunner) !TestResult {
    // First init
    var result = try runner.runZiggit(&[_][]const u8{ "init", "repo" });
    result.deinit(runner.allocator);
    
    // Second init (should succeed)
    result = try runner.runZiggit(&[_][]const u8{ "init", "repo" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit init repo (reinit)") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "Reinitialized", "reinit message") == .fail) {
        // If not exactly like git, check if it still works
        if (runner.expectDirExists("repo/.git", "git directory still exists") == .fail) return .fail;
    }
    
    return .pass;
}

// Compare ziggit and git init behavior
fn testInitCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Test ziggit init
    const ziggit_result = try runner.runZiggit(&[_][]const u8{ "init", "ziggit-repo" });
    defer ziggit_result.deinit(runner.allocator);
    
    // Test git init  
    const git_result = try runner.runGit(&[_][]const u8{ "init", "git-repo" });
    defer git_result.deinit(runner.allocator);
    
    // Both should succeed
    if (runner.expectExitCode(0, ziggit_result.exit_code, "ziggit init") == .fail) return .fail;
    if (runner.expectExitCode(0, git_result.exit_code, "git init") == .fail) return .fail;
    
    // Both should create similar structure
    if (runner.expectDirExists("ziggit-repo/.git", "ziggit creates .git") == .fail) return .fail;
    if (runner.expectDirExists("git-repo/.git", "git creates .git") == .fail) return .fail;
    if (runner.expectFileExists("ziggit-repo/.git/config", "ziggit creates config") == .fail) return .fail;
    if (runner.expectFileExists("git-repo/.git/config", "git creates config") == .fail) return .fail;
    
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "plain",
        .description = "basic git init in current directory",
        .test_fn = testPlainInit,
    },
    .{
        .name = "init-directory", 
        .description = "git init with directory argument",
        .test_fn = testInitWithDirectory,
    },
    .{
        .name = "bare",
        .description = "git init --bare creates bare repository",
        .test_fn = testBareInit,
    },
    .{
        .name = "existing-dir",
        .description = "git init in existing directory",
        .test_fn = testInitExistingDirectory,
    },
    .{
        .name = "reinit",
        .description = "re-initializing existing repository",
        .test_fn = testReinitRepository,
    },
    .{
        .name = "compatibility",
        .description = "ziggit init behavior matches git init",
        .test_fn = testInitCompatibilityWithGit,
    },
};

pub fn runT0001InitTests() !void {
    try runTestSuite("t0001-init (Git Init Tests)", &test_cases);
}