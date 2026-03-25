const std = @import("std");

pub fn main() !void {
    std.debug.print("=== Simple Git Compatibility Test ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test basic ziggit execution
    var proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "--version"}, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    
    try proc.spawn();
    
    const stdout = try proc.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(stdout);
    
    const term = try proc.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
    
    if (exit_code == 0) {
        std.debug.print("✅ ziggit --version works: {s}\n", .{stdout});
    } else {
        std.debug.print("❌ ziggit --version failed\n", .{});
        return;
    }
    
    // Test basic init workflow
    const temp_dir = "/tmp/simple-ziggit-test";
    
    // Clean up any previous test
    std.fs.cwd().deleteTree(temp_dir) catch {};
    try std.fs.cwd().makeDir(temp_dir);
    defer std.fs.cwd().deleteTree(temp_dir) catch {};
    
    // Test init
    var init_proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, allocator);
    init_proc.cwd = temp_dir;
    init_proc.stdout_behavior = .Pipe;
    init_proc.stderr_behavior = .Pipe;
    
    try init_proc.spawn();
    const init_term = try init_proc.wait();
    const init_exit_code: u8 = switch (init_term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
    
    if (init_exit_code == 0) {
        std.debug.print("✅ ziggit init works\n", .{});
    } else {
        std.debug.print("❌ ziggit init failed\n", .{});
        return;
    }
    
    // Check .git directory exists
    const git_dir = std.fs.path.join(allocator, &[_][]const u8{temp_dir, ".git"}) catch |err| {
        std.debug.print("❌ Failed to create git path: {}\n", .{err});
        return;
    };
    defer allocator.free(git_dir);
    
    std.fs.cwd().access(git_dir, .{}) catch {
        std.debug.print("❌ .git directory not created\n", .{});
        return;
    };
    
    std.debug.print("✅ .git directory created successfully\n", .{});
    std.debug.print("🎉 Basic git compatibility test PASSED!\n", .{});
}