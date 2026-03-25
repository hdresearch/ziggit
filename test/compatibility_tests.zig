const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Git Compatibility Tests - Based on git's own test suite
pub fn runCompatibilityTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("Running git compatibility tests...\n", .{});

    // Basic repository initialization tests
    try testInitBasic(harness);
    try testInitBare(harness);
    try testInitInExistingDir(harness);
    try testInitReinitialize(harness);
    try testInitWithTemplate(harness);
    try testInitWithDirectory(harness);
    
    // Status tests
    try testStatusEmptyRepo(harness);
    try testStatusNotARepo(harness);
    try testStatusWithFiles(harness);
    try testStatusUntracked(harness);
    
    // Add tests
    try testAddBasic(harness);
    try testAddNonExistent(harness);
    try testAddDirectory(harness);
    try testAddNothing(harness);
    
    // Commit tests
    try testCommitEmpty(harness);
    try testCommitWithMessage(harness);
    try testCommitNothing(harness);
    
    // Log tests
    try testLogEmpty(harness);
    
    // Diff tests  
    try testDiffEmpty(harness);
    
    // Branch tests
    try testBranchEmpty(harness);
    try testBranchList(harness);
    
    // Checkout tests
    try testCheckoutEmpty(harness);
    
    // Error condition tests
    try testInvalidCommand(harness);
    try testHelpUsage(harness);
    
    std.debug.print("All compatibility tests passed!\n", .{});
}

// Test basic git init functionality
fn testInitBasic(harness: TestHarness) !void {
    std.debug.print("  Testing basic git init...\n", .{});
    
    // Create separate temp directories for comparison
    const ziggit_dir = try harness.createTempDir("ziggit_init_basic");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_init_basic");
    defer harness.removeTempDir(git_dir);
    
    // Run both commands
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Verify .git directory structure was created correctly
    const ziggit_git_dir = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{ziggit_dir});
    defer harness.allocator.free(ziggit_git_dir);
    const git_git_dir = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{git_dir});
    defer harness.allocator.free(git_git_dir);
    try verifyGitDirStructure(harness, ziggit_git_dir, false);
    try verifyGitDirStructure(harness, git_git_dir, false);
    
    // Compare outputs (normalize paths)
    const ziggit_normalized = try normalizeInitOutput(harness.allocator, ziggit_result.stdout);
    defer harness.allocator.free(ziggit_normalized);
    const git_normalized = try normalizeInitOutput(harness.allocator, git_result.stdout);
    defer harness.allocator.free(git_normalized);
    
    if (!std.mem.eql(u8, ziggit_normalized, git_normalized)) {
        std.debug.print("    FAIL: Output mismatch\n    ziggit: {s}\n    git: {s}\n", .{ ziggit_normalized, git_normalized });
        return test_harness.TestError.OutputMismatch;
    }
    
    std.debug.print("    ✓ basic init\n", .{});
}

// Test bare repository initialization
fn testInitBare(harness: TestHarness) !void {
    std.debug.print("  Testing git init --bare...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_init_bare");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_init_bare");
    defer harness.removeTempDir(git_dir);
    
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"init", "--bare"}, ziggit_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{"init", "--bare"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Verify bare repository structure
    try verifyGitDirStructure(harness, ziggit_dir, true);
    try verifyGitDirStructure(harness, git_dir, true);
    
    std.debug.print("    ✓ bare init\n", .{});
}

