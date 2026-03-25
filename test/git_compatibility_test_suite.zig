const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const os = std.os;
const Child = std.process.Child;
const Allocator = std.mem.Allocator;

// Git Compatibility Test Suite
// Tests that ensure ziggit behaves exactly like git for basic operations

const TestResult = struct {
    name: []const u8,
    passed: bool,
    details: ?[]const u8 = null,
};

var test_results = std.ArrayList(TestResult).init(std.heap.page_allocator);
var temp_dir_counter: u32 = 0;

fn createTempTestDir(allocator: Allocator) ![]const u8 {
    temp_dir_counter += 1;
    const dir_name = try std.fmt.allocPrint(allocator, "test_compat_{d}_{d}", .{ std.time.timestamp(), temp_dir_counter });
    try fs.cwd().makeDir(dir_name);
    return dir_name;
}

fn cleanupTempDir(dir_name: []const u8) void {
    fs.cwd().deleteTree(dir_name) catch {};
}

fn runZiggit(allocator: Allocator, args: []const []const u8, cwd: ?[]const u8) !struct { output: []const u8, exit_code: u8 } {
    var cmd = std.ArrayList([]const u8).init(allocator);
    defer cmd.deinit();
    
    // Get current working directory and construct absolute path
    var current_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_dir = try std.posix.getcwd(&current_dir_buf);
    const ziggit_path = try std.fmt.allocPrint(allocator, "{/root/ziggit/zig-out/bin/ziggit", .{current_dir});
    
    try cmd.append(ziggit_path);
    for (args) |arg| {
        try cmd.append(arg);
    }

    var child = Child.init(cmd.items, allocator);
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

fn runGit(allocator: Allocator, args: []const []const u8, cwd: ?[]const u8) !struct { output: []const u8, exit_code: u8 } {
    var cmd = std.ArrayList([]const u8).init(allocator);
    defer cmd.deinit();
    
    try cmd.append("git");
    for (args) |arg| {
        try cmd.append(arg);
    }

    var child = Child.init(cmd.items, allocator);
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

// Test that compares ziggit vs git exit codes for compatibility
fn testExitCodeCompatibility(allocator: Allocator) !void {
    std.debug.print("  Testing exit code compatibility...\n", .{});
    
    // Test 1: init in new directory
    {
        const test_dir = try createTempTestDir(allocator);
        defer cleanupTempDir(test_dir);
        
        const ziggit_result = try runZiggit(allocator, &[_][]const u8{"init"}, test_dir);
        const git_result = try runGit(allocator, &[_][]const u8{"init"}, test_dir);
        
        const passed = ziggit_result.exit_code == git_result.exit_code;
        try test_results.append(.{
            .name = "init exit code",
            .passed = passed,
            .details = if (!passed) try std.fmt.allocPrint(allocator, "ziggit: {d}, git: {d}", .{ ziggit_result.exit_code, git_result.exit_code }) else null,
        });
        
        if (passed) {
            std.debug.print("    ✓ init exit code compatibility\n", .{});
        } else {
            std.debug.print("    ✗ init exit code compatibility\n", .{});
        }
    }
    
    // Test 2: status outside repository
    {
        const test_dir = try createTempTestDir(allocator);
        defer cleanupTempDir(test_dir);
        
        const ziggit_result = try runZiggit(allocator, &[_][]const u8{"status"}, test_dir);
        const git_result = try runGit(allocator, &[_][]const u8{"status"}, test_dir);
        
        // Both should fail, exit codes might differ but both should be non-zero
        const passed = (ziggit_result.exit_code != 0) == (git_result.exit_code != 0);
        try test_results.append(.{
            .name = "status outside repo exit code",
            .passed = passed,
            .details = if (!passed) try std.fmt.allocPrint(allocator, "ziggit: {d}, git: {d}", .{ ziggit_result.exit_code, git_result.exit_code }) else null,
        });
        
        if (passed) {
            std.debug.print("    ✓ status outside repo exit code compatibility\n", .{});
        } else {
            std.debug.print("    ✗ status outside repo exit code compatibility\n", .{});
        }
    }
}

// Test repository structure compatibility
fn testRepositoryStructure(allocator: Allocator) !void {
    std.debug.print("  Testing repository structure compatibility...\n", .{});
    
    const test_dir = try createTempTestDir(allocator);
    defer cleanupTempDir(test_dir);
    
    // Initialize repositories
    _ = try runZiggit(allocator, &[_][]const u8{"init"}, test_dir);
    
    // Check that .git directory exists and has expected structure
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{test_dir});
    
    var passed = true;
    var details: ?[]const u8 = null;
    
    // Check .git directory exists
    fs.cwd().access(git_dir, .{}) catch {
        passed = false;
        details = try std.fmt.allocPrint(allocator, ".git directory not found", .{});
    };
    
    if (passed) {
        // Check essential subdirectories
        const essential_dirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/tags" };
        for (essential_dirs) |dirname| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, dirname });
            fs.cwd().access(full_path, .{}) catch {
                passed = false;
                details = try std.fmt.allocPrint(allocator, "missing directory: {s}", .{dirname});
                break;
            };
        }
    }
    
    if (passed) {
        // Check essential files
        const essential_files = [_][]const u8{ "HEAD", "config" };
        for (essential_files) |filename| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, filename });
            fs.cwd().access(full_path, .{}) catch {
                passed = false;
                details = try std.fmt.allocPrint(allocator, "missing file: {s}", .{filename});
                break;
            };
        }
    }
    
    try test_results.append(.{
        .name = "repository structure",
        .passed = passed,
        .details = details,
    });
    
    if (passed) {
        std.debug.print("    ✓ repository structure compatibility\n", .{});
    } else {
        std.debug.print("    ✗ repository structure compatibility\n", .{});
    }
}

