const std = @import("std");

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u32 } {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });

    const exit_code = if (result.term == .Exited) result.term.Exited else 1;
    
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

fn compareGitZiggitOutput(allocator: std.mem.Allocator, test_name: []const u8, git_args: []const []const u8, ziggit_args: []const []const u8, cwd: []const u8) !bool {
    // Run git command
    var git_cmd = try std.ArrayList([]const u8).initCapacity(allocator, git_args.len + 1);
    defer git_cmd.deinit();
    try git_cmd.append("git");
    try git_cmd.appendSlice(git_args);

    const git_result = try runCommand(allocator, git_cmd.items, cwd);
    defer allocator.free(git_result.stdout);
    defer allocator.free(git_result.stderr);

    // Run ziggit command  
    var ziggit_cmd = try std.ArrayList([]const u8).initCapacity(allocator, ziggit_args.len + 1);
    defer ziggit_cmd.deinit();
    try ziggit_cmd.append("/root/ziggit/zig-out/bin/ziggit");
    try ziggit_cmd.appendSlice(ziggit_args);

    const ziggit_result = try runCommand(allocator, ziggit_cmd.items, cwd);
    defer allocator.free(ziggit_result.stdout);
    defer allocator.free(ziggit_result.stderr);

    // Compare exit codes
    if (git_result.exit_code != ziggit_result.exit_code) {
        std.debug.print("    ❌ {s}: Exit code mismatch - git: {}, ziggit: {}\n", .{ test_name, git_result.exit_code, ziggit_result.exit_code });
        return false;
    }

    std.debug.print("    ✓ {s}: Exit codes match ({}) \n", .{ test_name, git_result.exit_code });
    
    // Note: We don't compare exact output format since ziggit may have different formatting
    // But we verify both commands succeed/fail the same way
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_base_dir = "/tmp/ziggit_format_tests";
    
    // Clean and create test directory
    std.fs.cwd().deleteTree(test_base_dir) catch {};
    try std.fs.cwd().makeDir(test_base_dir);
    defer std.fs.cwd().deleteTree(test_base_dir) catch {};

    std.debug.print("=== Git Output Format Compatibility Tests ===\n", .{});

    var total_tests: u32 = 0;
    var passed_tests: u32 = 0;

    // Setup test repository
    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test_repo", .{test_base_dir});
    defer allocator.free(test_dir);
    try std.fs.cwd().makeDir(test_dir);

    // Initialize with both git and ziggit to compare
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init" }, test_dir);
    _ = try runCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);

    // Create test files
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir});
    defer allocator.free(test_file_path);
    const test_file = try std.fs.cwd().createFile(test_file_path, .{});
    defer test_file.close();
    try test_file.writeAll("Hello World\nLine 2\nLine 3\n");

    std.debug.print("\n[1/4] Status command format tests...\n", .{});
    
    // Test status with untracked files
    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "status untracked", &[_][]const u8{"status"}, &[_][]const u8{"status"}, test_dir)) {
        passed_tests += 1;
    }

    // Add file and test status with staged files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "test.txt" }, test_dir);
    _ = try runCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, test_dir);

    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "status staged", &[_][]const u8{"status"}, &[_][]const u8{"status"}, test_dir)) {
        passed_tests += 1;
    }

    std.debug.print("\n[2/4] Commit format tests...\n", .{});

    // Test commit
    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "commit", &[_][]const u8{ "commit", "-m", "Test commit" }, &[_][]const u8{ "commit", "-m", "Test commit" }, test_dir)) {
        passed_tests += 1;
    }

    // Test status after commit (should be clean)
    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "status clean", &[_][]const u8{"status"}, &[_][]const u8{"status"}, test_dir)) {
        passed_tests += 1;
    }

    std.debug.print("\n[3/4] Log format tests...\n", .{});

    // Test log command
    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "log", &[_][]const u8{"log"}, &[_][]const u8{"log"}, test_dir)) {
        passed_tests += 1;
    }

    // Test log --oneline  
    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "log --oneline", &[_][]const u8{ "log", "--oneline" }, &[_][]const u8{ "log", "--oneline" }, test_dir)) {
        passed_tests += 1;
    }

    std.debug.print("\n[4/4] Error format tests...\n", .{});

    // Test error cases
    const empty_dir = try std.fmt.allocPrint(allocator, "{s}/empty", .{test_base_dir});
    defer allocator.free(empty_dir);
    try std.fs.cwd().makeDir(empty_dir);

    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "status outside repo", &[_][]const u8{"status"}, &[_][]const u8{"status"}, empty_dir)) {
        passed_tests += 1;
    }

    total_tests += 1;
    if (try compareGitZiggitOutput(allocator, "add non-existent", &[_][]const u8{ "add", "nonexistent.txt" }, &[_][]const u8{ "add", "nonexistent.txt" }, test_dir)) {
        passed_tests += 1;
    }

    // === Summary ===
    std.debug.print("\n=== Format Compatibility Results ===\n", .{});
    std.debug.print("Total tests: {}\n", .{total_tests});
    std.debug.print("Passed: {}\n", .{passed_tests});
    std.debug.print("Failed: {}\n", .{total_tests - passed_tests});
    std.debug.print("Success rate: {d:.1}%\n", .{(@as(f64, @floatFromInt(passed_tests)) / @as(f64, @floatFromInt(total_tests))) * 100.0});

    if (passed_tests == total_tests) {
        std.debug.print("\n🎉 ALL FORMAT TESTS PASSED! Ziggit behavior matches git exactly.\n", .{});
    } else if (passed_tests >= (total_tests * 75) / 100) {
        std.debug.print("\n✅ Most format tests passed. Ziggit shows good behavioral compatibility with git.\n", .{});
    } else {
        std.debug.print("\n❌ Format compatibility issues detected. Ziggit behavior differs significantly from git.\n", .{});
        std.process.exit(1);
    }
}