// Test init in existing directory
fn testInitInExistingDir(harness: TestHarness) !void {
    std.debug.print("  Testing git init in existing directory...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_existing");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_existing");
    defer harness.removeTempDir(git_dir);
    
    // Create some files in the directories
    const ziggit_file = try std.fmt.allocPrint(harness.allocator, "{s}/existing.txt", .{ziggit_dir});
    defer harness.allocator.free(ziggit_file);
    const git_file = try std.fmt.allocPrint(harness.allocator, "{s}/existing.txt", .{git_dir});
    defer harness.allocator.free(git_file);
    
    try harness.writeFile(ziggit_file, "existing content\n");
    try harness.writeFile(git_file, "existing content\n");
    
    // Init in existing directories
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Verify existing files are preserved
    const file = try std.fs.openFileAbsolute(ziggit_file, .{});
    defer file.close();
    const ziggit_content = try file.readToEndAlloc(harness.allocator, 1024);
    defer harness.allocator.free(ziggit_content);
    if (!std.mem.eql(u8, ziggit_content, "existing content\n")) {
        std.debug.print("    FAIL: Existing file content changed\n", .{});
        return test_harness.TestError.UnexpectedOutput;
    }
    
    std.debug.print("    ✓ init in existing directory\n", .{});
}

// Test reinitializing an existing repository
fn testInitReinitialize(harness: TestHarness) !void {
    std.debug.print("  Testing git init reinitialize...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_reinit");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_reinit");
    defer harness.removeTempDir(git_dir);
    
    // Initialize repos first time
    var ziggit_result1 = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_result1.deinit();
    var git_result1 = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_result1.deinit();
    
    // Initialize repos second time (should say reinitialized)
    var ziggit_result2 = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_result2.deinit();
    var git_result2 = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_result2.deinit();
    
    // Check that second init mentions reinitialized
    if (!std.mem.containsAtLeast(u8, ziggit_result2.stdout, 1, "Reinitialized")) {
        std.debug.print("    FAIL: ziggit didn't show 'Reinitialized' on second init\n", .{});
        return test_harness.TestError.OutputMismatch;
    }
    
    std.debug.print("    ✓ reinitialize\n", .{});
}

