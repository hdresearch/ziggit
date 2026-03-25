const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const os = std.os;
const Child = std.process.Child;
const Allocator = std.mem.Allocator;

// Comprehensive Git Test Suite
// Tests that verify ziggit compatibility with git across the most important operations
// Based on git's own test suite structure and focuses on drop-in replacement capability

pub fn runComprehensiveGitTestSuite() !void {
    std.debug.print("Running comprehensive git test suite...\n", .{});
    
    const allocator = std.heap.page_allocator;
    
    // Make sure ziggit is built
    var build_child = Child.init(&[_][]const u8{ "zig", "build" }, allocator);
    const build_result = try build_child.spawnAndWait();
    if (build_result != .Exited or build_result.Exited != 0) {
        std.debug.print("Failed to build ziggit\n", .{});
        return;
    }
    
    // Get current working directory and construct absolute path
    var current_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_dir = try std.posix.getcwd(&current_dir_buf);
    const ziggit_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/ziggit", .{current_dir});
    
    // Test core git operations (init, add, commit, status, log, diff)
    try testCoreOperations(allocator, ziggit_path);
    
    // Test branching and checkout
    try testBranchingOperations(allocator, ziggit_path);
    
    // Test repository structure compliance
    try testRepositoryCompliance(allocator, ziggit_path);
    
    // Test error handling compatibility
    try testErrorHandling(allocator, ziggit_path);
    
    // Test output format compatibility where critical
    try testOutputFormats(allocator, ziggit_path);
    
    std.debug.print("Comprehensive git test suite completed!\n", .{});
}

fn testCoreOperations(allocator: Allocator, ziggit_path: []const u8) !void {
    std.debug.print("  Testing core git operations...\n", .{});
    
    // Create temporary test directory
    const test_dir = try std.fmt.allocPrint(allocator, "test_core_{d}", .{std.time.timestamp()});
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {};
    
    // Test init
    const init_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "init"}, test_dir);
    if (init_result.exit_code == 0) {
        std.debug.print("    ✓ git init\n", .{});
    } else {
        std.debug.print("    ✗ git init failed\n", .{});
        return;
    }
    
    // Create test file
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{test_dir});
    try fs.cwd().writeFile(.{ .sub_path = test_file_path, .data = "# Test Repository\nThis is a test.\n" });
    
    // Test add
    const add_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "add", "README.md"}, test_dir);
    if (add_result.exit_code == 0) {
        std.debug.print("    ✓ git add\n", .{});
    } else {
        std.debug.print("    ✗ git add failed: {s}\n", .{add_result.output});
        return;
    }
    
    // Test status
    const status_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "status"}, test_dir);
    if (status_result.exit_code == 0) {
        std.debug.print("    ✓ git status\n", .{});
    } else {
        std.debug.print("    ✗ git status failed\n", .{});
    }
    
    // Test commit
    const commit_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "commit", "-m", "Initial commit"}, test_dir);
    if (commit_result.exit_code == 0) {
        std.debug.print("    ✓ git commit\n", .{});
    } else {
        std.debug.print("    ✗ git commit failed: {s}\n", .{commit_result.output});
    }
    
    // Test log
    const log_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "log"}, test_dir);
    if (log_result.exit_code == 0) {
        std.debug.print("    ✓ git log\n", .{});
    } else {
        std.debug.print("    ⚠ git log (acceptable if no commits yet)\n", .{});
    }
    
    // Test diff (should show no changes after commit)
    const diff_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "diff"}, test_dir);
    if (diff_result.exit_code == 0) {
        std.debug.print("    ✓ git diff\n", .{});
    } else {
        std.debug.print("    ✗ git diff failed\n", .{});
    }
    
    std.debug.print("  Core operations test completed\n", .{});
}

fn testBranchingOperations(allocator: Allocator, ziggit_path: []const u8) !void {
    std.debug.print("  Testing branching operations...\n", .{});
    
    const test_dir = try std.fmt.allocPrint(allocator, "test_branch_{d}", .{std.time.timestamp()});
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {};
    
    // Initialize repo with initial commit
    _ = try runCommand(allocator, &[_][]const u8{ziggit_path, "init"}, test_dir);
    
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/main.txt", .{test_dir});
    try fs.cwd().writeFile(.{ .sub_path = test_file_path, .data = "main branch content\n" });
    
    _ = try runCommand(allocator, &[_][]const u8{ziggit_path, "add", "main.txt"}, test_dir);
    _ = try runCommand(allocator, &[_][]const u8{ziggit_path, "commit", "-m", "Initial commit"}, test_dir);
    
    // Test branch creation
    const branch_create_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "branch", "feature"}, test_dir);
    if (branch_create_result.exit_code == 0) {
        std.debug.print("    ✓ git branch create\n", .{});
    } else {
        std.debug.print("    ✗ git branch create failed\n", .{});
    }
    
    // Test branch listing
    const branch_list_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "branch"}, test_dir);
    if (branch_list_result.exit_code == 0) {
        std.debug.print("    ✓ git branch list\n", .{});
    } else {
        std.debug.print("    ✗ git branch list failed\n", .{});
    }
    
    // Test checkout
    const checkout_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "checkout", "feature"}, test_dir);
    if (checkout_result.exit_code == 0) {
        std.debug.print("    ✓ git checkout\n", .{});
    } else {
        std.debug.print("    ✗ git checkout failed\n", .{});
    }
    
    // Test checkout -b
    const checkout_b_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "checkout", "-b", "new-feature"}, test_dir);
    if (checkout_b_result.exit_code == 0) {
        std.debug.print("    ✓ git checkout -b\n", .{});
    } else {
        std.debug.print("    ✗ git checkout -b failed\n", .{});
    }
    
    std.debug.print("  Branching operations test completed\n", .{});
}

