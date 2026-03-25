const std = @import("std");

pub fn main() !void {
    std.debug.print("=== Comprehensive Git Workflow Test ===\n", .{});
    std.debug.print("Testing complete git workflow for drop-in compatibility\n\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var passed: u32 = 0;
    var total: u32 = 0;
    
    // Test 1: Version and Help
    std.debug.print("[1/10] Testing version and help...\n", .{});
    total += 1;
    if (testVersionAndHelp(allocator)) {
        passed += 1;
        std.debug.print("✅ Version and help tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Version and help tests failed: {}\n\n", .{err});
    }
    
    // Test 2: Repository initialization
    std.debug.print("[2/10] Testing repository initialization...\n", .{});
    total += 1;
    if (testRepositoryInit(allocator)) {
        passed += 1;
        std.debug.print("✅ Repository initialization tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Repository initialization tests failed: {}\n\n", .{err});
    }
    
    // Test 3: File staging (add)
    std.debug.print("[3/10] Testing file staging...\n", .{});
    total += 1;
    if (testFileStaging(allocator)) {
        passed += 1;
        std.debug.print("✅ File staging tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ File staging tests failed: {}\n\n", .{err});
    }
    
    // Test 4: Status reporting
    std.debug.print("[4/10] Testing status reporting...\n", .{});
    total += 1;
    if (testStatusReporting(allocator)) {
        passed += 1;
        std.debug.print("✅ Status reporting tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Status reporting tests failed: {}\n\n", .{err});
    }
    
    // Test 5: Committing changes
    std.debug.print("[5/10] Testing committing changes...\n", .{});
    total += 1;
    if (testCommittingChanges(allocator)) {
        passed += 1;
        std.debug.print("✅ Committing changes tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Committing changes tests failed: {}\n\n", .{err});
    }
    
    // Test 6: Commit history (log)
    std.debug.print("[6/10] Testing commit history...\n", .{});
    total += 1;
    if (testCommitHistory(allocator)) {
        passed += 1;
        std.debug.print("✅ Commit history tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Commit history tests failed: {}\n\n", .{err});
    }
    
    // Test 7: File differences (diff)
    std.debug.print("[7/10] Testing file differences...\n", .{});
    total += 1;
    if (testFileDifferences(allocator)) {
        passed += 1;
        std.debug.print("✅ File differences tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ File differences tests failed: {}\n\n", .{err});
    }
    
    // Test 8: Multiple commits workflow
    std.debug.print("[8/10] Testing multiple commits workflow...\n", .{});
    total += 1;
    if (testMultipleCommitsWorkflow(allocator)) {
        passed += 1;
        std.debug.print("✅ Multiple commits workflow tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Multiple commits workflow tests failed: {}\n\n", .{err});
    }
    
    // Test 9: Error handling
    std.debug.print("[9/10] Testing error handling...\n", .{});
    total += 1;
    if (testErrorHandling(allocator)) {
        passed += 1;
        std.debug.print("✅ Error handling tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Error handling tests failed: {}\n\n", .{err});
    }
    
    // Test 10: Complete integration workflow
    std.debug.print("[10/10] Testing complete integration workflow...\n", .{});
    total += 1;
    if (testCompleteWorkflow(allocator)) {
        passed += 1;
        std.debug.print("✅ Complete integration workflow tests passed\n\n", .{});
    } else |err| {
        std.debug.print("❌ Complete integration workflow tests failed: {}\n\n", .{err});
    }
    
    // Summary
    std.debug.print("=== Test Results ===\n", .{});
    std.debug.print("Passed: {d}/{d} tests\n", .{ passed, total });
    
    if (passed == total) {
        std.debug.print("🎉 ALL TESTS PASSED! ziggit shows excellent git compatibility.\n", .{});
    } else {
        std.debug.print("⚠️  Some tests failed. Compatibility score: {d:.1}%\n", .{ @as(f64, @floatFromInt(passed)) * 100.0 / @as(f64, @floatFromInt(total)) });
    }
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    var proc = std.process.Child.init(args, allocator);
    if (cwd) |dir| proc.cwd = dir;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    
    try proc.spawn();
    
    const stdout = try proc.stdout.?.readToEndAlloc(allocator, 8192);
    const stderr = try proc.stderr.?.readToEndAlloc(allocator, 8192);
    
    const term = try proc.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
    
    return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
}

fn createTempDir(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const temp_base = "/tmp";
    const full_name = try std.fmt.allocPrint(allocator, "ziggit-test-{s}-{d}", .{ name, std.time.timestamp() });
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_base, full_name });
    
    std.fs.cwd().makeDir(full_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    allocator.free(full_name);
    return full_path;
}