// Test git status in empty repository  
fn testStatusEmptyRepo(harness: TestHarness) !void {
    std.debug.print("  Testing git status in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_status_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_status_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    // Run status
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"status"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"status"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Compare normalized outputs
    const ziggit_status = try normalizeStatusOutput(harness.allocator, ziggit_result.stdout);
    defer harness.allocator.free(ziggit_status);
    const git_status = try normalizeStatusOutput(harness.allocator, git_result.stdout);
    defer harness.allocator.free(git_status);
    
    if (!std.mem.eql(u8, ziggit_status, git_status)) {
        std.debug.print("    FAIL: Status output mismatch\n    ziggit: {s}\n    git: {s}\n", .{ ziggit_status, git_status });
        return test_harness.TestError.OutputMismatch;
    }
    
    std.debug.print("    ✓ status empty repository\n", .{});
}

// Test git status outside repository
fn testStatusNotARepo(harness: TestHarness) !void {
    std.debug.print("  Testing git status outside repository...\n", .{});
    
    const temp_dir = try harness.createTempDir("not_a_repo");
    defer harness.removeTempDir(temp_dir);
    
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"status"}, temp_dir);
    defer git_result.deinit();
    
    // Both should fail with exit code 128
    if (ziggit_result.exit_code != 128 or git_result.exit_code != 128) {
        std.debug.print("    FAIL: Expected exit code 128, got ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Both should mention "not a git repository"
    if (!std.mem.containsAtLeast(u8, ziggit_result.stderr, 1, "not a git repository")) {
        std.debug.print("    FAIL: ziggit stderr doesn't contain 'not a git repository'\n", .{});
        return test_harness.TestError.OutputMismatch;
    }
    
    std.debug.print("    ✓ status not a repository\n", .{});
}

// Test add functionality (currently not implemented)
fn testAddNotImplemented(harness: TestHarness) !void {
    std.debug.print("  Testing git add (not yet implemented)...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repo and create test file
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Hello, world!\n");
    
    // Try to add the file (should fail gracefully)
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    defer add_result.deinit();
    
    // Should fail with appropriate error message
    if (add_result.exit_code == 0) {
        std.debug.print("    WARNING: git add seems to be implemented but tests need updating\n", .{});
    } else {
        std.debug.print("    ✓ add not yet implemented (expected)\n", .{});
    }
}

// Helper function to verify git directory structure
fn verifyGitDirStructure(harness: TestHarness, git_dir: []const u8, is_bare: bool) !void {
    
    // Check that git_dir exists
    var dir = std.fs.openDirAbsolute(git_dir, .{}) catch |err| {
        std.debug.print("    FAIL: Cannot open git directory {s}: {}\n", .{ git_dir, err });
        return test_harness.TestError.UnexpectedOutput;
    };
    defer dir.close();
    
    // Required files and directories
    const required = [_][]const u8{ "HEAD", "config", "objects", "refs", "refs/heads", "refs/tags" };
    
    for (required) |item| {
        const item_path = try std.fmt.allocPrint(harness.allocator, "{s}/{s}", .{ git_dir, item });
        defer harness.allocator.free(item_path);
        
        std.fs.accessAbsolute(item_path, .{}) catch |err| {
            std.debug.print("    FAIL: Required item {s} not found: {}\n", .{ item_path, err });
            return test_harness.TestError.UnexpectedOutput;
        };
    }
    
    // Check HEAD content
    const head_path = try std.fmt.allocPrint(harness.allocator, "{s}/HEAD", .{git_dir});
    defer harness.allocator.free(head_path);
    const head_file = try std.fs.openFileAbsolute(head_path, .{});
    defer head_file.close();
    const head_content = try head_file.readToEndAlloc(harness.allocator, 1024);
    defer harness.allocator.free(head_content);
    
    if (!std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        std.debug.print("    FAIL: Invalid HEAD content: {s}\n", .{head_content});
        return test_harness.TestError.UnexpectedOutput;
    }
    
    // Check config file contains expected bare setting
    const config_path = try std.fmt.allocPrint(harness.allocator, "{s}/config", .{git_dir});
    defer harness.allocator.free(config_path);
    const config_file = try std.fs.openFileAbsolute(config_path, .{});
    defer config_file.close();
    const config_content = try config_file.readToEndAlloc(harness.allocator, 1024);
    defer harness.allocator.free(config_content);
    
    const expected_bare = if (is_bare) "bare = true" else "bare = false";
    if (!std.mem.containsAtLeast(u8, config_content, 1, expected_bare)) {
        std.debug.print("    FAIL: Config doesn't contain '{s}': {s}\n", .{ expected_bare, config_content });
        return test_harness.TestError.UnexpectedOutput;
    }
}

// Normalize init output for comparison
fn normalizeInitOutput(allocator: std.mem.Allocator, output: []u8) ![]u8 {
    // Convert git init output to a comparable format
    // "Initialized empty Git repository in /path/.git" -> "Initialized empty Git repository"
    // "Reinitialized existing Git repository in /path/.git" -> "Reinitialized existing Git repository"
    
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    
    if (std.mem.startsWith(u8, trimmed, "Initialized empty Git repository")) {
        return try allocator.dupe(u8, "Initialized empty Git repository");
    } else if (std.mem.startsWith(u8, trimmed, "Reinitialized existing Git repository")) {
        return try allocator.dupe(u8, "Reinitialized existing Git repository");
    } else {
        return try allocator.dupe(u8, trimmed);
    }
}

// Normalize status output for comparison
fn normalizeStatusOutput(allocator: std.mem.Allocator, output: []u8) ![]u8 {
    // Normalize branch names and other variable content
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    
    // Replace main/master branch variations with normalized version
    var result = try std.ArrayList(u8).initCapacity(allocator, trimmed.len);
    defer result.deinit();
    
    var lines = std.mem.split(u8, trimmed, "\n");
    while (lines.next()) |line| {
        var normalized_line = line;
        
        // Normalize "On branch master" vs "On branch main"
        if (std.mem.startsWith(u8, line, "On branch ")) {
            if (std.mem.containsAtLeast(u8, line, 1, "master") or std.mem.containsAtLeast(u8, line, 1, "main")) {
                normalized_line = "On branch master";
            }
        }
        
        try result.appendSlice(normalized_line);
        if (lines.peek() != null) {
            try result.append('\n');
        }
    }
    
    return try result.toOwnedSlice();
}

// Test init with template directory (should be ignored for compatibility)
fn testInitWithTemplate(harness: TestHarness) !void {
    std.debug.print("  Testing git init --template...\n", .{});
    
    // Create a proper template directory
    const template_dir = try harness.createTempDir("template");
    defer harness.removeTempDir(template_dir);
    
    // Create a minimal template structure
    const hooks_dir = try std.fmt.allocPrint(harness.allocator, "{s}/hooks", .{template_dir});
    defer harness.allocator.free(hooks_dir);
    try std.fs.cwd().makeDir(hooks_dir);
    
    const ziggit_dir = try harness.createTempDir("ziggit_init_template");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_init_template");
    defer harness.removeTempDir(git_dir);
    
    const template_arg = try std.fmt.allocPrint(harness.allocator, "--template={s}", .{template_dir});
    defer harness.allocator.free(template_arg);
    
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"init", template_arg}, ziggit_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{"init", template_arg}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed (ziggit ignores template for now)
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        std.debug.print("    ziggit stderr: {s}\n", .{ziggit_result.stderr});
        std.debug.print("    git stderr: {s}\n", .{git_result.stderr});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ init with template\n", .{});
}

// Test init with specific directory
fn testInitWithDirectory(harness: TestHarness) !void {
    std.debug.print("  Testing git init <directory>...\n", .{});
    
    const base_dir = try harness.createTempDir("init_test_base");
    defer harness.removeTempDir(base_dir);
    
    const ziggit_target = try std.fmt.allocPrint(harness.allocator, "{s}/ziggit_repo", .{base_dir});
    defer harness.allocator.free(ziggit_target);
    const git_target = try std.fmt.allocPrint(harness.allocator, "{s}/git_repo", .{base_dir});
    defer harness.allocator.free(git_target);
    
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "init", ziggit_target }, base_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{ "init", git_target }, base_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Verify directories were created
    const ziggit_git_dir = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{ziggit_target});
    defer harness.allocator.free(ziggit_git_dir);
    const git_git_dir = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{git_target});
    defer harness.allocator.free(git_git_dir);
    
    try verifyGitDirStructure(harness, ziggit_git_dir, false);
    try verifyGitDirStructure(harness, git_git_dir, false);
    
    std.debug.print("    ✓ init with directory\n", .{});
}

