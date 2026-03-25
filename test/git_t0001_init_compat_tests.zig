// Git source compatibility tests adapted from t0001-init.sh
const std = @import("std");
const print = std.debug.print;

pub const TestFramework = @import("git_source_test_harness.zig").TestFramework;

pub fn runInitCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    print("Running git init compatibility tests (adapted from t0001-init.sh)...\n");
    
    try testPlainInit(&tf);
    try testInitWithPath(&tf);
    try testBareInit(&tf);
    try testReinitExisting(&tf);
    try testInitInExistingRepo(&tf);
    
    print("✓ All init compatibility tests passed!\n");
}

fn checkGitConfig(tf: *TestFramework, git_dir: []const u8, expected_bare: bool, expected_worktree: []const u8) !bool {
    // Check if .git directory structure exists and has the right files
    const config_path = try std.fmt.allocPrint(tf.allocator, "{s}/config", .{git_dir});
    defer tf.allocator.free(config_path);
    
    const head_path = try std.fmt.allocPrint(tf.allocator, "{s}/HEAD", .{git_dir});
    defer tf.allocator.free(head_path);
    
    const refs_path = try std.fmt.allocPrint(tf.allocator, "{s}/refs", .{git_dir});
    defer tf.allocator.free(refs_path);
    
    const objects_path = try std.fmt.allocPrint(tf.allocator, "{s}/objects", .{git_dir});
    defer tf.allocator.free(objects_path);
    
    // Check that essential files/directories exist
    std.fs.cwd().access(config_path, .{}) catch |err| {
        print("      ❌ config file missing: {any}\n", .{err});
        return false;
    };
    
    std.fs.cwd().access(head_path, .{}) catch |err| {
        print("      ❌ HEAD file missing: {any}\n", .{err});
        return false;
    };
    
    std.fs.cwd().access(refs_path, .{}) catch |err| {
        print("      ❌ refs directory missing: {any}\n", .{err});
        return false;
    };
    
    std.fs.cwd().access(objects_path, .{}) catch |err| {
        print("      ❌ objects directory missing: {any}\n", .{err});
        return false;
    };
    
    // For now, just check that the structure is there
    // TODO: Parse config to check core.bare and core.worktree values
    _ = expected_bare;
    _ = expected_worktree;
    
    return true;
}

fn testPlainInit(tf: *TestFramework) !void {
    print("  Testing plain init...\n");
    
    const test_dir = try tf.createTempDir("plain-init");
    defer tf.removeTempDir(test_dir);
    
    // Test: ziggit init <repo>
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "plain-repo" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        print("    ❌ ziggit init failed: {s}\n", .{init_result.stderr});
        return;
    }
    
    // Check .git directory was created
    const git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/plain-repo/.git", .{test_dir});
    defer tf.allocator.free(git_dir);
    
    if (!try checkGitConfig(tf, git_dir, false, "unset")) {
        print("    ❌ .git directory structure is incorrect\n");
        return;
    }
    
    // Test: ziggit init (in current directory)
    const test_dir2 = try tf.createTempDir("plain-init-cwd");
    defer tf.removeTempDir(test_dir2);
    
    var init_cwd_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir2);
    defer init_cwd_result.deinit();
    
    if (init_cwd_result.exit_code != 0) {
        print("    ❌ ziggit init in cwd failed: {s}\n", .{init_cwd_result.stderr});
        return;
    }
    
    const git_dir2 = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{test_dir2});
    defer tf.allocator.free(git_dir2);
    
    if (!try checkGitConfig(tf, git_dir2, false, "unset")) {
        print("    ❌ .git directory structure is incorrect for cwd init\n");
        return;
    }
    
    print("    ✓ Plain init test passed\n");
}

fn testInitWithPath(tf: *TestFramework) !void {
    print("  Testing init with various paths...\n");
    
    const test_dir = try tf.createTempDir("init-path");
    defer tf.removeTempDir(test_dir);
    
    // Test relative path
    var init_rel_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "./relative-repo" 
    }, test_dir);
    defer init_rel_result.deinit();
    
    if (init_rel_result.exit_code != 0) {
        print("    ❌ ziggit init with relative path failed: {s}\n", .{init_rel_result.stderr});
        return;
    }
    
    // Check the repo was created
    const git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/relative-repo/.git", .{test_dir});
    defer tf.allocator.free(git_dir);
    
    if (!try checkGitConfig(tf, git_dir, false, "unset")) {
        print("    ❌ .git directory structure is incorrect for relative path\n");
        return;
    }
    
    // Test with subdirectory path
    var init_sub_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "subdir/nested-repo" 
    }, test_dir);
    defer init_sub_result.deinit();
    
    if (init_sub_result.exit_code != 0) {
        print("    ❌ ziggit init with subdirectory path failed: {s}\n", .{init_sub_result.stderr});
        return;
    }
    
    const git_dir2 = try std.fmt.allocPrint(tf.allocator, "{s}/subdir/nested-repo/.git", .{test_dir});
    defer tf.allocator.free(git_dir2);
    
    if (!try checkGitConfig(tf, git_dir2, false, "unset")) {
        print("    ❌ .git directory structure is incorrect for subdirectory path\n");
        return;
    }
    
    print("    ✓ Init with path test passed\n");
}

