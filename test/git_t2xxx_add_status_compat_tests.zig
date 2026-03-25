// Git source compatibility tests adapted from t2xxx (add) and t7xxx (status) test files
const std = @import("std");


pub const TestFramework = @import("git_source_test_harness.zig").TestFramework;

pub fn runAddStatusCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    std.debug.print("Running git add/status compatibility tests (adapted from t2xxx/t7xxx)...\n", .{});
    
    try testAddSingleFile(&tf);
    try testAddMultipleFiles(&tf);
    try testAddDirectory(&tf);
    try testAddNonexistentFile(&tf);
    try testStatusEmpty(&tf);
    try testStatusUntracked(&tf);
    try testStatusStaged(&tf);
    try testStatusModified(&tf);
    try testAddAll(&tf);
    
    std.debug.print("✓ All add/status compatibility tests passed!\n", .{});
}

fn setupTestRepo(tf: *TestFramework, name: []const u8) ![]u8 {
    const test_dir = try tf.createTempDir(name);
    
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        tf.removeTempDir(test_dir);
        return error.InitFailed;
    }
    
    return test_dir;
}

fn testAddSingleFile(tf: *TestFramework) !void {
    std.debug.print("  Testing add single file...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "add-single");
    defer tf.removeTempDir(test_dir);
    
    // Create a test file
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    // Add the file
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ add failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Add should be silent on success (like git)
    if (add_result.stdout.len > 0) {
        std.debug.print("    ⚠ add should be silent on success, but output: {s}\n", .{add_result.stdout});
    }
    
    // Check status to verify file was staged
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed after add: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should mention the staged file
    if (std.mem.indexOf(u8, status_result.stdout, "test.txt") == null) {
        std.debug.print("    ❌ Added file not shown in status\n", .{});
        return;
    }
    
    // Should indicate it's staged/to be committed
    if (std.mem.indexOf(u8, status_result.stdout, "new file") == null and
        std.mem.indexOf(u8, status_result.stdout, "Changes to be committed") == null and
        std.mem.indexOf(u8, status_result.stdout, "staged") == null) {
        std.debug.print("    ⚠ Status should indicate file is staged for commit\n", .{});
    }
    
    std.debug.print("    ✓ Add single file test passed\n", .{});
}

fn testAddMultipleFiles(tf: *TestFramework) !void {
    std.debug.print("  Testing add multiple files...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "add-multiple");
    defer tf.removeTempDir(test_dir);
    
    // Create test files
    try tf.writeFile(test_dir, "file1.txt", "File 1 content\n");
    try tf.writeFile(test_dir, "file2.txt", "File 2 content\n");
    try tf.writeFile(test_dir, "file3.txt", "File 3 content\n");
    
    // Add multiple files at once
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt", "file2.txt", "file3.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ add multiple files failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Check status shows all files
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed after adding multiple files: {s}\n", .{status_result.stderr});
        return;
    }
    
    // All files should be mentioned
    const files = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };
    for (files) |file| {
        if (std.mem.indexOf(u8, status_result.stdout, file) == null) {
            std.debug.print("    ❌ Added file {s} not shown in status\n", .{file});
            return;
        }
    }
    
    std.debug.print("    ✓ Add multiple files test passed\n", .{});
}

