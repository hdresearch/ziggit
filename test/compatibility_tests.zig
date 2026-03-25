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
    
    // Status tests
    try testStatusEmptyRepo(harness);
    try testStatusNotARepo(harness);
    
    // Add tests (when implemented)
    try testAddNotImplemented(harness);
    
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

// Test runner for compatibility tests
test "git compatibility" {
    try runCompatibilityTests();
}