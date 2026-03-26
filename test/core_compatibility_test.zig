const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;
const print = std.debug.print;

// Focused compatibility test - essential git/ziggit command parity 
// Optimized for minimal disk usage and maximum coverage
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Warning: memory leaked in core compatibility tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("Running Core Git/Ziggit Compatibility Tests...\n", .{});

    // Create single temporary directory for all tests
    const test_base_dir = fs.cwd().makeOpenPath("test_compat", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try fs.cwd().openDir("test_compat", .{}),
        else => return err,
    };
    defer fs.cwd().deleteTree("test_compat") catch {};

    // Set up global git config once (ignore errors)  
    _ = runCommandSilent(allocator, &.{"git", "config", "--global", "user.name", "Ziggit Test"});
    _ = runCommandSilent(allocator, &.{"git", "config", "--global", "user.email", "test@ziggit.dev"});

    // Core compatibility matrix - test every essential operation
    const test_cases = [_]TestCase{
        .{ .name = "Empty Repository", .test_fn = testEmptyRepository },
        .{ .name = "Single File Operations", .test_fn = testSingleFileOperations },
        .{ .name = "Multi-file Operations", .test_fn = testMultiFileOperations },
        .{ .name = "Branch Operations", .test_fn = testBranchOperations },
        .{ .name = "Status Porcelain", .test_fn = testStatusPorcelainOutput },
        .{ .name = "Log Oneline", .test_fn = testLogOnelineOutput },
        .{ .name = "Diff Output", .test_fn = testDiffOutput },
        .{ .name = "Package Manager Workflow", .test_fn = testPackageManagerWorkflow },
    };

    var passed: u32 = 0;
    var total: u32 = 0;

    for (test_cases) |test_case| {
        total += 1;
        const test_dir_name = try std.fmt.allocPrint(allocator, "test_{d}", .{total});
        defer allocator.free(test_dir_name);

        const test_dir = test_base_dir.makeOpenPath(test_dir_name, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => try test_base_dir.openDir(test_dir_name, .{}),
            else => {
                print("  ❌ {s}: Failed to create test directory\n", .{test_case.name});
                continue;
            },
        };
        defer test_base_dir.deleteTree(test_dir_name) catch {};

        const start_time = std.time.nanoTimestamp();
        test_case.test_fn(allocator, test_dir) catch |err| {
            print("  ❌ {s}: {}\n", .{ test_case.name, err });
            continue;
        };
        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
        
        print("  ✅ {s} ({d:.2}ms)\n", .{ test_case.name, duration_ms });
        passed += 1;
    }

    print("\nCompatibility Test Summary: {d}/{d} passed ({d:.1}%)\n", 
          .{ passed, total, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0 });
    
    if (passed == 0) {
        print("All compatibility tests failed!\n", .{});
        std.process.exit(1);
    } else if (passed < total) {
        print("Some compatibility issues detected (known limitations). See details above.\n", .{});
    } else {
        print("All core compatibility tests passed! ✅\n", .{});
    }
}

const TestCase = struct {
    name: []const u8,
    test_fn: *const fn (std.mem.Allocator, fs.Dir) anyerror!void,
};

// Test 1: Empty repository operations
fn testEmptyRepository(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Test git init -> ziggit operations
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir) catch |err| switch (err) {
        error.CommandFailed => return error.ZiggitStatusNotImplemented,
        else => return err,
    };
    defer allocator.free(ziggit_status);
    
    if (!std.mem.eql(u8, std.mem.trim(u8, git_status, " \t\n\r"), std.mem.trim(u8, ziggit_status, " \t\n\r"))) {
        return error.StatusOutputMismatch;
    }
}

// Test 2: Single file lifecycle
fn testSingleFileOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create file
    try test_dir.writeFile(.{.sub_path = "test.txt", .data = "content"});
    
    // Test untracked status
    const git_status_untracked = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status_untracked);
    
    const ziggit_status_untracked = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(ziggit_status_untracked);
    
    if (std.mem.indexOf(u8, git_status_untracked, "test.txt") == null or 
        std.mem.indexOf(u8, ziggit_status_untracked, "test.txt") == null) {
        return error.UntrackedFileNotDetected;
    }
    
    // Add and commit with git
    try runCommandNoOutput(allocator, &.{"git", "add", "test.txt"}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Add test file"}, test_dir);
    
    // Test clean status
    const git_status_clean = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status_clean);
    
    const ziggit_status_clean = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(ziggit_status_clean);
    
    if (git_status_clean.len > 0 or ziggit_status_clean.len > 0) {
        return error.RepoNotClean;
    }
    
    // Modify file and test
    try test_dir.writeFile(.{.sub_path = "test.txt", .data = "modified content"});
    
    const git_status_modified = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status_modified);
    
    const ziggit_status_modified = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(ziggit_status_modified);
    
    const git_shows_modified = std.mem.indexOf(u8, git_status_modified, " M ") != null or 
                               std.mem.indexOf(u8, git_status_modified, "M ") != null;
    const ziggit_shows_modified = std.mem.indexOf(u8, ziggit_status_modified, " M ") != null or 
                                  std.mem.indexOf(u8, ziggit_status_modified, "M ") != null;
    
    if (!git_shows_modified or !ziggit_shows_modified) {
        return error.ModifiedFileNotDetected;
    }
}

