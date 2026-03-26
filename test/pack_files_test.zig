const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

/// Test pack file reading functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in pack file tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Pack File Tests...\n", .{});

    // Set up global git config for tests
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "config", "--global", "user.name", "Test User"},
        }) catch return;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "config", "--global", "user.email", "test@example.com"},
        }) catch return;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_tmp_pack", .{});
    defer fs.cwd().deleteTree("test_tmp_pack") catch {};

    try testPackFileReading(allocator, test_dir);

    std.debug.print("Pack file tests completed!\n", .{});
}

fn testPackFileReading(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test: Pack file reading after git gc\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("pack_repo", .{});
    defer test_dir.deleteTree("pack_repo") catch {};

    // Initialize repository
    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create initial file and commit
    try repo_path.writeFile(.{.sub_path = "initial.txt", .data = "Initial content\n"});
    try runCommandNoOutput(allocator, &.{"git", "add", "initial.txt"}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_path);

    // Create several commits to trigger pack creation
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {}\n", .{i});
        defer allocator.free(content);
        
        try repo_path.writeFile(.{.sub_path = filename, .data = content});
        try runCommandNoOutput(allocator, &.{"git", "add", filename}, repo_path);
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i});
        defer allocator.free(commit_msg);
        try runCommandNoOutput(allocator, &.{"git", "commit", "-m", commit_msg}, repo_path);
    }

    // Show git log before gc
    std.debug.print("  Git log before gc:\n", .{});
    const git_log_before = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_path);
    defer allocator.free(git_log_before);
    std.debug.print("  {s}\n", .{git_log_before});

    // Show ziggit log before gc
    std.debug.print("  Ziggit log before gc:\n", .{});
    const ziggit_log_before = runZiggitCommand(allocator, &.{"log"}, repo_path) catch |err| {
        std.debug.print("  Error running ziggit log before gc: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_log_before);
    std.debug.print("  {s}\n", .{ziggit_log_before});

    // Check what's in .git/objects before gc
    std.debug.print("  Objects before gc:\n", .{});
    listObjectsDir(repo_path, ".git/objects") catch {};

    // Run git gc to create pack files
    std.debug.print("  Running git gc...\n", .{});
    const gc_result = runCommand(allocator, &.{"git", "gc", "--aggressive"}, repo_path) catch |err| {
        std.debug.print("  git gc failed: {}\n", .{err});
        return;
    };
    defer allocator.free(gc_result);
    std.debug.print("  git gc output: {s}\n", .{gc_result});

    // Check what's in .git/objects after gc
    std.debug.print("  Objects after gc:\n", .{});
    listObjectsDir(repo_path, ".git/objects") catch {};
    listPackFiles(repo_path, ".git/objects/pack") catch {};

    // Show git log after gc (should still work)
    std.debug.print("  Git log after gc:\n", .{});
    const git_log_after = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_path);
    defer allocator.free(git_log_after);
    std.debug.print("  {s}\n", .{git_log_after});

    // Try ziggit log after gc - this is where the problem occurs
    std.debug.print("  Ziggit log after gc:\n", .{});
    const ziggit_log_after = runZiggitCommand(allocator, &.{"log"}, repo_path) catch |err| {
        std.debug.print("  Error running ziggit log after gc: {}\n", .{err});
        std.debug.print("  This confirms the pack file reading issue\n", .{});
        return;
    };
    defer allocator.free(ziggit_log_after);
    std.debug.print("  {s}\n", .{ziggit_log_after});

    // Check if ziggit found the initial commit
    if (std.mem.indexOf(u8, ziggit_log_after, "Initial commit")) |_| {
        std.debug.print("  ✓ ziggit successfully read from pack files\n", .{});
    } else {
        std.debug.print("  ✗ ziggit failed to read from pack files\n", .{});
    }
}

fn listObjectsDir(repo_path: fs.Dir, objects_path: []const u8) !void {
    var objects_dir = repo_path.openDir(objects_path, .{.iterate = true}) catch |err| {
        std.debug.print("    Could not open {s}: {}\n", .{objects_path, err});
        return;
    };
    defer objects_dir.close();

    var iterator = objects_dir.iterate();
    while (try iterator.next()) |entry| {
        std.debug.print("    {s}: {s}\n", .{@tagName(entry.kind), entry.name});
    }
}

fn listPackFiles(repo_path: fs.Dir, pack_path: []const u8) !void {
    std.debug.print("  Pack files:\n", .{});
    var pack_dir = repo_path.openDir(pack_path, .{.iterate = true}) catch |err| {
        std.debug.print("    Could not open {s}: {}\n", .{pack_path, err});
        return;
    };
    defer pack_dir.close();

    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        std.debug.print("    {s}: {s}\n", .{@tagName(entry.kind), entry.name});
        
        // Show size of pack files
        if (std.mem.endsWith(u8, entry.name, ".pack") or std.mem.endsWith(u8, entry.name, ".idx")) {
            const file = pack_dir.openFile(entry.name, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            std.debug.print("      Size: {} bytes\n", .{stat.size});
        }
    }
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = child.wait() catch {};
        return err;
    };
    
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = child.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\nstderr: {s}\n", .{args[0], stderr});
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

// Helper function for running commands when output is not needed
fn runCommandNoOutput(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) !void {
    const result = try runCommand(allocator, args, cwd);
    defer allocator.free(result);
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

test "pack file reading" {
    try main();
}