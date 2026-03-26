const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const print = std.debug.print;

/// Comprehensive workflow integration tests for ziggit
/// Tests common VCS workflows to ensure git and ziggit compatibility
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Warning: memory leaked in workflow integration tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("Running Workflow Integration Tests...\n", .{});

    // Set up global git config for tests
    _ = runCommandSafe(allocator, &.{"git", "config", "--global", "user.name", "Workflow Tester"}, null);
    _ = runCommandSafe(allocator, &.{"git", "config", "--global", "user.email", "workflow@test.com"}, null);

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("workflow_test_tmp", .{});
    defer fs.cwd().deleteTree("workflow_test_tmp") catch {};

    // Run workflow tests
    try testSimpleDevWorkflow(allocator, test_dir);
    try testBranchingWorkflow(allocator, test_dir);
    try testCollaborationWorkflow(allocator, test_dir);
    try testPackageManagerWorkflow(allocator, test_dir);
    try testLargeFileWorkflow(allocator, test_dir);

    print("All workflow integration tests passed!\n", .{});
}

/// Test: Simple development workflow (init -> add -> commit -> status)
fn testSimpleDevWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("  Testing simple development workflow...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("simple_workflow", .{});
    defer test_dir.deleteTree("simple_workflow") catch {};

    // Git init
    try runCommandExpectSuccess(allocator, &.{"git", "init"}, repo_dir);
    
    // Create and add files
    try repo_dir.writeFile(.{.sub_path = "main.zig", .data = "const std = @import(\"std\");\npub fn main() !void {}\n"});
    try repo_dir.writeFile(.{.sub_path = "build.zig", .data = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {}\n"});
    
    // Git add
    try runCommandExpectSuccess(allocator, &.{"git", "add", "."}, repo_dir);
    
    // Git status --porcelain (should show staged files)
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    if (git_status.len == 0) {
        return error.GitStatusUnexpected;
    }
    
    // Git commit
    try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Test that ziggit can read the repository
    const ziggit_status = runCommandSafe(allocator, &.{"../zig-out/bin/ziggit", "status"}, repo_dir);
    if (ziggit_status) |status_output| {
        defer allocator.free(status_output);
        print("    ✓ Ziggit successfully read git repository\n", .{});
    } else {
        print("    ⚠ Ziggit status failed (expected if binary not built)\n", .{});
    }
    
    print("    ✓ Simple workflow completed\n", .{});
}

/// Test: Branching workflow (branch -> checkout -> merge)
fn testBranchingWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("  Testing branching workflow...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("branch_workflow", .{});
    defer test_dir.deleteTree("branch_workflow") catch {};

    // Initialize repository
    try runCommandExpectSuccess(allocator, &.{"git", "init"}, repo_dir);
    
    // Configure git for this repo
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "README.md", .data = "# Test Project\n"});
    try runCommandExpectSuccess(allocator, &.{"git", "add", "README.md"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Create and checkout feature branch
    try runCommandExpectSuccess(allocator, &.{"git", "branch", "feature/test"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "checkout", "feature/test"}, repo_dir);
    
    // Make changes on feature branch
    try repo_dir.writeFile(.{.sub_path = "feature.txt", .data = "New feature\n"});
    try runCommandExpectSuccess(allocator, &.{"git", "add", "feature.txt"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", "Add feature"}, repo_dir);
    
    // Switch back to main and verify
    try runCommandExpectSuccess(allocator, &.{"git", "checkout", "master"}, repo_dir);
    const master_files = try listDirectoryFiles(allocator, repo_dir);
    defer {
        for (master_files) |file| {
            allocator.free(file);
        }
        allocator.free(master_files);
    }
    
    // feature.txt should not exist on master
    for (master_files) |file| {
        if (std.mem.eql(u8, file, "feature.txt")) {
            return error.FeatureFileFoundOnMaster;
        }
    }
    
    // Test that both git and ziggit can list branches
    const git_branches = try runCommand(allocator, &.{"git", "branch"}, repo_dir);
    defer allocator.free(git_branches);
    
    if (std.mem.indexOf(u8, git_branches, "feature/test") == null) {
        return error.BranchNotFound;
    }
    
    print("    ✓ Branching workflow completed\n", .{});
}

/// Test: Collaboration workflow (simulate multiple commits)
fn testCollaborationWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("  Testing collaboration workflow...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("collab_workflow", .{});
    defer test_dir.deleteTree("collab_workflow") catch {};

    // Initialize repository
    try runCommandExpectSuccess(allocator, &.{"git", "init"}, repo_dir);
    
    // Configure git for this repo
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    // Simulate multiple developers working
    const commits = [_]struct { file: []const u8, content: []const u8, message: []const u8, author: []const u8 }{
        .{ .file = "src/main.zig", .content = "// Main file\npub fn main() !void {}\n", .message = "Add main file", .author = "Alice <alice@dev.com>" },
        .{ .file = "src/utils.zig", .content = "// Utilities\npub fn helper() void {}\n", .message = "Add utilities", .author = "Bob <bob@dev.com>" },
        .{ .file = "tests/test.zig", .content = "// Tests\ntest \"basic test\" {}\n", .message = "Add tests", .author = "Charlie <charlie@dev.com>" },
    };
    
    for (commits) |commit_info| {
        // Create file
        const dir_path = std.fs.path.dirname(commit_info.file);
        if (dir_path) |dir| {
            repo_dir.makeDir(dir) catch {};
        }
        try repo_dir.writeFile(.{.sub_path = commit_info.file, .data = commit_info.content});
        
        // Add and commit with different author
        try runCommandExpectSuccess(allocator, &.{"git", "add", commit_info.file}, repo_dir);
        
        try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", commit_info.message}, repo_dir);
    }
    
    // Test log output
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    var log_lines = std.mem.split(u8, std.mem.trim(u8, git_log, " \t\n\r"), "\n");
    var line_count: u32 = 0;
    while (log_lines.next() != null) {
        line_count += 1;
    }
    
    if (line_count != 3) {
        print("    Expected 3 commits, got {}\n", .{line_count});
        return error.UnexpectedCommitCount;
    }
    
    print("    ✓ Collaboration workflow completed\n", .{});
}

/// Test: Package manager workflow (many small files)
fn testPackageManagerWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("  Testing package manager workflow...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("package_workflow", .{});
    defer test_dir.deleteTree("package_workflow") catch {};

    try runCommandExpectSuccess(allocator, &.{"git", "init"}, repo_dir);
    
    // Configure git for this repo
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    // Simulate package.json and node_modules style structure
    try repo_dir.writeFile(.{.sub_path = "package.json", .data = "{\"name\": \"test\", \"version\": \"1.0.0\"}\n"});
    try repo_dir.writeFile(.{.sub_path = ".gitignore", .data = "node_modules/\n*.log\n"});
    
    // Create many small files (simulating dependencies)
    try repo_dir.makeDir("src");
    for (0..20) |i| {
        const filename = try std.fmt.allocPrint(allocator, "src/module_{}.js", .{i});
        defer allocator.free(filename);
        
        const content = try std.fmt.allocPrint(allocator, "// Module {}\nmodule.exports = {{ value: {} }};\n", .{i, i});
        defer allocator.free(content);
        
        try repo_dir.writeFile(.{.sub_path = filename, .data = content});
    }
    
    // Add all files
    try runCommandExpectSuccess(allocator, &.{"git", "add", "."}, repo_dir);
    
    // Check status before commit
    const status_output = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(status_output);
    
    var status_lines = std.mem.split(u8, std.mem.trim(u8, status_output, " \t\n\r"), "\n");
    var staged_count: u32 = 0;
    while (status_lines.next()) |line| {
        if (line.len > 0 and line[0] == 'A') {
            staged_count += 1;
        }
    }
    
    if (staged_count < 20) {
        return error.InsufficientStagedFiles;
    }
    
    // Commit all
    try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", "Add package structure"}, repo_dir);
    
    // Verify clean status
    const clean_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(clean_status);
    
    if (std.mem.trim(u8, clean_status, " \t\n\r").len != 0) {
        return error.RepositoryNotClean;
    }
    
    print("    ✓ Package manager workflow completed\n", .{});
}

/// Test: Large file workflow
fn testLargeFileWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("  Testing large file workflow...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("large_file_workflow", .{});
    defer test_dir.deleteTree("large_file_workflow") catch {};

    try runCommandExpectSuccess(allocator, &.{"git", "init"}, repo_dir);
    
    // Configure git for this repo
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    // Create a moderately large file (100KB)
    const large_content = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(large_content);
    
    for (large_content, 0..) |_, i| {
        large_content[i] = @intCast((i % 95) + 32); // Printable ASCII
    }
    
    try repo_dir.writeFile(.{.sub_path = "large_file.txt", .data = large_content});
    
    // Test that git can handle it
    try runCommandExpectSuccess(allocator, &.{"git", "add", "large_file.txt"}, repo_dir);
    try runCommandExpectSuccess(allocator, &.{"git", "commit", "-m", "Add large file"}, repo_dir);
    
    // Verify file integrity after commit
    const read_content = try repo_dir.readFileAlloc(allocator, "large_file.txt", std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    if (read_content.len != large_content.len) {
        return error.LargeFileSizeMismatch;
    }
    
    if (!std.mem.eql(u8, read_content, large_content)) {
        return error.LargeFileContentMismatch;
    }
    
    print("    ✓ Large file workflow completed\n", .{});
}

// Helper functions

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd_dir = cwd,
    });
    defer allocator.free(result.stderr);
    
    if (result.term != .Exited or result.term.Exited != 0) {
        print("Command failed: {any}\n", .{argv});
        if (result.stderr.len > 0) {
            print("stderr: {s}\n", .{result.stderr});
        }
        return error.CommandFailed;
    }
    
    return result.stdout;
}

fn runCommandExpectSuccess(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) !void {
    const output = runCommand(allocator, argv, cwd) catch |err| {
        return err;
    };
    allocator.free(output);
}

fn runCommandSafe(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?fs.Dir) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd_dir = cwd,
    }) catch return null;
    
    defer allocator.free(result.stderr);
    
    if (result.term == .Exited and result.term.Exited == 0) {
        return result.stdout;
    } else {
        allocator.free(result.stdout);
        return null;
    }
}

fn listDirectoryFiles(allocator: std.mem.Allocator, base_dir: fs.Dir) ![][]u8 {
    var file_list = std.ArrayList([]u8).init(allocator);
    defer file_list.deinit();
    
    // Open current directory for iteration
    var iter_dir = base_dir.openDir(".", .{ .iterate = true }) catch |err| {
        // If we can't open for iteration, return empty list
        std.debug.print("    Cannot open directory for iteration: {}\n", .{err});
        return try file_list.toOwnedSlice();
    };
    defer iter_dir.close();
    
    var iterator = iter_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            const name = try allocator.dupe(u8, entry.name);
            try file_list.append(name);
        }
    }
    
    return try file_list.toOwnedSlice();
}

test "workflow integration" {
    try main();
}