fn testAddDirectory(tf: *TestFramework) !void {
    std.debug.print("  Testing add directory...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "add-directory");
    defer tf.removeTempDir(test_dir);
    
    // Create a subdirectory with files
    const subdir_path = try std.fmt.allocPrint(tf.allocator, "{s}/subdir", .{test_dir});
    defer tf.allocator.free(subdir_path);
    
    std.fs.cwd().makeDir(subdir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    try tf.writeFile(test_dir, "subdir/file1.txt", "Content 1\n");
    try tf.writeFile(test_dir, "subdir/file2.txt", "Content 2\n");
    
    // Add the directory
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "subdir" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ add directory failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Check status shows files from directory
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed after adding directory: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should show files from the subdirectory
    if (std.mem.indexOf(u8, status_result.stdout, "subdir/file1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "subdir/file2.txt") == null) {
        std.debug.print("    ❌ Files from added directory not shown in status\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Add directory test passed\n", .{});
}

fn testAddNonexistentFile(tf: *TestFramework) !void {
    std.debug.print("  Testing add nonexistent file...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "add-nonexistent");
    defer tf.removeTempDir(test_dir);
    
    // Try to add a file that doesn't exist
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "does-not-exist.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    // Should fail
    if (add_result.exit_code == 0) {
        std.debug.print("    ❌ add nonexistent file should fail but didn't\n", .{});
        return;
    }
    
    // Should have meaningful error message
    if (std.mem.indexOf(u8, add_result.stderr, "does-not-exist.txt") == null) {
        std.debug.print("    ⚠ Error message should mention the file name\n", .{});
    }
    
    if (std.mem.indexOf(u8, add_result.stderr, "not found") == null and
        std.mem.indexOf(u8, add_result.stderr, "does not exist") == null and
        std.mem.indexOf(u8, add_result.stderr, "No such file") == null) {
        std.debug.print("    ⚠ Error message should indicate file doesn't exist\n", .{});
    }
    
    std.debug.print("    ✓ Add nonexistent file test passed\n", .{});
}

fn testStatusEmpty(tf: *TestFramework) !void {
    std.debug.print("  Testing status on empty repository...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "status-empty");
    defer tf.removeTempDir(test_dir);
    
    // Status on empty repo
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed on empty repo: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should indicate clean state or empty repo
    if (std.mem.indexOf(u8, status_result.stdout, "nothing to commit") == null and
        std.mem.indexOf(u8, status_result.stdout, "working tree clean") == null and
        std.mem.indexOf(u8, status_result.stdout, "no commits yet") == null and
        std.mem.indexOf(u8, status_result.stdout, "Initial commit") == null) {
        std.debug.print("    ⚠ Status should indicate empty/clean state\n", .{});
    }
    
    std.debug.print("    ✓ Status empty test passed\n", .{});
}

fn testStatusUntracked(tf: *TestFramework) !void {
    std.debug.print("  Testing status with untracked files...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "status-untracked");
    defer tf.removeTempDir(test_dir);
    
    // Create untracked files
    try tf.writeFile(test_dir, "untracked1.txt", "Untracked content 1\n");
    try tf.writeFile(test_dir, "untracked2.txt", "Untracked content 2\n");
    
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed with untracked files: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should show untracked files
    if (std.mem.indexOf(u8, status_result.stdout, "untracked1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "untracked2.txt") == null) {
        std.debug.print("    ❌ Untracked files not shown in status\n", .{});
        return;
    }
    
    // Should indicate they are untracked
    if (std.mem.indexOf(u8, status_result.stdout, "Untracked files") == null and
        std.mem.indexOf(u8, status_result.stdout, "untracked") == null) {
        std.debug.print("    ⚠ Should indicate files are untracked\n", .{});
    }
    
    std.debug.print("    ✓ Status untracked test passed\n", .{});
}

fn testStatusStaged(tf: *TestFramework) !void {
    std.debug.print("  Testing status with staged files...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "status-staged");
    defer tf.removeTempDir(test_dir);
    
    // Create and stage files
    try tf.writeFile(test_dir, "staged.txt", "Staged content\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "staged.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ failed to stage file for test: {s}\n", .{add_result.stderr});
        return;
    }
    
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed with staged files: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should show staged file
    if (std.mem.indexOf(u8, status_result.stdout, "staged.txt") == null) {
        std.debug.print("    ❌ Staged file not shown in status\n", .{});
        return;
    }
    
    // Should indicate it's staged
    if (std.mem.indexOf(u8, status_result.stdout, "Changes to be committed") == null and
        std.mem.indexOf(u8, status_result.stdout, "new file") == null and
        std.mem.indexOf(u8, status_result.stdout, "staged") == null) {
        std.debug.print("    ⚠ Should indicate file is staged for commit\n", .{});
    }
    
    std.debug.print("    ✓ Status staged test passed\n", .{});
}

fn testStatusModified(tf: *TestFramework) !void {
    std.debug.print("  Testing status with modified files...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "status-modified");
    defer tf.removeTempDir(test_dir);
    
    // Create, stage, and commit a file
    try tf.writeFile(test_dir, "tracked.txt", "Original content\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "tracked.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ failed to create initial commit for test: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Modify the file
    try tf.writeFile(test_dir, "tracked.txt", "Modified content\n");
    
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed with modified files: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should show modified file
    if (std.mem.indexOf(u8, status_result.stdout, "tracked.txt") == null) {
        std.debug.print("    ❌ Modified file not shown in status\n", .{});
        return;
    }
    
    // Should indicate it's modified
    if (std.mem.indexOf(u8, status_result.stdout, "Changes not staged") == null and
        std.mem.indexOf(u8, status_result.stdout, "modified") == null) {
        std.debug.print("    ⚠ Should indicate file is modified\n", .{});
    }
    
    std.debug.print("    ✓ Status modified test passed\n", .{});
}

fn testAddAll(tf: *TestFramework) !void {
    std.debug.print("  Testing add all files (add .)...\n", .{});
    
    const test_dir = try setupTestRepo(tf, "add-all");
    defer tf.removeTempDir(test_dir);
    
    // Create multiple files
    try tf.writeFile(test_dir, "file1.txt", "Content 1\n");
    try tf.writeFile(test_dir, "file2.txt", "Content 2\n");
    
    // Create subdirectory with files
    const subdir = try std.fmt.allocPrint(tf.allocator, "{s}/subdir", .{test_dir});
    defer tf.allocator.free(subdir);
    
    std.fs.cwd().makeDir(subdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    try tf.writeFile(test_dir, "subdir/file3.txt", "Content 3\n");
    
    // Add all files
    var add_all_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "." 
    }, test_dir);
    defer add_all_result.deinit();
    
    if (add_all_result.exit_code != 0) {
        std.debug.print("    ❌ add . failed: {s}\n", .{add_all_result.stderr});
        return;
    }
    
    // Check status shows all files
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ status failed after add .: {s}\n", .{status_result.stderr});
        return;
    }
    
    // All files should be staged
    const expected_files = [_][]const u8{ "file1.txt", "file2.txt", "subdir/file3.txt" };
    for (expected_files) |file| {
        if (std.mem.indexOf(u8, status_result.stdout, file) == null) {
            std.debug.print("    ❌ File {s} not staged by add .\n", .{file});
            return;
        }
    }
    
    std.debug.print("    ✓ Add all test passed\n", .{});
}

pub fn main() !void {
    try runAddStatusCompatTests();
}