fn cleanupTempDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

fn writeFile(dir: []const u8, filename: []const u8, content: []const u8) !void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, filename });
    defer std.heap.page_allocator.free(file_path);
    
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn testVersionAndHelp(allocator: std.mem.Allocator) !void {
    // Test --version
    const version_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "--version"}, null);
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);
    
    if (version_result.exit_code != 0) {
        return error.VersionFailed;
    }
    
    std.debug.print("  ✓ --version works\n", .{});
    
    // Test --help
    const help_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "--help"}, null);
    defer allocator.free(help_result.stdout);
    defer allocator.free(help_result.stderr);
    
    if (help_result.exit_code != 0) {
        return error.HelpFailed;
    }
    
    std.debug.print("  ✓ --help works\n", .{});
}

fn testRepositoryInit(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "init");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Test basic init
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    if (init_result.exit_code != 0) {
        return error.InitFailed;
    }
    
    // Check .git directory exists
    const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{test_dir});
    defer allocator.free(git_path);
    
    std.fs.cwd().access(git_path, .{}) catch {
        return error.GitDirNotCreated;
    };
    
    std.debug.print("  ✓ Repository initialization works\n", .{});
}

fn testFileStaging(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "staging");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Initialize repo
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create file
    try writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    // Test add
    const add_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "test.txt"}, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    if (add_result.exit_code != 0) {
        return error.AddFailed;
    }
    
    std.debug.print("  ✓ File staging works\n", .{});
}

fn testStatusReporting(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "status");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Initialize repo
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Test status on empty repo
    const status1_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "status"}, test_dir);
    defer allocator.free(status1_result.stdout);
    defer allocator.free(status1_result.stderr);
    
    if (status1_result.exit_code != 0) {
        return error.StatusFailed;
    }
    
    // Create file and test status with untracked files
    try writeFile(test_dir, "untracked.txt", "Untracked content\n");
    
    const status2_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "status"}, test_dir);
    defer allocator.free(status2_result.stdout);
    defer allocator.free(status2_result.stderr);
    
    if (status2_result.exit_code != 0) {
        return error.StatusWithUntrackedFailed;
    }
    
    std.debug.print("  ✓ Status reporting works\n", .{});
}

fn testCommittingChanges(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "commit");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Initialize repo and add file
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    try writeFile(test_dir, "commit-test.txt", "Test content\n");
    
    const add_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "commit-test.txt"}, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    // Test commit
    const commit_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Test commit"}, test_dir);
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    if (commit_result.exit_code != 0) {
        return error.CommitFailed;
    }
    
    std.debug.print("  ✓ Committing changes works\n", .{});
}

fn testCommitHistory(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "log");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Setup with commit
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    try writeFile(test_dir, "log-test.txt", "Log test content\n");
    
    const add_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "log-test.txt"}, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    const commit_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Log test commit"}, test_dir);
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    // Test log
    const log_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "log"}, test_dir);
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);
    
    if (log_result.exit_code != 0) {
        return error.LogFailed;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Log test commit") == null) {
        return error.CommitNotInLog;
    }
    
    std.debug.print("  ✓ Commit history works\n", .{});
}

fn testFileDifferences(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "diff");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Setup with commit
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    try writeFile(test_dir, "diff-test.txt", "Original content\n");
    
    const add_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "diff-test.txt"}, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    const commit_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Diff test commit"}, test_dir);
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    // Modify file
    try writeFile(test_dir, "diff-test.txt", "Modified content\n");
    
    // Test diff
    const diff_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "diff"}, test_dir);
    defer allocator.free(diff_result.stdout);
    defer allocator.free(diff_result.stderr);
    
    if (diff_result.exit_code != 0) {
        return error.DiffFailed;
    }
    
    std.debug.print("  ✓ File differences work\n", .{});
}