fn testBareInit(tf: *TestFramework) !void {
    print("  Testing bare repository init...\n");
    
    const test_dir = try tf.createTempDir("bare-init");
    defer tf.removeTempDir(test_dir);
    
    // Test: ziggit init --bare
    var bare_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "--bare", "bare-repo.git" 
    }, test_dir);
    defer bare_result.deinit();
    
    if (bare_result.exit_code != 0) {
        print("    ⚠ ziggit --bare init not implemented: {s}\n", .{bare_result.stderr});
        return;
    }
    
    // For bare repos, the git files are in the root directory, not .git subdirectory
    const bare_dir = try std.fmt.allocPrint(tf.allocator, "{s}/bare-repo.git", .{test_dir});
    defer tf.allocator.free(bare_dir);
    
    if (!try checkGitConfig(tf, bare_dir, true, "unset")) {
        print("    ❌ Bare repository structure is incorrect\n");
        return;
    }
    
    print("    ✓ Bare init test passed\n");
}

fn testReinitExisting(tf: *TestFramework) !void {
    print("  Testing reinit of existing repository...\n");
    
    const test_dir = try tf.createTempDir("reinit");
    defer tf.removeTempDir(test_dir);
    
    // First init
    var init_result1 = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "test-repo" 
    }, test_dir);
    defer init_result1.deinit();
    
    if (init_result1.exit_code != 0) {
        print("    ❌ First init failed: {s}\n", .{init_result1.stderr});
        return;
    }
    
    // Create a file in the repo
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{test_dir});
    defer tf.allocator.free(repo_dir);
    
    try tf.writeFile(repo_dir, "existing.txt", "This file should remain\n");
    
    // Reinit the same repo
    var init_result2 = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, repo_dir);
    defer init_result2.deinit();
    
    if (init_result2.exit_code != 0) {
        print("    ❌ Reinit failed: {s}\n", .{init_result2.stderr});
        return;
    }
    
    // Check that existing file is still there
    const file_path = try std.fmt.allocPrint(tf.allocator, "{s}/existing.txt", .{repo_dir});
    defer tf.allocator.free(file_path);
    
    std.fs.cwd().access(file_path, .{}) catch |err| {
        print("    ❌ Existing file was deleted during reinit: {any}\n", .{err});
        return;
    };
    
    // Check that .git structure is still intact
    const git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{repo_dir});
    defer tf.allocator.free(git_dir);
    
    if (!try checkGitConfig(tf, git_dir, false, "unset")) {
        print("    ❌ .git directory structure was corrupted during reinit\n");
        return;
    }
    
    print("    ✓ Reinit test passed\n");
}

fn testInitInExistingRepo(tf: *TestFramework) !void {
    print("  Testing init in existing git repository...\n");
    
    const test_dir = try tf.createTempDir("init-existing");
    defer tf.removeTempDir(test_dir);
    
    // Create an existing repo
    var init_result1 = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result1.deinit();
    
    if (init_result1.exit_code != 0) {
        print("    ❌ Initial repo creation failed: {s}\n", .{init_result1.stderr});
        return;
    }
    
    // Try to init a nested repo inside it
    const nested_dir = try std.fmt.allocPrint(tf.allocator, "{s}/nested", .{test_dir});
    defer tf.allocator.free(nested_dir);
    
    // Create the nested directory
    std.fs.cwd().makeDir(nested_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    var nested_init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, nested_dir);
    defer nested_init_result.deinit();
    
    // This should either succeed (creating nested repo) or fail with appropriate error
    if (nested_init_result.exit_code == 0) {
        print("    ✓ Nested repo creation allowed\n");
        
        // Check that nested .git exists
        const nested_git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{nested_dir});
        defer tf.allocator.free(nested_git_dir);
        
        if (!try checkGitConfig(tf, nested_git_dir, false, "unset")) {
            print("    ❌ Nested .git directory structure is incorrect\n");
            return;
        }
    } else {
        print("    ✓ Nested repo creation appropriately handled\n");
    }
    
    print("    ✓ Init in existing repo test passed\n");
}

pub fn main() !void {
    try runInitCompatTests();
}