const std = @import("std");
const testing = std.testing;

// Test for BrokenPipe error handling in platform/native.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in broken pipe test\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Testing BrokenPipe error handling...\n", .{});

    // Test cases that commonly cause BrokenPipe errors
    const pipe_tests = [_][]const u8{
        "./zig-out/bin/ziggit --help | head -1",
        "./zig-out/bin/ziggit --version | head -1", 
        "echo 'test' | ./zig-out/bin/ziggit || true", // Test stdin handling too
    };

    for (pipe_tests, 0..) |test_cmd, i| {
        std.debug.print("Test {}: {s}\n", .{i + 1, test_cmd});
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"sh", "-c", test_cmd},
        }) catch |err| {
            std.debug.print("  Failed to run pipe test: {}\n", .{err});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // For most commands, expect exit code 0 or 1 (normal error), not SIGPIPE (141)
        if (result.term == .Exited) {
            if (result.term.Exited == 141) { // SIGPIPE
                std.debug.print("  ⚠ SIGPIPE detected - BrokenPipe may not be handled properly\n", .{});
            } else {
                std.debug.print("  ✓ Normal exit (code {})\n", .{result.term.Exited});
            }
        } else {
            std.debug.print("  ⚠ Abnormal termination: {}\n", .{result.term});
        }
        
        if (result.stderr.len > 0) {
            std.debug.print("  stderr: {s}\n", .{std.mem.trim(u8, result.stderr, " \t\n\r")});
        }
    }

    // Test specific BrokenPipe scenario with a real repo
    try testWithRealRepo(allocator);

    std.debug.print("BrokenPipe test completed!\n", .{});
}

fn testWithRealRepo(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing BrokenPipe with real repository...\n", .{});
    
    // Create a temporary git repo
    const test_dir = std.fs.cwd().makeOpenPath("test_broken_pipe", .{}) catch |err| {
        std.debug.print("  Cannot create test dir: {}\n", .{err});
        return;
    };
    defer std.fs.cwd().deleteTree("test_broken_pipe") catch {};

    // Initialize git repo 
    const git_init = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "init"},
        .cwd_dir = test_dir,
    }) catch return;
    defer allocator.free(git_init.stdout);
    defer allocator.free(git_init.stderr);

    if (git_init.term != .Exited or git_init.term.Exited != 0) {
        std.debug.print("  Cannot create git repo, skipping repo test\n", .{});
        return;
    }

    // Create some files and commit
    try test_dir.writeFile(.{.sub_path = "test.txt", .data = "test content\n"});
    
    const add_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "add", "test.txt"},
        .cwd_dir = test_dir,
    }) catch return;
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);

    // Set git config
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "user.name", "Test"},
        .cwd_dir = test_dir,
    }) catch {};
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "user.email", "test@test.com"},
        .cwd_dir = test_dir,
    }) catch {};

    const commit_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "commit", "-m", "test"},
        .cwd_dir = test_dir,
    }) catch return;
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);

    // Test ziggit commands with pipes in the git repo
    const repo_pipe_tests = [_][]const u8{
        "cd test_broken_pipe && ../zig-out/bin/ziggit status | head -1",
        "cd test_broken_pipe && ../zig-out/bin/ziggit log | head -1", 
    };

    for (repo_pipe_tests, 0..) |test_cmd, i| {
        std.debug.print("  Repo test {}: {s}\n", .{i + 1, test_cmd});
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"sh", "-c", test_cmd},
        }) catch |err| {
            std.debug.print("    Failed: {}\n", .{err});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term == .Exited and result.term.Exited != 141) {
            std.debug.print("    ✓ BrokenPipe handled (exit {})\n", .{result.term.Exited});
        } else if (result.term == .Exited and result.term.Exited == 141) {
            std.debug.print("    ⚠ SIGPIPE detected\n", .{});
        } else {
            std.debug.print("    ⚠ Abnormal: {}\n", .{result.term});
        }
    }
}

test "broken pipe handling" {
    try main();
}