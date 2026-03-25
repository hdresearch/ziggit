const std = @import("std");

pub fn main() !void {
    std.debug.print("=== Focused Commit Test ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_dir = "/tmp/focused-commit-test";
    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Initialize repo
    var init_proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "init"}, allocator);
    init_proc.cwd = test_dir;
    init_proc.stdout_behavior = .Pipe;
    init_proc.stderr_behavior = .Pipe;
    
    try init_proc.spawn();
    const init_stdout = try init_proc.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(init_stdout);
    const init_stderr = try init_proc.stderr.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(init_stderr);
    const init_term = try init_proc.wait();
    
    std.debug.print("Init result: exit={}, stdout='{s}', stderr='{s}'\n", .{ init_term, init_stdout, init_stderr });
    
    // Create file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir});
    defer allocator.free(file_path);
    
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("Test content\n");
    
    // Add file
    var add_proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "add", "test.txt"}, allocator);
    add_proc.cwd = test_dir;
    add_proc.stdout_behavior = .Pipe;
    add_proc.stderr_behavior = .Pipe;
    
    try add_proc.spawn();
    const add_stdout = try add_proc.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(add_stdout);
    const add_stderr = try add_proc.stderr.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(add_stderr);
    const add_term = try add_proc.wait();
    
    std.debug.print("Add result: exit={}, stdout='{s}', stderr='{s}'\n", .{ add_term, add_stdout, add_stderr });
    
    // Commit
    var commit_proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Test commit"}, allocator);
    commit_proc.cwd = test_dir;
    commit_proc.stdout_behavior = .Pipe;
    commit_proc.stderr_behavior = .Pipe;
    
    try commit_proc.spawn();
    const commit_stdout = try commit_proc.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(commit_stdout);
    const commit_stderr = try commit_proc.stderr.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(commit_stderr);
    const commit_term = try commit_proc.wait();
    
    std.debug.print("Commit result: exit={}, stdout='{s}', stderr='{s}'\n", .{ commit_term, commit_stdout, commit_stderr });
    
    const commit_exit_code: u8 = switch (commit_term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
    
    if (commit_exit_code == 0) {
        std.debug.print("✅ Commit succeeded!\n", .{});
    } else {
        std.debug.print("❌ Commit failed with exit code {d}\n", .{commit_exit_code});
    }
}