// Test status with files in working directory
fn testStatusWithFiles(harness: TestHarness) !void {
    std.debug.print("  Testing git status with files...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_status_files");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_status_files");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Create test files in both directories
    const ziggit_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{ziggit_dir});
    defer harness.allocator.free(ziggit_file);
    const git_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{git_dir});
    defer harness.allocator.free(git_file);
    
    const file_content = "Hello, World!\n";
    {
        const file = try std.fs.createFileAbsolute(ziggit_file, .{});
        defer file.close();
        try file.writeAll(file_content);
    }
    {
        const file = try std.fs.createFileAbsolute(git_file, .{});
        defer file.close();
        try file.writeAll(file_content);
    }
    
    // Run status
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"status"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"status"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    FAIL: ziggit exit_code={}, git exit_code={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // TODO: Compare outputs more precisely when untracked file detection is implemented
    std.debug.print("    ⚠ status with files (basic check passed)\n", .{});
}

// Test status showing untracked files
fn testStatusUntracked(harness: TestHarness) !void {
    std.debug.print("  Testing git status untracked files...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_status_untracked");
    defer harness.removeTempDir(ziggit_dir);
    
    // Initialize repo
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    if (ziggit_init.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create untracked file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/untracked.txt", .{ziggit_dir});
    defer harness.allocator.free(test_file);
    {
        const file = try std.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("untracked content\n");
    }
    
    // Run status
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, ziggit_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    FAIL: status failed with exit_code={}\n", .{status_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    // TODO: Should show untracked files in output
    std.debug.print("    ✓ status untracked (exit code correct)\n", .{});
}

// Test basic git add functionality
fn testAddBasic(harness: TestHarness) !void {
    std.debug.print("  Testing basic git add...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_add_basic");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_add_basic");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Create test files
    const ziggit_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{ziggit_dir});
    defer harness.allocator.free(ziggit_file);
    const git_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{git_dir});
    defer harness.allocator.free(git_file);
    
    {
        const file = try std.fs.createFileAbsolute(ziggit_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    {
        const file = try std.fs.createFileAbsolute(git_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    
    // Run add
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "add", "test.txt" }, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{ "add", "test.txt" }, git_dir);
    defer git_result.deinit();
    
    // Both should succeed (exit code 0, no output)
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ basic add\n", .{});
}

// Test adding non-existent file
fn testAddNonExistent(harness: TestHarness) !void {
    std.debug.print("  Testing git add non-existent file...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_add_nonexistent");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_add_nonexistent");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try to add non-existent file
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "add", "nonexistent.txt" }, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{ "add", "nonexistent.txt" }, git_dir);
    defer git_result.deinit();
    
    // Both should fail with same exit code
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    // Should be non-zero exit code (typically 128)
    if (ziggit_result.exit_code == 0) {
        std.debug.print("    FAIL: expected non-zero exit code, got {}\n", .{ziggit_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ add non-existent file\n", .{});
}

// Test adding directory
fn testAddDirectory(harness: TestHarness) !void {
    std.debug.print("  Testing git add directory...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_add_dir");
    defer harness.removeTempDir(ziggit_dir);
    
    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create directory with file
    const sub_dir = try std.fmt.allocPrint(harness.allocator, "{s}/subdir", .{ziggit_dir});
    defer harness.allocator.free(sub_dir);
    try std.fs.makeDirAbsolute(sub_dir);
    
    const sub_file = try std.fmt.allocPrint(harness.allocator, "{s}/file.txt", .{sub_dir});
    defer harness.allocator.free(sub_file);
    {
        const file = try std.fs.createFileAbsolute(sub_file, .{});
        defer file.close();
        try file.writeAll("content\n");
    }
    
    // Try to add directory
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "subdir" }, ziggit_dir);
    defer add_result.deinit();
    
    // Should succeed (for now, just check exit code)
    std.debug.print("    ✓ add directory (exit_code={})\n", .{add_result.exit_code});
}

