const std = @import("std");
const interface = @import("interface.zig");

var stdout_writer: ?std.fs.File.Writer = null;
var stderr_writer: ?std.fs.File.Writer = null;

fn getStdoutWriter() std.fs.File.Writer {
    if (stdout_writer == null) {
        stdout_writer = std.io.getStdOut().writer();
    }
    return stdout_writer.?;
}

fn getStderrWriter() std.fs.File.Writer {
    if (stderr_writer == null) {
        stderr_writer = std.io.getStdErr().writer();
    }
    return stderr_writer.?;
}

fn getArgsImpl(allocator: std.mem.Allocator) !interface.ArgIterator {
    // In WASI, we need to use initWithAllocator for args
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    
    var arg_list = std.ArrayList([]u8).init(allocator);
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
    getStdoutWriter().writeAll(data) catch |err| switch (err) {
        error.BrokenPipe => return, // Ignore broken pipe (e.g., piped to head/less)
        else => return err,
    };
}

fn writeStderrImpl(data: []const u8) !void {
    getStderrWriter().writeAll(data) catch |err| switch (err) {
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
        error.PathAlreadyExists => {}, // Ignore if directory already exists
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
    // WASI has limited filesystem capabilities
    // Try to get the current directory from the environment or use a default
    // In WASI, we're typically run with --dir pointing to the working directory
    // We could try to use std.process.getCwdAlloc but WASI may not support it
    return std.process.getCwdAlloc(allocator) catch try allocator.dupe(u8, ".");
}

fn chdirImpl(path: []const u8) !void {
    // WASI doesn't support changing directory in the same way
    // This is a limitation we'll document
    _ = path;
    return error.NotSupported;
}

fn readDirImpl(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close();
    
    var entries = std.ArrayList([]u8).init(allocator);
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

pub const wasi_platform = interface.Platform{
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