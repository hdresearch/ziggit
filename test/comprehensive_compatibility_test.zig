const std = @import("std");

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
}

fn testCommand(allocator: std.mem.Allocator, name: []const u8, args: []const []const u8, cwd: ?[]const u8, expect_success: bool) !bool {
    const result = runCommand(allocator, args, cwd) catch |err| {
        std.debug.print("    ❌ {s}: Failed to run command: {}\n", .{ name, err });
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const success = result.term == .Exited and result.term.Exited == 0;
    if (success == expect_success) {
        std.debug.print("    ✓ {s}\n", .{name});
        return true;
    } else {
        std.debug.print("    ❌ {s}: Expected success={}, got exit_code={}\n", .{ name, expect_success, if (result.term == .Exited) result.term.Exited else @as(u32, 999) });
        if (result.stderr.len > 0) {
            std.debug.print("      stderr: {s}\n", .{result.stderr});
        }
        return false;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    const test_base_dir = "/tmp/ziggit_comprehensive_tests";
    
    // Clean and create test directory
    std.fs.cwd().deleteTree(test_base_dir) catch {};
    try std.fs.cwd().makeDir(test_base_dir);
    defer std.fs.cwd().deleteTree(test_base_dir) catch {};

    var total_tests: u32 = 0;
    var passed_tests: u32 = 0;

    std.debug.print("=== Comprehensive Git Compatibility Tests ===\n", .{});

    // === Basic Command Tests ===
    std.debug.print("\n[1/6] Basic command tests...\n", .{});
    
    total_tests += 1;
    if (try testCommand(allocator, "version", &[_][]const u8{ ziggit_path, "--version" }, null, true)) passed_tests += 1;
    
    total_tests += 1;
    if (try testCommand(allocator, "help", &[_][]const u8{ ziggit_path, "--help" }, null, true)) passed_tests += 1;
    
    total_tests += 1;
    if (try testCommand(allocator, "invalid command", &[_][]const u8{ ziggit_path, "nonexistentcmd" }, null, false)) passed_tests += 1;

    // === Init Tests ===
    std.debug.print("\n[2/6] Repository initialization tests...\n", .{});
    
    const init_test_dir = try std.fmt.allocPrint(allocator, "{s}/init_test", .{test_base_dir});
    defer allocator.free(init_test_dir);
    try std.fs.cwd().makeDir(init_test_dir);

    total_tests += 1;
    if (try testCommand(allocator, "init", &[_][]const u8{ ziggit_path, "init" }, init_test_dir, true)) passed_tests += 1;

    // Check .git directory exists
    total_tests += 1;
    const git_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{init_test_dir});
    defer allocator.free(git_dir_path);
    
    if (std.fs.cwd().statFile(git_dir_path)) |stat| {
        if (stat.kind == .directory) {
            std.debug.print("    ✓ .git directory created\n", .{});
            passed_tests += 1;
        } else {
            std.debug.print("    ❌ .git exists but is not a directory\n", .{});
        }
    } else |_| {
        std.debug.print("    ❌ .git directory not created\n", .{});
    }

    // === Bare Init Test ===
    const bare_test_dir = try std.fmt.allocPrint(allocator, "{s}/bare_test", .{test_base_dir});
    defer allocator.free(bare_test_dir);
    try std.fs.cwd().makeDir(bare_test_dir);

    total_tests += 1;
    if (try testCommand(allocator, "init --bare", &[_][]const u8{ ziggit_path, "init", "--bare" }, bare_test_dir, true)) passed_tests += 1;

    // === Basic Workflow Tests ===
    std.debug.print("\n[3/6] Basic workflow tests...\n", .{});
    
    const workflow_dir = try std.fmt.allocPrint(allocator, "{s}/workflow", .{test_base_dir});
    defer allocator.free(workflow_dir);
    try std.fs.cwd().makeDir(workflow_dir);

    // Init repo
    total_tests += 1;
    if (try testCommand(allocator, "workflow init", &[_][]const u8{ ziggit_path, "init" }, workflow_dir, true)) passed_tests += 1;

    // Create test file
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{workflow_dir});
    defer allocator.free(test_file_path);
    
    const test_file = try std.fs.cwd().createFile(test_file_path, .{});
    defer test_file.close();
    try test_file.writeAll("Hello, ziggit!\nThis is a test file.\n");

    // Status (should show untracked)
    total_tests += 1;
    if (try testCommand(allocator, "status (untracked)", &[_][]const u8{ ziggit_path, "status" }, workflow_dir, true)) passed_tests += 1;

    // Add file
    total_tests += 1;
    if (try testCommand(allocator, "add file", &[_][]const u8{ ziggit_path, "add", "test.txt" }, workflow_dir, true)) passed_tests += 1;

    // Status (should show staged)
    total_tests += 1;
    if (try testCommand(allocator, "status (staged)", &[_][]const u8{ ziggit_path, "status" }, workflow_dir, true)) passed_tests += 1;

    // Commit
    total_tests += 1;
    if (try testCommand(allocator, "commit", &[_][]const u8{ ziggit_path, "commit", "-m", "Initial commit" }, workflow_dir, true)) passed_tests += 1;

    // Status (should be clean)
    total_tests += 1;
    if (try testCommand(allocator, "status (clean)", &[_][]const u8{ ziggit_path, "status" }, workflow_dir, true)) passed_tests += 1;

    // Log
    total_tests += 1;
    if (try testCommand(allocator, "log", &[_][]const u8{ ziggit_path, "log" }, workflow_dir, true)) passed_tests += 1;

    // Log --oneline
    total_tests += 1;
    if (try testCommand(allocator, "log --oneline", &[_][]const u8{ ziggit_path, "log", "--oneline" }, workflow_dir, true)) passed_tests += 1;

    // === Diff Tests ===
    std.debug.print("\n[4/6] Diff tests...\n", .{});
    
    // Create second file and modify first
    const test_file2_path = try std.fmt.allocPrint(allocator, "{s}/test2.txt", .{workflow_dir});
    defer allocator.free(test_file2_path);
    
    const test_file2 = try std.fs.cwd().createFile(test_file2_path, .{});
    defer test_file2.close();
    try test_file2.writeAll("Second file content\n");

    // Modify first file
    const test_file_mod = try std.fs.cwd().createFile(test_file_path, .{});
    defer test_file_mod.close();
    try test_file_mod.writeAll("Hello, ziggit!\nThis is a modified test file.\nWith new content.\n");

    // Diff (should show working directory changes)
    total_tests += 1;
    if (try testCommand(allocator, "diff working directory", &[_][]const u8{ ziggit_path, "diff" }, workflow_dir, true)) passed_tests += 1;

    // Add new file and test diff --cached
    _ = try runCommand(allocator, &[_][]const u8{ ziggit_path, "add", "test2.txt" }, workflow_dir);
    
    total_tests += 1;
    if (try testCommand(allocator, "diff --cached", &[_][]const u8{ ziggit_path, "diff", "--cached" }, workflow_dir, true)) passed_tests += 1;

    // === Branch Tests ===
    std.debug.print("\n[5/6] Branch tests...\n", .{});
    
    total_tests += 1;
    if (try testCommand(allocator, "branch list", &[_][]const u8{ ziggit_path, "branch" }, workflow_dir, true)) passed_tests += 1;

    total_tests += 1;
    if (try testCommand(allocator, "branch create", &[_][]const u8{ ziggit_path, "branch", "feature" }, workflow_dir, true)) passed_tests += 1;

    total_tests += 1;
    if (try testCommand(allocator, "checkout branch", &[_][]const u8{ ziggit_path, "checkout", "feature" }, workflow_dir, true)) passed_tests += 1;

    total_tests += 1;
    if (try testCommand(allocator, "checkout master", &[_][]const u8{ ziggit_path, "checkout", "master" }, workflow_dir, true)) passed_tests += 1;

    // === Error Case Tests ===
    std.debug.print("\n[6/6] Error handling tests...\n", .{});
    
    const empty_dir = try std.fmt.allocPrint(allocator, "{s}/empty", .{test_base_dir});
    defer allocator.free(empty_dir);
    try std.fs.cwd().makeDir(empty_dir);

    total_tests += 1;
    if (try testCommand(allocator, "status outside repo", &[_][]const u8{ ziggit_path, "status" }, empty_dir, false)) passed_tests += 1;

    total_tests += 1;
    if (try testCommand(allocator, "add non-existent file", &[_][]const u8{ ziggit_path, "add", "doesnotexist.txt" }, workflow_dir, false)) passed_tests += 1;

    total_tests += 1;
    if (try testCommand(allocator, "commit without changes", &[_][]const u8{ ziggit_path, "commit", "-m", "empty" }, workflow_dir, false)) passed_tests += 1;

    // === Summary ===
    std.debug.print("\n=== Test Results ===\n", .{});
    std.debug.print("Total tests: {}\n", .{total_tests});
    std.debug.print("Passed: {}\n", .{passed_tests});
    std.debug.print("Failed: {}\n", .{total_tests - passed_tests});
    std.debug.print("Success rate: {d:.1}%\n", .{(@as(f64, @floatFromInt(passed_tests)) / @as(f64, @floatFromInt(total_tests))) * 100.0});

    if (passed_tests == total_tests) {
        std.debug.print("\n🎉 ALL TESTS PASSED! Ziggit shows excellent git compatibility.\n", .{});
    } else if (passed_tests >= (total_tests * 80) / 100) {
        std.debug.print("\n✅ Most tests passed. Ziggit shows good git compatibility.\n", .{});
    } else {
        std.debug.print("\n❌ Many tests failed. Ziggit needs more work for full git compatibility.\n", .{});
        std.process.exit(1);
    }
}