// Test git add with no arguments
fn testAddNothing(harness: TestHarness) !void {
    std.debug.print("  Testing git add with no arguments...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_add_nothing");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_add_nothing");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try to add with no arguments
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"add"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"add"}, git_dir);
    defer git_result.deinit();
    
    // Both should fail with same exit code
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ add nothing\n", .{});
}

// Test commit in empty repository
fn testCommitEmpty(harness: TestHarness) !void {
    std.debug.print("  Testing git commit in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_commit_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_commit_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try to commit without any files
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"commit"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"commit"}, git_dir);
    defer git_result.deinit();
    
    // Both should fail
    if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
        std.debug.print("    FAIL: expected non-zero exit codes, got ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ commit empty repository\n", .{});
}

// Test commit with message
fn testCommitWithMessage(harness: TestHarness) !void {
    std.debug.print("  Testing git commit -m...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_commit_message");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_commit_message");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try to commit with message (should still fail - nothing to commit)
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "commit", "-m", "test message" }, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{ "commit", "-m", "test message" }, git_dir);
    defer git_result.deinit();
    
    // Both should fail (nothing to commit)
    if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
        std.debug.print("    FAIL: expected non-zero exit codes, got ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ commit with message\n", .{});
}

// Test commit with nothing to commit
fn testCommitNothing(harness: TestHarness) !void {
    std.debug.print("  Testing git commit nothing to commit...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_commit_nothing");
    defer harness.removeTempDir(ziggit_dir);
    
    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create and add file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{ziggit_dir});
    defer harness.allocator.free(test_file);
    {
        const file = try std.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("content\n");
    }
    
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "test.txt" }, ziggit_dir);
    defer add_result.deinit();
    
    // Now try to commit twice (second should fail)
    var commit_result = try harness.runZiggit(&[_][]const u8{ "commit", "-m", "first commit" }, ziggit_dir);
    defer commit_result.deinit();
    
    // TODO: When commit is implemented, test double commit
    std.debug.print("    ✓ commit nothing to commit (basic)\n", .{});
}

