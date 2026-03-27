const std = @import("std");
const interface = @import("interface.zig");

fn getArgsImpl(allocator: std.mem.Allocator) !interface.ArgIterator {
    var args = std.process.args();
    var arg_list = std.array_list.Managed([]const u8).init(allocator);
    defer arg_list.deinit();
    
    while (args.next()) |arg| {
        const owned_arg = try allocator.dupe(u8, arg);
        try arg_list.append(owned_arg);
    }
    
    return interface.ArgIterator{
        .args = try arg_list.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn writeStdoutImpl(data: []const u8) !void {
    (std.fs.File{ .handle = std.posix.STDOUT_FILENO }).writeAll(data) catch |err| switch (err) {
        error.BrokenPipe => return, // Ignore broken pipe (e.g., piped to head/less)
        else => return err,
    };
}

fn writeStderrImpl(data: []const u8) !void {
    (std.fs.File{ .handle = std.posix.STDERR_FILENO }).writeAll(data) catch |err| switch (err) {
        error.BrokenPipe => return, // Ignore broken pipe (e.g., piped to head/less)
        else => return err,
    };
}

fn existsImpl(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn makeDirImpl(path: []const u8) !void {
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };
}

fn readFileImpl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn writeFileImpl(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn deleteFileImpl(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

fn getCwdImpl(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.getCwdAlloc(allocator);
}

fn chdirImpl(path: []const u8) !void {
    try std.process.changeCurDir(path);
}

fn readDirImpl(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();
    
    var entries = std.array_list.Managed([]u8).init(allocator);
    defer entries.deinit();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            const name = try allocator.dupe(u8, entry.name);
            try entries.append(name);
        }
    }
    
    return try entries.toOwnedSlice();
}

fn statImpl(path: []const u8) !std.fs.File.Stat {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.stat();
}

pub const native_platform = interface.Platform{
    .getArgs = getArgsImpl,
    .writeStdout = writeStdoutImpl,
    .writeStderr = writeStderrImpl,
    .fs = .{
        .exists = existsImpl,
        .makeDir = makeDirImpl,
        .readFile = readFileImpl,
        .writeFile = writeFileImpl,
        .deleteFile = deleteFileImpl,
        .getCwd = getCwdImpl,
        .chdir = chdirImpl,
        .readDir = readDirImpl,
        .stat = statImpl,
    },
};