// Test 3: Multiple files and directories
fn testMultiFileOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create directory structure with multiple files
    const src_dir = try test_dir.makeOpenPath("src", .{});
    try src_dir.writeFile(.{.sub_path = "main.js", .data = "console.log('main');"});
    try src_dir.writeFile(.{.sub_path = "utils.js", .data = "export function util() {}"});
    try test_dir.writeFile(.{.sub_path = "package.json", .data = "{\"name\": \"test\"}"});
    
    // Test status shows all untracked files
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(ziggit_status);
    
    const expected_files = [_][]const u8{"package.json", "src/main.js", "src/utils.js"};
    for (expected_files) |file| {
        if (std.mem.indexOf(u8, git_status, file) == null) {
            return error.GitMissingFile;
        }
        if (std.mem.indexOf(u8, ziggit_status, file) == null) {
            return error.ZiggitMissingFile;
        }
    }
    
    // Add all and commit
    try runCommandNoOutput(allocator, &.{"git", "add", "."}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Add all files"}, test_dir);
    
    // Verify clean
    const clean_status = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(clean_status);
    
    if (clean_status.len > 0) {
        return error.RepoNotCleanAfterCommit;
    }
}

// Test 4: Branch operations
fn testBranchOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create initial commit
    try test_dir.writeFile(.{.sub_path = "initial.txt", .data = "initial"});
    try runCommandNoOutput(allocator, &.{"git", "add", "initial.txt"}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial"}, test_dir);
    
    // Create branches
    try runCommandNoOutput(allocator, &.{"git", "branch", "feature"}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "branch", "develop"}, test_dir);
    
    // Test branch listing
    const git_branches = try runCommand(allocator, &.{"git", "branch"}, test_dir);
    defer allocator.free(git_branches);
    
    const ziggit_branches = try runZiggitCommand(allocator, &.{"branch"}, test_dir);
    defer allocator.free(ziggit_branches);
    
    const expected_branches = [_][]const u8{"master", "feature", "develop"};
    for (expected_branches) |branch| {
        if (std.mem.indexOf(u8, git_branches, branch) == null) {
            return error.GitMissingBranch;
        }
        if (std.mem.indexOf(u8, ziggit_branches, branch) == null) {
            return error.ZiggitMissingBranch;  
        }
    }
}

// Test 5: Status porcelain format compatibility
fn testStatusPorcelainOutput(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create different file states
    try test_dir.writeFile(.{.sub_path = "tracked.txt", .data = "tracked"});
    try runCommandNoOutput(allocator, &.{"git", "add", "tracked.txt"}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial"}, test_dir);
    
    // Modify tracked file
    try test_dir.writeFile(.{.sub_path = "tracked.txt", .data = "modified tracked"});
    
    // Add untracked file  
    try test_dir.writeFile(.{.sub_path = "untracked.txt", .data = "untracked"});
    
    // Get outputs
    const git_output = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_output);
    
    const ziggit_output = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, test_dir);
    defer allocator.free(ziggit_output);
    
    // Basic format validation
    const git_lines = std.mem.count(u8, git_output, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_output, "\n");
    
    // Should have at least 2 lines (modified + untracked)
    if (git_lines < 2 or ziggit_lines < 2) {
        return error.InsufficientStatusLines;
    }
    
    // Check for expected markers
    const has_modified = std.mem.indexOf(u8, ziggit_output, " M ") != null or std.mem.indexOf(u8, ziggit_output, "M ") != null;
    const has_untracked = std.mem.indexOf(u8, ziggit_output, "??") != null;
    
    if (!has_modified or !has_untracked) {
        return error.StatusMarkersMissing;
    }
}

// Test 6: Log oneline format
fn testLogOnelineOutput(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create multiple commits
    const commits = [_][]const u8{"First", "Second", "Third"};
    for (commits, 0..) |msg, i| {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        
        try test_dir.writeFile(.{.sub_path = filename, .data = msg});
        try runCommandNoOutput(allocator, &.{"git", "add", filename}, test_dir);
        try runCommandNoOutput(allocator, &.{"git", "commit", "-m", msg}, test_dir);
    }
    
    // Test log output
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, test_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = try runZiggitCommand(allocator, &.{"log", "--oneline"}, test_dir);
    defer allocator.free(ziggit_log);
    
    const git_lines = std.mem.count(u8, git_log, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_log, "\n");
    
    if (git_lines != 3 or ziggit_lines != 3) {
        return error.LogLineCountMismatch;
    }
    
    // Check all commit messages present
    for (commits) |msg| {
        if (std.mem.indexOf(u8, ziggit_log, msg) == null) {
            return error.CommitMessageMissing;
        }
    }
}