// Test basic workflow compatibility
fn testBasicWorkflowCompatibility(allocator: Allocator) !void {
    std.debug.print("  Testing basic workflow compatibility...\n", .{});
    
    const test_dir = try createTempTestDir(allocator);
    defer cleanupTempDir(test_dir);
    
    var workflow_passed = true;
    var details: ?[]const u8 = null;
    
    // Step 1: Initialize repository
    const init_result = try runZiggit(allocator, &[_][]const u8{"init"}, test_dir);
    if (init_result.exit_code != 0) {
        workflow_passed = false;
        details = try std.fmt.allocPrint(allocator, "init failed with code {d}", .{init_result.exit_code});
    }
    
    if (workflow_passed) {
        // Step 2: Create and add file
        const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir});
        try fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Hello, World!\n" });
        
        const add_result = try runZiggit(allocator, &[_][]const u8{"add", "test.txt"}, test_dir);
        if (add_result.exit_code != 0) {
            workflow_passed = false;
            details = try std.fmt.allocPrint(allocator, "add failed with code {d}: {s}", .{ add_result.exit_code, add_result.output });
        }
    }
    
    if (workflow_passed) {
        // Step 3: Check status
        const status_result = try runZiggit(allocator, &[_][]const u8{"status"}, test_dir);
        if (status_result.exit_code != 0) {
            workflow_passed = false;
            details = try std.fmt.allocPrint(allocator, "status failed with code {d}", .{status_result.exit_code});
        }
    }
    
    if (workflow_passed) {
        // Step 4: Commit
        const commit_result = try runZiggit(allocator, &[_][]const u8{"commit", "-m", "Initial commit"}, test_dir);
        if (commit_result.exit_code != 0) {
            workflow_passed = false;
            details = try std.fmt.allocPrint(allocator, "commit failed with code {d}: {s}", .{ commit_result.exit_code, commit_result.output });
        }
    }
    
    try test_results.append(.{
        .name = "basic workflow",
        .passed = workflow_passed,
        .details = details,
    });
    
    if (workflow_passed) {
        std.debug.print("    ✓ basic workflow compatibility\n", .{});
    } else {
        std.debug.print("    ✗ basic workflow compatibility\n", .{});
    }
}

// Test error message compatibility
fn testErrorMessageCompatibility(allocator: Allocator) !void {
    std.debug.print("  Testing error message compatibility...\n", .{});
    
    // Test 1: Not a git repository error
    {
        const test_dir = try createTempTestDir(allocator);
        defer cleanupTempDir(test_dir);
        
        const ziggit_result = try runZiggit(allocator, &[_][]const u8{"status"}, test_dir);
        const git_result = try runGit(allocator, &[_][]const u8{"status"}, test_dir);
        
        // Check that both contain similar error indicators
        const ziggit_has_error = std.mem.indexOf(u8, ziggit_result.output, "not a git repository") != null or
                               std.mem.indexOf(u8, ziggit_result.output, "Not a git repository") != null or
                               std.mem.indexOf(u8, ziggit_result.output, "fatal:") != null;
        
        const git_has_error = std.mem.indexOf(u8, git_result.output, "not a git repository") != null or
                            std.mem.indexOf(u8, git_result.output, "Not a git repository") != null or
                            std.mem.indexOf(u8, git_result.output, "fatal:") != null;
        
        const passed = ziggit_has_error and git_has_error;
        try test_results.append(.{
            .name = "not a repository error",
            .passed = passed,
            .details = if (!passed) try std.fmt.allocPrint(allocator, "error message format mismatch", .{}) else null,
        });
        
        if (passed) {
            std.debug.print("    ✓ not a repository error compatibility\n", .{});
        } else {
            std.debug.print("    ✗ not a repository error compatibility\n", .{});
        }
    }
}

pub fn runGitCompatibilityTestSuite() !void {
    std.debug.print("Running git compatibility test suite...\n", .{});
    
    const allocator = std.heap.page_allocator;
    
    // Make sure ziggit is built
    var build_child = Child.init(&[_][]const u8{ "zig", "build" }, allocator);
    const build_result = try build_child.spawnAndWait();
    if (build_result != .Exited or build_result.Exited != 0) {
        std.debug.print("Failed to build ziggit\n", .{});
        return;
    }
    
    try testExitCodeCompatibility(allocator);
    try testRepositoryStructure(allocator);
    try testBasicWorkflowCompatibility(allocator);
    try testErrorMessageCompatibility(allocator);
    
    // Print summary
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    for (test_results.items) |result| {
        if (result.passed) {
            passed += 1;
        } else {
            failed += 1;
            std.debug.print("  FAIL {s}", .{result.name});
            if (result.details) |details| {
                std.debug.print(": {s}", .{details});
            }
            std.debug.print("\n", .{});
        }
    }
    
    std.debug.print("Git compatibility test suite completed: {d} passed, {d} failed\n", .{ passed, failed });
}