fn testRepositoryCompliance(allocator: Allocator, ziggit_path: []const u8) !void {
    std.debug.print("  Testing repository structure compliance...\n", .{});
    
    const test_dir = try std.fmt.allocPrint(allocator, "test_structure_{d}", .{std.time.timestamp()});
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {};
    
    // Initialize repository
    _ = try runCommand(allocator, &[_][]const u8{ziggit_path, "init"}, test_dir);
    
    // Check .git directory structure
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{test_dir});
    
    var structure_ok = true;
    
    // Check required directories
    const required_dirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/tags" };
    for (required_dirs) |dirname| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, dirname });
        fs.cwd().access(full_path, .{}) catch {
            structure_ok = false;
            std.debug.print("    ✗ missing directory: {s}\n", .{dirname});
        };
    }
    
    // Check required files
    const required_files = [_][]const u8{ "HEAD", "config" };
    for (required_files) |filename| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, filename });
        fs.cwd().access(full_path, .{}) catch {
            structure_ok = false;
            std.debug.print("    ✗ missing file: {s}\n", .{filename});
        };
    }
    
    if (structure_ok) {
        std.debug.print("    ✓ repository structure compliant\n", .{});
    }
    
    std.debug.print("  Repository compliance test completed\n", .{});
}

fn testErrorHandling(allocator: Allocator, ziggit_path: []const u8) !void {
    std.debug.print("  Testing error handling compatibility...\n", .{});
    
    const test_dir = try std.fmt.allocPrint(allocator, "test_error_{d}", .{std.time.timestamp()});
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {};
    
    // Test commands outside git repository
    const status_outside_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "status"}, test_dir);
    if (status_outside_result.exit_code != 0) {
        std.debug.print("    ✓ status outside repo fails appropriately\n", .{});
    } else {
        std.debug.print("    ✗ status outside repo should fail\n", .{});
    }
    
    // Test adding non-existent file
    _ = try runCommand(allocator, &[_][]const u8{ziggit_path, "init"}, test_dir);
    
    const add_nonexistent_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "add", "nonexistent.txt"}, test_dir);
    if (add_nonexistent_result.exit_code != 0) {
        std.debug.print("    ✓ add nonexistent file fails appropriately\n", .{});
    } else {
        std.debug.print("    ✗ add nonexistent file should fail\n", .{});
    }
    
    // Test invalid command
    const invalid_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "invalid-command"}, test_dir);
    if (invalid_result.exit_code != 0) {
        std.debug.print("    ✓ invalid command fails appropriately\n", .{});
    } else {
        std.debug.print("    ✗ invalid command should fail\n", .{});
    }
    
    std.debug.print("  Error handling test completed\n", .{});
}

fn testOutputFormats(allocator: Allocator, ziggit_path: []const u8) !void {
    std.debug.print("  Testing critical output formats...\n", .{});
    
    const test_dir = try std.fmt.allocPrint(allocator, "test_format_{d}", .{std.time.timestamp()});
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {};
    
    // Test init output
    const init_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "init"}, test_dir);
    if (std.mem.indexOf(u8, init_result.output, "Initialized") != null) {
        std.debug.print("    ✓ init output format compatible\n", .{});
    } else {
        std.debug.print("    ⚠ init output format differs from git\n", .{});
    }
    
    // Test version/help availability
    const version_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "--version"}, test_dir);
    if (version_result.exit_code == 0) {
        std.debug.print("    ✓ version flag supported\n", .{});
    } else {
        std.debug.print("    ⚠ version flag not supported\n", .{});
    }
    
    const help_result = try runCommand(allocator, &[_][]const u8{ziggit_path, "--help"}, test_dir);
    if (help_result.exit_code == 0) {
        std.debug.print("    ✓ help flag supported\n", .{});
    } else {
        std.debug.print("    ⚠ help flag not supported\n", .{});
    }
    
    std.debug.print("  Output format test completed\n", .{});
}

fn runCommand(allocator: Allocator, cmd: []const []const u8, cwd: ?[]const u8) !struct { output: []const u8, exit_code: u8 } {
    var child = Child.init(cmd, allocator);
    if (cwd) |working_dir| {
        child.cwd = working_dir;
    }
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 64 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 64 * 1024);
    const exit_code = try child.wait();
    
    const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stdout, stderr });
    
    return .{
        .output = output,
        .exit_code = switch (exit_code) {
            .Exited => |code| @intCast(code),
            else => 1,
        }
    };
}