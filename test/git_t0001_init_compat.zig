const std = @import("std");
const fs = std.fs;
const process = std.process;

// Git t0001-init.sh compatibility tests
// Based on git source test suite for comprehensive init command testing

const TestFramework = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }
    
    fn runCommand(self: *TestFramework, args: []const []const u8, cwd: ?[]const u8) !struct { 
        exit_code: u32, 
        stdout: []u8, 
        stderr: []u8 
    } {
        var proc = process.Child.init(args, self.allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        if (cwd) |dir| {
            proc.cwd = dir;
        }
        
        proc.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                return .{
                    .exit_code = 127,
                    .stdout = try self.allocator.dupe(u8, ""),
                    .stderr = try self.allocator.dupe(u8, "command not found\n"),
                };
            },
            else => return err,
        };
        
        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        
        const result = try proc.wait();
        const exit_code = switch (result) {
            .Exited => |code| @as(u32, @intCast(code)),
            else => 1,
        };
        
        return .{
            .exit_code = exit_code,
            .stdout = stdout,
            .stderr = stderr,
        };
    }
    
    fn checkConfig(self: *TestFramework, git_dir: []const u8, expect_bare: bool, _: []const u8) !bool {
        // Check basic git directory structure
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
        defer self.allocator.free(config_path);
        
        const refs_path = try std.fmt.allocPrint(self.allocator, "{s}/refs", .{git_dir});
        defer self.allocator.free(refs_path);
        
        const objects_path = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{git_dir});
        defer self.allocator.free(objects_path);
        
        // Check if directory structure exists
        fs.cwd().access(git_dir, .{}) catch return false;
        fs.cwd().access(config_path, .{}) catch return false;
        fs.cwd().access(refs_path, .{}) catch return false;
        fs.cwd().access(objects_path, .{}) catch return false;
        
        // Check configuration using git config
        const bare_result = try self.runCommand(&[_][]const u8{ "git", "config", "--bool", "core.bare" }, git_dir);
        defer self.allocator.free(bare_result.stdout);
        defer self.allocator.free(bare_result.stderr);
        
        const expected_bare = if (expect_bare) "true\n" else "false\n";
        if (!std.mem.eql(u8, std.mem.trim(u8, bare_result.stdout, " \n\t"), std.mem.trim(u8, expected_bare, " \n\t"))) {
            return false;
        }
        
        return true;
    }
    
    fn cleanupTestDir(_: *TestFramework, dir: []const u8) void {
        fs.cwd().deleteTree(dir) catch {};
    }
};

pub fn runGitT0001InitCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    
    std.debug.print("Running git t0001-init compatibility tests...\n", .{});
    
    // Test plain init
    try testPlainInit(&tf);
    
    // Test bare init
    try testBareInit(&tf);
    
    // Test init in existing directory
    try testInitInExistingDir(&tf);
    
    // Test reinitialize
    try testReinitialize(&tf);
    
    // Test init with template (basic check)
    try testInitTemplate(&tf);
    
    // Test init with directory argument
    try testInitWithDir(&tf);
    
    std.debug.print("Git t0001-init compatibility tests completed!\n", .{});
}

fn testPlainInit(tf: *TestFramework) !void {
    std.debug.print("  Testing plain init...\n", .{});
    
    tf.cleanupTestDir("test-plain");
    
    // Create directory
    try fs.cwd().makeDir("test-plain");
    defer tf.cleanupTestDir("test-plain");
    
    // Test ziggit init
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, "test-plain");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Test git init for comparison
    tf.cleanupTestDir("test-plain-git");
    try fs.cwd().makeDir("test-plain-git");
    defer tf.cleanupTestDir("test-plain-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-plain-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        std.debug.print("    ✗ exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        return;
    }
    
    // Check repository structure
    const ziggit_config_ok = tf.checkConfig("test-plain/.git", false, "unset") catch false;
    const git_config_ok = tf.checkConfig("test-plain-git/.git", false, "unset") catch false;
    
    if (ziggit_config_ok and git_config_ok) {
        std.debug.print("    ✓ plain init\n", .{});
    } else {
        std.debug.print("    ✗ repository structure differs\n", .{});
    }
}

