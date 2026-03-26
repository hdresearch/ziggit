const std = @import("std");

// These tests require network access to github.com.
// They test the native HTTPS clone/fetch pipeline end-to-end
// using the ziggit binary built by `zig build`.
// Run with: zig build https-test

fn getZiggitPath(allocator: std.mem.Allocator) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, "zig-out/bin/ziggit");
    return cwd;
}

fn runCmd(bin: []const u8, extra_args: []const []const u8, cwd: ?[]const u8) !u8 {
    var args = std.ArrayList([]const u8).init(std.testing.allocator);
    defer args.deinit();
    try args.append(bin);
    for (extra_args) |a| try args.append(a);

    var child = std.process.Child.init(args.items, std.testing.allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    if (cwd) |d| child.cwd = d;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 255,
    };
}

fn runCmdGetStdout(bin: []const u8, extra_args: []const []const u8, cwd: ?[]const u8) ![]u8 {
    var args = std.ArrayList([]const u8).init(std.testing.allocator);
    defer args.deinit();
    try args.append(bin);
    for (extra_args) |a| try args.append(a);

    var child = std.process.Child.init(args.items, std.testing.allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    if (cwd) |d| child.cwd = d;

    try child.spawn();

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    errdefer stdout_buf.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try stdout_buf.appendSlice(buf[0..n]);
    }

    const term = try child.wait();
    const code = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        stdout_buf.deinit();
        return error.CommandFailed;
    }
    return stdout_buf.toOwnedSlice();
}

fn tmpDir(comptime prefix: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    const name = try std.fmt.bufPrint(&buf, "/tmp/{s}-{d}", .{ prefix, ts });
    return try std.testing.allocator.dupe(u8, name);
}

fn cleanup(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

fn fileExists(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

test "clone --bare from public GitHub repo" {
    const bin = try getZiggitPath(std.testing.allocator);
    defer std.testing.allocator.free(bin);

    const target = try tmpDir("ziggit-test-bare");
    defer cleanup(target);

    const code = try runCmd(bin, &.{ "clone", "--bare", "https://github.com/octocat/Hello-World.git", target }, null);
    try std.testing.expectEqual(@as(u8, 0), code);

    // Verify bare repo structure
    var buf: [512]u8 = undefined;
    try std.testing.expect(fileExists(try std.fmt.bufPrint(&buf, "{s}/HEAD", .{target})));
    try std.testing.expect(dirExists(try std.fmt.bufPrint(&buf, "{s}/objects", .{target})));
    try std.testing.expect(dirExists(try std.fmt.bufPrint(&buf, "{s}/refs", .{target})));
}

test "fetch on already-cloned bare repo" {
    const bin = try getZiggitPath(std.testing.allocator);
    defer std.testing.allocator.free(bin);

    const target = try tmpDir("ziggit-test-fetch");
    defer cleanup(target);

    // Clone first
    const clone_code = try runCmd(bin, &.{ "clone", "--bare", "https://github.com/octocat/Hello-World.git", target }, null);
    try std.testing.expectEqual(@as(u8, 0), clone_code);

    // Fetch
    const fetch_code = try runCmd(bin, &.{ "fetch", "--quiet" }, target);
    try std.testing.expectEqual(@as(u8, 0), fetch_code);
}

test "rev-parse HEAD on cloned repo returns valid hash" {
    const bin = try getZiggitPath(std.testing.allocator);
    defer std.testing.allocator.free(bin);

    const target = try tmpDir("ziggit-test-revparse");
    defer cleanup(target);

    // Clone --no-checkout
    const clone_code = try runCmd(bin, &.{ "clone", "--no-checkout", "https://github.com/octocat/Hello-World.git", target }, null);
    try std.testing.expectEqual(@as(u8, 0), clone_code);

    // rev-parse HEAD
    const hash_raw = try runCmdGetStdout(bin, &.{ "rev-parse", "HEAD" }, target);
    defer std.testing.allocator.free(hash_raw);

    const hash = std.mem.trim(u8, hash_raw, " \t\n\r");
    try std.testing.expectEqual(@as(usize, 40), hash.len);

    // Verify it's all hex
    for (hash) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