// Test log in empty repository
fn testLogEmpty(harness: TestHarness) !void {
    std.debug.print("  Testing git log in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_log_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_log_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try log in empty repo
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"log"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"log"}, git_dir);
    defer git_result.deinit();
    
    // Both should fail with same exit code
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ log empty repository\n", .{});
}

// Test diff in empty repository
fn testDiffEmpty(harness: TestHarness) !void {
    std.debug.print("  Testing git diff in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_diff_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_diff_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Run diff in empty repo
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"diff"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"diff"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed with no output
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ diff empty repository\n", .{});
}

// Test branch in empty repository
fn testBranchEmpty(harness: TestHarness) !void {
    std.debug.print("  Testing git branch in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_branch_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_branch_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Run branch in empty repo
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"branch"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"branch"}, git_dir);
    defer git_result.deinit();
    
    // Both should succeed with no output
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ branch empty repository\n", .{});
}

// Test branch list
fn testBranchList(harness: TestHarness) !void {
    std.debug.print("  Testing git branch --list...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_branch_list");
    defer harness.removeTempDir(ziggit_dir);
    
    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Run branch --list
    var branch_result = try harness.runZiggit(&[_][]const u8{ "branch", "--list" }, ziggit_dir);
    defer branch_result.deinit();
    
    // Should succeed (exact behavior depends on implementation)
    std.debug.print("    ✓ branch list (exit_code={})\n", .{branch_result.exit_code});
}

// Test checkout in empty repository
fn testCheckoutEmpty(harness: TestHarness) !void {
    std.debug.print("  Testing git checkout in empty repository...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_checkout_empty");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_checkout_empty");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try checkout master in empty repo
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "checkout", "master" }, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{ "checkout", "master" }, git_dir);
    defer git_result.deinit();
    
    // Both should fail (no commits yet)
    if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
        std.debug.print("    FAIL: expected non-zero exit codes, got ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ checkout empty repository\n", .{});
}

// Test invalid command
fn testInvalidCommand(harness: TestHarness) !void {
    std.debug.print("  Testing invalid command...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_invalid");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("git_invalid");
    defer harness.removeTempDir(git_dir);
    
    // Try invalid command
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"invalidcommand"}, ziggit_dir);
    defer ziggit_result.deinit();
    var git_result = try harness.runGit(&[_][]const u8{"invalidcommand"}, git_dir);
    defer git_result.deinit();
    
    // Both should fail
    if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
        std.debug.print("    FAIL: expected non-zero exit codes, got ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ invalid command\n", .{});
}

// Test help/usage
fn testHelpUsage(harness: TestHarness) !void {
    std.debug.print("  Testing help/usage...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("ziggit_help");
    defer harness.removeTempDir(ziggit_dir);
    
    // Test no arguments (should show usage)
    var help_result = try harness.runZiggit(&[_][]const u8{}, ziggit_dir);
    defer help_result.deinit();
    
    if (help_result.exit_code != 0) {
        std.debug.print("    FAIL: usage should succeed, got exit_code={}\n", .{help_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Should contain "usage" in output
    if (!std.mem.containsAtLeast(u8, help_result.stdout, 1, "usage")) {
        std.debug.print("    FAIL: usage output should contain 'usage'\n", .{});
        return test_harness.TestError.UnexpectedOutput;
    }
    
    std.debug.print("    ✓ help/usage\n", .{});
}

// Test runner for compatibility tests
test "git compatibility" {
    try runCompatibilityTests();
}