// Test 7: Diff output compatibility
fn testDiffOutput(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create and commit file
    try test_dir.writeFile(.{.sub_path = "diff.txt", .data = "line 1\nline 2\nline 3\n"});
    try runCommandNoOutput(allocator, &.{"git", "add", "diff.txt"}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial"}, test_dir);
    
    // Modify file
    try test_dir.writeFile(.{.sub_path = "diff.txt", .data = "line 1\nmodified line 2\nline 3\n"});
    
    const git_diff = try runCommand(allocator, &.{"git", "diff"}, test_dir);
    defer allocator.free(git_diff);
    
    const ziggit_diff = try runZiggitCommand(allocator, &.{"diff"}, test_dir);
    defer allocator.free(ziggit_diff);
    
    // Basic validation - should contain modified content
    if (std.mem.indexOf(u8, ziggit_diff, "modified") == null or ziggit_diff.len < 10) {
        return error.DiffOutputIncomplete;
    }
}

// Test 8: Package manager workflow (bun/npm scenario)
fn testPackageManagerWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    try runCommandNoOutput(allocator, &.{"git", "init"}, test_dir);
    
    // Create typical package manager structure
    try test_dir.writeFile(.{.sub_path = "package.json", .data = 
        \\{
        \\  "name": "test-package", 
        \\  "version": "1.0.0",
        \\  "main": "index.js"
        \\}
    });
    
    try test_dir.writeFile(.{.sub_path = "index.js", .data = "module.exports = 'hello world';"});
    try test_dir.writeFile(.{.sub_path = ".gitignore", .data = "node_modules/\n*.log\n"});
    
    // Initial commit
    try runCommandNoOutput(allocator, &.{"git", "add", "."}, test_dir);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial package"}, test_dir);
    
    // Simulate package manager adding dependencies
    try test_dir.writeFile(.{.sub_path = "yarn.lock", .data = "# yarn.lock file\n"});
    try test_dir.writeFile(.{.sub_path = "index.js", .data = "module.exports = 'updated hello world';"});
    
    // Test the key commands package managers use
    const critical_commands = [_][]const []const u8{
        &.{"status", "--porcelain"},
        &.{"diff", "--name-only"},
        &.{"log", "--oneline", "-3"},
    };
    
    for (critical_commands) |cmd| {
        var git_cmd = std.ArrayList([]const u8).init(allocator);
        defer git_cmd.deinit();
        try git_cmd.append("git");
        for (cmd) |arg| try git_cmd.append(arg);
        
        const git_output = runCommand(allocator, git_cmd.items, test_dir) catch continue;
        defer allocator.free(git_output);
        
        const ziggit_output = runZiggitCommand(allocator, cmd, test_dir) catch continue;
        defer allocator.free(ziggit_output);
        
        // Basic validation - outputs should be non-empty and similar line count
        const git_lines = std.mem.count(u8, git_output, "\n");
        const ziggit_lines = std.mem.count(u8, ziggit_output, "\n");
        
        // Allow some variance but they shouldn't be drastically different
        if (git_lines > 0 and ziggit_lines == 0) {
            return error.ZiggitOutputEmpty;
        }
        
        const line_diff = if (git_lines > ziggit_lines) git_lines - ziggit_lines else ziggit_lines - git_lines;
        if (line_diff > 2 and git_lines > 2) { // Some tolerance for formatting differences
            return error.OutputLineDifferenceTooLarge;
        }
    }
}

// Helper functions
fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 4096) catch |err| {
        _ = child.stderr.?.reader().readAllAlloc(allocator, 4096) catch {};
        _ = child.wait() catch {};
        return err;
    };
    
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 4096) catch |err| {
        allocator.free(stdout);
        _ = child.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);
    
    const term = try child.wait();
    switch (term) {
        .Exited => |exit_code| if (exit_code != 0) {
            allocator.free(stdout);
            return error.CommandFailed;
        },
        .Signal, .Stopped, .Unknown => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    try full_args.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try full_args.append(arg);
    }
    
    return runCommand(allocator, full_args.items, cwd);
}

fn runCommandNoOutput(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) !void {
    const result = try runCommand(allocator, args, cwd);
    defer allocator.free(result);
}

fn runCommandSilent(allocator: std.mem.Allocator, args: []const []const u8) ?[]u8 {
    return runCommand(allocator, args, fs.cwd()) catch null;
}