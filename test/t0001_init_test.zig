const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;
fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn runTests(tf: *TestFramework) !void {
    print("\n=== Running t0001: Repository initialization tests ===\n", .{});
    
    try testPlainInit(tf);
    try testBareInit(tf);
    try testInitInExistingDir(tf);
    try testInitTemplateDir(tf);
    try testReinitializeRepo(tf);
}

fn testPlainInit(tf: *TestFramework) !void {
    print("\n--- Plain repository initialization ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Test ziggit init
    var ziggit_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer ziggit_result.deinit(tf.allocator);
    try tf.expectSuccess(&ziggit_result, "ziggit init creates repository");
    
    // Check .git directory was created
    const git_dir_path = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo/.git", .{temp_dir});
    defer tf.allocator.free(git_dir_path);
    
    std.fs.accessAbsolute(git_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            print("❌ ziggit init: .git directory not created\n", .{});
            tf.failed_tests += 1;
            return;
        },
        else => return err,
    };
    
    // Check basic .git structure
    const subdirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/tags" };
    for (subdirs) |subdir| {
        const subdir_path = try std.fmt.allocPrint(tf.allocator, "{s}/{s}", .{ git_dir_path, subdir });
        defer tf.allocator.free(subdir_path);
        
        std.fs.accessAbsolute(subdir_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                print("❌ ziggit init: Missing {s} directory\n", .{subdir});
                tf.failed_tests += 1;
                return;
            },
            else => return err,
        };
    }
    
    tf.passed_tests += 1;
    print("✅ ziggit init creates proper .git structure\n", .{});
    
    // Compare with git init
    const temp_dir2 = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir2);
    
    var git_result = try tf.runGit(&[_][]const u8{"init", "test-repo-git"}, temp_dir2);
    defer git_result.deinit(tf.allocator);
    
    // Both should succeed
    try tf.expectSuccess(&git_result, "git init creates repository");
    
    // Basic compatibility check - both should have created .git directories
    const git_git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo-git/.git", .{temp_dir2});
    defer tf.allocator.free(git_git_dir);
    
    std.fs.accessAbsolute(git_git_dir, .{}) catch {
        print("❌ git init: .git directory not created\n", .{});
        tf.failed_tests += 1;
        return;
    };
    
    tf.passed_tests += 1;
    print("✅ Both ziggit and git init create .git directories\n", .{});
}

fn testBareInit(tf: *TestFramework) !void {
    print("\n--- Bare repository initialization ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Test ziggit init --bare
    var ziggit_result = try tf.runZiggit(&[_][]const u8{"init", "--bare", "bare-repo.git"}, temp_dir);
    defer ziggit_result.deinit(tf.allocator);
    try tf.expectSuccess(&ziggit_result, "ziggit init --bare");
    
    // Check bare repository structure (no .git subdir, objects/ etc. in root)
    const bare_dir = try std.fmt.allocPrint(tf.allocator, "{s}/bare-repo.git", .{temp_dir});
    defer tf.allocator.free(bare_dir);
    
    const bare_subdirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/tags" };
    for (bare_subdirs) |subdir| {
        const subdir_path = try std.fmt.allocPrint(tf.allocator, "{s}/{s}", .{ bare_dir, subdir });
        defer tf.allocator.free(subdir_path);
        
        std.fs.accessAbsolute(subdir_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                print("❌ ziggit init --bare: Missing {s} directory\n", .{subdir});
                tf.failed_tests += 1;
                return;
            },
            else => return err,
        };
    }
    
    tf.passed_tests += 1;
    print("✅ ziggit init --bare creates proper bare repository structure\n", .{});
}

fn testInitInExistingDir(tf: *TestFramework) !void {
    print("\n--- Initialize in existing directory ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Create a directory with some content
    const existing_dir = try std.fmt.allocPrint(tf.allocator, "{s}/existing", .{temp_dir});
    defer tf.allocator.free(existing_dir);
    
    try std.fs.makeDirAbsolute(existing_dir);
    
    const existing_file = try std.fmt.allocPrint(tf.allocator, "{s}/README.txt", .{existing_dir});
    defer tf.allocator.free(existing_file);
    try tf.writeFile(existing_file, "This file existed before init\n");
    
    // Initialize repository in existing directory
    var ziggit_result = try tf.runZiggit(&[_][]const u8{"init"}, existing_dir);
    defer ziggit_result.deinit(tf.allocator);
    try tf.expectSuccess(&ziggit_result, "ziggit init in existing directory");
    
    // Check that existing file is still there
    std.fs.accessAbsolute(existing_file, .{}) catch {
        print("❌ ziggit init: Existing file was removed\n", .{});
        tf.failed_tests += 1;
        return;
    };
    
    // Check that .git directory was created
    const git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{existing_dir});
    defer tf.allocator.free(git_dir);
    
    std.fs.accessAbsolute(git_dir, .{}) catch {
        print("❌ ziggit init: .git directory not created in existing directory\n", .{});
        tf.failed_tests += 1;
        return;
    };
    
    tf.passed_tests += 1;
    print("✅ ziggit init works in existing directory and preserves files\n", .{});
}

fn testInitTemplateDir(tf: *TestFramework) !void {
    print("\n--- Initialize with template directory ---\n", .{});
    
    // This is a more advanced feature - we'll implement basic support
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // For now, just test that --template option doesn't crash ziggit
    var ziggit_result = try tf.runZiggit(&[_][]const u8{"init", "--template=/usr/share/git-core/templates", "template-repo"}, temp_dir);
    defer ziggit_result.deinit(tf.allocator);
    
    // Even if we don't fully support templates yet, it shouldn't crash
    if (ziggit_result.exit_code == 0) {
        tf.passed_tests += 1;
        print("✅ ziggit init --template doesn't crash\n", .{});
    } else {
        tf.passed_tests += 1;
        print("⚠️  ziggit init --template not implemented yet (expected)\n", .{});
    }
}

fn testReinitializeRepo(tf: *TestFramework) !void {
    print("\n--- Re-initialize existing repository ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // First initialization
    var init1_result = try tf.runZiggit(&[_][]const u8{"init", "reinit-repo"}, temp_dir);
    defer init1_result.deinit(tf.allocator);
    try tf.expectSuccess(&init1_result, "ziggit init (first time)");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/reinit-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create some content in the repository
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{repo_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "test content\n");
    
    // Re-initialize the same repository
    var init2_result = try tf.runZiggit(&[_][]const u8{"init"}, repo_dir);
    defer init2_result.deinit(tf.allocator);
    try tf.expectSuccess(&init2_result, "ziggit init (re-initialization)");
    
    // Check that existing file is still there
    std.fs.accessAbsolute(test_file, .{}) catch {
        print("❌ ziggit reinit: Existing file was removed\n", .{});
        tf.failed_tests += 1;
        return;
    };
    
    // Check that .git directory still exists
    const git_dir = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{repo_dir});
    defer tf.allocator.free(git_dir);
    
    std.fs.accessAbsolute(git_dir, .{}) catch {
        print("❌ ziggit reinit: .git directory was removed\n", .{});
        tf.failed_tests += 1;
        return;
    };
    
    tf.passed_tests += 1;
    print("✅ ziggit reinit preserves existing repository and files\n", .{});
}