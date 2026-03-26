const std = @import("std");
const testing = std.testing;
const refs = @import("../src/git/refs.zig");

test "branch management functionality" {
    const allocator = testing.allocator;
    
    // Create a temporary test repository
    const temp_path = "/tmp/zig-branch-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    // Initialize git repo
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Branch Test User"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "branchtest@ziggit.dev"});
    
    // Create test files and initial commit
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "test.txt", .data = "Initial content\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "test.txt"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Initial commit"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Create test platform
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => return false,
                    else => return err,
                };
                return true;
            }
        };
    };
    
    // Test branch management
    var branch_manager = refs.BranchManager.init(allocator, git_dir);
    
    // Test creating a new branch
    try branch_manager.createBranch("feature", null, TestPlatform);
    
    // Verify branch was created
    const feature_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/feature", .{git_dir});
    defer allocator.free(feature_ref_path);
    
    const feature_exists = std.fs.cwd().access(feature_ref_path, .{}) catch false;
    try testing.expect(feature_exists);
    
    // Test resolving the new branch
    const feature_hash = try refs.resolveRef(git_dir, "feature", TestPlatform, allocator);
    try testing.expect(feature_hash != null);
    if (feature_hash) |hash| {
        defer allocator.free(hash);
        try testing.expect(hash.len == 40); // Should be a full SHA-1
    }
    
    // Test setting upstream (this will create config entries)
    try branch_manager.setUpstream("feature", "origin", "feature");
    
    std.debug.print("Branch management test completed successfully\n", .{});
}

test "ref name validation" {
    // Test valid ref names
    try testing.expect(refs.isValidRefName("master"));
    try testing.expect(refs.isValidRefName("feature/new"));
    try testing.expect(refs.isValidRefName("hotfix-123"));
    try testing.expect(refs.isValidRefName("v1.0.0"));
    
    // Test invalid ref names
    try testing.expect(!refs.isValidRefName(""));
    try testing.expect(!refs.isValidRefName("feature..bad"));
    try testing.expect(!refs.isValidRefName("feature~bad"));
    try testing.expect(!refs.isValidRefName("feature^bad"));
    try testing.expect(!refs.isValidRefName("feature:bad"));
    try testing.expect(!refs.isValidRefName("feature?bad"));
    try testing.expect(!refs.isValidRefName("feature*bad"));
    try testing.expect(!refs.isValidRefName("feature[bad"));
    try testing.expect(!refs.isValidRefName("feature bad")); // space
    
    std.debug.print("Ref name validation test completed successfully\n", .{});
}

/// Helper function to run git commands
fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var cmd = std.process.Child.init(args, allocator);
    cmd.cwd = cwd;
    cmd.stdout_behavior = .Ignore;
    cmd.stderr_behavior = .Ignore;
    
    const result = try cmd.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("Git command failed: {any}\n", .{args});
        return error.GitCommandFailed;
    }
}

test "enhanced ref resolution edge cases" {
    const allocator = testing.allocator;
    
    // Test ref resolution with invalid characters
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = alloc;
                _ = path;
                return error.FileNotFound;
            }
        };
    };
    
    // Test invalid ref names
    const invalid_refs = [_][]const u8{
        "bad ref", // space
        "bad~ref", // tilde
        "bad^ref", // caret
        "bad:ref", // colon
        "bad?ref", // question
        "bad*ref", // asterisk
        "bad[ref", // bracket
        "",        // empty
        "a\x00b",  // null character
        "bad\tref", // tab
        "bad\nref", // newline
        "bad\rref", // carriage return
        "bad\x7fref", // DEL character
    };
    
    for (invalid_refs) |invalid_ref| {
        const result = refs.resolveRef("/tmp", invalid_ref, TestPlatform, allocator);
        try testing.expectError(error.InvalidRefNameChar, result);
    }
    
    std.debug.print("Enhanced ref resolution edge cases test completed successfully\n", .{});
}