fn testBareInit(tf: *TestFramework) !void {
    std.debug.print("  Testing bare init...\n", .{});
    
    tf.cleanupTestDir("test-bare.git");
    
    // Test ziggit init --bare
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "--bare", "test-bare.git" }, null);
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Test git init --bare for comparison
    tf.cleanupTestDir("test-bare-git.git");
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "init", "--bare", "test-bare-git.git" }, null);
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    defer {
        tf.cleanupTestDir("test-bare.git");
        tf.cleanupTestDir("test-bare-git.git");
    }
    
    // Both should succeed
    if (ziggit_result.exit_code == 0 and git_result.exit_code == 0) {
        std.debug.print("    ✓ bare init\n", .{});
    } else {
        std.debug.print("    ✗ bare init exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testInitInExistingDir(tf: *TestFramework) !void {
    std.debug.print("  Testing init in existing directory...\n", .{});
    
    tf.cleanupTestDir("test-existing");
    
    // Create directory and add a file
    try fs.cwd().makeDir("test-existing");
    const file = try fs.cwd().createFile("test-existing/existing-file.txt", .{});
    defer file.close();
    try file.writeAll("existing content\n");
    
    defer tf.cleanupTestDir("test-existing");
    
    // Test ziggit init
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, "test-existing");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Should succeed and preserve existing file
    if (ziggit_result.exit_code == 0) {
        const file_exists = if (fs.cwd().access("test-existing/existing-file.txt", .{})) true else |_| false;
        if (file_exists) {
            std.debug.print("    ✓ init in existing directory\n", .{});
        } else {
            std.debug.print("    ✗ existing file was removed\n", .{});
        }
    } else {
        std.debug.print("    ✗ init in existing directory failed\n", .{});
    }
}

fn testReinitialize(tf: *TestFramework) !void {
    std.debug.print("  Testing reinitialize...\n", .{});
    
    tf.cleanupTestDir("test-reinit");
    
    // Create directory and initialize
    try fs.cwd().makeDir("test-reinit");
    defer tf.cleanupTestDir("test-reinit");
    
    // First init
    const first_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, "test-reinit");
    defer tf.*.allocator.free(first_result.stdout);
    defer tf.*.allocator.free(first_result.stderr);
    
    // Second init (reinitialize)
    const second_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, "test-reinit");
    defer tf.*.allocator.free(second_result.stdout);
    defer tf.*.allocator.free(second_result.stderr);
    
    // Both should succeed
    if (first_result.exit_code == 0 and second_result.exit_code == 0) {
        std.debug.print("    ✓ reinitialize\n", .{});
    } else {
        std.debug.print("    ✗ reinitialize failed: first={}, second={}\n", .{ first_result.exit_code, second_result.exit_code });
    }
}

fn testInitTemplate(tf: *TestFramework) !void {
    std.debug.print("  Testing init with template...\n", .{});
    
    tf.cleanupTestDir("test-template");
    
    // Test ziggit init --template (may not be implemented yet)
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "--template=/dev/null", "test-template" }, null);
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    defer tf.cleanupTestDir("test-template");
    
    // Git --template should work
    tf.cleanupTestDir("test-template-git");
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "init", "--template=/dev/null", "test-template-git" }, null);
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    defer tf.cleanupTestDir("test-template-git");
    
    // Compare exit codes
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ init with template\n", .{});
    } else {
        std.debug.print("    ⚠ init with template exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testInitWithDir(tf: *TestFramework) !void {
    std.debug.print("  Testing init with directory argument...\n", .{});
    
    tf.cleanupTestDir("test-newdir");
    
    // Test ziggit init <directory>
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "test-newdir" }, null);
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    defer tf.cleanupTestDir("test-newdir");
    
    // Test git init <directory> for comparison
    tf.cleanupTestDir("test-newdir-git");
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "init", "test-newdir-git" }, null);
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    defer tf.cleanupTestDir("test-newdir-git");
    
    // Both should succeed
    if (ziggit_result.exit_code == 0 and git_result.exit_code == 0) {
        std.debug.print("    ✓ init with directory argument\n", .{});
    } else {
        std.debug.print("    ✗ init with directory argument failed: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}