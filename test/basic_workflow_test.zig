const std = @import("std");

fn execCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running basic workflow test...\n", .{});

    // Create temporary test directory
    const test_base_dir = "/tmp/ziggit_basic_test";
    std.fs.cwd().deleteTree(test_base_dir) catch {};
    try std.fs.cwd().makeDir(test_base_dir);
    defer std.fs.cwd().deleteTree(test_base_dir) catch {};

    std.debug.print("  Testing init...\n", .{});
    // Test init
    var result = try execCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_base_dir);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term.Exited != 0) {
        std.debug.print("    ❌ init failed: {s}\n", .{result.stderr});
        return;
    }
    
    // Check .git directory exists
    std.fs.cwd().access(test_base_dir ++ "/.git", .{}) catch {
        std.debug.print("    ❌ .git directory not created\n", .{});
        return;
    };
    std.debug.print("    ✓ init successful\n", .{});

    // Create a test file
    std.debug.print("  Testing add and status...\n", .{});
    const test_file_path = test_base_dir ++ "/test.txt";
    const test_file = try std.fs.cwd().createFile(test_file_path, .{});
    try test_file.writeAll("Hello, ziggit!");
    test_file.close();

    // Test status
    result = try execCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_base_dir);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term.Exited != 0) {
        std.debug.print("    ❌ status failed: {s}\n", .{result.stderr});
        return;
    }
    std.debug.print("    ✓ status successful\n", .{});

    // Test add
    result = try execCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, test_base_dir);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term.Exited != 0) {
        std.debug.print("    ❌ add failed: {s}\n", .{result.stderr});
        return;
    }
    std.debug.print("    ✓ add successful\n", .{});

    // Test commit
    std.debug.print("  Testing commit...\n", .{});
    result = try execCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_base_dir);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term.Exited != 0) {
        std.debug.print("    ❌ commit failed: {s}\n", .{result.stderr});
        return;
    }
    std.debug.print("    ✓ commit successful\n", .{});

    // Test log
    std.debug.print("  Testing log...\n", .{});
    result = try execCommand(allocator, &[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "log" }, test_base_dir);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    if (result.term.Exited != 0) {
        std.debug.print("    ❌ log failed: {s}\n", .{result.stderr});
        return;
    }
    std.debug.print("    ✓ log successful\n", .{});

    std.debug.print("🎉 Basic workflow test PASSED!\n", .{});
}