fn testMultipleCommitsWorkflow(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "multiple-commits");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Initialize repo
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    // First commit
    try writeFile(test_dir, "file1.txt", "First file\n");
    
    const add1_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt"}, test_dir);
    defer allocator.free(add1_result.stdout);
    defer allocator.free(add1_result.stderr);
    
    const commit1_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "First commit"}, test_dir);
    defer allocator.free(commit1_result.stdout);
    defer allocator.free(commit1_result.stderr);
    
    // Second commit
    try writeFile(test_dir, "file2.txt", "Second file\n");
    
    const add2_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "file2.txt"}, test_dir);
    defer allocator.free(add2_result.stdout);
    defer allocator.free(add2_result.stderr);
    
    const commit2_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Second commit"}, test_dir);
    defer allocator.free(commit2_result.stdout);
    defer allocator.free(commit2_result.stderr);
    
    // Test log shows both commits
    const log_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "log", "--oneline"}, test_dir);
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);
    
    if (log_result.exit_code != 0) {
        return error.LogFailed;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "First commit") == null or 
        std.mem.indexOf(u8, log_result.stdout, "Second commit") == null) {
        return error.CommitsNotInLog;
    }
    
    std.debug.print("  ✓ Multiple commits workflow works\n", .{});
}

fn testErrorHandling(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "error-handling");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Test invalid command
    const invalid_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "invalid-command"}, test_dir);
    defer allocator.free(invalid_result.stdout);
    defer allocator.free(invalid_result.stderr);
    
    if (invalid_result.exit_code == 0) {
        return error.InvalidCommandShouldFail;
    }
    
    // Test add non-existent file
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    const add_nonexistent_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "nonexistent.txt"}, test_dir);
    defer allocator.free(add_nonexistent_result.stdout);
    defer allocator.free(add_nonexistent_result.stderr);
    
    if (add_nonexistent_result.exit_code == 0) {
        return error.AddNonexistentShouldFail;
    }
    
    std.debug.print("  ✓ Error handling works\n", .{});
}

fn testCompleteWorkflow(allocator: std.mem.Allocator) !void {
    const test_dir = try createTempDir(allocator, "complete-workflow");
    defer allocator.free(test_dir);
    defer cleanupTempDir(test_dir);
    
    // Complete git workflow simulation
    const init_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, test_dir);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create project files
    try writeFile(test_dir, "README.md", "# Test Project\n\nA test repository for ziggit.\n");
    try writeFile(test_dir, "main.zig", "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"Hello, ziggit!\\n\", .{});\n}\n");
    
    // Add files
    const add_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "."}, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    if (add_result.exit_code != 0) return error.AddFailed;
    
    // Check status
    const status_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "status"}, test_dir);
    defer allocator.free(status_result.stdout);
    defer allocator.free(status_result.stderr);
    if (status_result.exit_code != 0) return error.StatusFailed;
    
    // Commit
    const commit_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial project setup"}, test_dir);
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    if (commit_result.exit_code != 0) return error.CommitFailed;
    
    // Modify and test diff
    try writeFile(test_dir, "main.zig", "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"Hello, updated ziggit!\\n\", .{});\n}\n");
    
    const diff_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "diff"}, test_dir);
    defer allocator.free(diff_result.stdout);
    defer allocator.free(diff_result.stderr);
    if (diff_result.exit_code != 0) return error.DiffFailed;
    
    // Stage and commit changes
    const add2_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "main.zig"}, test_dir);
    defer allocator.free(add2_result.stdout);
    defer allocator.free(add2_result.stderr);
    if (add2_result.exit_code != 0) return error.Add2Failed;
    
    const commit2_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Update greeting message"}, test_dir);
    defer allocator.free(commit2_result.stdout);
    defer allocator.free(commit2_result.stderr);
    if (commit2_result.exit_code != 0) return error.Commit2Failed;
    
    // Final log check
    const log_result = try runCommand(allocator, &[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "log", "--oneline"}, test_dir);
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);
    if (log_result.exit_code != 0) return error.LogFailed;
    
    // Should have both commits
    if (std.mem.indexOf(u8, log_result.stdout, "Initial project setup") == null or
        std.mem.indexOf(u8, log_result.stdout, "Update greeting message") == null) {
        return error.CommitsNotInLog;
    }
    
    std.debug.print("  ✓ Complete workflow integration works\n", .{});
}